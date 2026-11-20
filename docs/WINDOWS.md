# Pea on Windows

Status: **written and reviewed without access to a Windows machine.** Everything platform-neutral is unit-tested
(Linux, Docker); the Win32 files are only type-checked against a hand-written WinSDK stub. See "What is verified".

## Run / build

Requirements: Windows 10 1803+ (for `curl.exe`) or 11, the Swift 6.1+ toolchain for Windows (swift.org installer, with
Visual Studio Build Tools + Windows SDK), and `winget` (App Installer) for the first-run tool install.

```powershell
swift build -c release --product PeaWindows
swift test                                   # PeaCore tests
./scripts/package-windows.ps1 -Version 1.0.0 # dist/Pea-1.0.0-windows-x64.zip
```

First run installs the tools for you: `winget install --id yt-dlp.yt-dlp` and `--id Gyan.FFmpeg`. A running process never
sees a PATH change made after it started, so `Tools.find` also searches `%LOCALAPPDATA%\Microsoft\WinGet\Links`,
`%ProgramFiles%\WinGet\Links`, `...\WinGet\Packages\*yt-dlp*|*ffmpeg*` (incl. `<unzipped>\bin`), scoop shims and
Chocolatey's `bin` directly. If winget is missing or fails, the copyable command
`winget install yt-dlp.yt-dlp; winget install Gyan.FFmpeg` is placed on the clipboard.

## Layout

| Path | What |
|---|---|
| `Sources/PeaCore/Process.swift` | `ChildProcess` abstraction, `WindowsCommandLine` (quoting, env block). Portable + tested. |
| `Sources/PeaCore/Windows/` | `WinChild` (CreateProcessW + Job Object), `KnownFolders` (Downloads). `#if os(Windows)`. |
| `Sources/PeaCore/Transport.swift` | `DownloadTransport`, `CurlTransport` (curl.exe). Portable + tested. |
| `Sources/PeaWindowsPlatform/` | `WindowsServices`, `WindowsClipboard`, `WindowsTray` (Win32). `#if os(Windows)`. |
| `Sources/PeaWindows/` | executable; `UIEntry.swift` is the **only** seam to the shared UI. |
| `scripts/package-windows.ps1`, `packaging/winget/` | portable zip, winget manifest skeleton. |
| `.github/workflows/ci.yml` | macOS / Ubuntu / Windows matrix + Windows app artifact. |

### UI seam (assumption, adjust when merging)

`Sources/PeaWindows/UIEntry.swift` assumes the shared module exposes

```swift
// module PeaUI
@MainActor public func runPea(services: PlatformServices)   // runs the app loop, does not return
```

and compiles to a `fatalError("PeaUI is not linked")` stub until `PeaUI` is a dependency (`#if canImport(PeaUI)`).
To integrate: add the `PeaUI` target to `Package.swift`, add it to the `PeaWindows` dependencies, change the single call
in `launchSharedUI` if the name or shape differs. A tray is optional: `WindowsTray` conforms to `PeaCore.TrayIcon`
(`isLit`, `toolTip`, `onToggle`, `onSecondaryClick`); wire `model.onChange = { tray.isLit = model.suggestion != nil }`.
The tray needs a message loop on the thread that creates it (any Win32/WinUI shell has one).
If the executable is linked as a console app, a console window appears; link with `/SUBSYSTEM:WINDOWS`
(`-Xlinker /SUBSYSTEM:WINDOWS -Xlinker /ENTRY:mainCRTStartup`).

## Decisions and why

* **Own process launcher instead of `Foundation.Process` on Windows.** Reading swift-corelibs-foundation's `Process.swift`
  (main): arguments are correctly quoted (Colascione rules) and `Path` is handled, but the creation flags are only
  `CREATE_UNICODE_ENVIRONMENT` (a console window flashes for every yt-dlp/ffmpeg launch from a GUI app) and
  `terminate()` is a bare `TerminateProcess` on the root (ffmpeg, and the real python child of the PyInstaller
  `yt-dlp.exe` launcher, keep running after Cancel). `WinChild` adds `CREATE_NO_WINDOW`, starts suspended, puts the process
  in a Job Object with `KILL_ON_JOB_CLOSE`, and `terminate()` kills the whole job. Pipes are raw `ReadFile` loops feeding
  the same `LineStream`. Command lines are built by `WindowsCommandLine.quote` (same rules; proven by a round-trip test
  against a reference MS-CRT splitter, including the `--ppa` value with `"`, `'`, `(`, `)` and `%(...)s` templates).
  No shell is ever involved, so `%`/`^`/`&` need no escaping.
* **yt-dlp output encoding:** on Windows `--encoding utf-8` is added (yt-dlp encodes everything it writes through it) and
  `PYTHONUTF8=1`, `PYTHONIOENCODING=utf-8` are set for the child, because Python on a pipe otherwise uses the ANSI code
  page and corrupts non-ASCII titles in the printed `after_move:filepath` and in `ERROR` lines. Paths we pass in go through
  `CreateProcessW` (UTF-16), which is lossless. `--ffmpeg-location` points at the ffmpeg we found (winget's isn't on PATH).
* **Paths:** `Platform.nativePath` normalises `URL.path` (`/C:/x`, forward slashes) before it is handed to other programs.
  yt-dlp prints `C:\...` / UNC paths; `YtDlpRun.looksLikePath` accepts them. `Tools.find` appends `.exe`, uses a plain
  file-exists check (winget's app-execution-alias `winget.exe` is a reparse point), reads `Path` case-insensitively and
  strips quotes. Temp dirs are `pea-<12 hex>` to save MAX_PATH budget.
* **File names:** `FileNames.sanitize` strips `\ / : * ? " < > |` and control characters on all OSes (as before), and on
  Windows also trailing dots/spaces, device names (CON, PRN, AUX, NUL, COM1-9, LPT1-9, with or without extension) and
  keeps `dir + name` under 260 chars; all OSes cap at 255 UTF-8 bytes keeping the extension. yt-dlp's own `-o` names are
  sanitised by yt-dlp (Windows-safe by default; the template uses `%(title).120B`).
* **Cross-volume moves:** `FileNames.move` = `moveItem`, falling back to copy + delete.
* **Settings:** Windows uses `JSONFileSettings` (`%APPDATA%\Pea\settings.json`, atomic write); macOS/Linux keep
  `UserDefaults` so existing users keep their choices. swift-corelibs-foundation's `UserDefaults` on Windows rides on
  CFPreferences with no documented persistence location or tests there, so it wasn't worth trusting for `setupDone`.
* **Clipboard:** `GetClipboardSequenceNumber()` is the change token. `OpenClipboard` is retried 10x10 ms (other apps hold it
  briefly). Writes use `GetDesktopWindow()` as owner: with a NULL owner `EmptyClipboard` leaves SetClipboardData failing.
* **Downloads folder:** `SHGetKnownFolderPath(FOLDERID_Downloads)` (GUID spelled out, so no `uuid.lib` link dependency),
  falling back to `%USERPROFILE%\Downloads`.

## URLSession on Windows: research and decision

Evidence (Swift 6.1 era):
* Swift forums "Windows-specific timeout issue with URLSession (-1001)" (forums.swift.org/t/.../81259): requests that work
  on macOS/Linux always run into the timeout on Windows; the only reported fix was a custom swift-corelibs-foundation build
  with HTTP/2 (nghttp2) enabled. The stock Windows toolchain's libcurl is built without HTTP/2.
* "URLSessionTasks on Windows can cause crashes" (.../64795) and "Workaround for networking crash on Windows?" (.../69010):
  a task that times out or is cancelled could crash the process (libdispatch socket-source teardown, partly addressed by
  swift-corelibs-foundation PR #4859). Cancel-heavy usage (Pea cancels segment tasks) is precisely that path.
* "Is there anyone successfully using URLSession tasks on Windows VM?" (.../73697): timeouts in a VMware VM only.
* Nothing found documenting `httpMaximumConnectionsPerHost` or system-proxy behaviour on Windows. libcurl in Foundation
  reads proxies from the environment only (`HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`), not from the registry / WinINet
  settings, and so does `curl.exe`. yt-dlp (Python) does read the Windows proxy settings.
* No official resolution found; the proposal to replace libcurl with SwiftNIO is not shipped.

Decision (not over-engineered): a `DownloadTransport` protocol with two implementations. macOS/Linux unchanged
(URLSession). **Windows defaults to `curl.exe`** (`%SystemRoot%\System32\curl.exe`, shipped since Windows 10 1803; HTTP/2,
Schannel, system trust store), one process per segment, progress from file size, killed with the awaiting Task; falls back
to URLSession if `curl.exe` is missing. Override with `PEA_TRANSPORT=urlsession|curl` and `PEA_CURL=<path>`.
Hardening for both transports: stall detection (curl `--speed-limit/--speed-time`; URLSession 30 s request timeout),
segment retries with 1/2/4 s back-off (was a flat 1 s), and if a segmented download still fails it **falls back to a single
stream** instead of failing. Metadata fetches (`HEAD` probe, Spotify page, artwork) use the same transport.
Known gap: system proxy configuration is not picked up (set `HTTPS_PROXY`).

## What is verified

Verified (Linux, `swift:6.1` Docker; macOS host):
* `swift test` green, including new tests for quoting round trips, argument builder, PATH/`.exe` resolution, winget
  package-dir expansion, path normalisation, file-name sanitising (reserved names, trailing dots, 255-byte / MAX_PATH
  budget), JSON settings (incl. corrupt file), LineStream chunking/CRLF, curl header parsing, tray glyph.
* Segmented 7 MB download against a local range server through both transports
  (`PEA_TRANSPORT=curl` and `urlsession`, with `PEA_TEST_URL` / `PEA_TEST_SIZE`; see `LocalTransportTests`).
* macOS app still builds (`swift build --product Pea`).
* The Windows-only files type-check under macOS `swiftc` against a hand-written stub of the WinSDK imports
  (self-consistency only: it does not prove the real WinSDK signatures match).

Not verified (no Windows machine, no Windows Swift SDK available for cross-compiling here):
* That any `#if os(Windows)` file compiles against the real WinSDK (`WinChild`, `KnownFolders`, `WindowsClipboard`,
  `WindowsTray`, `WindowsServices`). Likeliest trouble spots: `BOOL` importing as `WindowsBool` (handled via an `ok()`
  helper that accepts `Int32` too), `HANDLE`/`HWND` optionality, `STARTUPINFOW()`/`NOTIFYICONDATAW()` zero-initialisers,
  `szTip` tuple access.
* Runtime behaviour on Windows: job-object kill, pipe EOF semantics, clipboard owner workaround, tray messages, winget flow,
  `swift test` on the Windows CI job, the packaging script's DLL scan, the CI workflow itself (YAML parses; action tags exist).

## Packaging options

1. **Portable zip** (`scripts/package-windows.ps1`): exe + Swift runtime DLLs (found via the `llvm-readobj --coff-imports`
   closure). `-StaticStdlib` tries `-static-stdlib` to ship fewer DLLs.
2. **winget** portable-zip manifest skeleton: `packaging/winget/manifest.yaml.template` (depends on `yt-dlp.yt-dlp` and
   `Gyan.FFmpeg`).
3. **Inno Setup**: simplest installer; a `.iss` that copies the zip contents to `{autopf}\Pea`, adds a Start menu
   shortcut, optional run-at-login via `HKCU\...\Run`. Per-user, no UAC.
4. **WiX 4** (`wix build`) for an MSI if enterprise deployment matters; **MSIX** for Store / clean uninstall (needs signing;
   packaged apps get a virtualised view of `%LOCALAPPDATA%`, so test the winget Links lookup under it).
5. Unsigned binaries trigger SmartScreen; sign releases (code-signing certificate or Azure Trusted Signing).

## Risks

* Windows Foundation details that differ per toolchain: `URL.path` shape, `FileManager.isExecutableFile`, `moveItem` across
  volumes. Mitigated (see above) but untested.
* Antivirus products sometimes flag unsigned exes that spawn processes and read the clipboard.
* If job assignment fails (restrictive parent job) we fall back to `TerminateProcess` on the root only.
* yt-dlp's `--encoding` is documented as experimental.
