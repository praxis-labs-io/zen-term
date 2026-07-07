#!/usr/bin/env bash
# Local mirror of CI: build → test → format-lint → lint. Run before shipping.
# Pass --fix to auto-apply swift-format + swiftlint fixes instead of failing.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v swiftlint >/dev/null 2>&1; then
    echo "✗ swiftlint not found — install it with: brew install swiftlint" >&2
    exit 1
fi

if [[ "${1:-}" == "--fix" ]]; then
    echo "▸ swift format (in place)"
    swift format --in-place --recursive Sources Tests
    echo "▸ swiftlint --fix"
    swiftlint lint --fix --quiet Sources Tests
    echo "✓ fixes applied — re-run scripts/check.sh to verify"
    exit 0
fi

echo "▸ swift build"
swift build

echo "▸ swift test"
swift test

echo "▸ swift format lint"
swift format lint --strict --recursive Sources Tests

echo "▸ swiftlint"
swiftlint lint --strict --quiet Sources Tests

echo "✓ all checks passed"
