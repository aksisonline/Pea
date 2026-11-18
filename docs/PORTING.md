# Porting D-All to Linux (and the shared UI layer for Windows)

## Decision: direct GTK4 + Cairo/Pango through Swift C interop

| | SwiftCrossUI (GTK / WinUI backends) | GTK4 + Cairo + Pango directly (chosen) |
|---|---|---|
| Same UI code on Linux + Windows | Yes (GTK backend); WinUI Windows-only | Yes (GTK4 builds on Windows) |
| 72 gradient, rotating round dots, accent progress, comet | No custom-draw primitive with gradients / per-frame animation | Cairo: exact |
| Blurred, saturated artwork circle, glass highlight, rim | No blur / saturation | Pre-blurred small surface + gradients: close match |
| Text set round a circle, rotating | No | Pango per glyph + rotate: exact |
| Drag a file OUT (text/uri-list, MOVE only) | No API | `GtkDragSource` + `gdk_content_provider_new_for_bytes` |
| Drop link/text IN | Limited | `GtkDropTargetAsync` (uri-list, moz-url, text) |
| Borderless window, move by background | Limited | `set_decorated(false)` + `gdk_toplevel_begin_move` |
| Animation curves | Implicit only | Own frame clock (`gtk_widget_add_tick_callback`) |
| Main actor / async | Handled | Bridged here: an 8 ms GLib timer pumps `RunLoop.main` so `Task { @MainActor }` runs |
| Risk | Young, moving API | GTK4 stable; C interop only |

The macOS look is almost all custom drawing, so a widget toolkit buys nothing: the window is one `GtkDrawingArea`
painted by `Scene` (layout identical to `Views.swift`: 232x266, 172 px ring of 72 dots, 142 px circle). Hit-testing,
hover capsules, pill, tooltips and cursor live in the scene. Animations are small `Chan` tweens on the frame clock,
which only runs while something moves. `Model.animate(motion)` selects the curve for the transition that follows.

Layout: `Sources/CGTK` (module map), `Sources/DAllUI` (shared), `Sources/DAllLinux` (`LinuxServices`,
StatusNotifierItem tray, `main.swift`). `docs/UI-CONTRACT.md` is the Windows hand-off.

## Verified (Linux container, Xvfb, aarch64, GTK 4.14)
Screenshot-checked: idle, armed (artwork + badge), armed without artwork, hover hint (vinyl text), Video/Audio,
quality, audio + Opus/MP3/WAV pill, downloading ring (progress and comet), done (image thumbnail, generic icon), failed,
setup steps 1-3 with Skip, Ready tick. Real flows: clipboard link detection -> click -> multi-connection HTTP download of
`proof.ovh.net/files/10Mb.dat` -> done -> drag onto a second GTK app (received `file:///...`, MOVE) -> window back to
idle. Real YouTube: title + artwork + palette fetched; Audio / Save Space / Opus produced `Me at the zoo.opus`.
Tray: registration, properties, pixmap, `Activate` against a fake StatusNotifierWatcher. `swift test` green (core
untouched). Scripts: `docker/shots.sh` (contact sheet), `docker/e2e-*.sh`.

## Degraded / differences (explicit)
- Not verified on a real desktop: Wayland compositors, a real tray host (KDE / GNOME AppIndicator), a real file manager
  as drop target, HiDPI, the xdg-portal accent colour (fallback #0a84ff; `DALL_ACCENT` overrides), dropping INTO the
  window, the tray-mode toggle UI, the video path through yt-dlp (only audio run live), the setup-step installer.
- Tray: no right-click menu (no dbusmenu): right-click shows the window, middle-click quits. Needs a SNI host (GNOME needs
  the AppIndicator extension); otherwise window-only and the bottom-left toggle is hidden.
- Borderless window without rounded corners; a small x appears top-right while hovering (closes, or hides in tray mode);
  Ctrl+Q quits. Not in the macOS app, which has traffic lights.
- Working without progress shows a short accent comet (per spec) instead of macOS's slow gradient ring.
- Clipboard: GDK, cached via "changed" + focus + 1.5 s poll. GNOME/Wayland restricts background clipboard reads, so
  auto-detect may only update while the window is focused; Ctrl+V always works.
- Thumbnails: images via GdkPixbuf, video frames via ffmpeg; Opus cover art is not extracted (generic icon shown).
- Blur is a downscaled + box-blurred surface; shadows are stacked discs.
- Cover-art embedding for Opus/MP3 needs Python `mutagen` for yt-dlp: install `yt-dlp[default]` (setup command does).
  Without it audio jobs fail (seen in the container before installing it).
- `Platform.downloadsDirectory` honours only `XDG_DOWNLOAD_DIR`, not `~/.config/user-dirs.dirs` (core left untouched).

## Windows notes
GTK4 on Windows via MSYS2/gvsbuild. `GTKClipboard`, drag/drop and `gdk_toplevel_begin_move` use portable GDK API but
were not exercised on Windows. The tray is a Windows-shell job (`app.trayAvailable = true` after creating the icon).
Only `Accent.portal()` is `#if os(Linux)` inside DAllUI.

## Packaging
`scripts/package-linux.sh [version]` builds a release binary in the container and a `.deb` (`packaging/linux/` has the
desktop file and icon; not run end to end). AppImage: `linuxdeploy --plugin gtk` on the same binary + desktop file.
Flatpak: GNOME runtime, build with `-static-stdlib`, permissions `--socket=fallback-x11 --socket=wayland
--share=network --filesystem=xdg-download --talk-name=org.kde.StatusNotifierWatcher
--talk-name=org.freedesktop.portal.Desktop`; bundle yt-dlp as a module and use the
`org.freedesktop.Platform.ffmpeg-full` extension.
