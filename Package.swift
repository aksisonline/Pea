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

#if os(Windows)
// Windows platform services (clipboard, winget setup, tray icon). Win32 only; no UI.
targets.append(.target(name: "DAllWindowsPlatform", dependencies: ["DAllCore"], path: "Sources/DAllWindowsPlatform"))
// Windows app: WindowsServices + the shared UI module. Integration: add the shared UI target (e.g. "DAllUI")
// to `dependencies` below and to `targets`; Sources/DAllWindows/UIEntry.swift switches on `canImport(DAllUI)`.
targets.append(.executableTarget(name: "DAllWindows", dependencies: ["DAllCore", "DAllWindowsPlatform"], path: "Sources/DAllWindows"))
products.append(.executable(name: "DAllWindows", targets: ["DAllWindows"]))
#endif

let package = Package(
    name: "DAll",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
