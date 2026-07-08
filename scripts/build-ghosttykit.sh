#!/usr/bin/env bash
# Build GhosttyKit.xcframework from source for the libghostty backend (ZEN-40 spike).
#
# libghostty ships no prebuilt embeddable artifact — the released Ghostty.app statically
# links it into its main binary. So we build it ourselves: pin the ghostty source, drive
# its Zig build to emit the macOS xcframework, and drop it where Package.swift's
# GhosttyKit binaryTarget expects it. The result (Frameworks/GhosttyKit.xcframework) is
# gitignored; every machine rebuilds it once with this script.
#
# Prereqs it can't install for you:
#   • Xcode (full) selected: xcode-select -p → /Applications/Xcode.app/...
#   • Metal toolchain: xcodebuild -downloadComponent MetalToolchain
# Everything else (Zig 0.15.2, the ghostty checkout) this script fetches on demand.
set -euo pipefail

GHOSTTY_TAG="v1.3.1"        # pins the C API + Swift reference we ported against
ZIG_VERSION="0.15.2"       # ghostty v1.3.1's minimum_zig_version
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"
ZIG_DIR="$VENDOR/zig-aarch64-macos-$ZIG_VERSION"
ZIG="$ZIG_DIR/zig"
GHOSTTY="$VENDOR/ghostty"

mkdir -p "$VENDOR"

# 1. Zig 0.15.2 — Homebrew tracks a newer Zig whose stdlib won't compile v1.3.1, so we
#    fetch the exact toolchain locally rather than install it system-wide.
if [ ! -x "$ZIG" ]; then
  echo "▸ fetching Zig $ZIG_VERSION"
  curl -sSL "https://ziglang.org/download/$ZIG_VERSION/zig-aarch64-macos-$ZIG_VERSION.tar.xz" \
    -o "$VENDOR/zig.tar.xz"
  tar xf "$VENDOR/zig.tar.xz" -C "$VENDOR"
  rm -f "$VENDOR/zig.tar.xz"
fi

# 2. ghostty source, pinned.
if [ ! -d "$GHOSTTY/.git" ]; then
  echo "▸ cloning ghostty $GHOSTTY_TAG"
  git clone --depth 1 --branch "$GHOSTTY_TAG" https://github.com/ghostty-org/ghostty.git "$GHOSTTY"
fi

# 3. Build the native (arm64-only) xcframework. app-runtime=none selects libghostty;
#    emit-macos-app=false skips the full app (which would need xcodebuild + signing).
echo "▸ building GhosttyKit.xcframework (this takes a few minutes)"
( cd "$GHOSTTY" && "$ZIG" build \
    -Dapp-runtime=none \
    -Demit-macos-app=false \
    -Dxcframework-target=native \
    -Doptimize=ReleaseFast )

# 4. Stage it where Package.swift's binaryTarget points.
echo "▸ staging Frameworks/GhosttyKit.xcframework"
rm -rf "$ROOT/Frameworks/GhosttyKit.xcframework"
mkdir -p "$ROOT/Frameworks"
cp -R "$GHOSTTY/macos/GhosttyKit.xcframework" "$ROOT/Frameworks/"

echo "✓ done — build with: swift build; run libghostty with: ZENTERM_BACKEND=ghostty swift run ZenTerm"
