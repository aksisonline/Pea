import CGTK
import Foundation

// Small helpers around GLib/GTK C interop: pointer casts, signal connection, timers.

typealias Ptr = UnsafeMutableRawPointer

protocol AnyGPtr { var gp: Ptr { get } }
extension UnsafeMutableRawPointer: AnyGPtr { var gp: Ptr { self } }
extension OpaquePointer: AnyGPtr { var gp: Ptr { Ptr(self) } }
extension UnsafeMutablePointer: AnyGPtr { var gp: Ptr { Ptr(self) } }

@inline(__always) func raw<T>(_ p: UnsafeMutablePointer<T>) -> Ptr { Ptr(p) }
@inline(__always) func raw(_ p: OpaquePointer) -> Ptr { Ptr(p) }
@inline(__always) func op(_ p: some AnyGPtr) -> OpaquePointer { OpaquePointer(p.gp) }
@inline(__always) func cast<T>(_ p: Ptr, _ t: T.Type) -> UnsafeMutablePointer<T> { p.assumingMemoryBound(to: T.self) }
@inline(__always) func cast<T, U>(_ p: UnsafeMutablePointer<T>, _ u: U.Type) -> UnsafeMutablePointer<U> {
    UnsafeMutableRawPointer(p).assumingMemoryBound(to: U.self)
}

final class Box<T> {
    let f: T
    init(_ f: T) { self.f = f }
}

/// Connects `handler` to a GObject signal through a C thunk. The box is intentionally retained for
/// the life of the process (our widgets live as long as the app).
func connect<T, F>(_ instance: some AnyGPtr, _ signal: String, thunk: F, handler: T) {
    let box = Unmanaged.passRetained(Box(handler)).toOpaque()
    g_signal_connect_data(instance.gp, signal, unsafeBitCast(thunk, to: GCallback.self), box, nil, GConnectFlags(rawValue: 0))
}

@inline(__always) func unbox<T>(_ u: Ptr?, _ t: T.Type) -> T {
    Unmanaged<Box<T>>.fromOpaque(u!).takeUnretainedValue().f
}

// Thunks, one per signal shape.
typealias V0 = () -> Void
let thunk0: @convention(c) (Ptr?, Ptr?) -> Void = { _, u in unbox(u, V0.self)() }
let thunk0Pspec: @convention(c) (Ptr?, Ptr?, Ptr?) -> Void = { _, _, u in unbox(u, V0.self)() }
let thunkBool0: @convention(c) (Ptr?, Ptr?) -> gboolean = { _, u in unbox(u, (() -> Bool).self)() ? 1 : 0 }

typealias VXY = (Double, Double) -> Void
let thunkXY: @convention(c) (Ptr?, Double, Double, Ptr?) -> Void = { _, x, y, u in unbox(u, VXY.self)(x, y) }

typealias VPress = (Int, Double, Double, Ptr) -> Void      // n_press, x, y, gesture
let thunkPress: @convention(c) (Ptr?, Int32, Double, Double, Ptr?) -> Void = { g, n, x, y, u in
    unbox(u, VPress.self)(Int(n), x, y, g!)
}
typealias VKey = (UInt32, UInt32) -> Bool                    // keyval, modifier state
let thunkKey: @convention(c) (Ptr?, UInt32, UInt32, UInt32, Ptr?) -> gboolean = { _, kv, _, st, u in
    unbox(u, VKey.self)(kv, st) ? 1 : 0
}
typealias VTip = (Int, Int, Ptr) -> Bool
let thunkTip: @convention(c) (Ptr?, Int32, Int32, gboolean, Ptr?, Ptr?) -> gboolean = { _, x, y, _, tip, u in
    unbox(u, VTip.self)(Int(x), Int(y), tip!) ? 1 : 0
}
typealias VPrepare = (Double, Double) -> Ptr?
let thunkPrepare: @convention(c) (Ptr?, Double, Double, Ptr?) -> Ptr? = { _, x, y, u in unbox(u, VPrepare.self)(x, y) }
typealias VDragBegin = (Ptr) -> Void
let thunkDragBegin: @convention(c) (Ptr?, Ptr?, Ptr?) -> Void = { s, d, u in unbox(u, VDragBegin.self)(s!) }
typealias VDragEnd = (Bool) -> Void
let thunkDragEnd: @convention(c) (Ptr?, Ptr?, gboolean, Ptr?) -> Void = { _, _, del, u in unbox(u, VDragEnd.self)(del != 0) }
typealias VDrop = (Ptr) -> Bool
let thunkDrop: @convention(c) (Ptr?, Ptr?, Double, Double, Ptr?) -> gboolean = { _, drop, _, _, u in
    unbox(u, VDrop.self)(drop!) ? 1 : 0
}
let thunkDragAction: @convention(c) (Ptr?, Ptr?, Double, Double, Ptr?) -> UInt32 = { _, _, _, _, _ in GDK_ACTION_COPY.rawValue }

/// Runs `f` once after `ms` milliseconds on the GLib main loop.
func after(ms: UInt32, _ f: @escaping () -> Void) {
    let box = Unmanaged.passRetained(Box(f)).toOpaque()
    g_timeout_add_full(G_PRIORITY_DEFAULT, ms, { u in
        let b = Unmanaged<Box<() -> Void>>.fromOpaque(u!)
        b.takeUnretainedValue().f()
        b.release()
        return 0
    }, box, nil)
}

/// Repeats `f` every `ms` milliseconds until the process ends.
func every(ms: UInt32, _ f: @escaping () -> Void) {
    let box = Unmanaged.passRetained(Box(f)).toOpaque()
    g_timeout_add_full(G_PRIORITY_DEFAULT, ms, { u in
        Unmanaged<Box<() -> Void>>.fromOpaque(u!).takeUnretainedValue().f()
        return 1
    }, box, nil)
}

func str(_ p: UnsafePointer<CChar>?) -> String? { p.map { String(cString: $0) } }

/// Monotonic seconds.
func nowSec() -> Double { Double(g_get_monotonic_time()) / 1_000_000 }

/// Process-wide GTK start-up, shared by the clipboard (which is created before the window).
public enum GTKRuntime {
    nonisolated(unsafe) private static var started = false
    @discardableResult
    public static func ensureInit() -> Bool {
        if started { return true }
        g_set_prgname("pea")
        g_set_application_name("Pea")
        setenv("GTK_THEME", "Adwaita:dark", 0)
        setenv("GTK_A11Y", "none", 0)     // no AT-SPI bus needed; silences warnings on minimal systems
        started = gtk_init_check() != 0
        return started
    }
}
