import CGTK
import DAllCore
import Foundation

/// Handle to the running UI, given to the platform shell (tray icon, global shortcuts, …).
@MainActor
public final class DAllUIApp {
    public let model: Model
    public let services: PlatformServices
    /// System accent colour (0...1 sRGB) the UI is using.
    public let accent: (r: Double, g: Double, b: Double)

    /// The shell sets this once it has a tray / status icon; it enables the window<->tray toggle.
    public var trayAvailable = false { didSet { trayChanged() } }
    /// True when the user chose tray mode: closing or toggling hides the window instead of quitting.
    public private(set) var trayMode = UserDefaults.standard.bool(forKey: "menuBarMode")

    private var observers: [() -> Void] = []
    let scene = Scene()
    var window: Ptr?
    var area: Ptr?
    var loop: OpaquePointer?

    init(model: Model, services: PlatformServices) {
        self.model = model
        self.services = services
        let a = Accent.resolve()
        scene.accent = a
        accent = (a.r, a.g, a.b)
    }

    /// Called after every model change (after the UI itself has updated).
    public func observe(_ f: @escaping () -> Void) { observers.append(f) }
    func notify() { observers.forEach { $0() } }

    /// A downloadable link is on the clipboard and the circle is lit.
    public var isArmed: Bool { if case .idle = model.phase { return model.suggestion != nil } else { return false } }
    public var isWorking: Bool { if case .working = model.phase { return true } else { return false } }

    public var windowVisible: Bool { window.map { gtk_widget_get_visible(cast($0, GtkWidget.self)) != 0 } ?? false }

    public func showWindow() {
        guard let w = window else { return }
        gtk_window_present(cast(w, GtkWindow.self))
    }
    public func hideWindow() { if let w = window { gtk_widget_set_visible(cast(w, GtkWidget.self), 0) } }
    /// Tray click: show (and jump into the choices if a fresh link is waiting) or hide.
    public func toggleWindow() {
        if windowVisible { hideWindow() } else { model.popoverOpened(); showWindow() }
    }
    public func quit() { if let l = loop { g_main_loop_quit(l) } }

    func setTrayMode(_ on: Bool) {
        guard on == false || trayAvailable else { return }
        trayMode = on
        UserDefaults.standard.set(on, forKey: "menuBarMode")
        scene.trayMode = on
        if on { hideWindow() } else { showWindow() }
        scene.requestFrame()
    }

    private func trayChanged() {
        scene.trayAvailable = trayAvailable
        if trayAvailable, trayMode { hideWindow() }
        if !trayAvailable, trayMode { trayMode = false; scene.trayMode = false; showWindow() }
        scene.trayMode = trayMode
        scene.requestFrame()
    }
}
