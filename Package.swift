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

let package = Package(
    name: "DAll",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
