#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ $EUID -eq 0 ]]; then
    echo "Don't run build.sh with sudo: it leaves root-owned files in .build/ and build/, and root can't see your signing certificate." >&2
    echo "If a normal run fails with 'Permission denied': sudo chown -R \"\$(id -un)\" .build build" >&2
    exit 1
fi

SWIFT_ARGS=(-c release)
if [[ -n "${ARCH:-}" ]]; then SWIFT_ARGS+=(--arch "$ARCH"); fi
swift build "${SWIFT_ARGS[@]}"
BIN="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)/Clipsie"
APP="build/Clipsie.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Clipsie"
cp Resources/Info.plist "$APP/Contents/Info.plist"
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp Resources/StatusIcon.png Resources/StatusIcon@2x.png "$APP/Contents/Resources/"
cp -R Resources/plugins "$APP/Contents/Resources/plugins"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Signed with: ${SIGN_IDENTITY:-ad hoc (set SIGN_IDENTITY to use a certificate)}"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x Clipsie || true
    pkill -x ClipboardManager || true
    rm -rf /Applications/ClipboardManager.app
    rm -rf /Applications/Clipsie.app
    cp -R "$APP" /Applications/
    open /Applications/Clipsie.app
    echo "Installed to /Applications"
fi
