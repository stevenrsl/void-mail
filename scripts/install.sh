#!/bin/zsh
# Builds Void Mail in Release and puts it in /Applications, in place of the copy there; quits the
# app first if it is running, and opens the new one.
#   ./scripts/install.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
DERIVED="$ROOT/build/DerivedData"
APP="$DERIVED/Build/Products/Release/Void Mail.app"
TARGET="/Applications/Void Mail.app"

echo "→ Compilation Release…"
# The Mac target alone, explicit build folders: the same command as Void Notes, ready for an iPhone target.
xcodebuild -project VoidMail.xcodeproj -target VoidMail -configuration Release \
  SYMROOT="$DERIVED/Build/Products" OBJROOT="$DERIVED/Build/Intermediates.noindex" build -quiet

"$ROOT/scripts/copy-to-applications.sh" "$APP"
# Right after the old copy quits, Launch Services may still refuse (error -600): once more.
open "$TARGET" 2>/dev/null || { sleep 1; open "$TARGET"; }
