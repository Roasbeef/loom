#!/usr/bin/env bash
# Use the same trusted publisher that installed clients carry for loom update.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
export LOOM_INSTALL_SOURCE="${LOOM_INSTALL_SOURCE:-$ROOT}"
exec bash "$ROOT/packages/tui/priv/install.sh" "$@"
