#!/usr/bin/env bash
# Verify packaging and the updater against private local fixtures.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/release-archive-test.py
python3 scripts/download_integration.py
python3 scripts/update_integration.py
