#!/bin/bash
# Downloads the standalone helper binaries that ship inside Pea, so nobody has to install anything.
#   scripts/fetch-tools.sh <macos|linux|windows> <out-dir>
# Puts yt-dlp[.exe] and ffmpeg[.exe] in <out-dir> plus VERSIONS.txt. Needs curl, unzip, tar (and lipo on macOS).
set -euo pipefail
OS=${1:?usage: fetch-tools.sh <macos|linux|windows> <out-dir>}
OUT=${2:?usage: fetch-tools.sh <macos|linux|windows> <out-dir>}
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
dl() { curl -fsSL --retry 4 --retry-delay 3 -o "$2" "$1"; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# --- yt-dlp: official single-file builds (no Python needed), verified against the release checksums ---
case $OS in
  macos)   YT=yt-dlp_macos ;;
  linux)   YT=yt-dlp_linux ;;
  windows) YT=yt-dlp.exe ;;
  *) echo "unknown OS $OS" >&2; exit 2 ;;
esac
BASE=https://github.com/yt-dlp/yt-dlp/releases/latest/download
dl "$BASE/$YT" "$TMP/$YT"
dl "$BASE/SHA2-256SUMS" "$TMP/SUMS"
want=$(grep " $YT\$" "$TMP/SUMS" | cut -d' ' -f1)
[ "$(sha256 "$TMP/$YT")" = "$want" ] || { echo "yt-dlp checksum mismatch" >&2; exit 1; }

# --- ffmpeg: static builds. Pea only needs the ffmpeg binary (yt-dlp falls back to it when ffprobe is absent) ---
case $OS in
  macos)
    for arch in arm64 amd64; do
      B=https://ffmpeg.martin-riedl.de/redirect/latest/macos/$arch/snapshot
      dl "$B/ffmpeg.zip" "$TMP/ffmpeg-$arch.zip"
      dl "$B/ffmpeg.zip.sha256" "$TMP/ffmpeg-$arch.sha256" || true
      if [ -s "$TMP/ffmpeg-$arch.sha256" ]; then
        [ "$(sha256 "$TMP/ffmpeg-$arch.zip")" = "$(awk '{print $1}' "$TMP/ffmpeg-$arch.sha256")" ] || { echo "ffmpeg $arch checksum mismatch" >&2; exit 1; }
      fi
      mkdir "$TMP/ff-$arch"; unzip -q "$TMP/ffmpeg-$arch.zip" -d "$TMP/ff-$arch"
    done
    lipo -create "$TMP/ff-arm64/ffmpeg" "$TMP/ff-amd64/ffmpeg" -output "$OUT/ffmpeg"
    chmod +x "$OUT/ffmpeg"; codesign --force --sign - "$OUT/ffmpeg" >/dev/null 2>&1 || true ;;
  linux)
    dl https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz "$TMP/ff.tar.xz"
    dl https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz.md5 "$TMP/ff.md5" || true
    if [ -s "$TMP/ff.md5" ]; then
      want=$(cut -d' ' -f1 "$TMP/ff.md5")
      got=$( (command -v md5sum >/dev/null && md5sum "$TMP/ff.tar.xz" || md5 -r "$TMP/ff.tar.xz") | cut -d' ' -f1)
      [ "$got" = "$want" ] || { echo "ffmpeg checksum mismatch" >&2; exit 1; }
    fi
    mkdir "$TMP/ffx"; tar -xJf "$TMP/ff.tar.xz" -C "$TMP/ffx"
    install -m755 "$(find "$TMP/ffx" -name ffmpeg -type f | head -1)" "$OUT/ffmpeg" ;;
  windows)
    dl https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip "$TMP/ff.zip"
    dl https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip.sha256 "$TMP/ff.sha256" || true
    if [ -s "$TMP/ff.sha256" ]; then
      [ "$(sha256 "$TMP/ff.zip")" = "$(awk '{print tolower($1)}' "$TMP/ff.sha256")" ] || { echo "ffmpeg checksum mismatch" >&2; exit 1; }
    fi
    unzip -q -j "$TMP/ff.zip" '*/bin/ffmpeg.exe' -d "$OUT" ;;
esac
install -m755 "$TMP/$YT" "$OUT/$([ $OS = windows ] && echo yt-dlp.exe || echo yt-dlp)"

{
  echo "yt-dlp: $(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/yt-dlp/yt-dlp/releases/latest | sed 's|.*/||') https://github.com/yt-dlp/yt-dlp (Unlicense)"
  case $OS in
    macos)   echo "ffmpeg: static build from https://ffmpeg.martin-riedl.de (GPL-3.0+); source and build scripts are linked there. Universal (arm64 + x86_64)." ;;
    linux)   echo "ffmpeg: static build from https://johnvansickle.com/ffmpeg (GPL-3.0+); source at https://johnvansickle.com/ffmpeg/release-source/" ;;
    windows) echo "ffmpeg: essentials build from https://www.gyan.dev/ffmpeg/builds (GPL-3.0+); source at https://github.com/GyanD/codexffmpeg" ;;
  esac
} > "$OUT/VERSIONS.txt"
ls -la "$OUT"
