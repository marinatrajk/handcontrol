#!/bin/bash
# Builds build/HandControl.app. Needs only the Xcode Command Line Tools.
#   ./build.sh          build the app
#   ./build.sh test     run the gesture engine tests
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build

if [[ "${1:-}" == "test" ]]; then
  xcrun swiftc -O -swift-version 5 Sources/HandPose.swift Sources/GestureEngine.swift Tests/main.swift -o build/engine-tests
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
