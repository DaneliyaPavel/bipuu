#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bipuu-channel-auth.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -parse-as-library \
    Bipuu/Sources/App/ChannelAuth.swift \
    tests/ChannelAuthTests.swift -o "$TEST_DIR/channel-auth-tests"
"$TEST_DIR/channel-auth-tests"
