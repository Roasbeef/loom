#!/usr/bin/env bash
#
# Build a libkrunfw whose guest kernel has Landlock (ADR-022, D3): the
# libkrunfw.5.dylib a macOS host loads, or the libkrunfw.so.5 a Linux host
# loads.
#
# Upstream builds the macOS variant by compiling the kernel in a Linux VM and
# bundling the resulting image into a shared library on the host. This script
# follows the same split. The Linux half produces kernel.c with upstream's own
# Makefile (patches, config, olddefconfig and bin2cbundle.py). The link half
# compiles kernel.c as upstream's Makefile does: cc -fPIC -DABI_VERSION=5
# -shared, with a soname and a strip on Linux.
#
# A kernel is built for one architecture and a library serves guests of one
# architecture: aarch64 on an Apple Silicon host, and the host's own on Linux.
# An x86_64 kernel links into the arm64 dylib without complaint and fails only
# when a guest boots, so the link half reads the architecture back out of
# kernel.c and refuses a kernel that does not match the library.
#
# Each half is a mode of its own, so that CI can run the Linux half on a Linux
# runner and the link on a macOS one, and a developer can run both with one
# command:
#
#   build-libkrunfw.sh OUTPUT_DIR
#       Both halves. On macOS the kernel builds in a podman container and the
#       dylib is linked on the host. On Linux both run natively, as --kernel
#       and --link below.
#   build-libkrunfw.sh --kernel OUTPUT_DIR
#       Linux, the first half with no container: OUTPUT_DIR/kernel.c and the
#       resolved configs, for this machine's architecture (aarch64 or x86_64).
#       Installs its build dependencies with apt-get, through sudo when not
#       root.
#   build-libkrunfw.sh --link KERNEL_C OUTPUT_DIR
#       The second half: OUTPUT_DIR/libkrunfw.5.dylib on macOS or
#       OUTPUT_DIR/libkrunfw.so.5 on Linux, from kernel.c. Refuses a kernel
#       built for another architecture than the library's.
#
# Environment:
#   PODMAN_CONNECTION  podman connection to build on (default: loom-build).
#   JOBS               parallel kernel jobs (default: 8 in the container, the
#                      CPU count with --kernel).
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

# sha256_of prints the SHA-256 of a file on macOS and on Linux.
sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

# fetch_sources clones libkrunfw at the pinned tag, verifies the commit it
# resolves to, and downloads the kernel tarball, verifying its checksum. It
# leaves the clone at WORK/libkrunfw and the tarball under WORK/in.
fetch_sources() {
	local work=$1 got sum

	local src=${work}/libkrunfw
	if [ ! -d "${src}/.git" ]; then
		git clone --quiet --depth 1 --branch "${LIBKRUNFW_TAG}" \
			"${LIBKRUNFW_REPO}" "${src}"
	fi
	got=$(git -C "${src}" rev-parse HEAD)
	if [ "${got}" != "${LIBKRUNFW_COMMIT}" ]; then
		echo "libkrunfw ${LIBKRUNFW_TAG} is ${got}, expected ${LIBKRUNFW_COMMIT}" >&2
		exit 1
	fi

	mkdir -p "${work}/in"
	local tarball=${work}/in/${KERNEL_VERSION}.tar.xz
	if [ ! -f "${tarball}" ]; then
		curl -fsSL "${KERNEL_URL}" -o "${tarball}"
	fi
	sum=$(sha256_of "${tarball}")
	if [ "${sum}" != "${KERNEL_SHA256}" ]; then
		echo "${KERNEL_VERSION}.tar.xz sha256 is ${sum}, expected ${KERNEL_SHA256}" >&2
		rm -f "${tarball}"
		exit 1
	fi
}

# build_kernel is the Linux half. It copies the libkrunfw checkout out of its
# read-only source directory, so that the kernel tree lives on a writable
# disk, builds kernel.c, and leaves it with the resolved configs in OUT_DIR.
#
# The directories default to the mount points the podman mode uses. --kernel
# overrides them with host paths. SUDO is empty in a container, which runs as
# root, and "sudo" on a runner.
build_kernel() {
	local src=${SRC_DIR:-/src} in=${IN_DIR:-/in} guest=${GUEST_DIR:-/guest}
	local out=${OUT_DIR:-/out} build=${BUILD_DIR:-/build} sudo=${SUDO:-}

	export DEBIAN_FRONTEND=noninteractive
	${sudo} apt-get update -qq
	${sudo} apt-get install -y -qq --no-install-recommends \
		build-essential bc bison flex libssl-dev libelf-dev \
		python3 python3-pyelftools xz-utils patch cpio rsync kmod \
		libncurses-dev dwarves ca-certificates >/dev/null

	cp -a "${src}" "${build}"
	cd "${build}"
	mkdir -p tarballs
	cp "${in}/${KERNEL_VERSION}.tar.xz" tarballs/

	# Extract, patch, install upstream's config and run olddefconfig.
	make -j"${JOBS}" "${KERNEL_VERSION}"
	cp "${KERNEL_VERSION}/.config" "${out}/config.upstream-resolved"

	# Merge the Landlock fragment, then resolve newly exposed symbols.
	(cd "${KERNEL_VERSION}" &&
		./scripts/kconfig/merge_config.sh -m .config "${guest}/libkrunfw-landlock.config" >/dev/null &&
		make olddefconfig)
	cp "${KERNEL_VERSION}/.config" "${out}/config.landlock"
	for opt in CONFIG_SECURITY=y CONFIG_SECURITYFS=y CONFIG_SECURITY_LANDLOCK=y \
		'CONFIG_LSM="landlock"'; do
		grep -qxF "${opt}" "${KERNEL_VERSION}/.config" || {
			echo "config check failed: ${opt} missing" >&2
			exit 1
		}
	done

	# Build the kernel image and bundle it as C, as upstream's make does.
	make -j"${JOBS}" kernel.c
	cp kernel.c "${out}/kernel.c"
}

# kernel_arch prints the guest architecture a kernel.c holds. bin2cbundle.py
# ends the file with the kernel's load address: the fixed 0x80000000 for an
# arm64 Image, and the decimal address of the first PT_LOAD segment for an
# x86_64 vmlinux. Reading it from the file, not from a sidecar, means a
# kernel.c that crossed a CI artifact boundary still says what it is.
kernel_arch() {
	if grep -qF '*load_addr = 0x80000000;' "$1"; then
		echo aarch64
	elif grep -qE '\*load_addr = [0-9]+;' "$1"; then
		echo x86_64
	else
		echo "build-libkrunfw.sh: $1 has no load address footer" >&2
		return 1
	fi
}

# library_arch prints the architecture of the guest the library built on this
# machine serves. A macOS host is Apple Silicon and runs an aarch64 guest; a
# Linux host runs a guest of its own architecture.
library_arch() {
	if [ "$(uname -s)" = Darwin ]; then
		echo aarch64
	else
		case "$(uname -m)" in
		arm64 | aarch64) echo aarch64 ;;
		*) uname -m ;;
		esac
	fi
}

# library_name prints the file name the runner's loader looks for.
library_name() {
	if [ "$(uname -s)" = Darwin ]; then
		echo "libkrunfw.${ABI_VERSION}.dylib"
	else
		echo "libkrunfw.so.${ABI_VERSION}"
	fi
}

# link_library is the link half: upstream's link line for the bundle, which
# adds a soname and strips on Linux. It refuses a kernel built for another
# architecture than this machine's library serves.
link_library() {
	local kernel_c=$1 out=$2 want got

	want=$(library_arch)
	got=$(kernel_arch "${kernel_c}")
	if [ "${got}" != "${want}" ]; then
		echo "build-libkrunfw.sh: ${kernel_c} is a ${got} kernel, and this library serves ${want} guests" >&2
		exit 1
	fi

	mkdir -p "${out}"
	if [ "$(uname -s)" = Darwin ]; then
		cc -fPIC -DABI_VERSION="${ABI_VERSION}" -shared \
			-o "${out}/$(library_name)" "${kernel_c}"
	else
		cc -fPIC -DABI_VERSION="${ABI_VERSION}" -shared \
			-Wl,-soname,"$(library_name)" \
			-o "${out}/$(library_name)" "${kernel_c}"
		strip "${out}/$(library_name)"
	fi
}

# kernel_native is the first half run directly on this Linux machine, with no
# container. It installs build dependencies, builds in a fresh directory under
# WORK on the machine's own disk and leaves kernel.c and the configs in OUT.
kernel_native() {
	local out=$1 work=$2

	fetch_sources "${work}"

	SUDO=
	[ "$(id -u)" = 0 ] || SUDO=sudo
	export SUDO

	BUILD_DIR=${work}/build
	rm -rf "${BUILD_DIR}"
	export SRC_DIR=${work}/libkrunfw IN_DIR=${work}/in GUEST_DIR=${here} \
		OUT_DIR=${out} BUILD_DIR
	JOBS=${JOBS:-$(nproc)}
	build_kernel
}

# absolute prints the absolute form of a directory, creating it.
absolute() {
	mkdir -p "$1"
	(cd "$1" && pwd)
}

case "${1:-}" in
--in-container)
	# Runs inside the podman container the default mode starts.
	JOBS=${JOBS:-8}
	build_kernel
	exit 0
	;;

--kernel)
	if [ "$(uname -s)" != Linux ]; then
		echo "build-libkrunfw.sh: --kernel runs on Linux; on macOS give OUTPUT_DIR alone" >&2
		exit 1
	fi

	out=$(absolute "${2:?usage: build-libkrunfw.sh --kernel OUTPUT_DIR}")
	kernel_native "${out}" "$(absolute "${WORK_DIR:-${out}/../firmware-work}")"
	echo "built ${out}/kernel.c ($(kernel_arch "${out}/kernel.c"))"
	exit 0
	;;

--link)
	kernel_c=${2:?usage: build-libkrunfw.sh --link KERNEL_C OUTPUT_DIR}
	out=$(absolute "${3:?usage: build-libkrunfw.sh --link KERNEL_C OUTPUT_DIR}")
	link_library "${kernel_c}" "${out}"
	echo "built ${out}/$(library_name)"
	exit 0
	;;
esac

# The default mode: both halves. On Linux they run natively. On macOS the
# kernel builds in a podman container and the link runs on the host.
out=$(absolute "${1:?usage: build-libkrunfw.sh OUTPUT_DIR}")
work=$(absolute "${WORK_DIR:-${out}/../firmware-work}")
start=$(date +%s)

rm -rf "${work}/out"
mkdir -p "${work}/out"

if [ "$(uname -s)" = Linux ]; then
	kernel_native "${work}/out" "${work}"
else
	conn=${PODMAN_CONNECTION:-loom-build}
	jobs=${JOBS:-8}

	fetch_sources "${work}"
	podman --connection "${conn}" run --rm \
		-v "${work}/libkrunfw:/src:ro" \
		-v "${work}/in:/in:ro" \
		-v "${here}:/guest:ro" \
		-v "${work}/out:/out" \
		-e JOBS="${jobs}" -e KERNEL_VERSION="${KERNEL_VERSION}" \
		"${BUILD_IMAGE}" bash /guest/build-libkrunfw.sh --in-container
fi

link_library "${work}/out/kernel.c" "${out}"

echo "built ${out}/$(library_name) in $(( $(date +%s) - start )) s"
