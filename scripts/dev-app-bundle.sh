#!/usr/bin/env bash
# Builds a runnable, ad-hoc-signed Bipuu.app with plain swiftc (no Xcode needed) for local
# end-to-end checks. Not a release build: no sandbox, no Developer ID, no notarisation.
#   scripts/dev-app-bundle.sh [output-dir]      default: /tmp/bipuu-dev
# Uses the macOS 26.5 SDK when present: the 27 SDK needs the SwiftUI macro plugin that only
# ships inside Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-/tmp/bipuu-dev}"
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
[ -d "$SDK" ] || SDK="$(xcrun --show-sdk-path)"
APP="$OUT/Bipuu.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
( cd Bipuu && swiftc -parse-as-library -O -swift-version 6 -target arm64-apple-macos15.0 -sdk "$SDK" \
    $(find Sources/App Sources/BipuuKit -name '*.swift') -o "$APP/Contents/MacOS/Bipuu" 2>&1 | grep -E 'error' || true )
cp -R Bipuu/Resources/hook "$APP/Contents/Resources/hook"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Bipuu</string>
<key>CFBundleIdentifier</key><string>app.bipuu.Bipuu</string>
<key>CFBundleName</key><string>Bipuu</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.0.0-dev</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "$APP"
