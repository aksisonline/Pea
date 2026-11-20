#!/bin/bash
# Builds a release binary in the dev container and packages a .deb (dist/pea_<ver>_<arch>.deb).
# Usage: scripts/package-linux.sh [version]      (needs Docker; image from docker/Dockerfile)
set -e
VER=${1:-0.1.0}
cd "$(dirname "$0")/.."
# yt-dlp and ffmpeg ship inside the package so nothing has to be installed.
[ -x .tools-cache/linux/ffmpeg ] && [ -x .tools-cache/linux/yt-dlp ] || scripts/fetch-tools.sh linux .tools-cache/linux
docker build -t pea-linux docker
mkdir -p dist
docker run --rm -v "$PWD":/src -v pea-build:/build -w /src pea-linux bash -c "
  set -e
  swift build -c release --scratch-path /build -Xswiftc -static-stdlib
  ARCH=\$(dpkg --print-architecture)
  R=/tmp/pkg; rm -rf \$R; mkdir -p \$R/DEBIAN \$R/usr/bin \$R/opt/pea/tools \$R/usr/share/applications \$R/usr/share/icons/hicolor/scalable/apps
  install -m755 /build/release/PeaLinux \$R/opt/pea/pea
  ln -s /opt/pea/pea \$R/usr/bin/pea
  install -m755 .tools-cache/linux/yt-dlp .tools-cache/linux/ffmpeg \$R/opt/pea/tools/
  install -m644 .tools-cache/linux/VERSIONS.txt \$R/opt/pea/tools/
  install -m644 NOTICE.md LICENSE \$R/opt/pea/
  install -m644 packaging/linux/pea.desktop \$R/usr/share/applications/
  install -m644 packaging/linux/pea.svg \$R/usr/share/icons/hicolor/scalable/apps/
  cat > \$R/DEBIAN/control <<CTL
Package: pea
Version: $VER
Architecture: \$ARCH
Maintainer: aksisonline
Depends: libgtk-4-1
Recommends: wl-clipboard
Description: Minimal media downloader
 Copy a link, click the circle, drag the file out. Ships with yt-dlp and ffmpeg; nothing else to install.
CTL
  dpkg-deb --build \$R /src/dist/pea_${VER}_\$ARCH.deb
"
ls -la dist
