import CGTK
import Foundation

/// The system accent colour when the OS gives one (xdg-desktop-portal `accent-color`, GNOME 47+/KDE),
/// `PEA_ACCENT=#rrggbb` when set, else the macOS-style blue.
enum Accent {
    static let fallback = Col(0.04, 0.52, 1.0)

    static func resolve() -> Col {
        if let hex = ProcessInfo.processInfo.environment["PEA_ACCENT"], let c = parse(hex) { return c }
        #if os(Linux)
        if let c = portal() { return c }
        #endif
        return fallback
    }

    static func parse(_ s: String) -> Col? {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return Col(Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255)
    }

    #if os(Linux)
    private static func portal() -> Col? {
        guard let bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nil, nil) else { return nil }
        defer { g_object_unref(Ptr(bus)) }
        var kids: [OpaquePointer?] = [g_variant_new_string("org.freedesktop.appearance"), g_variant_new_string("accent-color")]
        let params = kids.withUnsafeMutableBufferPointer { g_variant_new_tuple($0.baseAddress, 2) }
        guard let res = g_dbus_connection_call_sync(bus, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
                                                    "org.freedesktop.portal.Settings", "ReadOne", params, nil,
                                                    G_DBUS_CALL_FLAGS_NONE, 400, nil, nil) else { return nil }
        defer { g_variant_unref(res) }
        guard let boxed = g_variant_get_child_value(res, 0), let inner = g_variant_get_variant(boxed) else { return nil }
        defer { g_variant_unref(boxed); g_variant_unref(inner) }
        guard g_variant_n_children(inner) == 3 else { return nil }
        var v = [Double]()
        for i in 0..<3 {
            guard let d = g_variant_get_child_value(inner, gsize(i)) else { return nil }
            v.append(g_variant_get_double(d)); g_variant_unref(d)
        }
        guard v.allSatisfy({ $0 >= 0 && $0 <= 1 }) else { return nil }
        return Col(v[0], v[1], v[2])
    }
    #endif
}
