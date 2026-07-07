#!/usr/bin/env bash
# Regenerate icon/AppIcon.icns from make-icon.swift. Pure macOS tooling.
set -euo pipefail
cd "$(dirname "$0")"

ICONSET="AppIcon.iconset"
rm -rf "$ICONSET"
swift make-icon.swift "$ICONSET"
iconutil --convert icns --output AppIcon.icns "$ICONSET"
rm -rf "$ICONSET"
echo "✓ icon/AppIcon.icns"
