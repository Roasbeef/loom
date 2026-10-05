#!/usr/bin/env bash
# web_assets.sh — build and gate what the web view's page loads.
#
#   scripts/web_assets.sh              build it (needs gleam, and the network
#                                      once, for lustre_dev_tools' binaries)
#   scripts/web_assets.sh --check      fail if it has drifted (needs nothing)
#   scripts/web_assets.sh --self-test  prove the gate catches every drift
#
# `make gen-client` and `make gen-css` run the first; `make client-check` and
# `make css-check` run the second and third, and `make check` runs them with
# web_view.
#
# ## What is built
#
# Everything the page loads besides Lustre's own server-component runtime
# comes from packages/web_client and is built by Lustre's own tool,
# lustre_dev_tools, a dev dependency of that package and of nothing else:
#
# - web_client.mjs, the client components bundled into one ES module;
# - web_client.css, the page's stylesheet, which lustre_dev_tools builds
#   with Tailwind v4 from packages/web_client/src/web_client.css. Its
#   `@source` lines name the server component's views and the client
#   components, so the utilities in it are exactly the classes those spell;
# - web_view_enter.js and web_view_page.js, the page's two bootstrap
#   scripts, and favicon.svg, copied from packages/web_client/assets.
#
# They land in packages/web_view/priv/static, which the daemon reads once at
# startup and a release carries like any application's priv.
#
# lustre_dev_tools downloads its bundler (Bun) and Tailwind the first time,
# checking each against a sha256 it carries for its pinned version, and
# caches them under packages/web_client/build. That is the one step that
# needs the network, and only `make gen-client` takes it.
#
# ## Why the gate needs no toolchain
#
# `make check` may not reach the network or run a JavaScript bundler, so the
# gate is digest comparison and nothing else, in the shape
# scripts/gen-prelude.sh uses. Each built file records the sha256 of every
# input it was built from and of its own body; `--check` recomputes them.
# An input digest that moved means a source changed and `make gen-client`
# was not run. A body digest that moved means somebody edited the output by
# hand. The two copied scripts are compared with their sources directly.
set -euo pipefail
self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
cd "$(dirname "$0")/.."

client="packages/web_client"
static="packages/web_view/priv/static"
scratch="$client/build/web_assets"
marker="/* --- generated body: the digests above cover everything below this line --- */"

# The bundle's inputs: the client package's sources, native modules and
# dependency lock, which names the lustre and lustre_dev_tools versions.
bundle_inputs() {
	echo "$client/gleam.toml"
	echo "$client/manifest.toml"
	find "$client/src" \( -name '*.gleam' -o -name '*.mjs' \) | LC_ALL=C sort
}

# The stylesheet's inputs: the Tailwind input, every source it scans, and
# the lock that names the lustre_dev_tools, and so the Tailwind, version.
stylesheet_inputs() {
	echo "$client/src/web_client.css"
	echo "$client/manifest.toml"
	find packages/web_view/src "$client/src" -name '*.gleam' | LC_ALL=C sort
}

# The copied files: the scripts and the favicon.
scripts() {
	ls "$client"/assets/*.js "$client"/assets/*.svg | LC_ALL=C sort
}

digest_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | cut -d' ' -f1
	else
		openssl dgst -sha256 "$1" | awk '{print $NF}'
	fi
}

body_of() {
	awk -v marker="$marker" 'found { print } $0 == marker { found = 1 }' "$1"
}

body_digest_of() {
	local tmp
	tmp=$(mktemp)
	body_of "$1" >"$tmp"
	digest_of "$tmp"
	rm -f "$tmp"
}

stamped_inputs() {
	awk '/^   input [0-9a-f]+  / && NF == 3 { print $2, $3 }' "$1"
}

stamped_body_digest() {
	awk '/^   body [0-9a-f]+$/ { print $2 }' "$1"
}

# ------------------------------------------------------------- the check

# check_artifact <file> <inputs function>
check_artifact() {
	local artifact="$1"
	local list="$2"
	local failed=0
	local stamped want path got

	if [ ! -f "$artifact" ]; then
		echo "web_assets: $artifact is missing; run make gen-client" >&2
		return 1
	fi

	stamped=$(stamped_inputs "$artifact")
	if [ "$(echo "$stamped" | awk '{print $2}')" != "$($list)" ]; then
		echo "web_assets: the inputs of $artifact changed (a module was added," >&2
		echo "web_assets: removed or renamed); run make gen-client" >&2
		failed=1
	fi
	while read -r want path; do
		[ -n "$path" ] || continue
		if [ ! -f "$path" ]; then
			failed=1
			continue
		fi
		got=$(digest_of "$path")
		if [ "$got" != "$want" ]; then
			echo "web_assets: $path changed since $artifact was built; run make gen-client" >&2
			failed=1
		fi
	done <<<"$stamped"

	if [ "$(body_digest_of "$artifact")" != "$(stamped_body_digest "$artifact")" ]; then
		echo "web_assets: $artifact was edited by hand; change its sources and run" >&2
		echo "web_assets: make gen-client instead" >&2
		failed=1
	fi
	return $failed
}

check_scripts() {
	local failed=0
	local source copy
	for source in $(scripts); do
		copy="$static/$(basename "$source")"
		if ! cmp -s "$source" "$copy"; then
			echo "web_assets: $copy is not a copy of $source; run make gen-client" >&2
			failed=1
		fi
	done
	return $failed
}

check_all() {
	local status=0
	check_artifact "$static/web_client.mjs" bundle_inputs || status=1
	check_artifact "$static/web_client.css" stylesheet_inputs || status=1
	check_scripts || status=1
	return $status
}

# ------------------------------------------------------------- the build

# stamp <built body> <output> <inputs function> <what>
stamp() {
	local body="$1"
	local output="$2"
	local list="$3"
	local what="$4"
	local path
	[ -z "$(tail -c 1 "$body")" ] || echo >>"$body"
	{
		echo "/* $what, built by scripts/web_assets.sh (make gen-client) with"
		echo "   lustre_dev_tools. Do not edit this file: change its inputs and run"
		echo "   make gen-client."
		$list | while read -r path; do
			echo "   input $(digest_of "$path")  $path"
		done
		echo "   body $(digest_of "$body")"
		echo "*/"
		echo "$marker"
		cat "$body"
	} >"$output"
}

build() {
	local path
	rm -rf "$scratch"
	mkdir -p "$static"
	(cd "$client" && gleam run -m lustre/dev build --minify --no-html \
		--outdir=build/web_assets)
	stamp "$scratch/web_client.js" "$static/web_client.mjs" bundle_inputs \
		"The web view's client components"
	stamp "$scratch/web_client.css" "$static/web_client.css" stylesheet_inputs \
		"The web view's stylesheet"
	for path in $(scripts); do
		cp "$path" "$static/$(basename "$path")"
	done
	check_all
	echo "built $static/web_client.mjs ($(wc -c <"$static/web_client.mjs" | tr -d ' ') bytes)"
	echo "built $static/web_client.css ($(wc -c <"$static/web_client.css" | tr -d ' ') bytes)"
}

# ------------------------------------------------------------- the self-test
#
# Each drift the gate exists for, applied to a copy of a built file: a
# stale input digest and a hand edit to the body. Each must fail.

self_test() {
	local tmp artifact list
	tmp=$(mktemp)
	for pair in "web_client.mjs bundle_inputs" "web_client.css stylesheet_inputs"; do
		artifact="$static/${pair%% *}"
		list="${pair##* }"
		if ! check_artifact "$artifact" "$list" >/dev/null 2>&1; then
			echo "web_assets: self-test: $artifact does not pass the check" >&2
			rm -f "$tmp"
			return 1
		fi

		awk 'done == 0 && /^   input / { sub(/input [0-9a-f]+/, "input 0000000000000000000000000000000000000000000000000000000000000000"); done = 1 } { print }' "$artifact" >"$tmp"
		if check_artifact "$tmp" "$list" >/dev/null 2>&1; then
			echo "web_assets: self-test: a stale input digest passed the check" >&2
			rm -f "$tmp"
			return 1
		fi

		cp "$artifact" "$tmp"
		echo "/* edited */" >>"$tmp"
		if check_artifact "$tmp" "$list" >/dev/null 2>&1; then
			echo "web_assets: self-test: an edited body passed the check" >&2
			rm -f "$tmp"
			return 1
		fi
	done
	rm -f "$tmp"
}

case "${1-}" in
--check) check_all ;;
--self-test) self_test ;;
"") build ;;
*)
	echo "usage: $self [--check | --self-test]" >&2
	exit 2
	;;
esac
