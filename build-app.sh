#!/bin/bash
# Build "AB6A RigCtl.app" - a menu bar app (Swift/AppKit) supervising rigctld.
# Pass --install to put it in /Applications and the CLI on your PATH.
set -euo pipefail

cd "$(dirname "$0")"
APP="build/AB6A RigCtl.app"
BIN_DIR="${RIGCTL_BIN_DIR:-/opt/homebrew/bin}"

echo "==> icon"
if python3 -c "import PIL" 2>/dev/null; then
    python3 make-icon.py RigCtl.icns
elif [ -f RigCtl.icns ]; then
    echo "    Pillow not installed - reusing the existing RigCtl.icns"
else
    echo "    need Pillow for the icon: python3 -m pip install pillow" >&2
    exit 1
fi

echo "==> menu bar app (Swift)"
( cd app && swift build -c release 2>&1 \
    | grep -vE 'prohibited flag|^\[|^Building|^Compiling|^Planning|^Build complete' || true )
SWIFT_BIN="app/.build/release/RigCtlApp"
[ -x "$SWIFT_BIN" ] || { echo "    swift build produced no binary" >&2; exit 1; }

echo "==> bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$SWIFT_BIN" "$APP/Contents/MacOS/RigCtl"
cp RigCtl.icns "$APP/Contents/Resources/RigCtl.icns"

# the CLI ships inside the bundle so the PATH symlink has a stable target and
# both share one profiles.json
cp ab6a-rigctl "$APP/Contents/Resources/ab6a-rigctl"
chmod +x "$APP/Contents/Resources/ab6a-rigctl" "$APP/Contents/MacOS/RigCtl"

printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>AB6A RigCtl</string>
    <key>CFBundleDisplayName</key>       <string>AB6A RigCtl</string>
    <key>CFBundleIdentifier</key>        <string>local.ab6a.rigctl</string>
    <key>CFBundleExecutable</key>        <string>RigCtl</string>
    <key>CFBundleIconFile</key>          <string>RigCtl</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleSignature</key>         <string>????</string>
    <key>CFBundleShortVersionString</key><string>1.7</string>
    <key>CFBundleVersion</key>           <string>8</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key>    <string>26.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSHumanReadableCopyright</key>  <string>GPL-2.0-or-later &#183; Help: AB6A.US@gmail.com</string>
    <!-- menu bar only: no Dock icon, no main window -->
    <key>LSUIElement</key>               <true/>
</dict>
</plist>
PLIST

# ---------------------------------------------------------------------------
# Signing.
#
# The app links no third-party dylibs, so a Developer ID signature with the
# hardened runtime is all notarization needs - nothing to bundle, no
# library-validation exemption.
DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')

if [ -n "$DEV_ID" ] && [ "${SKIP_SIGN:-}" != "1" ]; then
    codesign --force --timestamp --options runtime --sign "$DEV_ID" \
        "$APP/Contents/Resources/ab6a-rigctl"
    codesign --force --timestamp --options runtime --sign "$DEV_ID" "$APP"
    echo "    signed: $DEV_ID (hardened runtime)"
    codesign --verify --deep --strict "$APP" && echo "    signature verifies"
else
    codesign --force --deep --sign - "$APP" 2>/dev/null \
        && echo "    signed (ad-hoc - not notarizable)" \
        || echo "    codesign unavailable - still runs"
fi

echo "==> built $APP"

if [ "${1:-}" = "--install" ]; then
    echo "==> installing"
    pkill -x RigCtl 2>/dev/null || true
    pkill -x Shack 2>/dev/null || true
    rm -rf "/Applications/AB6A RigCtl.app" /Applications/Shack.app
    cp -R "$APP" "/Applications/AB6A RigCtl.app"
    echo "    /Applications/AB6A RigCtl.app"
    if [ -d "$BIN_DIR" ] && [ -w "$BIN_DIR" ]; then
        rm -f "$BIN_DIR/shack"
        ln -sf "/Applications/AB6A RigCtl.app/Contents/Resources/ab6a-rigctl" "$BIN_DIR/ab6a-rigctl"
        echo "    $BIN_DIR/ab6a-rigctl"
    fi
    touch "/Applications/AB6A RigCtl.app"
    echo "==> done - launch it from /Applications; it lives in the menu bar"
fi
