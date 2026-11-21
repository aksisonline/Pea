// swift-tools-version:5.9
import PackageDescription
import Foundation

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

#if os(Windows)
// GTK 4 for Windows (wingtk/gvsbuild, see scripts/setup-gtk-windows.ps1). SwiftPM's pkg-config parser can't read those
// .pc files (drive letters), so the include/lib layout is spelled out here instead.
let gtkRoot = (ProcessInfo.processInfo.environment["GTK_ROOT"] ?? "C:/gtk-build/gtk/x64/release").replacingOccurrences(of: "\\", with: "/")
let gtkIncludes = ["include", "include/gtk-4.0", "include/glib-2.0", "lib/glib-2.0/include", "include/pango-1.0", "include/harfbuzz",
                   "include/cairo", "include/gdk-pixbuf-2.0", "include/graphene-1.0", "lib/graphene-1.0/include"]
let gtkLibs = ["gtk-4", "pangocairo-1.0", "pango-1.0", "cairo", "cairo-gobject", "gdk_pixbuf-2.0", "gio-2.0", "gobject-2.0",
               "glib-2.0", "graphene-1.0", "harfbuzz"]
let gtkSwift: [SwiftSetting] = [.unsafeFlags(gtkIncludes.flatMap { ["-Xcc", "-I\(gtkRoot)/\($0)"] })]
let gtkLink: [LinkerSetting] = [.unsafeFlags(["-L", "\(gtkRoot)/lib"])] + gtkLibs.map { .linkedLibrary($0) }
#endif

#if os(Linux)
// Shared GTK4 + Cairo UI (see docs/PORTING.md). PeaUI is toolkit-only: platform executables hand it
// a `PlatformServices` through `runPea(services:)`.
targets.append(.systemLibrary(name: "CGTK", path: "Sources/CGTK", pkgConfig: "gtk4",
                              providers: [.apt(["libgtk-4-dev"]), .brew(["gtk4"])]))
targets.append(.target(name: "PeaUI", dependencies: ["PeaCore", "CGTK"], path: "Sources/PeaUI"))
#endif

#if os(Windows)
targets.append(.systemLibrary(name: "CGTK", path: "Sources/CGTK"))
targets.append(.target(name: "PeaUI", dependencies: ["PeaCore", "CGTK"], path: "Sources/PeaUI",
                       swiftSettings: gtkSwift, linkerSettings: gtkLink))
#endif

#if os(Linux)
targets.append(.executableTarget(name: "PeaLinux", dependencies: ["PeaCore", "PeaUI", "CGTK"], path: "Sources/PeaLinux"))
products.append(.executable(name: "PeaLinux", targets: ["PeaLinux"]))
#endif

#if os(Windows)
// Windows platform services (clipboard, winget setup, tray icon). Win32 only; no UI.
targets.append(.target(name: "PeaWindowsPlatform", dependencies: ["PeaCore"], path: "Sources/PeaWindowsPlatform"))
// Windows app: WindowsServices + the shared UI module (Sources/PeaWindows/UIEntry.swift calls runPea).
targets.append(.executableTarget(name: "PeaWindows", dependencies: ["PeaCore", "PeaUI", "PeaWindowsPlatform"], path: "Sources/PeaWindows",
                       swiftSettings: gtkSwift, linkerSettings: gtkLink))
products.append(.executable(name: "PeaWindows", targets: ["PeaWindows"]))
#endif

let package = Package(
    name: "Pea",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
