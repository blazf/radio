#!/bin/zsh
# Builds Radio.app into ./build. Run ./build.sh then open build/Radio.app
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Radio"

APP="build/Radio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Radio"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/* "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
