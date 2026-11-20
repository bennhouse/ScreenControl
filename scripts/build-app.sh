#!/bin/zsh
# Builds ScreenControl with SwiftPM, assembles build/ScreenControl.app, signs it ad hoc and
# installs it in /Applications.
#   scripts/build-app.sh               build, sign, install, relaunch
#   NO_INSTALL=1 scripts/build-app.sh  only build/ScreenControl.app
#   UNIVERSAL=1 ...                    Apple Silicon + Intel binary
#
# Ad hoc signing is enough: ScreenControl asks for no privacy permission (DDC, gamma tables and
# brightness need none), so nothing is lost when the signature changes between builds.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    swift build -c release --triple arm64-apple-macosx15.0
    swift build -c release --triple x86_64-apple-macosx15.0
    mkdir -p build
    lipo -create -output build/ScreenControl-bin \
        .build/arm64-apple-macosx/release/ScreenControl \
        .build/x86_64-apple-macosx/release/ScreenControl
    BIN="build/ScreenControl-bin"
else
    swift build -c release
    BIN=".build/release/ScreenControl"
fi

APP="build/ScreenControl.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ScreenControl"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - --identifier "local.screencontrol.ScreenControl" "$APP"

if [[ "${NO_INSTALL:-0}" != "1" ]]; then
    osascript -e 'tell application id "local.screencontrol.ScreenControl" to quit' 2>/dev/null || true
    sleep 0.5
    rm -rf "/Applications/ScreenControl.app"
    ditto "$APP" "/Applications/ScreenControl.app"
    open "/Applications/ScreenControl.app"
    echo "Installed and launched /Applications/ScreenControl.app"
else
    echo "Built $PWD/$APP"
fi
