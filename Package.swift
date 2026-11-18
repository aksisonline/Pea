// swift-tools-version:5.9
import PackageDescription

var targets: [Target] = [
    // All backend logic: link handling, yt-dlp, multi-connection HTTP downloads, app state.
    // Foundation-only so it builds on macOS, Linux and Windows.
    .target(name: "DAllCore", path: "Sources/DAllCore"),
    .testTarget(name: "DAllCoreTests", dependencies: ["DAllCore"], path: "Tests/DAllCoreTests"),
]
var products: [Product] = [.library(name: "DAllCore", targets: ["DAllCore"])]

#if os(macOS)
// macOS app: SwiftUI shell around DAllCore.
targets.append(.executableTarget(name: "DAll", dependencies: ["DAllCore"], path: "Sources/DAll"))
#endif

#if os(Linux) || os(Windows)
// Shared GTK4 + Cairo UI (see docs/PORTING.md). DAllUI is toolkit-only: platform executables hand it
// a `PlatformServices` through `runDAll(services:)`.
targets.append(.systemLibrary(name: "CGTK", path: "Sources/CGTK", pkgConfig: "gtk4",
                              providers: [.apt(["libgtk-4-dev"]), .brew(["gtk4"])]))
targets.append(.target(name: "DAllUI", dependencies: ["DAllCore", "CGTK"], path: "Sources/DAllUI"))
#endif

#if os(Linux)
targets.append(.executableTarget(name: "DAllLinux", dependencies: ["DAllCore", "DAllUI", "CGTK"], path: "Sources/DAllLinux"))
products.append(.executable(name: "DAllLinux", targets: ["DAllLinux"]))
#endif

#if os(Windows)
// Windows platform services (clipboard, winget setup, tray icon). Win32 only; no UI.
targets.append(.target(name: "DAllWindowsPlatform", dependencies: ["DAllCore"], path: "Sources/DAllWindowsPlatform"))
// Windows app: WindowsServices + the shared UI module (Sources/DAllWindows/UIEntry.swift calls runDAll).
targets.append(.executableTarget(name: "DAllWindows", dependencies: ["DAllCore", "DAllUI", "DAllWindowsPlatform"], path: "Sources/DAllWindows"))
products.append(.executable(name: "DAllWindows", targets: ["DAllWindows"]))
#endif

let package = Package(
    name: "DAll",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
