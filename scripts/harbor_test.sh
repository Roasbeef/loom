#!/usr/bin/env bash
# Run the Harbor agent adapter's unit tests (integrations/harbor).
#
# The tests need no Docker, no network once the environment exists, and no
# model. They need Python >= 3.12, `uv`, and Harbor itself, because the
# adapter subclasses Harbor's installed-agent base class and its trajectories
# are checked with Harbor's own validator. The script skips with a message
# when `uv` is missing rather than failing, the way `make docker-smoke` skips
# without Docker, and it is not part of `make check`.
#
#   HARBOR_SRC=/path/to/harbor   use a local Harbor checkout (editable)
#   HARBOR_REF=<git ref>         otherwise install laude-institute/harbor at this ref
set -euo pipefail
cd "$(dirname "$0")/../integrations/harbor"

# The Harbor commit the adapter was verified against. The 0.24.0 wheel on PyPI
# is older than this and is not compatible.
HARBOR_REF="${HARBOR_REF:-6099b8cf2bfbbb3e7ff1eb2163bfc4524dbd9ba5}"

if ! command -v uv >/dev/null 2>&1; then
  echo "harbor-test: skipped, uv is not installed (https://docs.astral.sh/uv/)" >&2
  exit 0
fi

stamp=".venv/.harbor-source"
want="${HARBOR_SRC:-git+https://github.com/laude-institute/harbor@$HARBOR_REF}"
if [ ! -x .venv/bin/python ] || [ "$(cat "$stamp" 2>/dev/null)" != "$want" ]; then
  uv venv --python 3.13 --allow-existing .venv >/dev/null
  if [ -n "${HARBOR_SRC:-}" ]; then
    uv pip install --python .venv/bin/python -e "$HARBOR_SRC"
  else
    uv pip install --python .venv/bin/python "$want"
  fi
  uv pip install --python .venv/bin/python -e ".[test]"
  printf '%s\n' "$want" > "$stamp"
fi

exec .venv/bin/python -m pytest tests "$@"
