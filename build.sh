#!/bin/bash
# Builds "GPT Translate.app" for Apple silicon and Intel. `./build.sh install` also copies it to /Applications
# and (re)starts it.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/GPT Translate.app"
BUNDLE_ID="io.github.yufei-zhou.GPTTranslate"
# Releases are signed with one fixed self-signed certificate, so macOS keeps treating every update as the same app
# and the Input Monitoring permission carries over. (Keychain access is tied to the exact build without a Team ID,
# so the first launch after an update asks for the Mac password once.) Without it the build is signed ad hoc.
SIGN_ID="${SIGN_ID:-GPT Translate Release}"

swift build -c release --arch arm64 --arch x86_64
mkdir -p build
if [ ! -f build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
  swift Scripts/make_icon.swift build/icon_1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/out/Products/Release/GPTTranslate "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp build/AppIcon.icns "$APP/Contents/Resources/"
# The certificate is self-signed, so it isn't "valid" for find-identity -v; look for it among all identities.
if security find-identity -p codesigning | grep -q "\"$SIGN_ID\""; then
  codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
elif [ "${REQUIRE_SIGNING:-}" = 1 ]; then
  echo "Signing certificate \"$SIGN_ID\" not found; a release must be signed with it." >&2
  exit 1
else
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi

if [ "${1:-}" = "install" ]; then
  pkill -x GPTTranslate || true
  sleep 0.5
  rm -rf "/Applications/GPT Translate.app"
  cp -R "$APP" /Applications/
  open "/Applications/GPT Translate.app"
fi
echo "Built $APP"
