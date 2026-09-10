#!/bin/bash
# Notarize and staple the built app, then produce a release zip.
#
# One-time setup - stores an app-specific password in your keychain so it never
# appears on a command line or in this repo:
#
#   xcrun notarytool store-credentials ab6a-rigctl \
#       --apple-id you@example.com \
#       --team-id HG979YFABK \
#       --password xxxx-xxxx-xxxx-xxxx
#
# The password is an app-specific password from https://account.apple.com,
# not your Apple ID password.
set -euo pipefail

cd "$(dirname "$0")"
APP="build/AB6A RigCtl.app"
PROFILE="${NOTARY_PROFILE:-ab6a-rigctl}"
VERSION=$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleShortVersionString)
ZIP="AB6A-RigCtl-${VERSION}.zip"

[ -d "$APP" ] || { echo "no build - run ./build-app.sh first" >&2; exit 1; }

echo "==> checking the signature is notarizable"
if ! codesign -dv "$APP" 2>&1 | grep -q "flags=.*runtime"; then
    echo "    the app is not signed with the hardened runtime." >&2
    echo "    ./build-app.sh signs it automatically when a Developer ID cert exists." >&2
    exit 1
fi
codesign --verify --deep --strict --verbose=1 "$APP"

echo "==> submitting to Apple"
# ditto, not zip: it preserves the bundle structure and the signature
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> stapling"
# staple the .app, then re-zip, so the ticket travels with the download and the
# app opens even on a machine that is offline
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "==> $ZIP is notarized and stapled"

echo
echo "Verify it the way Gatekeeper will:"
echo "    spctl -a -vvv -t install \"$APP\""
echo
echo "Attach it to a release with:"
echo "    gh release upload vX.Y \"$ZIP\" --clobber"
