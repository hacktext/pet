#!/bin/bash
# macOS (Apple silicon) package of 桌遇 DeskMeet: builds aipet.app and wraps
# it, named 桌遇.app, in dist/DeskMeet-<version>-arm64.dmg at the repo root
# (dist/ is git-ignored). The bundle's binary and id stay aipet: renaming
# those would cut existing installs off their data and settings.
#
#   apps/aipet/installer/build_macos.sh
#
# Without signing settings the app keeps Flutter's ad-hoc signature: fine on
# this Mac; on another Mac the first launch needs right-click -> Open (or
# `xattr -dr com.apple.quarantine /Applications/桌遇.app`).
#
# To ship to other people, sign and notarize (Apple Developer account):
#   AIPET_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   AIPET_NOTARY_PROFILE=your-notary-profile \
#   apps/aipet/installer/build_macos.sh
# where the profile was stored once with
#   xcrun notarytool store-credentials your-notary-profile --apple-id ... --team-id ...
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$APP_DIR/../.." && pwd)"
DIST="$REPO_DIR/dist"
VERSION="$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' "$APP_DIR/pubspec.yaml")"
DMG="$DIST/DeskMeet-$VERSION-arm64.dmg"

command -v flutter >/dev/null || export PATH="$HOME/development/flutter/bin:$PATH"
export LANG="${LANG:-en_US.UTF-8}"  # CocoaPods needs a UTF-8 locale

cd "$APP_DIR"
flutter build macos --release
# flutter (re)writes analysis_options.yaml on every build; keep the tracked one.
git -C "$APP_DIR" checkout -- analysis_options.yaml 2>/dev/null || true

APP="$APP_DIR/build/macos/Build/Products/Release/aipet.app"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/aipet")"
[ "$ARCHS" = "arm64" ] || { echo "expected an arm64-only binary, got: $ARCHS" >&2; exit 1; }

if [ -n "${AIPET_SIGN_IDENTITY:-}" ]; then
  codesign --force --deep --options runtime --timestamp \
    --entitlements "$APP_DIR/macos/Runner/Release.entitlements" \
    --sign "$AIPET_SIGN_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"

# Staple the app itself too, so it still opens once copied out of the dmg on a
# Mac that cannot reach Apple's servers.
if [ -n "${AIPET_SIGN_IDENTITY:-}" ] && [ -n "${AIPET_NOTARY_PROFILE:-}" ]; then
  ZIP="$(mktemp -d)/aipet.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$AIPET_NOTARY_PROFILE" --wait
  rm -f "$ZIP"
  xcrun stapler staple "$APP"
fi

# dmg: the app plus an Applications link to drag it onto.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/桌遇.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$DIST"
rm -f "$DMG"
hdiutil create -volname "桌遇" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

if [ -n "${AIPET_SIGN_IDENTITY:-}" ]; then
  codesign --sign "$AIPET_SIGN_IDENTITY" --timestamp "$DMG"
  if [ -n "${AIPET_NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$AIPET_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi

echo "wrote $DMG ($(du -h "$DMG" | cut -f1))"
