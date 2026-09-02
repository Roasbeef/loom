#!/usr/bin/env bash
# gen-prelude.sh — generate and gate `tools/prelude`, the capability
# prelude's public surface as the `code_mode` description renders it.
#
#   scripts/gen-prelude.sh              regenerate it (needs gleam, python3)
#   scripts/gen-prelude.sh --check      fail if it has drifted (needs nothing)
#   scripts/gen-prelude.sh --self-test  prove the gate catches every drift
#
# ## Why an artifact rather than a call at startup
#
# The rendered surface is part of the `code_mode` tool description, and a
# tool description is the byte prefix of the provider's cached head: it is
# paid on every request of every strand for the life of the session, so it
# must be a constant, and it must be the *same* constant every run. Asking
# the compiler at boot would put `gleam export package-interface` on the
# startup path of a harness whose whole point is that model-influenced
# code never runs in its VM, and would make the description depend on
# whether a toolchain happened to be reachable. Generating once and
# committing the result keeps the description constant and keeps the
# compiler where it belongs — in the hermetic build.
#
# ## Why the gate needs no toolchain
#
# A generated artifact that nothing checks is a lie waiting to be told:
# `packages/cap` moves, the description keeps describing the old prelude,
# and the model writes against signatures that no longer exist. So drift
# is a build failure. But the gate runs inside `make check`, which people
# run constantly and CI runs on every push, so it may not cost a `cap`
# build or import a second language into the merge gate — `make check`
# needs gleam, erlang and go today and this must not add to that list.
#
# The gate is therefore digest comparison and nothing else, in the shape
# `scripts/doc_check.sh` already uses for the AGENTS.md mirror: the
# artifact records the sha256 of every input it was rendered from, and
# `--check` recomputes them. Regeneration — which does need gleam and
# python3, the way `make gen-sql` needs sqlite3 — is a developer step run
# when `packages/cap` changes.
#
# Two digests, because there are two ways to drift and they need different
# fixes. The input digests catch "cap moved, the artifact did not" and
# send you to `make gen-prelude`. The body digest catches "somebody edited
# the generated file" and sends you to `packages/cap`, because a hand-edit
# here is a claim about the prelude that the prelude does not make — the
# exact silent lie the artifact exists to prevent.
#
# ## The third thing --check gates: every cap module is decided about
#
# The description filters these rendered blocks through each seam's
# `allowed_imports`, so it fails closed: a module on no allowlist simply
# never reaches a model. That is right for `cap/runtime`, which is the
# boot runtime and belongs to the harness — and indistinguishable from an
# omission for anything else. A capability written, vendored into the
# build seed and never allowlisted produces exactly one symptom: a program
# failing to vet against a module its author believes shipped (issue #95).
#
# So every `cap/*` module must appear either on a seam's allowlist or on
# `harness_only_cap_modules`, the written-down "reachable by nobody, on
# purpose" list — all four read out of the allowlist source itself. This
# script is where the check belongs because it already enumerates the
# package and already runs in `make check`, and because it needs no
# toolchain to do either: the lists are string literals and the modules
# are files.
set -euo pipefail
self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
cd "$(dirname "$0")/.."

artifact="packages/tools/src/tools/prelude.gleam"
renderer="scripts/gen-prelude.py"
marker="// --- generated body: the digests above cover every line below this one ---"
placeholder="0000000000000000000000000000000000000000000000000000000000000000"

# The rendering's inputs, in the order they are stamped. The `cap` modules
# are what `gleam export package-interface` reports (its `internal/`
# modules cannot reach a public signature — a leak is a build warning and
# this tree builds with --warnings-as-errors), and the renderer is the
# other half: a change to how a signature is drawn stales the artifact
# exactly as a change to the signature does. This script is not an input;
# it decides nothing about what is rendered, and stamping it would turn
# every comment fix here into a regenerated artifact.
inputs() {
	ls packages/cap/src/cap/*.gleam | LC_ALL=C sort
	echo "$renderer"
}

# sha256 of one file, on whatever the platform gives us. Linux runners
# have sha256sum, macOS has shasum, and openssl is the fallback for
# neither; CI runs both of the first two.
digest_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | cut -d' ' -f1
	else
		openssl dgst -sha256 "$1" | awk '{print $NF}'
	fi
}

digest_of_stdin() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 | cut -d' ' -f1
	else
		openssl dgst -sha256 | awk '{print $NF}'
	fi
}

# Everything strictly after the marker line: the generated body, which is
# what the body digest covers. The header above the marker holds the
# digests themselves, so it cannot be part of what they cover.
body_of() {
	awk -v marker="$marker" 'found { print } $0 == marker { found = 1 }' "$1"
}

stamped_inputs() {
	# Interval expressions are not portable across every awk this has to
	# run on (the macOS gate included), so the shape is pinned by the
	# field count and the fixed prefix rather than by {64}.
	awk '/^\/\/\/\/   [0-9a-f]+  / && NF == 3 { print $2, $3 }' "$1"
}

stamped_body_digest() {
	awk '/^\/\/\/\/ Body digest/ { print $NF }' "$1"
}

# ------------------------------------------------- every cap is decided
#
# Takes the allowlist source as an argument for the same reason
# `check_artifact` takes the artifact: the self-test below points it at a
# deliberately broken copy. The module set is always the real tree.

allowlist_source="packages/codemode/src/codemode/vet/policy.gleam"

# The `cap/*` modules `packages/cap` actually ships. `internal/` is a
# directory and cannot be imported by a submitted program at all, so the
# glob is the whole set by construction.
cap_modules() {
	for path in packages/cap/src/cap/*.gleam; do
		name=$(basename "$path" .gleam)
		echo "cap/$name"
	done | LC_ALL=C sort
}

# Every `cap/*` name on any of the four lists that decide reachability.
# Read out of the function bodies rather than the whole file, because the
# doc comments quote module names too and a quote is not a decision.
listed_caps() {
	awk '
		/^pub fn (default_cap_modules|orchestration_cap_modules|extension_cap_modules|harness_only_cap_modules)\(\)/ {
			inside = 1
			next
		}
		inside && /^}/ { inside = 0; next }
		inside {
			line = $0
			while (match(line, /"cap\/[a-z_]+"/)) {
				print substr(line, RSTART + 1, RLENGTH - 2)
				line = substr(line, RSTART + RLENGTH)
			}
		}
	' "$1" | LC_ALL=C sort -u
}

check_coverage() {
	local source="$1"
	local failed=0
	local listed module

	if [ ! -f "$source" ]; then
		echo "gen-prelude: $source is missing; the allowlists live there" >&2
		return 1
	fi

	listed=$(listed_caps "$source")
	if [ -z "$listed" ]; then
		echo "gen-prelude: no cap module names could be read out of $source;" >&2
		echo "gen-prelude: the allowlist functions moved or were renamed." >&2
		return 1
	fi

	for module in $(cap_modules); do
		case "
$listed" in
		*"
$module"*) ;;
		*)
			echo "gen-prelude: $module is on no seam's allowlist and on no" >&2
			echo "gen-prelude: harness-only list, so no program can import it and" >&2
			echo "gen-prelude: nothing says that is deliberate. Add it to a seam in" >&2
			echo "gen-prelude: $source, or to harness_only_cap_modules there if it" >&2
			echo "gen-prelude: is the harness's own." >&2
			failed=1
			;;
		esac
	done

	for module in $listed; do
		if [ ! -f "packages/cap/src/${module}.gleam" ]; then
			echo "gen-prelude: $source lists $module, which packages/cap does not" >&2
			echo "gen-prelude: ship; a program allowed to import it would not compile." >&2
			failed=1
		fi
	done

	return "$failed"
}

# ------------------------------------------------------------------ check
#
# Takes the artifact as an argument so `--self-test` can point it at a
# deliberately broken copy. The stamped paths are repo-relative and the
# digests are recomputed against the real tree either way, which is what
# lets a fixture simulate "cap moved" by editing one stamp.

check_artifact() {
	local target="$1"
	local failed=0

	if [ ! -f "$target" ]; then
		echo "gen-prelude: $target is missing; run \`make gen-prelude\`" >&2
		return 1
	fi

	local recorded
	recorded=$(stamped_inputs "$target")
	if [ -z "$recorded" ]; then
		echo "gen-prelude: $target carries no input digests; run \`make gen-prelude\`" >&2
		return 1
	fi

	# Name the file that moved rather than only the fact that something
	# did. "Out of date" costs the reader the diff; "cap/fs.gleam changed"
	# costs them nothing and says which change to go and look at.
	local stamp path current
	while read -r stamp path; do
		if [ ! -f "$path" ]; then
			echo "gen-prelude: $path was deleted since $target was generated" >&2
			failed=1
			continue
		fi
		current=$(digest_of "$path")
		if [ "$stamp" != "$current" ]; then
			echo "gen-prelude: $path has changed since $target was generated" >&2
			failed=1
		fi
	done <<EOF
$recorded
EOF

	for path in $(inputs); do
		case "$recorded" in
		*" $path"*) ;;
		*)
			echo "gen-prelude: $path is new since $target was generated" >&2
			failed=1
			;;
		esac
	done

	if [ "$failed" -ne 0 ]; then
		echo "gen-prelude: the signatures in the code_mode description no longer match" >&2
		echo "gen-prelude: what they were rendered from, so the description may be telling" >&2
		echo "gen-prelude: a model about a prelude that does not exist. Run" >&2
		echo "gen-prelude: \`make gen-prelude\` and commit the regenerated $artifact." >&2
		return 1
	fi

	stamp=$(stamped_body_digest "$target")
	current=$(body_of "$target" | digest_of_stdin)
	if [ "$stamp" != "$current" ]; then
		echo "gen-prelude: $target has been edited by hand (body digest $current," >&2
		echo "gen-prelude: stamped $stamp). It is generated from packages/cap: put the" >&2
		echo "gen-prelude: change in the prelude's own source and run \`make gen-prelude\`," >&2
		echo "gen-prelude: which is also the answer if a formatter reflowed the file." >&2
		echo "gen-prelude: An edit here is a claim about the prelude that the prelude" >&2
		echo "gen-prelude: does not make." >&2
		return 1
	fi

	return 0
}

if [ "${1:-}" = "--check" ]; then
	check_artifact "$artifact"
	check_coverage "$allowlist_source"
	count=$(stamped_inputs "$artifact" | wc -l | tr -d ' ')
	decided=$(cap_modules | wc -l | tr -d ' ')
	echo "prelude surface is current ($count inputs, $decided cap modules decided about)"
	exit 0
fi

# -------------------------------------------------------------- self test
#
# A gate nobody has watched fail is a gate nobody knows works. This drives
# each drift shape against a copy of the real file and insists it is
# caught: a stamp edited to something else stands in for a `cap` module
# that moved, a line appended to the body stands in for a hand-edit, a
# capability dropped from a seam list stands in for a module nobody
# decided about, and an entry added to the harness-only list stands in for
# a list naming a module that does not ship. All of it is sha256 and text
# work on temporary files; nothing in the tree is touched, so it is cheap
# enough to run beside the gate itself.

if [ "${1:-}" = "--self-test" ]; then
	work=$(mktemp -d)
	trap 'rm -rf "$work"' EXIT

	cp "$artifact" "$work/fresh.gleam"
	if ! check_artifact "$work/fresh.gleam" >/dev/null 2>&1; then
		echo "gen-prelude: self-test FAILED — an unmodified copy did not pass" >&2
		exit 1
	fi

	# One stamped digest replaced: the shape of a changed `cap` module.
	awk '/^\/\/\/\/   [0-9a-f]+  / && NF == 3 && !done { sub(/[0-9a-f]+/, "'"$placeholder"'"); done = 1 } { print }' \
		"$artifact" >"$work/stale.gleam"
	if check_artifact "$work/stale.gleam" >/dev/null 2>&1; then
		echo "gen-prelude: self-test FAILED — a stale input digest was not caught" >&2
		exit 1
	fi
	stale_says=$(check_artifact "$work/stale.gleam" 2>&1 >/dev/null || true)
	stale_says=${stale_says%%$'\n'*}

	# A line appended below the marker: the shape of a hand-edit.
	cp "$artifact" "$work/edited.gleam"
	printf '\n// hand-written\n' >>"$work/edited.gleam"
	if check_artifact "$work/edited.gleam" >/dev/null 2>&1; then
		echo "gen-prelude: self-test FAILED — a hand-edited body was not caught" >&2
		exit 1
	fi
	edited_says=$(check_artifact "$work/edited.gleam" 2>&1 >/dev/null || true)
	edited_says=${edited_says%%$'\n'*}

	case "$stale_says" in
	*"has changed since"*) ;;
	*)
		echo "gen-prelude: self-test FAILED — the stale case did not name the file: $stale_says" >&2
		exit 1
		;;
	esac
	case "$edited_says" in
	*"edited by hand"*) ;;
	*)
		echo "gen-prelude: self-test FAILED — the hand-edit case did not say so: $edited_says" >&2
		exit 1
		;;
	esac

	# The coverage gate, driven against copies of the allowlist source the
	# same way. Two shapes again, and again they need different fixes: a
	# module nobody decided about sends you to a seam list, and a list
	# naming a module that does not ship sends you to `packages/cap`.
	if ! check_coverage "$allowlist_source" >/dev/null 2>&1; then
		echo "gen-prelude: self-test FAILED — the real allowlists did not pass coverage" >&2
		exit 1
	fi

	# One capability dropped from a seam list: the shape of a module
	# nobody allowlisted.
	sed 's/"cap\/kv", //; s/, "cap\/kv"//' "$allowlist_source" >"$work/undecided.gleam"
	if check_coverage "$work/undecided.gleam" >/dev/null 2>&1; then
		echo "gen-prelude: self-test FAILED — an unallowlisted cap module was not caught" >&2
		exit 1
	fi
	undecided_says=$(check_coverage "$work/undecided.gleam" 2>&1 >/dev/null || true)
	undecided_says=${undecided_says%%$'\n'*}

	# A listed module the package does not ship: the shape of a rename
	# that moved the file and not the list.
	sed 's/"cap\/runtime"\]/"cap\/runtime", "cap\/ghost"]/' \
		"$allowlist_source" >"$work/phantom.gleam"
	if check_coverage "$work/phantom.gleam" >/dev/null 2>&1; then
		echo "gen-prelude: self-test FAILED — a listed but unshipped module was not caught" >&2
		exit 1
	fi
	phantom_says=$(check_coverage "$work/phantom.gleam" 2>&1 >/dev/null || true)
	phantom_says=${phantom_says%%$'\n'*}

	case "$undecided_says" in
	*"cap/kv is on no seam"*) ;;
	*)
		echo "gen-prelude: self-test FAILED — the undecided case did not name the module: $undecided_says" >&2
		exit 1
		;;
	esac
	case "$phantom_says" in
	*"lists cap/ghost"*) ;;
	*)
		echo "gen-prelude: self-test FAILED — the phantom case did not name the module: $phantom_says" >&2
		exit 1
		;;
	esac

	echo "prelude gate self-test passed (fresh accepted; stale input, hand-edit,"
	echo "undecided cap module and phantom allowlist entry all refused)"
	exit 0
fi

if [ $# -ne 0 ]; then
	echo "usage: scripts/gen-prelude.sh [--check | --self-test]" >&2
	exit 2
fi

# ------------------------------------------------------------- regenerate

command -v python3 >/dev/null 2>&1 || {
	echo "gen-prelude: python3 is required to render the artifact (the --check gate is not)" >&2
	exit 1
}
command -v gleam >/dev/null 2>&1 || {
	echo "gen-prelude: gleam is required to export packages/cap's interface" >&2
	exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "==> exporting packages/cap's package interface"
(cd packages/cap && gleam export package-interface --out "$work/interface.json" >/dev/null)

echo "==> rendering $artifact"
python3 "$renderer" "$work/interface.json" >"$work/body.gleam"

if grep -qF -- "$marker" "$work/body.gleam"; then
	echo "gen-prelude: the rendered body contains the marker line; the digest boundary" >&2
	echo "gen-prelude: would be ambiguous. Change the marker in scripts/gen-prelude.sh." >&2
	exit 1
fi

# Compose with a placeholder body digest, format, then stamp. The digest
# has to cover the *formatted* body, and stamping only rewrites a header
# comment, so formatting stays stable across the substitution.
{
	cat <<'HEADER'
//// Code generated by `make gen-prelude`. DO NOT EDIT.
////
//// The capability prelude's public surface, one rendered block per
//// module, as the `code_mode` tool description shows it to a model.
////
//// A model writing a code-mode program authors blind: it submits source
//// and finds out what the prelude looks like from the compiler, as a
//// `CompileFailed` round trip carrying a whole hermetic build. The
//// module namespace was the discovery index and the compiler the schema
//// oracle, and the oracle was reachable only by being wrong first. This
//// is that oracle, moved in front of the writing (issue #36).
////
//// Rendered by `scripts/gen-prelude.py` from `gleam export
//// package-interface` over `packages/cap` — the compiler's own account
//// of what it will accept, so the description cannot describe a prelude
//// the build would reject. `scripts/gen-prelude.sh --check` gates the
//// two ways this file can go stale and `make check` runs it.
////
//// Nothing here is filtered. `tools/codemode` selects from `surfaces`
//// through each seam's own `allowed_imports`, which is why `cap/runtime`
//// — on neither seam — is present in this list and must never reach a
//// description.
////
//// Generated from these inputs; `--check` recomputes each digest and
//// names the file that moved:
////
HEADER
	for path in $(inputs); do
		printf '////   %s  %s\n' "$(digest_of "$path")" "$path"
	done
	printf '////\n//// Body digest (every line after the marker): %s\n\n' "$placeholder"
	printf '%s\n' "$marker"
	cat "$work/body.gleam"
} >"$work/prelude.gleam"

gleam format "$work/prelude.gleam"

body_digest=$(body_of "$work/prelude.gleam" | digest_of_stdin)
# Only the stamp line, never the body: a body line that happened to hold
# sixty-four zeroes would otherwise be rewritten and the digest would then
# describe a file that no longer exists.
awk -v placeholder="$placeholder" -v digest="$body_digest" \
	'/^\/\/\/\/ Body digest/ { sub(placeholder, digest) } { print }' \
	"$work/prelude.gleam" >"$artifact"

gleam format --check "$artifact" >/dev/null
"$self" --check >/dev/null

echo "wrote $artifact"
