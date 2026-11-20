#if os(Windows)
import PeaCore
import PeaWindowsPlatform

// ===========================================================================================================
// THE ONLY SEAM BETWEEN THE WINDOWS PLATFORM LAYER AND THE SHARED UI.
//
// Integrated: PeaUI is a dependency of this target, so the real call below is compiled.
// assumes:
//
//     // module PeaUI
//     @MainActor public func runPea(services: PlatformServices)     // never returns (runs the app loop)
//
// When merging: add the PeaUI target (and the SwiftCrossUI backend products it needs) to Package.swift, put
// "PeaUI" in the PeaWindows target's dependencies (marked in Package.swift), and adapt the one call below if the
// real name or shape differs. Optional: the UI may take a tray, e.g. `WindowsTray()` (conforms to PeaCore.TrayIcon).
// ===========================================================================================================
#if canImport(PeaUI)
import PeaUI

@MainActor
func launchSharedUI(services: PlatformServices) {
    runPea(services: services)
}
#else
@MainActor
func launchSharedUI(services: PlatformServices) {
    // PeaUI isn't part of this package yet: say so instead of failing silently.
    fatalError("PeaUI is not linked. Add the shared UI target to PeaWindows (see Sources/PeaWindows/UIEntry.swift).")
}
#endif
#endif
