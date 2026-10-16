#!/bin/bash
# Publishes a release: builds the DMG, creates the GitHub release v<version> (CFBundleShortVersionString in
# Info.plist) and points the Homebrew cask in vcamaral/homebrew-tap at it.
# Usage: ./scripts/release.sh [notes.md]   (without a notes file, GitHub writes them from the commits)
set -euo pipefail
cd "$(dirname "$0")/.."

APP=Utter
CASK=utter
REPO=vcamaral/utter
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
TAG="v$VERSION"

[[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first."; exit 1; }
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    echo "$TAG already exists: bump CFBundleShortVersionString in Info.plist."
    exit 1
fi
git push -q origin HEAD

./scripts/make-dmg.sh
notes=(--generate-notes)
[[ -n "${1:-}" ]] && notes=(--notes-file "$1")
gh release create "$TAG" "build/$APP.dmg" -R "$REPO" --title "$APP $VERSION" "${notes[@]}"

# Homebrew: brew upgrade compares the cask's version, so update it along with the DMG's checksum.
SHA=$(shasum -a 256 "build/$APP.dmg" | cut -d' ' -f1)
TAP=$(mktemp -d)
trap 'rm -rf "$TAP"' EXIT
gh repo clone vcamaral/homebrew-tap "$TAP" -- -q
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TAP/Casks/$CASK.rb"
git -C "$TAP" commit -qam "$CASK $VERSION"
git -C "$TAP" push -q
echo "Released $APP $VERSION: https://github.com/$REPO/releases/tag/$TAG"
