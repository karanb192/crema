#!/usr/bin/env bash
# Build, sign, notarize, and staple Crema.app into a distributable zip.
#
# Usage:
#   scripts/release.sh sign-only   # build + sign + verify (no Apple round trip)
#   scripts/release.sh             # full: sign + notarize + staple + zip
#
# One-time notarization setup (stores an app-specific password in the keychain):
#   xcrun notarytool store-credentials crema-notary \
#     --apple-id "you@example.com" --team-id GHS356Z2GX --password "app-specific-pw"
#
# Overridable via env: CREMA_SIGN_IDENTITY, CREMA_NOTARY_PROFILE.

set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-full}"
APP="Crema.app"
IDENTITY="${CREMA_SIGN_IDENTITY:-Developer ID Application: Karan Bansal (GHS356Z2GX)}"
PROFILE="${CREMA_NOTARY_PROFILE:-crema-notary}"
ENTITLEMENTS="assets/entitlements.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
ZIP="Crema-${VERSION}-arm64-mac.zip"

echo "==> Building release bundle ($VERSION)"
make app >/dev/null

echo "==> Signing with hardened runtime"
# Sign the inner binary first, then the bundle.
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP/Contents/MacOS/crema"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Zipping"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ "$MODE" = "sign-only" ]; then
  echo "==> sign-only: skipping notarization"
  # Signed but not notarized: Gatekeeper will still reject on first open. This
  # mode is for verifying the signing step, not for distribution.
  codesign -dvv "$APP" 2>&1 | grep -E "Authority|TeamIdentifier|Runtime" || true
  echo "signed: $ZIP  (NOT notarized)"
  exit 0
fi

echo "==> Notarizing (this waits for Apple)"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Stapling and re-zipping"
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Verifying"
xcrun stapler validate "$APP"
spctl --assess --type exec --verbose=2 "$APP"

echo
echo "artifact: $ZIP"
echo "version:  $VERSION"
echo "sha256:   $(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo
echo "Next: gh release create v${VERSION} ${ZIP} --title \"Crema ${VERSION}\" --notes ..."
echo "Then update the sha256 and version in the karanb192/tap crema cask."
