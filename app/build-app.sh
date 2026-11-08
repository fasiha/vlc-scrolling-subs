#!/bin/sh
# Builds build/OperaSubs.app (release) with VLCKit embedded.
set -e
cd "$(dirname "$0")"
CONFIG=${CONFIG:-release}
swift build -c "$CONFIG"
BIN=$(swift build -c "$CONFIG" --show-bin-path)
APP=build/OperaSubs.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp "$BIN/OperaSubs" "$APP/Contents/MacOS/"
ditto Vendor/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework "$APP/Contents/Frameworks/VLCKit.framework"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OperaSubs</string>
<key>CFBundleIdentifier</key><string>me.aldebrn.OperaSubs</string>
<key>CFBundleName</key><string>Opera Subs</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
