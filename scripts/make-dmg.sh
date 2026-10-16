#!/bin/bash
# Builds the app and packages it as build/Utter.dmg (drag-to-Applications installer).
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh release

# dmgbuild lays out the DMG window without scripting Finder.
if [ ! -x build/venv/bin/dmgbuild ]; then
  python3 -m venv build/venv
  build/venv/bin/pip install -q dmgbuild
fi

swift scripts/make-dmg-background.swift build/dmg-background.png 1
swift scripts/make-dmg-background.swift build/dmg-background@2x.png 2
tiffutil -cathidpicheck build/dmg-background.png build/dmg-background@2x.png -out build/dmg-background.tiff >/dev/null

rm -f build/Utter.dmg
build/venv/bin/dmgbuild -s scripts/dmg-settings.py Utter build/Utter.dmg
echo "Built build/Utter.dmg"
