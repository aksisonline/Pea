import DAllUI

// main.swift top-level code isn't main-actor isolated in Swift 5 mode, but it does run on the main thread.
MainActor.assumeIsolated {
    runDAll(services: LinuxServices()) { app in
        // Tray / status icon when the desktop has one; otherwise stay window-only.
        if Tray.start(app: app) != nil { app.trayAvailable = true }
    }
}
