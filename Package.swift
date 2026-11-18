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

let package = Package(
    name: "DAll",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
