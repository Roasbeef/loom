#!/usr/bin/env bash
# Build a release candidate from a clean checkout inside an identified builder.
# Reproduction uses the same immutable toolchain image and /work/loom prefix.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd -P)"
[ "$ROOT" = /work/loom ] || {
  echo 'release-build: run inside the fixed /work/loom builder prefix' >&2
  exit 1
}
[ -z "$(git status --porcelain)" ] || {
  echo 'release-build: commit or remove checkout changes before building a candidate' >&2
  exit 1
}
: "${LOOM_BUILDER_ID:?set LOOM_BUILDER_ID to the immutable builder image identity}"
export SOURCE_DATE_EPOCH="$(git show -s --format=%ct HEAD)"
export TZ=UTC LC_ALL=C
export ERL_COMPILER_OPTIONS='[deterministic]'
export DIST_DEBUG=0 DIST_STRIP_ERTS=1 DIST_CODEMODE=1
# Native compilation receives the same logical source prefix in both builders.
export CFLAGS="${CFLAGS:-} -ffile-prefix-map=$ROOT=/work/loom -fdebug-prefix-map=$ROOT=/work/loom"
export CXXFLAGS="${CXXFLAGS:-} -ffile-prefix-map=$ROOT=/work/loom -fdebug-prefix-map=$ROOT=/work/loom"
python3 - <<'PY'
import os
import subprocess
for name in subprocess.check_output(['git', 'ls-files', '-z']).split(b'\0'):
    if name:
        os.utime(os.fsdecode(name), (int(os.environ['SOURCE_DATE_EPOCH']),) * 2, follow_symlinks=False)
PY
mkdir -p build
python3 scripts/release-inputs.py > build/release-inputs.json
make codemode-seed release release-client tui-shipment
scripts/dist.sh
make release-smoke release-client-smoke
# Every claimed input must still match the source tree after generation.
git diff --exit-code
