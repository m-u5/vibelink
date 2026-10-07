#!/bin/bash
# Builds build/VibeLink.app (menu bar app) and build/vibelink (CLI).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product VibeLinkApp
swift build -c release --product vibelink
BIN=$(swift build -c release --show-bin-path)

APP=build/VibeLink.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/VibeLinkApp" "$APP/Contents/MacOS/VibeLink"
cp "$BIN/vibelink" build/vibelink

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>VibeLink</string>
    <key>CFBundleIdentifier</key><string>io.github.m-u5.vibelink</string>
    <key>CFBundleName</key><string>VibeLink</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>VibeLink advertises your remote iPhone on this Mac's network so Xcode can find it.</string>
    <key>NSBonjourServices</key>
    <array><string>_remotepairing._tcp</string></array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "built $APP and build/vibelink"
