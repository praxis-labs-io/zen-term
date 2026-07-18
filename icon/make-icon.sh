#!/usr/bin/env bash
# Regenerate the app icons from make-icon.swift. Pure macOS tooling.
#   bin/make-icon.sh            both AppIcon.icns and AppIcon-Dev.icns (keeps them in sync)
#   bin/make-icon.sh --dev      only AppIcon-Dev.icns (leaves the release icon untouched)
#   bin/make-icon.sh --release  only AppIcon.icns
set -euo pipefail
cd "$(dirname "$0")"

build() {
    local out="$1"; shift
    local iconset="${out%.icns}.iconset"
    rm -rf "$iconset"
    swift make-icon.swift "$iconset" "$@"
    iconutil --convert icns --output "$out" "$iconset"
    rm -rf "$iconset"
    echo "✓ icon/$out"
}

# Bare run rebuilds both so the committed AppIcon-Dev.icns can't drift stale behind
# an AppIcon.icns redesign. --dev / --release refresh one without touching the other.
case "${1:-}" in
    --dev) build AppIcon-Dev.icns --dev ;;
    --release) build AppIcon.icns ;;
    "") build AppIcon.icns; build AppIcon-Dev.icns --dev ;;
    *) echo "✗ unknown argument: $1 (want --dev | --release | none)" >&2; exit 1 ;;
esac
