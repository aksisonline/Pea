import Foundation

/// The system clipboard. `changeToken` must change whenever the contents do (macOS: changeCount;
/// elsewhere: a hash of the text) and must be cheap — it's polled.
public protocol Clipboard: AnyObject {
    var changeToken: Int { get }
    func read() -> String?
    func write(_ text: String)
}

public enum SetupResult {
    case done
    case needsAction(String)           // shown under the step; the user taps again after doing it
    case failed(String)
}

/// Everything platform-specific the core needs. Each OS shell provides one of these.
@MainActor
public protocol PlatformServices: AnyObject {
    var clipboard: Clipboard { get }
    /// First-run steps in order (permissions, installing tools, …). Empty = no setup screen.
    var setupSteps: [SetupStep] { get }
    /// True when a step needs no action (e.g. tools already installed); it is skipped.
    func isSatisfied(_ step: SetupStep) -> Bool
    /// Carries out a step. `again` is true when the user taps a second time after a `.needsAction` note.
    func perform(_ step: SetupStep, again: Bool) async -> SetupResult
}

/// Where things live on this OS.
public enum Platform {
    #if os(Windows)
    public static let isWindows = true
    public static let pathSeparator = ";"
    public static let exeSuffix = ".exe"
    #else
    public static let isWindows = false
    public static let pathSeparator = ":"
    public static let exeSuffix = ""
    #endif

    /// Where finished downloads go.
    public static var downloadsDirectory: URL {
        #if os(Linux)
        // Honour XDG_DOWNLOAD_DIR / `xdg-user-dir DOWNLOAD` when set up, else ~/Downloads.
        if let dir = ProcessInfo.processInfo.environment["XDG_DOWNLOAD_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        #endif
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Directories searched for yt-dlp / ffmpeg in addition to PATH (GUI apps often get a bare PATH).
    public static var extraSearchPaths: [String] {
        let home = NSHomeDirectory()
        #if os(Windows)
        let env = ProcessInfo.processInfo.environment
        let local = env["LOCALAPPDATA"] ?? home + "\\AppData\\Local"
        return [
            local + "\\Microsoft\\WinGet\\Links",
            home + "\\scoop\\shims",
            (env["ChocolateyInstall"] ?? "C:\\ProgramData\\chocolatey") + "\\bin",
            home + "\\.local\\bin",
        ]
        #else
        return ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.deno/bin", "/usr/bin", "/bin",
                home + "/.nix-profile/bin", "/snap/bin"]
        #endif
    }
}
