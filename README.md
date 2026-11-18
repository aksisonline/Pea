# D-All

Minimal media downloader: copy a link, click the circle, drag the file out.
`Sources/DAllCore` is the portable Swift backend; `Sources/DAll` is the macOS SwiftUI app; `Sources/DAllUI` +
`Sources/DAllLinux` are the shared GTK4 UI and the Linux app (see `docs/PORTING.md`, `docs/UI-CONTRACT.md`).

## Linux
Needs Swift 5.9+, GTK4 dev files (`libgtk-4-dev`, `pkg-config`); at runtime `ffmpeg` and `yt-dlp`
(`pipx install 'yt-dlp[default]'`). The first-run step offers to install them.

```sh
swift build -c release && .build/release/DAllLinux
# or in Docker (image with Swift, GTK4, Xvfb, yt-dlp, ffmpeg):
docker build -t dall-linux docker
docker run --rm -v "$PWD":/src -v dall-build:/build dall-linux swift build --scratch-path /build
docker run --rm -v "$PWD":/src -v dall-build:/build -v /tmp/shots:/shots dall-linux /src/docker/shots.sh /shots
```
Keys: Ctrl+V paste, Esc reset, Ctrl+Q quit. `scripts/package-linux.sh` builds a .deb.
