#!/bin/sh
# The release owns pre-VM deployment validation and the fixed TLS boot options.
# This wrapper selects a packaged role and refuses missing deployment support.
set -eu
role=${1:-}
[ "$#" -gt 0 ] && shift
case "$role" in
  owner) binary=loomd ;;
  executor) binary=loom-executor ;;
  *) echo 'loom-distributed-role: expected owner or executor' >&2; exit 64 ;;
esac
if ! command -v "$binary" >/dev/null 2>&1; then
  echo "loom-distributed-role: missing packaged $binary" >&2
  exit 69
fi
# Check direct entrypoint use as well as the utility's preliminary preflight.
help=$("$binary" --help) || exit $?
case "$help" in
  *--deployment*) ;;
  *) echo "loom-distributed-role: $binary lacks --deployment support" >&2; exit 69 ;;
esac
if [ "${1:-}" = --check-role ] && [ "$#" -eq 1 ]; then
  exit 0
fi
if [ "${1:-}" != --deployment ] || [ "$#" -lt 2 ]; then
  echo 'loom-distributed-role: explicit --deployment PATH required' >&2
  exit 64
fi
exec "$binary" "$@"
