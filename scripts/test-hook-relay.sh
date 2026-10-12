#!/usr/bin/env bash
# Characterization tests for the hook relay (Python) against a fake app socket.
set -euo pipefail
cd "$(dirname "$0")/.."
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/relay -v 2>&1 | tail -n 45
