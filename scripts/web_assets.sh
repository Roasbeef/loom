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
# lustre_dev_tools downloads and verifies Bun. This script pins Tailwind
# separately because Lustre 2.4.0 selects a standalone macOS binary whose
# signature fails on macOS 27. Only `make gen-client` downloads tools.
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
mermaid="packages/web_mermaid"
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

# The stylesheet records the Tailwind pin, the Lustre configuration, and
# the sources Tailwind scans.
stylesheet_inputs() {
	echo scripts/web_assets.sh
	echo "$client/gleam.toml"
	echo "$client/src/web_client.css"
	echo "$client/manifest.toml"
	find packages/web_view/src "$client/src" -name '*.gleam' | LC_ALL=C sort
}

# The frame program's inputs. web_client's manifest pins the Lustre dev tools
# whose verified Bun builds the bundle.
mermaid_inputs() {
	echo scripts/web_assets.sh
	echo "$client/manifest.toml"
	echo "$mermaid/gleam.toml"
	echo "$mermaid/manifest.toml"
	echo "$mermaid/bundle/licenses.py"
	echo "$mermaid/bundle/package.json"
	echo "$mermaid/bundle/package-lock.json"
	echo "$mermaid/bundle/renderer.js"
	find "$mermaid/src" \( -name '*.gleam' -o -name '*.mjs' \) | LC_ALL=C sort
}

# The copied files: the scripts and the favicon.
scripts() {
	ls "$client"/assets/*.js "$client"/assets/*.svg "$mermaid"/bundle/mermaid.html | LC_ALL=C sort
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
	check_artifact "$static/mermaid.js" mermaid_inputs || status=1
	check_artifact "$static/mermaid-licenses.txt" mermaid_inputs || status=1
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

# Keep unverified downloads away from Lustre's executable path. The digest
# also rejects a cache populated for another platform or Tailwind version.
prepare_tailwind() (
	local version=4.3.5 target sha binary download platform
	platform="$(uname -s)/$(uname -m)"
	if [[ $platform == Linux/* && $(ldd --version 2>&1 || true) == *musl* ]]; then
		platform+=/musl
	fi
	case "$platform" in
	Darwin/arm64) target=macos-arm64; sha=f3f4f5d1727e2b693b8f1c9a1492b5dd87008c86ea286bee1589cb458e6235fc ;;
	Darwin/x86_64) target=macos-x64; sha=a63702686a3ed048b3135d84a73be49ea9d47f880c9b20e54b3ef60934ad8cdf ;;
	Linux/aarch64|Linux/arm64) target=linux-arm64; sha=ffcd0d21dbd7c605dc12743ff0c0b47debc963c86b399674084c1c8f2c96ecad ;;
	Linux/x86_64) target=linux-x64; sha=e47695cee3f0d90623a91f3939b08bdee610eb5ad99340adff9d4145b284d6cc ;;
	Linux/aarch64/musl|Linux/arm64/musl) target=linux-arm64-musl; sha=564dad3028c029b0c69042c66a7a79873ed7289b73fcb7b37973fbf79cb9a32f ;;
	Linux/x86_64/musl) target=linux-x64-musl; sha=bb050edd13f15006d872a9bb1772b908618a8df6806d30bf095cba26a09e640b ;;
	*) echo "web_assets: unsupported Tailwind platform: $platform" >&2; return 1 ;;
	esac

	binary="$client/build/web_asset_tools/tailwindcss"
	if [ -x "$binary" ] && [ "$(digest_of "$binary")" = "$sha" ]; then
		return 0
	fi
	mkdir -p "$(dirname "$binary")"
	download=$(mktemp "$binary.XXXXXXXX")
	trap 'rm -f "$download"' EXIT
	curl --fail --silent --show-error --location \
		"https://github.com/tailwindlabs/tailwindcss/releases/download/v$version/tailwindcss-$target" \
		--output "$download"
	if [ "$(digest_of "$download")" != "$sha" ]; then
		echo "web_assets: Tailwind v$version ($target) checksum mismatch" >&2
		return 1
	fi
	chmod +x "$download"
	mv -f "$download" "$binary"
)

build() {
	local path
	prepare_tailwind
	rm -rf "$scratch"
	mkdir -p "$static"
	(cd "$client" && gleam run -m lustre/dev build --minify --no-html \
		--outdir=build/web_assets)
	stamp "$scratch/web_client.js" "$static/web_client.mjs" bundle_inputs \
		"The web view's client components"
	stamp "$scratch/web_client.css" "$static/web_client.css" stylesheet_inputs \
		"The web view's stylesheet"
	(cd "$mermaid" && gleam build --warnings-as-errors)
	(cd "$mermaid/bundle" && npm ci --ignore-scripts --no-audit --no-fund)

	# Reuse the platform binary whose version and hash Lustre just verified.
	# The system Bun must not silently choose a different renderer build.
	local bun="" candidate expected_bun
	expected_bun=$(awk -F '"' '/^const version = / { print $2; exit }' \
		"$client/build/packages/lustre_dev_tools/src/lustre_dev_tools/bin/bun.gleam")
	[ -n "$expected_bun" ] || { echo "web_assets: cannot read pinned Bun version" >&2; return 1; }
	for candidate in "$client"/.lustre/bin/bun-*/bun; do
		if [ -x "$candidate" ] && [ "$("$candidate" --version 2>/dev/null)" = "$expected_bun" ]; then
			bun=$candidate
			break
		fi
	done
	[ -n "$bun" ] || { echo "web_assets: Lustre's verified Bun is missing" >&2; return 1; }
	"$bun" build "$mermaid/bundle/renderer.js" --target browser --format iife \
		--minify --outfile "$scratch/mermaid.js"
	stamp "$scratch/mermaid.js" "$static/mermaid.js" mermaid_inputs \
		"Isolated Mermaid renderer"
	python3 "$mermaid/bundle/licenses.py" "$scratch/mermaid-licenses.txt"
	stamp "$scratch/mermaid-licenses.txt" "$static/mermaid-licenses.txt" \
		mermaid_inputs "Mermaid third-party notices"
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
	for pair in "web_client.mjs bundle_inputs" "web_client.css stylesheet_inputs" "mermaid.js mermaid_inputs" "mermaid-licenses.txt mermaid_inputs"; do
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
