#!/bin/zsh
# Builds D-All.app next to this script.  Usage: ./bundle.sh [--install]
set -e
cd "$(dirname "$0")"
swift build -c release
APP="D-All.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/DAll "$APP/Contents/MacOS/DAll"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>D-All</string>
<key>CFBundleDisplayName</key><string>D-All</string>
<key>CFBundleIdentifier</key><string>com.aksisonline.dall</string>
<key>CFBundleExecutable</key><string>DAll</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
[[ "$1" == "--install" ]] && { rm -rf /Applications/$APP; cp -R "$APP" /Applications/; echo "Installed to /Applications/$APP"; }
echo "Built $PWD/$APP"
