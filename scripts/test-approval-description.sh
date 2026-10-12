#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bipuu-approval-description.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -parse-as-library \
    Bipuu/Sources/BipuuKit/ApprovalDescription.swift \
    tests/ApprovalDescriptionTests.swift -o "$TEST_DIR/approval-description-tests"
"$TEST_DIR/approval-description-tests"
