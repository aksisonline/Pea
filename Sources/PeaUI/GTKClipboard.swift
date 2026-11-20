import CGTK
import PeaCore
import Foundation

/// System clipboard through GDK (X11, Wayland and Windows alike). GDK's read is asynchronous, so we keep the
/// latest text cached: `changeToken` and `read()` are free to call every poll. The cache is refreshed from
/// GDK's "changed" signal, on window focus, and by a slow poll (see `PeaUIApp`).
public final class GTKClipboard: Clipboard {
    private var board: Ptr?
    private var text: String?
    private var token = 0

    public init() {}

    private func setup() {
        guard board == nil, GTKRuntime.ensureInit(), let display = gdk_display_get_default(),
              let cb = gdk_display_get_clipboard(display) else { return }
        board = Ptr(cb)
        connect(cb, "changed", thunk: thunk0, handler: { [weak self] in self?.refresh() } as V0)
        refresh()
    }

    public var changeToken: Int { setup(); return token }
    public func read() -> String? { setup(); return text }

    public func write(_ t: String) {
        setup()
        guard let b = board else { return }
        gdk_clipboard_set_text(op(b), t)
        adopt(t)
    }

    private func adopt(_ t: String?) {
        guard t != text else { return }
        text = t
        // FNV-1a: stable, cheap, and distinct for distinct texts.
        var h: UInt64 = 0xcbf29ce484222325
        for byte in (t ?? "").utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        token = Int(truncatingIfNeeded: h)
    }

    /// Re-reads the clipboard text; `done` runs on the main loop afterwards (even if nothing changed).
    public func refresh(_ done: (() -> Void)? = nil) {
        setup()
        guard let b = board else { done?(); return }
        let box = Unmanaged.passRetained(Box((self, done))).toOpaque()
        gdk_clipboard_read_text_async(op(b), nil, { src, res, user in
            let ctx = Unmanaged<Box<(GTKClipboard, (() -> Void)?)>>.fromOpaque(user!)
            let (me, done) = ctx.takeUnretainedValue().f
            ctx.release()
            if let src, let res, let c = gdk_clipboard_read_text_finish(op(Ptr(src)), res, nil) {
                me.adopt(String(cString: c))
                g_free(c)
            }
            done?()
        }, box)
    }
}
