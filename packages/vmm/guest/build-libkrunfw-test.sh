#!/usr/bin/env bash
#
# Test the link half of build-libkrunfw.sh with stub kernels, which needs no
# kernel build: a kernel.c is linked into this machine's library when its
# architecture is the one the library serves, and refused when it is not.
#
# The stubs carry the footer bin2cbundle.py writes, which is what the script
# reads the architecture from: the fixed 0x80000000 for an arm64 Image and a
# decimal address for an x86_64 vmlinux (libkrunfw v5.5.0).

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

# stub writes a kernel.c with the given load address into DIR.
stub() {
	local dir=$1 load=$2
	mkdir -p "${dir}"
	cat >"${dir}/kernel.c" <<C
#include <stddef.h>
__attribute__ ((aligned (65536))) char KERNEL_BUNDLE[] =
"\x0";
char * krunfw_get_kernel(size_t *load_addr, size_t *entry_addr, size_t *size)
{
    *load_addr = ${load};
    *entry_addr = ${load};
    *size = sizeof(KERNEL_BUNDLE) - 1;
    return &KERNEL_BUNDLE[0];
}

int krunfw_get_version()
{
    return ABI_VERSION;
}
C
}

stub "${tmp}/arm" 0x80000000
stub "${tmp}/x86" 16777216

case "$(uname -s)-$(uname -m)" in
Darwin-* | Linux-aarch64 | Linux-arm64)
	want=arm
	other=x86
	;;
Linux-x86_64)
	want=x86
	other=arm
	;;
*)
	echo "build-libkrunfw-test.sh: no library is built for $(uname -sm)" >&2
	exit 1
	;;
esac

# A kernel of the library's architecture links, under the name the loader
# looks for.
"${here}/build-libkrunfw.sh" --link "${tmp}/${want}/kernel.c" "${tmp}/out" >/dev/null
if [ "$(uname -s)" = Darwin ]; then
	test -f "${tmp}/out/libkrunfw.5.dylib"
else
	test -f "${tmp}/out/libkrunfw.so.5"
	readelf -d "${tmp}/out/libkrunfw.so.5" | grep -q 'SONAME.*libkrunfw.so.5'
fi

# A kernel of the other architecture is refused, and no library is written.
if "${here}/build-libkrunfw.sh" --link "${tmp}/${other}/kernel.c" "${tmp}/refused" 2>"${tmp}/err"; then
	echo "build-libkrunfw-test.sh: a ${other} kernel was linked" >&2
	exit 1
fi
grep -q "kernel, and this library serves" "${tmp}/err"
test -z "$(ls "${tmp}/refused")"

# A file that is not a bundled kernel is refused too.
echo 'int x;' >"${tmp}/junk.c"
if "${here}/build-libkrunfw.sh" --link "${tmp}/junk.c" "${tmp}/refused" 2>/dev/null; then
	echo "build-libkrunfw-test.sh: a file with no footer was linked" >&2
	exit 1
fi

echo "build-libkrunfw-test.sh: ok"
