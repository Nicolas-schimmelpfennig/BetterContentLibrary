#!/bin/bash
#
# Cuts a macOS release and publishes it to the Sparkle update feed.
#
#   scripts/release-macos.sh 1.1
#
# What it does:
#   1. Archives the app (Release) with the given version baked in.
#   2. Zips it into updates/ — that folder accumulates one zip per version so
#      generate_appcast can build a multi-version feed (and delta updates);
#      don't clean it out between releases.
#   3. Signs + regenerates updates/appcast.xml (EdDSA private key is read from
#      the login Keychain — the one generate_keys created; releases must be
#      cut from a machine that has it).
#   4. Uploads the zip and appcast to the rolling "updates" GitHub release,
#      whose asset URLs are stable (that's what SUFeedURL points at).
#
# The app checks https://github.com/…/releases/download/updates/appcast.xml,
# so the update is live the moment the upload finishes.

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: scripts/release-macos.sh <version, e.g. 1.1>}
REPO="Nicolas-schimmelpfennig/BetterContentLibrary"
FEED_TAG="updates"
DOWNLOAD_PREFIX="https://github.com/$REPO/releases/download/$FEED_TAG/"

ARCHIVE="build/BetterContentLibrary-$VERSION.xcarchive"
ZIP="updates/BetterContentLibrary-$VERSION.zip"

# Sparkle's tools ship inside the SPM artifact; resolve the path dynamically.
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData \
    -type d -path "*SourcePackages/artifacts/sparkle/Sparkle/bin" 2>/dev/null | head -1)
if [[ -z "$SPARKLE_BIN" ]]; then
    echo "error: Sparkle tools not found — build the app once in Xcode so SPM fetches them" >&2
    exit 1
fi

echo "==> Archiving $VERSION"
xcodebuild -project BetterContentLibrary.xcodeproj \
    -scheme BetterContentLibrary \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$VERSION" \
    archive | tail -2

APP="$ARCHIVE/Products/Applications/BetterContentLibrary.app"
[[ -d "$APP" ]] || { echo "error: archive produced no app at $APP" >&2; exit 1; }

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
