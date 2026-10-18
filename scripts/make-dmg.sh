#!/bin/zsh
# Builds Void Mail in Release and packages it as build/Void-Mail-<version>.dmg
# (Void Mail.app + a shortcut to /Applications, to install by drag and drop).
#   ./scripts/make-dmg.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
DERIVED="$ROOT/build/DerivedData"
APP="$DERIVED/Build/Products/Release/Void Mail.app"

echo "→ Compilation Release…"
# The Mac target alone, explicit build folders: the same command as Void Notes, ready for an iPhone target.
xcodebuild -project VoidMail.xcodeproj -target VoidMail -configuration Release \
  SYMROOT="$DERIVED/Build/Products" OBJROOT="$DERIVED/Build/Intermediates.noindex" build -quiet

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="$ROOT/build/Void-Mail-$VERSION.dmg"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

echo "→ Préparation de l'image disque…"
ditto "$APP" "$STAGING/Void Mail.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "Void Mail $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" -quiet

echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
