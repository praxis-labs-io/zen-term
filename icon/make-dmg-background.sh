#!/usr/bin/env bash
# Regenerate the DMG installer background from make-dmg-background.swift. Pure macOS tooling.
#   bin/make-dmg-background.sh   emits dmg-background.tiff (1x + 2x HiDPI reps)
# The committed dmg-background.tiff is what bin/make-dmg copies into the volume's
# .background/ — regenerate it here whenever the installer art changes.
set -euo pipefail
cd "$(dirname "$0")"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

swift make-dmg-background.swift "$tmp/bg.png" 1
swift make-dmg-background.swift "$tmp/bg@2x.png" 2

# One TIFF carrying both resolutions; -cathidpicheck tags the 2x rep as HiDPI so Finder
# picks the right one for the display. This is the form a DMG background image expects.
tiffutil -cathidpicheck "$tmp/bg.png" "$tmp/bg@2x.png" -out dmg-background.tiff

echo "✓ icon/dmg-background.tiff"
