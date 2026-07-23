#!/bin/bash
# Builds Stick-It.app into ./build. Run with --run to also launch it.
set -e
cd "$(dirname "$0")"

swift build -c release

APP=build/Stick-It.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/StickIt "$APP/Contents/MacOS/Stick-It"
# Loaded via Bundle.main, not SPM's generated Bundle.module — that accessor expects
# either a bundle sitting loose at the .app's top level (which codesign refuses to
# seal: "unsealed contents present in the bundle root") or a hardcoded path to
# whichever machine compiled it (only ever valid here). Plain files in the standard
# Contents/Resources/ location sidesteps both problems.
cp Sources/StickIt/Resources/*.html "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/"
codesign --force -s - "$APP"

echo "Built $APP"
if [ "$1" = "--run" ]; then
  open "$APP"
fi
