#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bipuu-approval-queue.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc Bipuu/Sources/App/ApprovalQueue.swift Bipuu/Sources/BipuuKit/ApprovalDescription.swift \
    tests/ApprovalQueueTests.swift -o "$TEST_DIR/approval-queue-tests"
"$TEST_DIR/approval-queue-tests"
