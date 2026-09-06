#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="dist/Codex Usage Bar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/CodexUsageBar" "$APP/Contents/MacOS/CodexUsageBar"
for bundle in "$BIN_DIR"/*.bundle; do
    [ -d "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.amitka.codexusagebar</string>
<key>CFBundleName</key><string>Codex Usage Bar</string>
<key>CFBundleDisplayName</key><string>Codex Usage Bar</string>
<key>CFBundleExecutable</key><string>CodexUsageBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
printf 'Built %s\n' "$PWD/$APP"
