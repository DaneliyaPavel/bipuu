#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bipuu-hook-event-adapter.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
source scripts/_sdk.sh
scripts/build-core-modules.sh "$TEST_DIR/mods"
swiftc -swift-version 6 -target "$SWIFT_TARGET" -sdk "$SDK" -parse-as-library -I "$TEST_DIR/mods" -L "$TEST_DIR/mods" -lBipuuCore \
    Bipuu/Sources/App/Recording/HookEventAdapter.swift \
    tests/HookEventAdapterTests.swift -o "$TEST_DIR/hook-event-adapter-tests"
"$TEST_DIR/hook-event-adapter-tests"
