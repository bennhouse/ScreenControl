#!/bin/zsh
# Builds a universal ScreenControl.app and packs it into build/ScreenControl-<version>.dmg, with a
# shortcut to /Applications next to it. Nothing is installed.
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSAL=1 NO_INSTALL=1 scripts/build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG="build/ScreenControl-$VERSION.dmg"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R build/ScreenControl.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "ScreenControl" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "Built $PWD/$DMG"
