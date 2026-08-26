#!/bin/bash
# Regenerate Resources/AppIcon.icns from assets/icon.svg.
# Needs rsvg-convert (brew install librsvg); iconutil ships with macOS.
set -euo pipefail
cd "$(dirname "$0")/.."
SET="$(mktemp -d)/Crema.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  rsvg-convert -w "$s" -h "$s" assets/icon.svg -o "$SET/icon_${s}x${s}.png"
  d=$((s * 2))
  rsvg-convert -w "$d" -h "$d" assets/icon.svg -o "$SET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
