import DAllCore
import DAllUI
import Foundation

/// Linux specifics: GDK clipboard, and a single setup step that makes sure yt-dlp + ffmpeg exist.
/// There are no fake permission steps: the clipboard and the downloads folder need no grant on Linux.
@MainActor
final class LinuxServices: PlatformServices {
    let clipboard: Clipboard = GTKClipboard()

    private static let toolsStep = SetupStep(id: "tools", title: "Download tools", reason: "yt-dlp and ffmpeg do the work",
                                             icon: "tools", action: "Install")
    let setupSteps = [toolsStep]

    func isSatisfied(_ step: SetupStep) -> Bool { Tools.toolsInstalled }

    func perform(_ step: SetupStep, again: Bool) async -> SetupResult {
        let distro = Distro.current
        let command = distro.installCommand
        // Best effort without a terminal: yt-dlp through pipx/pip (user install, no root), ffmpeg through
        // polkit (a graphical password prompt). Anything that fails falls back to a copyable command.
        if Tools.ytdlp == nil { await installYtDlp() }
        if Tools.ffmpeg == nil, let pk = Tools.find("pkexec"), let args = distro.rootInstallArgs {
            _ = await Tools.capture(pk, args, timeout: 1200)
        }
        if Tools.toolsInstalled { return .done }
        clipboard.write(command)
        let note = "Run the copied command in a terminal, then tap again"
        return again ? .failed("Still missing — " + note.lowercased()) : .needsAction(note)
    }

    private func installYtDlp() async {
        if let pipx = Tools.find("pipx") {
            _ = await Tools.capture(pipx, ["install", "yt-dlp[default]"], timeout: 600)
        } else if let py = Tools.find("python3") {
            _ = await Tools.capture(py, ["-m", "pip", "install", "--user", "yt-dlp[default]"], timeout: 600)
        }
    }
}

/// Just enough distro knowledge to print the right install command.
struct Distro {
    var ids: [String]

    static var current: Distro {
        let text = (try? String(contentsOfFile: "/etc/os-release", encoding: .utf8)) ?? ""
        var ids = [String]()
        for line in text.split(separator: "\n") {
            for key in ["ID=", "ID_LIKE="] where line.hasPrefix(key) {
                ids += line.dropFirst(key.count).replacingOccurrences(of: "\"", with: "").split(separator: " ").map(String.init)
            }
        }
        return Distro(ids: ids)
    }

    private func has(_ names: String...) -> Bool { names.contains { ids.contains($0) } }

    var installCommand: String {
        let pipx = "pipx install \"yt-dlp[default]\""
        if has("debian", "ubuntu") { return "sudo apt install ffmpeg pipx && " + pipx }
        if has("fedora", "rhel", "centos") { return "sudo dnf install ffmpeg-free pipx && " + pipx }
        if has("arch") { return "sudo pacman -S --needed ffmpeg yt-dlp python-mutagen" }
        if has("suse", "opensuse") { return "sudo zypper install ffmpeg pipx && " + pipx }
        if has("alpine") { return "sudo apk add ffmpeg yt-dlp py3-mutagen" }
        return "pipx install \"yt-dlp[default]\"   # and install ffmpeg with your package manager"
    }

    /// Arguments for `pkexec` to install ffmpeg unattended, where we know how.
    var rootInstallArgs: [String]? {
        if has("debian", "ubuntu") { return ["apt-get", "install", "-y", "ffmpeg"] }
        if has("fedora", "rhel", "centos") { return ["dnf", "install", "-y", "ffmpeg-free"] }
        if has("arch") { return ["pacman", "-S", "--needed", "--noconfirm", "ffmpeg"] }
        if has("suse", "opensuse") { return ["zypper", "--non-interactive", "install", "ffmpeg"] }
        return nil
    }
}
