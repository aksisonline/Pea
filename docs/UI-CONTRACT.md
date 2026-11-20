# PeaUI contract (shared GTK4 + Cairo UI)

`PeaUI` is the single UI codebase for Linux and Windows. A platform executable only provides a
`PlatformServices`; everything else (window, drawing, animation, drag-out, drop, keyboard) is inside.

```swift
import PeaUI

// Blocks in the GTK main loop until the window is closed. Creates the Model itself.
@MainActor public func runPea(services: PlatformServices)

// Same, and gives the shell a handle once the window exists (tray icon, hotkeys, ...).
@MainActor public func runPea(services: PlatformServices, onReady: (PeaUIApp) -> Void)
```

Notes for callers
- `main.swift` top-level code is not main-actor isolated in Swift 5 mode, so call it as
  `MainActor.assumeIsolated { runPea(services: MyServices()) }` (see `Sources/PeaLinux/main.swift`).
- `Model` is created inside `runPea`; do not create one. `Artwork.sampler` is set by the UI (GdkPixbuf, no ffmpeg).
- `public final class GTKClipboard: Clipboard` is provided: `let clipboard: Clipboard = GTKClipboard()` works wherever
  GDK works (X11, Wayland, Win32). A native clipboard may be used instead; Ctrl+V then calls `model.paste()` directly.
- `PeaUIApp`: `model`, `services`, `accent`, `observe(_:)` (after every model change), `isArmed`, `isWorking`,
  `windowVisible`, `showWindow()`, `hideWindow()`, `toggleWindow()`, `quit()`, `trayAvailable` (set `true` once the shell
  has a tray icon: enables the bottom-left window/tray toggle and tray mode), `trayMode`.
- Debug: `PEA_DEBUG=<idle|armed|armed-noart|hint|hint-noart|kind|video|audio|working[:p]|comet|done|done-file|failed|setup1|setup2|setup3|ready>`
  forces a screen; `PEA_DEBUG_HOVER=1` puts the pointer over the circle; `PEA_ACCENT=#rrggbb` overrides the accent.
- Package wiring: `PeaUI` depends on `PeaCore` and the system-library target `CGTK` (pkg-config `gtk4`), declared under
  `#if os(Linux) || os(Windows)` in Package.swift. Windows needs GTK4 + pkg-config at build time (MSYS2
  `mingw-w64-x86_64-gtk4` / gvsbuild) and the GTK DLLs next to the exe.
