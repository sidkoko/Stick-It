#!/bin/bash
# Double-click this to install and open Stick-It in one step — clears the
# macOS "unidentified developer" flag so there's no System Settings hunting.
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -d "/Applications/Stick-It.app" ]; then
  APP="/Applications/Stick-It.app"
elif [ -d "$DIR/Stick-It.app" ]; then
  echo "Moving Stick-It to Applications..."
  cp -R "$DIR/Stick-It.app" /Applications/
  APP="/Applications/Stick-It.app"
else
  echo "Couldn't find Stick-It.app — make sure this is in the same unzipped folder as it."
  read -p "Press Return to close..."
  exit 1
fi

echo "Clearing the security flag..."
xattr -cr "$APP"

echo "Opening Stick-It..."
open "$APP"

sleep 1
echo ""
echo "Done! Stick-It should be opening now. This window can be closed."
sleep 3
