#!/bin/bash
# Builds Stick-It.app into ./build. Run with --run to also launch it.
set -e
cd "$(dirname "$0")"

swift build -c release

APP=build/Stick-It.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/StickIt "$APP/Contents/MacOS/Stick-It"
cp -R .build/release/StickIt_StickIt.bundle "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/"
codesign --force -s - "$APP" 2>/dev/null

echo "Built $APP"
if [ "$1" = "--run" ]; then
  open "$APP"
fi
