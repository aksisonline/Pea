import DAllCore
import DAllUI
import Foundation

@MainActor
final class LinuxServices: PlatformServices {
    let clipboard: Clipboard = GTKClipboard()
    private static let toolsStep = SetupStep(id: "tools", title: "Download tools", reason: "yt-dlp and ffmpeg do the work",
                                             icon: "tools", action: "Install")
    let setupSteps = [toolsStep]
    func isSatisfied(_ step: SetupStep) -> Bool { Tools.toolsInstalled }
    func perform(_ step: SetupStep, again: Bool) async -> SetupResult { .done }
}
