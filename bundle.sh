#!/bin/zsh
# Builds Pea.app next to this script.
#   ./bundle.sh                    debug-free release build for this Mac's architecture
#   ./bundle.sh --universal        arm64 + x86_64
#   ./bundle.sh --install          also copies it to /Applications
#   ./bundle.sh --dist 1.0.0       universal, plus dist/Pea-1.0.0-macOS.zip and .dmg
set -e
cd "$(dirname "$0")"
UNIVERSAL=0; INSTALL=0; VERSION="1.0.0"; DIST=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --universal) UNIVERSAL=1 ;;
    --install) INSTALL=1 ;;
    --dist) DIST=1; UNIVERSAL=1; VERSION="${2:-1.0.0}"; shift ;;
  esac
  shift
done

ARCHS=(); [[ $UNIVERSAL == 1 ]] && ARCHS=(--arch arm64 --arch x86_64)
swift build -c release --product Pea $ARCHS
BIN="$(swift build -c release --product Pea $ARCHS --show-bin-path)/Pea"

APP="Pea.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Pea"

# Icon: the Liquid Glass .icon is compiled into Assets.car (macOS 26+); the .icns is the fallback for older systems.
TMP="$(mktemp -d)"
if xcrun actool assets/Pea.icon --compile "$TMP" --platform macosx --minimum-deployment-target 14.0 \
     --app-icon Pea --include-all-app-icons --target-device mac \
     --output-partial-info-plist "$TMP/partial.plist" >/dev/null 2>&1 && [[ -f "$TMP/Assets.car" ]]; then
  cp "$TMP/Assets.car" "$APP/Contents/Resources/Assets.car"
else
  echo "note: actool (Xcode 26+) couldn't compile Pea.icon; using the .icns only" >&2
fi
cp assets/Pea.icns "$APP/Contents/Resources/Pea.icns"
rm -rf "$TMP"

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Pea</string>
<key>CFBundleDisplayName</key><string>Pea</string>
<key>CFBundleIdentifier</key><string>com.aksisonline.pea</string>
<key>CFBundleExecutable</key><string>Pea</string>
<key>CFBundleIconFile</key><string>Pea</string>
<key>CFBundleIconName</key><string>Pea</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

if [[ $INSTALL == 1 ]]; then rm -rf /Applications/$APP; cp -R "$APP" /Applications/; echo "Installed to /Applications/$APP"; fi

if [[ $DIST == 1 ]]; then
  mkdir -p dist
  ZIP="dist/Pea-$VERSION-macOS.zip"; DMG="dist/Pea-$VERSION-macOS.dmg"
  rm -f "$ZIP" "$DMG"
  ditto -c -k --keepParent "$APP" "$ZIP"
  STAGE="$(mktemp -d)"; cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
  hdiutil create -quiet -volname "Pea" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
  rm -rf "$STAGE"
  echo "Built $ZIP and $DMG"
fi
echo "Built $PWD/$APP"
