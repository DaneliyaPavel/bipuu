#!/usr/bin/env bash
# The work view's data path against a real database filled by the real recorder: read, refresh on events,
# confirm, rename, idle while hidden. Pass a directory to keep the rendered pictures.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bipuu-work-model.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
source scripts/_sdk.sh
scripts/build-core-modules.sh "$TEST_DIR/mods"
swiftc -swift-version 6 -target "$SWIFT_TARGET" -sdk "$SDK" -parse-as-library -I "$TEST_DIR/mods" -L "$TEST_DIR/mods" \
    -lBipuuCore -lBipuuSQLite \
    Bipuu/Sources/BipuuKit/ColorHex.swift Bipuu/Sources/App/Work/WorkOverviewView.swift Bipuu/Sources/App/Work/WorkModel.swift \
    Bipuu/Sources/App/Recording/HookEventAdapter.swift Bipuu/Sources/App/Recording/EventRecorder.swift \
    tests/WorkModelTests.swift -o "$TEST_DIR/work-model-tests"
OUT="${1:-$TEST_DIR}"; mkdir -p "$OUT"
"$TEST_DIR/work-model-tests" "$OUT"
