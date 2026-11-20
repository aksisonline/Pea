import CGTK
import PeaCore
import PeaUI
import Foundation

/// Tray icon over the StatusNotifierItem D-Bus protocol (KDE, GNOME with the AppIndicator extension,
/// XFCE, Cinnamon, …). Lights up in the accent colour when a downloadable link is copied. Best effort:
/// without a StatusNotifierWatcher on the bus nothing is registered and the app stays window-only.
///
/// Limits: no dbusmenu, so right-click just shows the window and middle-click quits.
@MainActor
final class Tray {
    private static let xml = """
    <node><interface name="org.kde.StatusNotifierItem">
      <method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
      <method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
      <method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
      <method name="Scroll"><arg type="i" direction="in"/><arg type="s" direction="in"/></method>
      <property name="Category" type="s" access="read"/><property name="Id" type="s" access="read"/>
      <property name="Title" type="s" access="read"/><property name="Status" type="s" access="read"/>
      <property name="WindowId" type="i" access="read"/><property name="IconName" type="s" access="read"/>
      <property name="IconPixmap" type="a(iiay)" access="read"/><property name="ItemIsMenu" type="b" access="read"/>
      <property name="Menu" type="o" access="read"/>
      <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
      <signal name="NewIcon"/><signal name="NewStatus"><arg type="s"/></signal>
    </interface></node>
    """

    nonisolated(unsafe) static var current: Tray?

    private let app: PeaUIApp
    private var conn: OpaquePointer?
    private var kind = "idle"

    /// Returns nil when there is no tray host to talk to.
    static func start(app: PeaUIApp) -> Tray? {
        let t = Tray(app: app)
        guard t.register() else { return nil }
        current = t
        return t
    }

    private init(app: PeaUIApp) { self.app = app }

    private func register() -> Bool {
        guard let bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nil, nil) else { return false }
        // Is anyone hosting a tray?
        guard let has = g_dbus_connection_call_sync(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                                                    "NameHasOwner", g_variant_new_tuple([g_variant_new_string("org.kde.StatusNotifierWatcher")], 1),
                                                    nil, G_DBUS_CALL_FLAGS_NONE, 400, nil, nil) else { return false }
        let child = g_variant_get_child_value(has, 0)
        let present = child.map { g_variant_get_boolean($0) != 0 } ?? false
        guard present else { return false }
        conn = bus

        guard let node = g_dbus_node_info_new_for_xml(Self.xml, nil), let iface = node.pointee.interfaces[0] else { return false }
        let vt = UnsafeMutablePointer<GDBusInterfaceVTable>.allocate(capacity: 1)
        vt.initialize(to: GDBusInterfaceVTable())
        vt.pointee.method_call = { _, _, _, _, method, _, inv, _ in
            let m = String(cString: method!)
            MainActor.assumeIsolated {
                guard let app = Tray.current?.app else { return }
                switch m {
                case "Activate": app.toggleWindow()
                case "ContextMenu": app.showWindow()
                case "SecondaryActivate": app.quit()
                default: break
                }
            }
            g_dbus_method_invocation_return_value(inv, nil)
        }
        vt.pointee.get_property = { _, _, _, _, prop, _, _ in
            MainActor.assumeIsolated { Tray.current?.property(String(cString: prop!)) }
        }
        guard g_dbus_connection_register_object(bus, "/StatusNotifierItem", iface, vt, nil, nil, nil) != 0 else { return false }

        let name = "org.kde.StatusNotifierItem-\(getpid())-1"
        g_bus_own_name_on_connection(bus, name, G_BUS_NAME_OWNER_FLAGS_NONE, nil, nil, nil, nil)
        _ = g_dbus_connection_call_sync(bus, "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher",
                                        "RegisterStatusNotifierItem", g_variant_new_tuple([g_variant_new_string(name)], 1),
                                        nil, G_DBUS_CALL_FLAGS_NONE, 1000, nil, nil)
        app.observe { [weak self] in self?.refresh() }
        return true
    }

    private func refresh() {
        let k = app.isArmed ? "armed" : app.isWorking ? "working" : "idle"
        guard k != kind, let conn else { return }
        kind = k
        g_dbus_connection_emit_signal(conn, nil, "/StatusNotifierItem", "org.kde.StatusNotifierItem", "NewIcon", nil, nil)
        g_dbus_connection_emit_signal(conn, nil, "/StatusNotifierItem", "org.kde.StatusNotifierItem", "NewStatus",
                                      g_variant_new_tuple([g_variant_new_string(k == "armed" ? "NeedsAttention" : "Active")], 1), nil)
    }

    func property(_ name: String) -> OpaquePointer? {
        switch name {
        case "Category": return g_variant_new_string("ApplicationStatus")
        case "Id": return g_variant_new_string("pea")
        case "Title": return g_variant_new_string("Pea")
        case "Status": return g_variant_new_string(kind == "armed" ? "NeedsAttention" : "Active")
        case "WindowId": return g_variant_new_int32(0)
        case "IconName": return g_variant_new_string("")
        case "ItemIsMenu": return g_variant_new_boolean(0)
        case "Menu": return g_variant_new_object_path("/NO_DBUSMENU")
        case "IconPixmap": return pixmaps()
        case "ToolTip":
            let t = g_variant_type_new("(iiay)")
            let empty = g_variant_new_array(t, nil, 0)
            return g_variant_new_tuple([g_variant_new_string(""), empty, g_variant_new_string("Pea"),
                                        g_variant_new_string(kind == "armed" ? "Link ready — click to download" : "")], 4)
        default: return nil
        }
    }

    private func pixmaps() -> OpaquePointer? {
        let size = 32
        guard let s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(size), Int32(size)), let cr = cairo_create(s) else { return nil }
        let c = Double(size) / 2, a = app.accent
        func arrow(_ r: Double, _ g: Double, _ b: Double) {
            cairo_set_source_rgb(cr, r, g, b); cairo_set_line_width(cr, 2.6)
            cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND); cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
            cairo_move_to(cr, c, c - 6.5); cairo_line_to(cr, c, c + 6.5)
            cairo_move_to(cr, c - 5, c + 1.5); cairo_line_to(cr, c, c + 6.5); cairo_line_to(cr, c + 5, c + 1.5)
            cairo_stroke(cr)
        }
        cairo_new_sub_path(cr)
        cairo_arc(cr, c, c, 13, 0, 2 * .pi)
        if kind == "armed" {
            cairo_set_source_rgb(cr, a.r, a.g, a.b); cairo_fill(cr); arrow(1, 1, 1)
        } else {
            cairo_set_source_rgb(cr, 0.86, 0.86, 0.86); cairo_set_line_width(cr, 2.4); cairo_stroke(cr)
            if kind == "working" {
                cairo_new_sub_path(cr); cairo_arc(cr, c, c, 13, -.pi / 2, .pi / 2)
                cairo_set_source_rgb(cr, a.r, a.g, a.b); cairo_stroke(cr)
            }
            arrow(0.86, 0.86, 0.86)
        }
        cairo_destroy(cr)
        cairo_surface_flush(s)
        let src = cairo_image_surface_get_data(s)!, stride = Int(cairo_image_surface_get_stride(s))
        var out = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = y * stride + x * 4, o = (y * size + x) * 4
                let al = Int(src[i + 3])
                func un(_ v: UInt8) -> UInt8 { al == 0 ? 0 : UInt8(min(255, Int(v) * 255 / al)) }
                out[o] = UInt8(al); out[o + 1] = un(src[i + 2]); out[o + 2] = un(src[i + 1]); out[o + 3] = un(src[i])
            }
        }
        cairo_surface_destroy(s)
        let bytes = g_variant_new_fixed_array(g_variant_type_new("y"), out, gsize(out.count), 1)
        let st = g_variant_new_tuple([g_variant_new_int32(Int32(size)), g_variant_new_int32(Int32(size)), bytes], 3)
        var kids: [OpaquePointer?] = [st]
        return kids.withUnsafeMutableBufferPointer { g_variant_new_array(nil, $0.baseAddress, 1) }
    }
}
