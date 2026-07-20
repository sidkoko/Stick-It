#!/bin/bash
# Builds Stick-It and packages build/Stick-It.app.zip for a GitHub release —
# bundles "Read Me First.txt" alongside the app so the Gatekeeper fix is the
# first thing people see, not a link they have to go find.
set -e
cd "$(dirname "$0")"

./build.sh

STAGE=build/stage
rm -rf "$STAGE" build/Stick-It.app.zip
mkdir -p "$STAGE/Stick-It"
cp -R build/Stick-It.app "$STAGE/Stick-It/"
cp "Read Me First.txt" "$STAGE/Stick-It/"
ditto -c -k --sequesterRsrc --keepParent "$STAGE/Stick-It" build/Stick-It.app.zip
rm -rf "$STAGE"

echo "Packaged build/Stick-It.app.zip"
