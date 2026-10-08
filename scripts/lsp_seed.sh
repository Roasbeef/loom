#!/usr/bin/env bash
# Prepare every workspace package for an offline Gleam language server.
# The code-mode seed contains a different dependency graph; preparing it
# alone cannot install the dependencies of a queried workspace package.
set -euo pipefail
cd "$(dirname "$0")/.."

# Resolve Apple's developer-tool shim on the host, before a private HOME or
# offline jail makes its xcrun cache unavailable. No server gains networking.
if [ "$(uname -s)" = Darwin ] && [ "$(command -v git)" = /usr/bin/git ]; then
  git_program=$(/usr/bin/xcrun --find git)
  export PATH="$(dirname "$git_program"):$PATH"
fi

for project in packages/*/gleam.toml; do
  package=${project%/gleam.toml}
  echo "lsp seed: preparing $package"
  settled=0
  for attempt in 1 2 3 4 5 6; do
    if ! output=$(cd "$package" && gleam deps download 2>&1); then
      printf '%s\n' "$output" >&2
      echo "lsp seed: dependency preparation failed for $package" >&2
      exit 1
    fi
    case "$output" in
      *"Resolving versions"*) ;;
      *) settled=1; break ;;
    esac
  done
  if [ "$settled" -ne 1 ]; then
    echo "lsp seed: $package still resolves after six passes" >&2
    exit 1
  fi
done

echo "lsp seed: workspace dependencies prepared; language servers remain offline"
