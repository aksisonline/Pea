#if os(Windows)
import Foundation
import PeaCore
import PeaWindowsPlatform

// A GUI-subsystem app has no console: send stderr (our messages and GTK/GLib warnings) to %LOCALAPPDATA%\Pea\pea.log
// so "it just doesn't start" is diagnosable. Truncated on every launch.
if let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"] {
    let dir = base + "\\Pea"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    _ = freopen(dir + "\\pea.log", "w", stderr)
    setvbuf(stderr, nil, _IONBF, 0)
}

// Entry point of the Windows app: build the Windows services, hand them to the shared UI.
MainActor.assumeIsolated {
    launchSharedUI(services: WindowsServices())
}
#else
#error("PeaWindows is the Windows executable; it is only built on Windows (see Package.swift).")
#endif
