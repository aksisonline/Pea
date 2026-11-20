import AppKit
import PeaCore
import SwiftUI

@main
struct PeaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @AppStorage("menuBarMode") private var menuBarMode = false

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(Model.shared)
                .frame(width: 232, height: 266)
                .background(WindowConfig())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .pasteboard) {
                Button("Paste Link") { Model.shared.paste() }
            }
        }

        // SwiftUI writes `false` back into this binding when the system reports the status item as hidden
        // (e.g. a stale "VisibleCC" flag), which silently dropped us out of menu bar mode and quit the app.
        // Only our own toggle may change the mode.
        MenuBarExtra(isInserted: Binding(get: { menuBarMode }, set: { _ in })) {
            ContentView()
                .environmentObject(Model.shared)
                .frame(width: 232, height: 266)
        } label: {
            MenuLabel().environmentObject(Model.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu-bar icon: plain template glyph normally, lit in the accent colour when a downloadable link is copied.
struct MenuLabel: View {
    @EnvironmentObject var model: Model

    var body: some View {
        let armed: Bool = {
            if case .idle = model.phase { return model.suggestion != nil }
            return false
        }()
        let working: Bool = { if case .working = model.phase { return true } else { return false } }()
        Image(nsImage: MenuIcon.image(armed: armed, working: working))
    }
}

enum MenuIcon {
    static func image(armed: Bool, working: Bool) -> NSImage {
        if armed {
            let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
                let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
                    .applying(.init(paletteColors: [.white]))
                if let sym = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
                    .withSymbolConfiguration(cfg) {
                    let sz = sym.size
                    sym.draw(in: NSRect(x: (r.width - sz.width) / 2, y: (r.height - sz.height) / 2,
                                        width: sz.width, height: sz.height))
                }
                return true
            }
            img.isTemplate = false
            return img
        }
        let img = NSImage(systemSymbolName: working ? "arrow.down.circle.fill" : "arrow.down.circle",
                          accessibilityDescription: "Pea") ?? NSImage()
        img.isTemplate = true
        return img
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menuMode = UserDefaults.standard.bool(forKey: "menuBarMode")
        UserDefaults.standard.removeObject(forKey: "NSStatusItem VisibleCC Item-0")   // stale "hidden" flag
        Model.shared.start()
        NSApp.setActivationPolicy(menuMode ? .accessory : .regular)
        if !menuMode { NSApp.activate(ignoringOtherApps: true) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if e.keyCode == 9, mods == .command || mods == .control {   // V
                Task { @MainActor in Model.shared.paste() }
                return nil
            }
            if e.keyCode == 53 {                                         // Esc
                Task { @MainActor in Model.shared.reset() }
                return nil
            }
            return e
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: "menuBarMode")
    }
}
