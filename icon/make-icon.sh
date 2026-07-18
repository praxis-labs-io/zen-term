#!/usr/bin/env bash
# Regenerate icon/AppIcon.icns from make-icon.swift. Pure macOS tooling.
set -euo pipefail
cd "$(dirname "$0")"

build() {
    local out="$1" flag="${2:-}"
    local iconset="${out%.icns}.iconset"
    rm -rf "$iconset"
    swift make-icon.swift "$iconset" $flag
    iconutil --convert icns --output "$out" "$iconset"
    rm -rf "$iconset"
    echo "✓ icon/$out"
}

build AppIcon.icns
[[ "${1:-}" == "--dev" || "${1:-}" == "--all" ]] && build AppIcon-Dev.icns --dev
[[ "${1:-}" == "--dev" ]] && exit 0
