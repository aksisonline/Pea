// swift-tools-version:5.9
import PackageDescription

var targets: [Target] = [
    // All backend logic: link handling, yt-dlp, multi-connection HTTP downloads, app state.
    // Foundation-only so it builds on macOS, Linux and Windows.
    .target(name: "PeaCore", path: "Sources/PeaCore"),
    .testTarget(name: "PeaCoreTests", dependencies: ["PeaCore"], path: "Tests/PeaCoreTests"),
]
var products: [Product] = [.library(name: "PeaCore", targets: ["PeaCore"])]

#if os(macOS)
// macOS app: SwiftUI shell around PeaCore.
targets.append(.executableTarget(name: "Pea", dependencies: ["PeaCore"], path: "Sources/Pea"))
#endif

#if os(Linux) || os(Windows)
// Shared GTK4 + Cairo UI (see docs/PORTING.md). PeaUI is toolkit-only: platform executables hand it
// a `PlatformServices` through `runPea(services:)`.
targets.append(.systemLibrary(name: "CGTK", path: "Sources/CGTK", pkgConfig: "gtk4",
                              providers: [.apt(["libgtk-4-dev"]), .brew(["gtk4"])]))
targets.append(.target(name: "PeaUI", dependencies: ["PeaCore", "CGTK"], path: "Sources/PeaUI"))
#endif

#if os(Linux)
targets.append(.executableTarget(name: "PeaLinux", dependencies: ["PeaCore", "PeaUI", "CGTK"], path: "Sources/PeaLinux"))
products.append(.executable(name: "PeaLinux", targets: ["PeaLinux"]))
#endif

#if os(Windows)
// Windows platform services (clipboard, winget setup, tray icon). Win32 only; no UI.
targets.append(.target(name: "PeaWindowsPlatform", dependencies: ["PeaCore"], path: "Sources/PeaWindowsPlatform"))
// Windows app: WindowsServices + the shared UI module (Sources/PeaWindows/UIEntry.swift calls runPea).
targets.append(.executableTarget(name: "PeaWindows", dependencies: ["PeaCore", "PeaUI", "PeaWindowsPlatform"], path: "Sources/PeaWindows"))
products.append(.executable(name: "PeaWindows", targets: ["PeaWindows"]))
#endif

let package = Package(
    name: "Pea",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
