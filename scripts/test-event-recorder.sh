#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bipuu-event-recorder.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
source scripts/_sdk.sh
scripts/build-core-modules.sh "$TEST_DIR/mods"
swiftc -swift-version 6 -target "$SWIFT_TARGET" -sdk "$SDK" -parse-as-library -I "$TEST_DIR/mods" -L "$TEST_DIR/mods" \
    -lBipuuCore -lBipuuSQLite \
    Bipuu/Sources/App/Recording/HookEventAdapter.swift Bipuu/Sources/App/Recording/EventRecorder.swift \
    tests/EventRecorderTests.swift -o "$TEST_DIR/event-recorder-tests"
"$TEST_DIR/event-recorder-tests"
