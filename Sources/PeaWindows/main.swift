#if os(Windows)
import PeaCore
import PeaWindowsPlatform

// Entry point of the Windows app: build the Windows services, hand them to the shared UI.
MainActor.assumeIsolated {
    launchSharedUI(services: WindowsServices())
}
#else
#error("PeaWindows is the Windows executable; it is only built on Windows (see Package.swift).")
#endif
