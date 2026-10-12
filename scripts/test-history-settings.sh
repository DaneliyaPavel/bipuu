#!/usr/bin/env bash
# What the History settings mean (defaults, overrides, policies) and a render of the page. Pass a directory to keep the PNG.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bipuu-history-settings.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
source scripts/_sdk.sh
scripts/build-core-modules.sh "$TEST_DIR/mods"
swiftc -swift-version 6 -target "$SWIFT_TARGET" -sdk "$SDK" -parse-as-library -I "$TEST_DIR/mods" -L "$TEST_DIR/mods" -lBipuuCore \
    Bipuu/Sources/App/Recording/HistorySettings.swift Bipuu/Sources/App/Recording/HistorySettingsView.swift \
    tests/HistorySettingsTests.swift -o "$TEST_DIR/history-settings-tests"
OUT="${1:-$TEST_DIR}"; mkdir -p "$OUT"
"$TEST_DIR/history-settings-tests" "$OUT"
