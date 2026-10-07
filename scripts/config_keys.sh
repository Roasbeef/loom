#!/bin/sh
# config_keys.sh — gate docs/configuration.md against the loom.toml decoders.
#
# The configuration reference is only worth reading if it names every key the
# daemon accepts, and the daemon refuses an unknown key, so a key missing from
# the reference is a key an operator cannot discover. This script reads the key
# lists out of the decoders themselves and compares them, table by table, with
# the rows of docs/configuration.md.
#
#   scripts/config_keys.sh              check the tree (what `make doc-check` runs)
#   scripts/config_keys.sh --self-test  run the checker against fixtures
#
# What is extracted, and from where. Each decoder spells its closed key list in
# one of four shapes, and the spec below names, for every table, the file, the
# function that decodes it, and the shape:
#
#   call     the literal list in a `known_keys(dict.keys(fields), [..], place)`
#            call inside the function. Calls may span lines; the list is the
#            first bracketed literal after the first argument.
#   allowed  a `let allowed = [..]` inside the function.
#   arms     string-literal match arms (`"a" | "b" -> ..`) inside the function.
#   const    a module-level `const NAME = [..]` (the function column is NAME).
#
# What is compared. For each spec row, the section of docs/configuration.md
# whose `## ` heading is the heading, in backticks or bare, is read, and every
# table row whose first cell is a backticked word is a documented key. A key the
# decoder accepts and the section lacks is an error. So is a documented key the
# decoder does not accept, because a stale row is how an operator ends up with a
# file the daemon refuses.
#
# Three guards keep the extraction honest. A spec row that extracts no keys is an
# error, since that means the decoder's formatting moved out from under the
# pattern. A `known_keys` call with a literal list in a spec file, inside a
# function the spec does not name, is an error, since that is a new table nobody
# documented. And a missing section is an error.
#
# This is an approximation of reading the decoders with a parser, and it says
# where it can be wrong: a key list built by a helper rather than written as a
# literal is invisible to it, and a partly reformatted `arms` list loses the
# arms the pattern no longer matches. The first is covered by the unmapped-call
# guard when the list is literal; neither is covered otherwise. Gleam has no
# parser a shell can call, and the alternative, a Gleam test over the decoders,
# would need each decoder to export its list, which moves the keys into API
# surface for the sake of a document.
#
# A row marked optional in the spec names a decoder that is on another branch.
# While its file is absent the section is not checked and the top-level key it
# adds is tolerated in the documented list; once the file exists both checks
# apply with no edit here.

set -eu

root=${CONFIG_KEYS_ROOT:-.}
doc=${CONFIG_KEYS_DOC:-docs/configuration.md}
spec_file=${CONFIG_KEYS_SPEC:-}

# file|function|mode|heading|optional-top-level-key
default_spec() {
	cat <<'SPEC'
packages/client/src/client/catalog.gleam|parse|call|Top-level tables|
packages/client/src/client/catalog.gleam|parse_model|call|[models.<name>]|
packages/client/src/client/catalog.gleam|parse_pricing|call|[models.<name>.pricing]|
packages/client/src/client/catalog.gleam|parse_role|arms|[roles]|
packages/client/src/client/catalog.gleam|parse_role|arms|[profiles.<name>.roles]|
packages/client/src/client/catalog.gleam|parse_profile|call|[profiles.<name>]|
packages/client/src/client/catalog.gleam|parse_mcp_server|call|[mcp.<name>]|
packages/client/src/client/catalog.gleam|tools_table|call|[tools]|
packages/client/src/client/catalog.gleam|workspace_table|call|[workspace]|
packages/client/src/client/catalog.gleam|workspace_mount|call|[workspace] mounts|
packages/client/src/client/catalog.gleam|advisor_table|call|[advisor]|
packages/client/src/client/rules.gleam|parse_rule|call|[[rule]]|
packages/client/src/client/schedule.gleam|parse_schedule|call|[[schedule]]|
packages/client/src/client/schedule.gleam|policy_table|call|[schedules]|
packages/client/src/client/jobs.gleam|policy_table|call|[jobs]|
packages/client/src/client/distillpass.gleam|known_keys|allowed|[memory]|
packages/client/src/client/secrets.gleam|entry|call|[secrets]|
packages/client/src/client/retryconf.gleam|policy_table|call|[retry]|
packages/client/src/client/daemon/limits.gleam|from_fields|arms|[daemon]|
packages/codemode/src/codemode/lsp_host/profile.gleam|table_keys|const|[lsp.<name>]|
?packages/client/src/client/peer_defaults.gleam|from_fields|arms|[peers]|peers
SPEC
}

# Prints the string literals found in the text on stdin, one per line.
literals() {
	awk '{ s = s " " $0 }
	END {
		while (match(s, /"[^"]*"/)) {
			print substr(s, RSTART + 1, RLENGTH - 2)
			s = substr(s, RSTART + RLENGTH)
		}
	}'
}

# extract FILE FUNCTION MODE -> the keys, one per line, unsorted.
extract() {
	awk -v want="$2" -v mode="$3" '
	function strip(s) { gsub(/"[^"]*"/, "\"\"", s); return s }
	function cut_list(text,   rest) {
		rest = substr(text, index(text, "[") + 1)
		sub(/\].*/, "", rest)
		return rest
	}
	function emit(s) {
		while (match(s, /"[^"]*"/)) {
			print substr(s, RSTART + 1, RLENGTH - 2)
			s = substr(s, RSTART + RLENGTH)
		}
	}
	/^(pub )?fn / {
		name = $0
		sub(/^(pub )?fn /, "", name)
		sub(/\(.*/, "", name)
		infn = (name == want)
		call = 0
		next
	}
	/^}/ { infn = 0 }
	mode == "const" && $0 ~ ("^const " want " = \\[") { listing = 1; text = "" }
	mode == "const" && listing {
		text = text " " $0
		if ($0 ~ /\]/) { emit(cut_list(text)); listing = 0 }
		next
	}
	infn && mode == "allowed" {
		if (!listing && $0 ~ /let allowed = \[/) { listing = 1; text = "" }
		if (listing) {
			text = text " " $0
			if ($0 ~ /\]/) { emit(cut_list(text)); listing = 0 }
		}
	}
	infn && mode == "arms" {
		if ($0 ~ /^[ \t]*"[^"]*"([ \t]*\|[ \t]*"[^"]*")*[ \t]*->/) {
			arm = $0
			sub(/->.*/, "", arm)
			emit(arm)
		}
	}
	infn && mode == "call" {
		if (!call && $0 ~ /known_keys\(/ && $0 !~ /fn known_keys/) {
			call = 1
			text = ""
			depth = 0
			line = substr($0, index($0, "known_keys("))
		} else {
			line = $0
		}
		if (call) {
			text = text " " line
			s = strip(line)
			opens = gsub(/\(/, "(", s)
			closes = gsub(/\)/, ")", s)
			depth += opens - closes
			if (depth <= 0) {
				if (match(text, /\),[ ]*\[/)) {
					emit(cut_list(substr(text, RSTART)))
				}
				call = 0
			}
		}
	}
	' "$1"
}

# scan FILE -> the function enclosing each `known_keys` call that passes a
# literal list, one name per line.
scan() {
	awk '
	function strip(s) { gsub(/"[^"]*"/, "\"\"", s); return s }
	/^(pub )?fn / {
		name = $0
		sub(/^(pub )?fn /, "", name)
		sub(/\(.*/, "", name)
		call = 0
		next
	}
	{
		if (!call && $0 ~ /known_keys\(/ && $0 !~ /fn known_keys/) {
			call = 1
			text = ""
			depth = 0
			line = substr($0, index($0, "known_keys("))
		} else {
			line = $0
		}
		if (call) {
			text = text " " line
			s = strip(line)
			opens = gsub(/\(/, "(", s)
			closes = gsub(/\)/, ")", s)
			depth += opens - closes
			if (depth <= 0) {
				if (match(text, /\),[ ]*\[/)) print name
				call = 0
			}
		}
	}
	' "$1"
}

# documented DOC HEADING -> the backticked first cells of the section's rows,
# or the single line `!missing` when no such section exists.
documented() {
	awk -v h="$2" '
	/^## / { ins = (index($0, "## `" h "`") == 1 || $0 == "## " h); if (ins) found = 1; next }
	ins && /^\| `[^`]+` \|/ {
		k = $0
		sub(/^\| `/, "", k)
		sub(/`.*/, "", k)
		print k
	}
	END { if (!found) print "!missing" }
	' "$1"
}

check() {
	scratch=$(mktemp -d "${TMPDIR:-/tmp}/loom-config-keys.XXXXXX")
	trap 'rm -rf "$scratch"' EXIT

	errors=0
	tables=0
	keys=0
	ahead=""
	if [ -n "$spec_file" ]; then
		cp "$spec_file" "$scratch/spec"
	else
		default_spec >"$scratch/spec"
	fi

	if [ ! -f "$root/$doc" ]; then
		printf 'ERROR    %-12s %s does not exist\n' config-keys "$doc"
		return 1
	fi

	# An optional row whose decoder is absent adds nothing to compare and
	# tolerates its top-level key in the documented list. The keys are
	# gathered first because the top-level row is checked before the
	# optional row that adds one.
	while IFS='|' read -r file fn mode heading extra; do
		case $file in
		'?'*) [ -f "$root/${file#\?}" ] || ahead="$ahead $extra" ;;
		esac
	done <"$scratch/spec"
	: >"$scratch/files"
	while IFS='|' read -r file fn mode heading extra; do
		[ -n "$file" ] || continue
		case $file in
		'?'*)
			path=${file#\?}
			[ -f "$root/$path" ] || continue
			file=$path
			;;
		esac
		printf '%s\n' "$file" >>"$scratch/files"

		if [ ! -f "$root/$file" ]; then
			printf 'ERROR    %-12s %s: the decoder file %s is missing\n' \
				config-keys "$heading" "$file"
			errors=$((errors + 1))
			continue
		fi

		extract "$root/$file" "$fn" "$mode" | sort -u >"$scratch/decoded"
		if [ ! -s "$scratch/decoded" ]; then
			printf 'ERROR    %-12s %s: extracted no keys from %s (%s, %s); the decoder moved out from under scripts/config_keys.sh\n' \
				config-keys "$heading" "$file" "$fn" "$mode"
			errors=$((errors + 1))
			continue
		fi

		documented "$root/$doc" "$heading" | sort -u >"$scratch/written"
		if [ "$(cat "$scratch/written")" = '!missing' ]; then
			printf 'ERROR    %-12s %s has no section for %s\n' \
				config-keys "$doc" "$heading"
			errors=$((errors + 1))
			continue
		fi
		if [ "$mode" = call ] && [ "$fn" = parse ]; then
			for key in $ahead; do
				grep -vx -- "$key" "$scratch/written" >"$scratch/written.next" || true
				mv "$scratch/written.next" "$scratch/written"
			done
		fi

		tables=$((tables + 1))
		keys=$((keys + $(wc -l <"$scratch/decoded")))
		comm -23 "$scratch/decoded" "$scratch/written" >"$scratch/undocumented"
		comm -13 "$scratch/decoded" "$scratch/written" >"$scratch/stale"
		while IFS= read -r key; do
			[ -n "$key" ] || continue
			printf 'ERROR    %-12s %s: the decoder accepts `%s`, and %s has no row for it\n' \
				config-keys "$heading" "$key" "$doc"
			errors=$((errors + 1))
		done <"$scratch/undocumented"
		while IFS= read -r key; do
			[ -n "$key" ] || continue
			printf 'ERROR    %-12s %s: %s documents `%s`, which the decoder does not accept\n' \
				config-keys "$heading" "$doc" "$key"
			errors=$((errors + 1))
		done <"$scratch/stale"
	done <"$scratch/spec"

	# A new table is a known_keys call with a literal list in a function the
	# spec does not name.
	sort -u "$scratch/files" | while IFS= read -r file; do
		scan "$root/$file" | sort -u | while IFS= read -r fn; do
			if ! awk -F'|' -v f="$file" -v n="$fn" '
				{ p = $1; sub(/^\?/, "", p) }
				p == f && $2 == n && $3 == "call" { found = 1 }
				END { exit !found }' "$scratch/spec"; then
				printf 'ERROR    %-12s %s: `%s` checks a literal key list that scripts/config_keys.sh does not map to a documented table\n' \
					config-keys "$file" "$fn"
			fi
		done
	done >"$scratch/unmapped"
	if [ -s "$scratch/unmapped" ]; then
		cat "$scratch/unmapped"
		errors=$((errors + $(wc -l <"$scratch/unmapped")))
	fi

	if [ "$errors" -gt 0 ]; then
		printf 'config-keys FAILED: %d error(s)\n' "$errors"
		return 1
	fi
	printf 'ok       %-12s %d keys across %d tables match %s\n' \
		config-keys "$keys" "$tables" "$doc"
}

# --- the self-test ----------------------------------------------------------

self_test() {
	here=$(mktemp -d "${TMPDIR:-/tmp}/loom-config-keys-test.XXXXXX")
	trap 'rm -rf "$here"' EXIT
	script=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
	failures=0

	mkdir -p "$here/docs"
	cat >"$here/decoder.gleam" <<'GLEAM'
pub fn parse(document) {
  use Nil <- result.try(known_keys(
    dict.keys(document),
    ["models", "peers_ahead", "tools"],
    "the top level",
  ))
  Ok(Nil)
}

fn parse_model(fields) {
  use Nil <- result.try(known_keys(
    dict.keys(fields),
    [
      "dialect", "base_url",
      "model_id",
    ],
    place,
  ))
  Ok(Nil)
}

fn policy_table(fields) {
  use Nil <- result.try(
    known_keys(dict.keys(fields), ["max_wall", "heartbeat_s"]),
  )
  Ok(Nil)
}

fn known_keys(present, allowed, place) {
  Ok(Nil)
}

fn from_fields(fields) {
  case key {
    "ui" | "max_connections" -> Ok(Nil)
    _ -> Error("unknown key")
  }
}

fn memory_keys(fields) {
  let allowed = ["distill", "distill_wall_ms"]
  allowed
}

const table_keys = [
  "command", "extensions",
  "hint",
]
GLEAM
	cat >"$here/spec" <<'SPEC'
decoder.gleam|parse|call|Top-level tables|
decoder.gleam|parse_model|call|[models.<name>]|
decoder.gleam|policy_table|call|[jobs]|
decoder.gleam|from_fields|arms|[daemon]|
decoder.gleam|memory_keys|allowed|[memory]|
decoder.gleam|table_keys|const|[lsp.<name>]|
SPEC
	write_doc() {
		cat >"$here/$doc" <<'DOC'
# Fixture

## Top-level tables

| Key | Meaning |
| --- | --- |
| `models` | x |
| `tools` | x |
| `peers_ahead` | x |

## `[models.<name>]`

| Key | Meaning |
| --- | --- |
| `dialect` | x |
| `base_url` | x |
| `model_id` | x |

## `[jobs]`

| `max_wall` | x |
| `heartbeat_s` | x |

## `[daemon]`

| `ui` | x |
| `max_connections` | x |

## `[memory]`

| `distill` | x |
| `distill_wall_ms` | x |

## `[lsp.<name>]`

| `command` | x |
| `extensions` | x |
| `hint` | x |
DOC
	}

	# run NAME EXPECT -> runs the checker on the fixture; EXPECT is `pass`, or a
	# phrase the failing output must contain.
	run() {
		name=$1
		expect=$2
		if out=$(CONFIG_KEYS_ROOT="$here" CONFIG_KEYS_DOC="$doc" \
			CONFIG_KEYS_SPEC="$here/spec" "$script" 2>&1); then
			status=0
		else
			status=1
		fi
		case $expect in
		pass)
			if [ "$status" -ne 0 ]; then
				printf 'self-test FAIL %s: expected a pass, got:\n%s\n' "$name" "$out"
				failures=$((failures + 1))
			fi
			;;
		*)
			if [ "$status" -eq 0 ]; then
				printf 'self-test FAIL %s: expected a failure naming %s, but it passed\n' "$name" "$expect"
				failures=$((failures + 1))
			elif ! printf '%s\n' "$out" | grep -Fq -- "$expect"; then
				printf 'self-test FAIL %s: failure did not name %s:\n%s\n' "$name" "$expect" "$out"
				failures=$((failures + 1))
			fi
			;;
		esac
	}

	write_doc
	run "a matching tree passes" pass

	# A decoder key the document lacks.
	sed '/^| `base_url` |/d' "$here/$doc" >"$here/doc.tmp" && mv "$here/doc.tmp" "$here/$doc"
	run "an undocumented multi-line call key" 'accepts `base_url`'
	write_doc

	sed '/^| `heartbeat_s` |/d' "$here/$doc" >"$here/doc.tmp" && mv "$here/doc.tmp" "$here/$doc"
	run "an undocumented one-line call key" 'accepts `heartbeat_s`'
	write_doc

	sed '/^| `max_connections` |/d' "$here/$doc" >"$here/doc.tmp" && mv "$here/doc.tmp" "$here/$doc"
	run "an undocumented match-arm key" 'accepts `max_connections`'
	write_doc

	sed '/^| `distill_wall_ms` |/d' "$here/$doc" >"$here/doc.tmp" && mv "$here/doc.tmp" "$here/$doc"
	run "an undocumented let-allowed key" 'accepts `distill_wall_ms`'
	write_doc

	sed '/^| `hint` |/d' "$here/$doc" >"$here/doc.tmp" && mv "$here/doc.tmp" "$here/$doc"
	run "an undocumented const-list key" 'accepts `hint`'
	write_doc

	# A key added to the decoder.
	sed 's/"model_id",/"model_id", "thinking",/' "$here/decoder.gleam" >"$here/dec.tmp"
	cp "$here/decoder.gleam" "$here/decoder.orig"
	mv "$here/dec.tmp" "$here/decoder.gleam"
	run "a key added to the decoder" 'accepts `thinking`'
	cp "$here/decoder.orig" "$here/decoder.gleam"

	# A documented key the decoder does not accept.
	printf '| `ghost` | x |\n' >>"$here/$doc"
	run "a stale documented key" 'documents `ghost`'
	write_doc

	# A missing section.
	sed 's/^## `\[jobs\]`/## `[jobz]`/' "$here/$doc" >"$here/doc.tmp" && mv "$here/doc.tmp" "$here/$doc"
	run "a missing section" 'has no section for [jobs]'
	write_doc

	# A new table: a literal list in a function the spec does not name.
	cat >>"$here/decoder.gleam" <<'GLEAM'

fn parse_extra(fields) {
  use Nil <- result.try(known_keys(dict.keys(fields), ["extra"], "[extra]"))
  Ok(Nil)
}
GLEAM
	run "an unmapped table" '`parse_extra` checks a literal key list'
	cp "$here/decoder.orig" "$here/decoder.gleam"

	# A decoder reformatted out from under the pattern extracts nothing.
	cat >"$here/decoder.gleam" <<'GLEAM'
fn from_fields(fields) {
  case key {
    "ui"
    | "max_connections" -> Ok(Nil)
  }
}
GLEAM
	cat >"$here/spec.one" <<'SPEC'
decoder.gleam|from_fields|arms|[daemon]|
SPEC
	if out=$(CONFIG_KEYS_ROOT="$here" CONFIG_KEYS_DOC="$doc" \
		CONFIG_KEYS_SPEC="$here/spec.one" "$script" 2>&1); then
		printf 'self-test FAIL a reformatted arms list: expected a failure\n'
		failures=$((failures + 1))
	elif ! printf '%s\n' "$out" | grep -Fq 'extracted no keys'; then
		printf 'self-test FAIL a reformatted arms list: wrong message:\n%s\n' "$out"
		failures=$((failures + 1))
	fi
	cp "$here/decoder.orig" "$here/decoder.gleam"

	# An optional row whose file is absent is skipped, and its top-level key is
	# tolerated; once the file exists the section is checked.
	cat "$here/spec" >"$here/spec.opt"
	printf '?decoder_later.gleam|from_fields|arms|[peers]|peers_ahead\n' >>"$here/spec.opt"
	sed 's/"peers_ahead", //' "$here/decoder.gleam" >"$here/dec.tmp" && mv "$here/dec.tmp" "$here/decoder.gleam"
	if out=$(CONFIG_KEYS_ROOT="$here" CONFIG_KEYS_DOC="$doc" \
		CONFIG_KEYS_SPEC="$here/spec.opt" "$script" 2>&1); then :; else
		printf 'self-test FAIL an optional row with no decoder: expected a pass, got:\n%s\n' "$out"
		failures=$((failures + 1))
	fi
	cat >"$here/decoder_later.gleam" <<'GLEAM'
fn from_fields(fields) {
  case key {
    "default_links" -> Ok(Nil)
  }
}
GLEAM
	if out=$(CONFIG_KEYS_ROOT="$here" CONFIG_KEYS_DOC="$doc" \
		CONFIG_KEYS_SPEC="$here/spec.opt" "$script" 2>&1); then
		printf 'self-test FAIL an optional row whose decoder exists: expected a failure\n'
		failures=$((failures + 1))
	fi

	if [ "$failures" -gt 0 ]; then
		printf 'config-keys self-test FAILED: %d case(s)\n' "$failures"
		exit 1
	fi
	echo "config-keys self-test: all cases passed"
}

case ${1:-} in
--self-test) self_test ;;
'') check ;;
*)
	echo "usage: scripts/config_keys.sh [--self-test]" >&2
	exit 2
	;;
esac
