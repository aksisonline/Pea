import CGTK
import DAllCore
import Foundation

/// `DALL_DEBUG=<screen>` forces a screen for screenshots / visual review:
/// idle armed armed-noart hint kind video audio working[:0.42] comet done done-file failed setup1 setup2 setup3 ready.
/// `DALL_DEBUG_HOVER=1` also puts the (virtual) pointer over the circle.
@MainActor
enum Debug {
    static var name: String? { ProcessInfo.processInfo.environment["DALL_DEBUG"] }
    static var hover: Bool { ProcessInfo.processInfo.environment["DALL_DEBUG_HOVER"] == "1" }

    private static func png(_ top: (Double, Double, Double), _ bottom: (Double, Double, Double), name: String) -> Data? {
        guard let s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 320, 320), let cr = cairo_create(s) else { return nil }
        setGradient(cr, 0, 0, 320, 320, [(0, Col(top.0, top.1, top.2)), (1, Col(bottom.0, bottom.1, bottom.2))])
        cairo_paint(cr)
        fillCircle(cr, 220, 110, 60, Col(1, 0.85, 0.3, 0.9))
        fillCircle(cr, 90, 240, 80, Col(0.1, 0.1, 0.3, 0.5))
        cairo_destroy(cr)
        let path = NSTemporaryDirectory() + "dall-debug-\(name).png"
        cairo_surface_write_to_png(s, path)
        cairo_surface_destroy(s)
        return FileManager.default.contents(atPath: path)
    }

    private static func art() -> Artwork? {
        guard let d = png((0.95, 0.35, 0.25), (0.2, 0.25, 0.75), name: "art") else { return nil }
        return Artwork(data: d, palette: [RGB(0.98, 0.45, 0.30), RGB(0.40, 0.50, 0.95), RGB(1, 0.85, 0.3)])
    }

    private static let steps = [
        SetupStep(id: "clipboard", title: "Clipboard", reason: "To spot the links you copy", icon: "clipboard", action: "Allow"),
        SetupStep(id: "downloads", title: "Downloads folder", reason: "To save your files there", icon: "download", action: "Allow"),
        SetupStep(id: "tools", title: "Download tools", reason: "yt-dlp and ffmpeg do the work", icon: "tools", action: "Install"),
    ]

    static func state(_ name: String, model: Model) -> ViewState? {
        var s = ViewState()
        let yt = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        let title = "Never Gonna Give You Up (Official Video)"
        let parts = name.split(separator: ":").map(String.init)
        switch parts[0] {
        case "idle": break
        case "armed", "armed-noart":
            let a = parts[0] == "armed" ? art() : nil
            s.suggestion = Suggestion(url: yt, title: title, art: a, source: Source.of(yt)); s.art = a; s.badge = Source.of(yt)
        case "hint":
            s.hint = Suggestion(url: yt, title: title, art: art(), source: Source.of(yt))
        case "hint-noart":
            s.hint = Suggestion(url: yt, title: nil, art: nil, source: Source.of(yt))
        case "kind": s.screen = .kind; s.art = art()
        case "video": s.screen = .quality(.video); s.art = art()
        case "audio": s.screen = .quality(.audio); s.art = art()
        case "working":
            s.screen = .working; s.art = art(); s.badge = Source.of(yt); s.progress = Double(parts.dropFirst().first ?? "0.42") ?? 0.42
        case "comet": s.screen = .working; s.art = art(); s.badge = Source.of(yt)
        case "done", "done-file":
            let p = NSTemporaryDirectory() + (parts[0] == "done" ? "dall-debug-art.png" : "Never Gonna Give You Up.mp4")
            if parts[0] == "done" { _ = art() } else { FileManager.default.createFile(atPath: p, contents: Data()) }
            s.screen = .done(URL(fileURLWithPath: p))
        case "failed": s.screen = .failed("Video unavailable")
        case "setup1", "setup2", "setup3":
            let i = Int(parts[0].dropFirst(5))! - 1
            s.screen = .setup(steps[i].id); s.setupStep = steps[i]; s.setupDone = i; s.setupTotal = 3
            if parts.count > 1 { s.setupNote = "Allow it in Settings, then tap again" }
        case "ready": s.screen = .ready; s.setupTotal = 3
        default: return nil
        }
        s.audioFormat = model.audioFormat
        return s
    }
}
