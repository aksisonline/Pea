import DAllUI

// main.swift top-level code isn't main-actor isolated in Swift 5 mode, but it does run on the main thread.
MainActor.assumeIsolated {
    runDAll(services: LinuxServices())
}
