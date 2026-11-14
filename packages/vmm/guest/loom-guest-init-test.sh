#!/bin/sh
#
# Test ensure_identity from loom-guest-init without a guest. The function is
# cut out of the script and run against a scratch passwd and group file, with
# chown and stat replaced by functions that stand for a host that can hand
# files over and one that cannot.
#
# What it pins: the loom user keeps uid 10000 when the hand-over works and
# takes the share owner's ids when it does not; an entry that an earlier
# rootless boot renumbered is put back when the hand-over works; an entry that
# is already right is not rewritten; and a share owned by root is refused.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

# The function, with the files it edits pointed at the scratch directory.
sed -n '/^ensure_identity() {/,/^}/p' "${here}/loom-guest-init" |
	sed "s|/etc/passwd|${tmp}/passwd|g; s|/etc/group|${tmp}/group|g" >"${tmp}/fn.sh"

# run SETTLES OWNER_UID PASSWD_UID: one call, printing the passwd line.
run() {
	settles=$1 owner=$2 had=$3
	printf 'loom:x:%s:%s::/home/loom:/bin/sh\n' "$had" "$had" >"${tmp}/passwd"
	printf 'loom:x:%s:\n' "$had" >"${tmp}/group"
	(
		LOOM_UID=10000
		LOOM_GID=10000
		chown() { [ "$settles" = yes ]; }
		stat() { echo "$owner"; }
		# GNU `sed -i`, which the guest has, edits in place; BSD sed wants a
		# suffix argument, so the in-place form is spelled out here.
		sed() {
			if [ "$1" != -i ]; then
				command sed "$@"
				return
			fi
			shift
			for last in "$@"; do :; done
			command sed "$@" >"${last}.new"
			mv "${last}.new" "${last}"
		}
		. "${tmp}/fn.sh"
		ensure_identity
		echo "$LOOM_UID:$LOOM_GID"
	)
}

# A host that can hand files over keeps uid 10000 and leaves a right entry alone.
[ "$(run yes 501 10000)" = 10000:10000 ]
grep -q '^loom:x:10000:10000:' "${tmp}/passwd"
grep -q '^loom:x:10000:$' "${tmp}/group"

# A host that cannot takes the share owner's ids and writes them.
[ "$(run no 1000 10000)" = 1000:1000 ]
grep -q '^loom:x:1000:1000:' "${tmp}/passwd"
grep -q '^loom:x:1000:$' "${tmp}/group"

# A root renumbered by an earlier rootless boot is put back when the hand-over
# works now.
[ "$(run yes 1000 1000)" = 10000:10000 ]
grep -q '^loom:x:10000:10000:' "${tmp}/passwd"
grep -q '^loom:x:10000:$' "${tmp}/group"

# A share owned by root is refused, and the entry is not touched.
if (run no 0 10000) >/dev/null 2>"${tmp}/err"; then
	echo "loom-guest-init-test.sh: a root-owned share was accepted" >&2
	exit 1
fi
grep -q 'would make the loom user root' "${tmp}/err"
grep -q '^loom:x:10000:10000:' "${tmp}/passwd"

echo "loom-guest-init-test.sh: ok"
