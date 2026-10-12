#!/usr/bin/env bash
# Sentences of the work view, and a render of it to PNG (pass an output directory to keep the pictures).
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bipuu-work-overview.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
source scripts/_sdk.sh
scripts/build-core-modules.sh "$TEST_DIR/mods"
swiftc -swift-version 6 -target "$SWIFT_TARGET" -sdk "$SDK" -parse-as-library -I "$TEST_DIR/mods" -L "$TEST_DIR/mods" -lBipuuCore \
    Bipuu/Sources/BipuuKit/ColorHex.swift Bipuu/Sources/App/Work/WorkOverviewView.swift \
    tests/WorkOverviewTests.swift -o "$TEST_DIR/work-overview-tests"
OUT="${1:-$TEST_DIR}"; mkdir -p "$OUT"
"$TEST_DIR/work-overview-tests" "$OUT"
