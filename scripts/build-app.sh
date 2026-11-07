#!/bin/bash
# Builds MacPilot.app into ./build/ .
#   scripts/build-app.sh            release build
#   scripts/build-app.sh --install  also copy to /Applications and relaunch
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/MacPilot.app
IDENTITY="${MACPILOT_SIGN_IDENTITY:-MacPilot Dev}"

echo "▸ Compiling (release)…"
swift build -c release --product MacPilot
swift build -c release --product mpctl
BIN=$(swift build -c release --show-bin-path)

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MacPilot" "$BIN/mpctl" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/playbook "$APP/Contents/Resources/playbook"

if [[ ! -f build/AppIcon.icns ]]; then
    echo "▸ Rendering icon"
    swift scripts/make-icon.swift build/AppIcon.iconset >/dev/null
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# A stable signing identity keeps macOS permissions (Accessibility, Screen Recording)
# across rebuilds. Without one we fall back to ad-hoc signing, and macOS may ask again
# after every rebuild. Create one with scripts/create-signing-identity.sh.
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    echo "▸ Signing with \"$IDENTITY\""
    codesign --force --sign "$IDENTITY" --identifier com.macpilot.mpctl "$APP/Contents/MacOS/mpctl"
    codesign --force --sign "$IDENTITY" --identifier com.macpilot.app "$APP"
else
    echo "▸ Signing ad-hoc (no \"$IDENTITY\" identity found)"
    codesign --force --sign - --identifier com.macpilot.mpctl "$APP/Contents/MacOS/mpctl"
    codesign --force --sign - --identifier com.macpilot.app "$APP"
fi

echo "✓ Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x MacPilot 2>/dev/null || true
    pkill -f "whisper-server.*--port 18733" 2>/dev/null || true
    rm -rf /Applications/MacPilot.app
    cp -R "$APP" /Applications/
    open /Applications/MacPilot.app
    echo "✓ Installed to /Applications and launched"
fi
