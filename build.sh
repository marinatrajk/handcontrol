#!/bin/bash
# Builds build/HandControl.app. Needs only the Xcode Command Line Tools.
#   ./build.sh                 build the app
#   ./build.sh test            run the gesture engine tests on synthetic hands
#   ./build.sh replay FILE     play a saved hand recording through the gesture engine
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build

if [[ "${1:-}" == "test" || "${1:-}" == "replay" ]]; then
  xcrun swiftc -O -swift-version 5 Sources/HandPose.swift Sources/GestureEngine.swift Sources/Recording.swift \
    Tests/*.swift -o build/engine-tests
  if [[ "$1" == "replay" ]]; then exec ./build/engine-tests "${2:?give the recording file}"; fi
  exec ./build/engine-tests
fi

APP=build/HandControl.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
  Sources/*.swift -o "$APP/Contents/MacOS/HandControl"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
