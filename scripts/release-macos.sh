#!/bin/bash
#
# Cuts a macOS release and publishes it to the Sparkle update feed.
#
#   scripts/release-macos.sh 1.1
#
# What it does:
#   1. Archives the app (Release) with the given version baked in.
#   2. Exports it re-signed with the Developer ID Application certificate,
#      submits it to Apple's notary service, and staples the ticket — so
#      Gatekeeper opens it cleanly on any Mac, no right-click dance.
#   3. Zips it into updates/ — that folder accumulates one zip per version so
#      generate_appcast can build a multi-version feed (and delta updates);
#      don't clean it out between releases.
#   4. Signs + regenerates updates/appcast.xml (EdDSA private key is read from
#      the login Keychain — the one generate_keys created; releases must be
#      cut from a machine that has it).
#   5. Uploads the zip and appcast to the rolling "updates" GitHub release,
#      whose asset URLs are stable (that's what SUFeedURL points at).
#
# One-time machine setup (see docs/RELEASING.md):
#   - A "Developer ID Application" certificate in the Keychain
#   - Notary credentials: xcrun notarytool store-credentials bcl-notary …
#
# The app checks https://github.com/…/releases/download/updates/appcast.xml,
# so the update is live the moment the upload finishes.

set -euo pipefail
cd "$(dirname "$0")/.."

# The argument is the human-facing (marketing) version — "0.1-alpha" is fine.
# Sparkle orders releases by CFBundleVersion, which is derived from the clock
# below, so the marketing string never has to be sortable (or even increase).
VERSION=${1:?usage: scripts/release-macos.sh <version, e.g. 0.2-alpha>}
BUILD=$(date +%Y%m%d.%H%M)
REPO="Nicolas-schimmelpfennig/BetterContentLibrary"
FEED_TAG="updates"
DOWNLOAD_PREFIX="https://github.com/$REPO/releases/download/$FEED_TAG/"
NOTARY_PROFILE="bcl-notary"

ARCHIVE="build/BetterContentLibrary-$VERSION.xcarchive"
EXPORT_DIR="build/export-$VERSION"
ZIP="updates/BetterContentLibrary-$VERSION.zip"

# Preflight: fail fast on missing machine setup, before the slow archive.
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "error: no 'Developer ID Application' certificate in the Keychain." >&2
    echo "       Xcode → Settings → Accounts → Manage Certificates… → + → Developer ID Application" >&2
    exit 1
fi

# Notarization is skipped (loudly) when credentials aren't stored yet:
# Sparkle-installed updates aren't quarantined, so in-app updating still
# works — only fresh downloads hit Gatekeeper until this is set up.
NOTARIZE=1
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    NOTARIZE=0
    echo "warning: notary credentials missing (profile '$NOTARY_PROFILE') — SKIPPING notarization." >&2
    echo "         Fresh downloads of this build will be blocked by Gatekeeper (right-click → Open)." >&2
    echo "         To fix: xcrun notarytool store-credentials $NOTARY_PROFILE \\" >&2
    echo "                     --apple-id <your apple id> --team-id 226AMQMFG9" >&2
    echo "         (password = an app-specific password from account.apple.com)" >&2
fi

# Sparkle's tools ship inside the SPM artifact; resolve the path dynamically.
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData \
    -type d -path "*SourcePackages/artifacts/sparkle/Sparkle/bin" 2>/dev/null | head -1)
if [[ -z "$SPARKLE_BIN" ]]; then
    echo "error: Sparkle tools not found — build the app once in Xcode so SPM fetches them" >&2
    exit 1
fi

echo "==> Archiving $VERSION (build $BUILD)"
xcodebuild -project BetterContentLibrary.xcodeproj \
    -scheme BetterContentLibrary \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    archive | tail -2

echo "==> Exporting with Developer ID signing"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist scripts/ExportOptions.plist | tail -2

APP="$EXPORT_DIR/BetterContentLibrary.app"
[[ -d "$APP" ]] || { echo "error: export produced no app at $APP" >&2; exit 1; }

if [[ "$NOTARIZE" == 1 ]]; then
    echo "==> Notarizing (waits for Apple; usually a few minutes)"
    NOTARIZE_ZIP="$EXPORT_DIR/notarize.zip"
    ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
    xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

    echo "==> Stapling the notarization ticket"
    xcrun stapler staple "$APP"
fi

# Zip only after stapling — the ticket lives inside the bundle.
echo "==> Zipping to $ZIP"
mkdir -p updates
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Signing and regenerating appcast"
"$SPARKLE_BIN/generate_appcast" updates/ --download-url-prefix "$DOWNLOAD_PREFIX"

echo "==> Publishing to the '$FEED_TAG' release"
if ! gh release view "$FEED_TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release create "$FEED_TAG" --repo "$REPO" --latest=false \
        --title "App Updates" \
        --notes "Rolling Sparkle update feed for the macOS app. Assets here are consumed by in-app auto-update; grab the newest zip for a first install."
fi
gh release upload "$FEED_TAG" "$ZIP" updates/appcast.xml --repo "$REPO" --clobber

echo "==> Done. $VERSION is live on the update feed."
