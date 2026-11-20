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
        #if os(Windows)
        // The real (possibly relocated / OneDrive-redirected) Downloads known folder.
        if let dir = windowsDownloads { return URL(fileURLWithPath: dir, isDirectory: true) }
        #endif
        #if os(Linux)
        // Honour XDG_DOWNLOAD_DIR / `xdg-user-dir DOWNLOAD` when set up, else ~/Downloads.
        if let dir = ProcessInfo.processInfo.environment["XDG_DOWNLOAD_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        #endif
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Downloads", isDirectory: true)
    }

    #if os(Windows)
    private static let windowsDownloads: String? = KnownFolders.downloads()
    #endif

    /// Per-user app data (settings file).
    public static var supportDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        #if os(Windows)
        let base = env["APPDATA"] ?? NSHomeDirectory() + "\\AppData\\Roaming"
        return URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("Pea", isDirectory: true)
        #elseif os(Linux)
        let base = env["XDG_CONFIG_HOME"] ?? NSHomeDirectory() + "/.config"
        return URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("pea", isDirectory: true)
        #else
        return URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Pea", isDirectory: true)
        #endif
    }

    /// A path to hand to another program. On Windows `URL.path` can come back as `/C:/Users/x` or with forward
    /// slashes depending on the Foundation version; programs want `C:\Users\x`.
    public static func nativePath(_ url: URL, windows: Bool = isWindows) -> String {
        windows ? windowsPath(fromURLPath: url.path) : url.path
    }

    public static func windowsPath(fromURLPath p: String) -> String {
        var s = p
        let u = Array(s.utf8)
        if u.count >= 3, u[0] == 0x2F, u[2] == 0x3A, (u[1] | 0x20) >= 0x61, (u[1] | 0x20) <= 0x7A { s.removeFirst() }   // "/C:/…"
        return s.replacingOccurrences(of: "/", with: "\\")
    }

    /// Joins a directory and a file name with this OS's separator (NSString would always use "/").
    public static func join(_ dir: String, _ name: String) -> String {
        if dir.isEmpty { return name }
        let sep = isWindows ? "\\" : "/"
        return dir.hasSuffix(sep) || (isWindows && dir.hasSuffix("/")) ? dir + name : dir + sep + name
    }

    /// Where the helper programs shipped inside the app live: `Pea.app/Contents/Resources/bin` on macOS,
    /// `<install dir>/tools` on Linux (.deb) and Windows (zip). Nothing needs installing.
    public static var bundledToolDirs: [String] {
        var dirs: [String] = []
        if let r = Bundle.main.resourceURL { dirs.append(nativePath(r.appendingPathComponent("bin", isDirectory: true))) }
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
            dirs.append(nativePath(exe.appendingPathComponent("tools", isDirectory: true)))
        }
        return dirs
    }

    /// A user-writable copy of yt-dlp that the app keeps up to date (sites change faster than app releases).
    public static var updatedToolsDirectory: URL { supportDirectory.appendingPathComponent("bin", isDirectory: true) }

    /// Tools to try first: the self-updated yt-dlp, then what ships inside the app, then whatever the system has.
    public static var extraSearchPaths: [String] {
        [nativePath(updatedToolsDirectory)] + bundledToolDirs + systemSearchPaths
    }

    /// Directories searched for yt-dlp / ffmpeg in addition to PATH (GUI apps often get a bare PATH; and a
    /// process never sees a PATH change made after it started, e.g. by `winget install`).
    private static var systemSearchPaths: [String] {
        let home = NSHomeDirectory()
        #if os(Windows)
        let env = ProcessInfo.processInfo.environment
        func e(_ k: String) -> String? { env.first { $0.key.caseInsensitiveCompare(k) == .orderedSame }?.value }
        let local = e("LOCALAPPDATA") ?? home + "\\AppData\\Local"
        let programFiles = e("ProgramFiles") ?? "C:\\Program Files"
        var dirs = [
            local + "\\Microsoft\\WinGet\\Links",                    // winget portable-package aliases (user scope)
            programFiles + "\\WinGet\\Links",                          // machine scope
            local + "\\Microsoft\\WindowsApps",                        // winget.exe itself
            (e("SCOOP") ?? home + "\\scoop") + "\\shims",
            (e("ChocolateyInstall") ?? "C:\\ProgramData\\chocolatey") + "\\bin",
            home + "\\.local\\bin",
        ]
        dirs += expandPackageDirs(root: local + "\\Microsoft\\WinGet\\Packages") { dir in
            (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        }
        return dirs
        #else
        return ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.deno/bin", "/usr/bin", "/bin",
                home + "/.nix-profile/bin", "/snap/bin"]
        #endif
    }

    /// winget "portable" packages live under `Packages\<Id>_<source>\`; the binary is at the top (yt-dlp) or under
    /// `<unzipped folder>\bin` (Gyan.FFmpeg). Returns candidate folders for the yt-dlp / ffmpeg packages.
    public static func expandPackageDirs(root: String, list: (String) -> [String]) -> [String] {
        var out: [String] = []
        for pkg in list(root).sorted() {
            let l = pkg.lowercased()
            guard l.contains("yt-dlp") || l.contains("ffmpeg") else { continue }
            let dir = root + "\\" + pkg
            out.append(dir)
            out.append(dir + "\\bin")
            for sub in list(dir).sorted() { out.append(dir + "\\" + sub + "\\bin") }
        }
        return out
    }
}
