#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
signing_identity=${PADBRIDGE_SIGNING_IDENTITY:-}
if [[ -z "$signing_identity" ]]; then
    signing_identity=$(security find-identity -v -p codesigning | awk '/"Apple Development:/ {print $2}')
    if [[ ! "$signing_identity" =~ '^[[:xdigit:]]{40}$' ]]; then
        print -u2 'Pilih satu sertifikat Apple Development dengan PADBRIDGE_SIGNING_IDENTITY. Gunakan PADBRIDGE_SIGNING_IDENTITY=- hanya untuk build ad hoc.'
        exit 1
    fi
fi
swift build -c release
app="$PWD/dist/PadBridge.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
rm -rf "$app/Contents/Resources/PadBridge_PadBridge.bundle"
iconset=$(mktemp -d)
trap 'rm -rf "$iconset"' EXIT
mkdir "$iconset/PadBridge.iconset"
for size in 16 32 128 256 512; do
    source_icon=iPad/App/Assets.xcassets/AppIcon.appiconset/PadBridge.png
    sips -z "$size" "$size" "$source_icon" --out "$iconset/PadBridge.iconset/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$source_icon" --out "$iconset/PadBridge.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset/PadBridge.iconset" -o "$app/Contents/Resources/PadBridge.icns"
cp .build/release/PadBridge "$app/Contents/MacOS/PadBridge"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIconFile</key><string>PadBridge.icns</string>
<key>CFBundleIdentifier</key><string>local.padbridge.host</string>
<key>CFBundleName</key><string>DeskShift</string>
<key>CFBundleDisplayName</key><string>DeskShift</string>
<key>CFBundleExecutable</key><string>PadBridge</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>DeskShift menampilkan layar Mac ini di iPad atau iPhone yang kamu pasangkan.</string>
<key>NSLocalNetworkUsageDescription</key><string>DeskShift menghubungkan Mac langsung ke iPad atau iPhone milikmu.</string>
<key>NSBonjourServices</key><array><string>_padbridge._tcp</string></array>
<key>NSUserActivityTypes</key><array><string>local.padbridge.pair</string></array>
</dict></plist>
PLIST
if [[ -n "${PADBRIDGE_DEFAULT_RELAY:-}" ]]; then
    plutil -insert PadBridgeRelayAddress -string "$PADBRIDGE_DEFAULT_RELAY" "$app/Contents/Info.plist"
fi
codesign --force --deep --sign "$signing_identity" --identifier local.padbridge.host "$app"
print "Aplikasi: $app"
print 'Jalankan: open dist/PadBridge.app'
