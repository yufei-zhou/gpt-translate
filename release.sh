#!/bin/bash
# Publishes a release that install.sh picks up:  ./release.sh 1.0.1 "What changed"
# Needs the "GPT Translate Release" certificate in the Keychain and the GitHub CLI signed in.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
NOTES="${2:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: ./release.sh X.Y.Z [notes]" >&2
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "Commit or discard your changes first." >&2
  exit 1
fi

plutil -replace CFBundleShortVersionString -string "$VERSION" Resources/Info.plist
build=$(( $(plutil -extract CFBundleVersion raw Resources/Info.plist) + 1 ))
plutil -replace CFBundleVersion -string "$build" Resources/Info.plist

REQUIRE_SIGNING=1 ./build.sh
rm -f build/GPT-Translate.zip
ditto -c -k --keepParent "build/GPT Translate.app" build/GPT-Translate.zip

git commit -qam "Release $VERSION"
git tag "v$VERSION"
git push -q origin HEAD "v$VERSION"
gh release create "v$VERSION" build/GPT-Translate.zip --title "GPT Translate $VERSION" --notes "$NOTES"
