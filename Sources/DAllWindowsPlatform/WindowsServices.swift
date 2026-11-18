#if os(Windows)
import DAllCore
import Foundation

/// Windows first-run setup: no permission prompts exist, so the only step is making sure yt-dlp and ffmpeg are present.
@MainActor
public final class WindowsServices: PlatformServices {
    public let clipboard: Clipboard = WindowsClipboard()

    private static let toolsStep = SetupStep(id: "tools", title: "Download tools", reason: "yt-dlp and ffmpeg do the work",
                                             icon: "tools", action: "Install")
    public let setupSteps = [toolsStep]

    public init() {}

    public func isSatisfied(_ step: SetupStep) -> Bool { step == Self.toolsStep && Tools.toolsInstalled }

    public func perform(_ step: SetupStep, again: Bool) async -> SetupResult { await installTools() }

    /// Copyable fallback. `;` works in PowerShell (the default terminal), unlike `&&` in Windows PowerShell 5.1.
    static let manualCommand = "winget install yt-dlp.yt-dlp; winget install Gyan.FFmpeg"

    private func installTools() async -> SetupResult {
        guard let winget = Tools.find("winget") else {
            clipboard.write(Self.manualCommand)
            return .needsAction("Install “App Installer” from the Microsoft Store (it provides winget), or install yt-dlp and ffmpeg yourself. The winget command is copied")
        }
        // One package per call (winget install takes a single package). Nonzero exits like "already installed"
        // are normal, so the only judge is whether the tools can be found afterwards. The running process won't see
        // the updated PATH; Tools.find searches winget's Links and Packages folders directly (Platform.extraSearchPaths).
        let packages = [(Tools.ytdlp == nil ? "yt-dlp.yt-dlp" : nil), (Tools.ffmpeg == nil ? "Gyan.FFmpeg" : nil)].compactMap { $0 }
        for id in packages {
            _ = await Tools.capture(winget, ["install", "--id", id, "--exact", "--silent",
                                             "--accept-package-agreements", "--accept-source-agreements"], timeout: 1200)
        }
        if Tools.toolsInstalled { return .done }
        clipboard.write(Self.manualCommand)
        return .failed("Install failed. Paste the copied command in PowerShell, then tap again")
    }
}
#endif
