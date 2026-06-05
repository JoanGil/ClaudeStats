#!/bin/bash
# Build ClaudeStats and assemble a macOS .app bundle (menu-bar agent, no dock icon).
set -euo pipefail
cd "$(dirname "$0")"

APP="ClaudeStats"
DEST="${1:-/Applications}"     # install location; pass a dir to override
BUNDLE="$DEST/$APP.app"
SRCICON="Sources/ClaudeStats/Resources/icon.png"

echo "▸ swift build -c release"
swift build -c release
BINPATH=$(swift build -c release --show-bin-path)
BIN="$BINPATH/$APP"

echo "▸ assembling $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/$APP"

# SwiftPM resource bundle must sit next to the executable for Bundle.module
for b in "$BINPATH"/*.bundle; do
    [ -e "$b" ] && cp -R "$b" "$BUNDLE/Contents/MacOS/"
done

# generate AppIcon.icns from the burst png (for Finder / Raycast / Dock)
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 64 128 256 512; do
    sips -z $s $s    "$SRCICON" --out "$ICONSET/icon_${s}x${s}.png"        >/dev/null
    sips -z $((s*2)) $((s*2)) "$SRCICON" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP</string>
    <key>CFBundleDisplayName</key><string>Claude Stats</string>
    <key>CFBundleIdentifier</key><string>com.joangil.claudestats</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleExecutable</key><string>$APP</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>com.joangil.claudestats</string>
            <key>CFBundleURLSchemes</key>
            <array><string>claudestats</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# ad-hoc sign so Gatekeeper/TCC treat it as a stable identity
codesign --force --deep --sign - "$BUNDLE" 2>/dev/null || true

echo "✓ built $BUNDLE"
echo "  launch:  open \"$BUNDLE\""
