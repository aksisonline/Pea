#!/bin/bash
# Builds a release binary in the dev container and packages a .deb (dist/d-all_<ver>_<arch>.deb).
# Usage: scripts/package-linux.sh [version]      (needs Docker; image from docker/Dockerfile)
set -e
VER=${1:-0.1.0}
cd "$(dirname "$0")/.."
docker build -t dall-linux docker
mkdir -p dist
docker run --rm -v "$PWD":/src -v dall-build:/build -w /src dall-linux bash -c "
  set -e
  swift build -c release --scratch-path /build -Xswiftc -static-stdlib
  ARCH=\$(dpkg --print-architecture)
  R=/tmp/pkg; rm -rf \$R; mkdir -p \$R/DEBIAN \$R/usr/bin \$R/usr/share/applications \$R/usr/share/icons/hicolor/scalable/apps
  install -m755 /build/release/DAllLinux \$R/usr/bin/d-all
  install -m644 packaging/linux/d-all.desktop \$R/usr/share/applications/
  install -m644 packaging/linux/d-all.svg \$R/usr/share/icons/hicolor/scalable/apps/
  cat > \$R/DEBIAN/control <<CTL
Package: d-all
Version: $VER
Architecture: \$ARCH
Maintainer: D-All
Depends: libgtk-4-1, ffmpeg
Recommends: pipx, wl-clipboard
Description: Minimal media downloader
 Copy a link, click the circle. yt-dlp (pipx install 'yt-dlp[default]') does the work.
CTL
  dpkg-deb --build \$R /src/dist/d-all_${VER}_\$ARCH.deb
"
ls -la dist
