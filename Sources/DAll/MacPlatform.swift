import AppKit
import DAllCore
import SwiftUI

// MARK: Services

final class MacClipboard: Clipboard {
    var changeToken: Int { NSPasteboard.general.changeCount }
    func read() -> String? { NSPasteboard.general.string(forType: .string) }
    func write(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

@MainActor
final class MacServices: PlatformServices {
    let clipboard: Clipboard = MacClipboard()

    private static let clipboardStep = SetupStep(id: "clipboard", title: "Clipboard", reason: "To spot the links you copy",
                                                 icon: "clipboard", action: "Allow")
    private static let downloadsStep = SetupStep(id: "downloads", title: "Downloads folder", reason: "To save your files there",
                                                 icon: "download", action: "Allow")
    private static let toolsStep = SetupStep(id: "tools", title: "Download tools", reason: "yt-dlp and ffmpeg do the work",
                                             icon: "tools", action: "Install")
    let setupSteps = [clipboardStep, downloadsStep, toolsStep]

    func isSatisfied(_ step: SetupStep) -> Bool { step == Self.toolsStep && Tools.toolsInstalled }

    func perform(_ step: SetupStep, again: Bool) async -> SetupResult {
        switch step {
        case Self.clipboardStep:
            // Reading is what raises the system's "Allow Paste" prompt.
            _ = NSPasteboard.general.string(forType: .string)
            if #available(macOS 15.4, *) {
                switch NSPasteboard.general.accessBehavior {
                case .alwaysAllow: return .done
                case .alwaysDeny:
                    Self.openPrivacySettings()
                    return .needsAction("Allow it in System Settings, then tap again")
                default:
                    if again { return .done }                     // second tap: fine to keep being asked
                    Self.openPrivacySettings()
                    return .needsAction("Set “Paste from Other Apps” to Allow, then tap again")
                }
            }
            return .done
        case Self.downloadsStep:
            // Listing the folder raises the "Downloads Folder" prompt the first time.
            if (try? FileManager.default.contentsOfDirectory(atPath: Platform.downloadsDirectory.path)) != nil { return .done }
            Self.openPrivacySettings()
            return .needsAction("Allow Downloads access in System Settings, then tap again")
        default:
            return await installTools()
        }
    }

    private func installTools() async -> SetupResult {
        let command = "brew install yt-dlp ffmpeg"
        guard let brew = Tools.find("brew") else {
            clipboard.write(command)
            return .needsAction("Install Homebrew (brew.sh), then paste the copied command in Terminal")
        }
        _ = await Tools.capture(brew, ["install", "yt-dlp", "ffmpeg"], timeout: 1200)
        if Tools.toolsInstalled { return .done }
        clipboard.write(command)
        return .failed("Install failed — paste the copied command in Terminal")
    }

    private static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: Model wiring

extension Model: ObservableObject {
    /// The one model, wired to SwiftUI: state changes publish, and core `Motion`s become SwiftUI animations.
    @MainActor static let shared: Model = {
        Artwork.sampler = { data in await Task.detached { MacArtwork.sample(data) }.value }
        let m = Model(services: MacServices())
        m.onChange = { [weak m] in m?.objectWillChange.send() }
        m.animate = { motion, body in
            switch motion {
            case .snappy: withAnimation(.snappy) { body() }
            case .gentle: withAnimation(.easeInOut(duration: 0.5)) { body() }
            case .quick: withAnimation(.easeInOut(duration: 0.35)) { body() }
            }
        }
        return m
    }()
}

/// Settings read by the shell itself (not core state).
enum Settings {
    /// true = lives in the menu bar (no Dock icon / window). Observed through @AppStorage in views.
    static var menuBarMode: Bool {
        get { UserDefaults.standard.bool(forKey: "menuBarMode") }
        set { UserDefaults.standard.set(newValue, forKey: "menuBarMode") }
    }
}

// MARK: Mapping core types to AppKit / SwiftUI

enum MacArtwork {
    /// 16×16 RGB24 sample via CoreGraphics (no ffmpeg needed for this).
    static func sample(_ data: Data) -> [UInt8]? {
        let side = 16
        guard let img = NSImage(data: data),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let px = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var rgb = [UInt8]()
        rgb.reserveCapacity(side * side * 3)
        for i in 0..<(side * side) { rgb += [px[i * 4], px[i * 4 + 1], px[i * 4 + 2]] }
        return rgb
    }
}

extension Artwork {
    var nsImage: NSImage {
        if let i = native as? NSImage { return i }
        let i = NSImage(data: data) ?? NSImage()
        native = i
        return i
    }
    var colors: [Color] { palette.map { Color(red: $0.r, green: $0.g, blue: $0.b) } }
}

extension Source {
    var symbol: String {
        ["music": "music.note", "waveform": "waveform", "video": "play.rectangle.fill", "camera": "camera.fill",
         "chat": "text.bubble.fill", "pin": "pin.fill"][icon] ?? "globe"
    }
}

extension SetupStep {
    var symbol: String {
        ["clipboard": "doc.on.clipboard", "download": "arrow.down.to.line", "tools": "wrench.and.screwdriver"][icon] ?? "gearshape"
    }
}
