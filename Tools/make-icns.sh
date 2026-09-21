#!/bin/zsh
# Regenerates Resources/AppIcon.icns from Tools/make-icon.swift
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
swift Tools/make-icon.swift "$TMP/icon_1024.png"
ISET="$TMP/AppIcon.iconset"
mkdir -p "$ISET"
for sz in 16 32 128 256 512; do
  sips -z $sz $sz "$TMP/icon_1024.png" --out "$ISET/icon_${sz}x${sz}.png" >/dev/null
  dbl=$((sz*2))
  sips -z $dbl $dbl "$TMP/icon_1024.png" --out "$ISET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ISET" -o Resources/AppIcon.icns
cp "$TMP/icon_1024.png" Tools/icon-preview.png
echo "wrote Resources/AppIcon.icns"
