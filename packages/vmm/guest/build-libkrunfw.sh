#!/usr/bin/env bash
#
# Build a libkrunfw.5.dylib whose guest kernel has Landlock (ADR-022, D3).
#
# Upstream builds the macOS variant by compiling the kernel in a Linux VM and
# bundling the resulting image into a shared library on the host. This script
# follows the same split. The Linux half runs in a podman container and
# produces kernel.c with upstream's own Makefile (patches, config, olddefconfig
# and bin2cbundle.py). The host half compiles kernel.c as upstream's Makefile
# does for Darwin: cc -fPIC -DABI_VERSION=5 -shared.
#
# Usage: build-libkrunfw.sh OUTPUT_DIR
#
# Environment:
#   PODMAN_CONNECTION  podman connection to build on (default: loom-build).
#   JOBS               parallel kernel jobs inside the container (default: 8).
#   WORK_DIR           scratch directory (default: OUTPUT_DIR/../firmware-work).
#
# The libkrunfw tag and the kernel tarball are pinned below. The installed
# libkrun must accept the ABI version of the tag (libkrun 1.19.4 loads ABI 5).

set -euo pipefail

LIBKRUNFW_REPO=https://github.com/containers/libkrunfw
LIBKRUNFW_TAG=v5.5.0
# The commit the tag must resolve to. A moved tag fails the build.
LIBKRUNFW_COMMIT=ec4b297964877d83432f9ccda6dad8ff6e9de3e4

KERNEL_VERSION=linux-6.12.91
KERNEL_URL=https://cdn.kernel.org/pub/linux/kernel/v6.x/${KERNEL_VERSION}.tar.xz
# From https://cdn.kernel.org/pub/linux/kernel/v6.x/sha256sums.asc.
KERNEL_SHA256=0ff2ab9e169f9f1948557471fbb450d3018f8c5b77caf288e1a3982582597969

# The stock libkrunfw is built with Ubuntu 24.04's toolchain.
BUILD_IMAGE=docker.io/library/ubuntu:24.04
ABI_VERSION=5

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# in_container runs inside the build container. It copies the checkout out of
# the bind mount, so that the kernel tree lives on the container's own disk,
# builds kernel.c, and leaves it with the resolved configs in /out.
in_container() {
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y -qq --no-install-recommends \
		build-essential bc bison flex libssl-dev libelf-dev \
		python3 python3-pyelftools xz-utils patch cpio rsync kmod \
		libncurses-dev dwarves ca-certificates >/dev/null

	cp -a /src /build
	cd /build
	mkdir -p tarballs
	cp "/in/${KERNEL_VERSION}.tar.xz" tarballs/

	# Extract, patch, install upstream's config and run olddefconfig.
	make -j"${JOBS}" "${KERNEL_VERSION}"
	cp "${KERNEL_VERSION}/.config" /out/config.upstream-resolved

	# Merge the Landlock fragment, then resolve newly exposed symbols.
	(cd "${KERNEL_VERSION}" &&
		./scripts/kconfig/merge_config.sh -m .config /guest/libkrunfw-landlock.config >/dev/null &&
		make olddefconfig)
	cp "${KERNEL_VERSION}/.config" /out/config.landlock
	for opt in CONFIG_SECURITY=y CONFIG_SECURITYFS=y CONFIG_SECURITY_LANDLOCK=y \
		'CONFIG_LSM="landlock"'; do
		grep -qxF "${opt}" "${KERNEL_VERSION}/.config" || {
			echo "config check failed: ${opt} missing" >&2
			exit 1
		}
	done

	# Build the kernel image and bundle it as C, as upstream's make does.
	make -j"${JOBS}" kernel.c
	cp kernel.c /out/kernel.c
}

if [ "${1:-}" = "--in-container" ]; then
	in_container
	exit 0
fi

# A Linux host loads libkrunfw.so.5 rather than a dylib, and that half is not
# written yet. It is refused before the container build, which takes minutes,
# rather than after it.
if [ "$(uname -s)" != Darwin ]; then
	echo "build-libkrunfw.sh: only the macOS dylib is built so far" >&2
	exit 1
fi

out=${1:?usage: build-libkrunfw.sh OUTPUT_DIR}
mkdir -p "${out}"
out=$(cd "${out}" && pwd)
work=${WORK_DIR:-${out}/../firmware-work}
mkdir -p "${work}"
work=$(cd "${work}" && pwd)
conn=${PODMAN_CONNECTION:-loom-build}
jobs=${JOBS:-8}

start=$(date +%s)

# Fetch libkrunfw at the pinned tag and verify the commit it resolves to.
src=${work}/libkrunfw
if [ ! -d "${src}/.git" ]; then
	git clone --quiet --depth 1 --branch "${LIBKRUNFW_TAG}" \
		"${LIBKRUNFW_REPO}" "${src}"
fi
got=$(git -C "${src}" rev-parse HEAD)
if [ "${got}" != "${LIBKRUNFW_COMMIT}" ]; then
	echo "libkrunfw ${LIBKRUNFW_TAG} is ${got}, expected ${LIBKRUNFW_COMMIT}" >&2
	exit 1
fi

# Fetch the kernel tarball and verify its checksum.
mkdir -p "${work}/in"
tarball=${work}/in/${KERNEL_VERSION}.tar.xz
if [ ! -f "${tarball}" ]; then
	curl -fsSL "${KERNEL_URL}" -o "${tarball}"
fi
sum=$(shasum -a 256 "${tarball}" | cut -d' ' -f1)
if [ "${sum}" != "${KERNEL_SHA256}" ]; then
	echo "${KERNEL_VERSION}.tar.xz sha256 is ${sum}, expected ${KERNEL_SHA256}" >&2
	rm -f "${tarball}"
	exit 1
fi

# The Linux half: patches, config, kernel, kernel.c.
rm -rf "${work}/out"
mkdir -p "${work}/out"
podman --connection "${conn}" run --rm \
	-v "${src}:/src:ro" \
	-v "${work}/in:/in:ro" \
	-v "${here}:/guest:ro" \
	-v "${work}/out:/out" \
	-e JOBS="${jobs}" -e KERNEL_VERSION="${KERNEL_VERSION}" \
	"${BUILD_IMAGE}" bash /guest/build-libkrunfw.sh --in-container

# The host half: upstream's Darwin link line for the bundle.
cc -fPIC -DABI_VERSION="${ABI_VERSION}" -shared \
	-o "${out}/libkrunfw.${ABI_VERSION}.dylib" "${work}/out/kernel.c"

echo "built ${out}/libkrunfw.${ABI_VERSION}.dylib in $(( $(date +%s) - start )) s"
