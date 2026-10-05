#!/bin/zsh
set -e
set -o pipefail
cd "$(dirname "$0")/.."
APP_NAME="NotchApp"
BUILD_DIR=".build/release"
APP_BUNDLE="dist/$APP_NAME.app"
rm -rf dist
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

swift build -c release
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Vendored yt-dlp powers in-notch YouTube audio — must be executable, no quarantine flag
if [ -f "Resources/yt-dlp" ]; then
  cp "Resources/yt-dlp" "$APP_BUNDLE/Contents/Resources/yt-dlp"
  chmod +x "$APP_BUNDLE/Contents/Resources/yt-dlp"
  xattr -d com.apple.quarantine "$APP_BUNDLE/Contents/Resources/yt-dlp" 2>/dev/null || true
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>NotchApp</string>
<key>CFBundleIdentifier</key><string>com.local.notchapp</string>
<key>CFBundleVersion</key><string>0.1.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleExecutable</key><string>NotchApp</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSCameraUsageDescription</key><string>Not needed</string>
<key>NSCalendarsUsageDescription</key><string>Show agenda in notch</string>
<key>NSRemindersUsageDescription</key><string>Show reminders in notch</string>
<key>NSAppleEventsUsageDescription</key><string>Control Spotify and Apple Music playback from the notch</string>
</dict></plist>
PLIST

echo "Built $APP_BUNDLE"
