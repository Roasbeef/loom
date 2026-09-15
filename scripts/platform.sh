#!/usr/bin/env bash
# Name the native platform shared by release builders and installed clients.
set -euo pipefail
case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=macos ;;
  *) echo 'unsupported release operating system' >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64) arch=x86_64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo 'unsupported release architecture' >&2; exit 1 ;;
esac
printf '%s-%s\n' "$os" "$arch"
