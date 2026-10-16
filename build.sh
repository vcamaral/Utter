#!/bin/bash
# Usage: ./build.sh          -> builds build/Utter.app
#        ./build.sh install  -> builds, installs to ~/Applications and launches
set -euo pipefail
cd "$(dirname "$0")"

./scripts/setup-signing.sh >/dev/null
./scripts/build-whisper.sh
swift build -c release

APP="build/Utter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Utter "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Sign with the stable local certificate so Accessibility and Microphone permissions survive rebuilds.
if security find-identity -p codesigning | grep -q "Utter Local Signing"; then
    codesign --force --sign "Utter Local Signing" "$APP"
else
    echo "Warning: 'Utter Local Signing' certificate not found, using ad-hoc signing."
    codesign --force --sign - "$APP"
fi
echo "OK: $APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x Utter || true
    while pgrep -x Utter >/dev/null; do sleep 0.2; done
    mkdir -p ~/Applications
    rm -rf ~/Applications/Utter.app
    cp -R "$APP" ~/Applications/
    # LaunchServices sometimes refuses to open a bundle it hasn't registered yet (error -600): retry.
    for _ in 1 2 3 4 5; do open ~/Applications/Utter.app 2>/dev/null && break; sleep 1; done
    echo "Installed to ~/Applications/Utter.app"
fi
