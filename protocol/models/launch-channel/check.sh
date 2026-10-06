#!/usr/bin/env bash
# This model-local gate retains safety, exact witness and mutation evidence.
set -euo pipefail
model="$(cd "$(dirname "$0")" && pwd)"
python3 "$model/run.py" --schedules "${MODEL_SCHEDULES:-1000}" --probe-schedules "${MODEL_PROBE_SCHEDULES:-2000}" --seed "${MODEL_SEED:-697}"
python3 "$model/mutate.py" --schedules "${MODEL_MUTATION_SCHEDULES:-100}" --seed "${MODEL_SEED:-697}"
