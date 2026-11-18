#if os(Windows)
import DAllCore
import DAllWindowsPlatform

// ===========================================================================================================
// THE ONLY SEAM BETWEEN THE WINDOWS PLATFORM LAYER AND THE SHARED UI.
//
// Integrated: DAllUI is a dependency of this target, so the real call below is compiled.
// assumes:
//
//     // module DAllUI
//     @MainActor public func runDAll(services: PlatformServices)     // never returns (runs the app loop)
//
// When merging: add the DAllUI target (and the SwiftCrossUI backend products it needs) to Package.swift, put
// "DAllUI" in the DAllWindows target's dependencies (marked in Package.swift), and adapt the one call below if the
// real name or shape differs. Optional: the UI may take a tray, e.g. `WindowsTray()` (conforms to DAllCore.TrayIcon).
// ===========================================================================================================
#if canImport(DAllUI)
import DAllUI

@MainActor
func launchSharedUI(services: PlatformServices) {
    runDAll(services: services)
}
#else
@MainActor
func launchSharedUI(services: PlatformServices) {
    // DAllUI isn't part of this package yet: say so instead of failing silently.
    fatalError("DAllUI is not linked. Add the shared UI target to DAllWindows (see Sources/DAllWindows/UIEntry.swift).")
}
#endif
#endif
