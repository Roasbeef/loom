#!/usr/bin/env bash
#
# Build libkrun from source on Linux, for the runner to link and load.
#
# macOS has a libkrun in a Homebrew tap, and Ubuntu has none. go-microvm's
# runner links libkrun with cgo through pkg-config, so a Linux host needs
# libkrun.so, its header and libkrun.pc in one prefix. This script builds that
# prefix from the release tag go-microvm v0.0.43 pins (versions.env), with the
# same feature flags as its builder image (BLK=1 NET=1).
#
#   build-libkrun.sh PREFIX
#       Writes PREFIX/lib64/libkrun.so{,.1,.1.19.7}, PREFIX/include and
#       PREFIX/lib64/pkgconfig/libkrun.pc. Installs its build dependencies
#       with apt-get, through sudo when not root.
#
# Environment:
#   WORK_DIR  scratch directory for the clone and, when no cargo is on PATH,
#             a Rust toolchain installed with rustup (default: PREFIX/../libkrun-work).
#             Ubuntu's own rustc is too old for libkrun; the toolchain stays in
#             WORK_DIR, so removing it removes everything the build added.
#   JOBS      parallel jobs (default: the CPU count).
#
# The loader looks up the library through LD_LIBRARY_PATH, which loom-vm sets
# from the manifest's lib_dir, so PREFIX/lib64 is what `--lib-dir` names.

set -euo pipefail

LIBKRUN_REPO=https://github.com/containers/libkrun
LIBKRUN_TAG=v1.19.7
# The commit the tag must resolve to. A moved tag fails the build.
LIBKRUN_COMMIT=43b2f5aadeebb90f42053c9df2ec8b16583e554f

if [ "$(uname -s)" != Linux ]; then
	echo "build-libkrun.sh: runs on Linux; macOS installs libkrun with Homebrew" >&2
	exit 1
fi

prefix=$(mkdir -p "${1:?usage: build-libkrun.sh PREFIX}" && cd "$1" && pwd)
work=$(mkdir -p "${WORK_DIR:-${prefix}/../libkrun-work}" && cd "${WORK_DIR:-${prefix}/../libkrun-work}" && pwd)
jobs=${JOBS:-$(nproc)}

SUDO=
[ "$(id -u)" = 0 ] || SUDO=sudo
export DEBIAN_FRONTEND=noninteractive
${SUDO} apt-get update -qq
${SUDO} apt-get install -y -qq --no-install-recommends \
	build-essential pkg-config clang libclang-dev patchelf git curl ca-certificates >/dev/null

# A Rust toolchain: the one on PATH, or a minimal rustup install in WORK_DIR.
if ! command -v cargo >/dev/null 2>&1; then
	export RUSTUP_HOME=${work}/rustup CARGO_HOME=${work}/cargo
	if [ ! -x "${CARGO_HOME}/bin/cargo" ]; then
		curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
	fi
	export PATH=${CARGO_HOME}/bin:${PATH}
fi
cargo --version

src=${work}/libkrun
if [ ! -d "${src}/.git" ]; then
	git clone --quiet --depth 1 --branch "${LIBKRUN_TAG}" "${LIBKRUN_REPO}" "${src}"
fi
got=$(git -C "${src}" rev-parse HEAD)
if [ "${got}" != "${LIBKRUN_COMMIT}" ]; then
	echo "libkrun ${LIBKRUN_TAG} is ${got}, expected ${LIBKRUN_COMMIT}" >&2
	exit 1
fi

# PREFIX is read when libkrun.pc is generated, so it is given to every make.
make -C "${src}" -j"${jobs}" PREFIX="${prefix}" BLK=1 NET=1
make -C "${src}" PREFIX="${prefix}" BLK=1 NET=1 install

echo "built libkrun ${LIBKRUN_TAG} in ${prefix}/lib64"
