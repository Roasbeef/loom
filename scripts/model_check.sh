#!/usr/bin/env bash
# model_check.sh — check every protocol model: the TLA+ session-move models
# with TLC, then every P project.
#
# Usage: scripts/model_check.sh
#   (MODEL_SCHEDULES, MODEL_PROBE_SCHEDULES, TLA2TOOLS, TLA_JAVA)
#
# The TLA+ models, protocol/models/session-move, run first. There are two
# specifications: Move.tla, the move where catalogue rows decide, and
# KhepriMove.tla, the moves where the directory's owner record decides
# (protocol-change/080). For each, TLC must pass the clean configuration
# (Move.cfg, KhepriMove.cfg) and must report a violation of the property
# each mutant configuration (Mutant*.cfg, KhepriMutant*.cfg) names on its
# `\* expect-violation:` line: an invariant, which TLC names when it fails
# (exit 12), or the one temporal property the configuration lists, which
# TLC reports as a temporal violation (exit 13). A mutation that no longer
# fails means the model stopped depending on the rule the mutation removes.
# TLC needs tla2tools.jar ($TLA2TOOLS, or ~/tools/tla2tools.jar) and a Java
# 11 or later ($TLA_JAVA, java on PATH, or a Homebrew openjdk). Without both,
# this script prints a SKIP line, which the skip census refuses in CI, and
# moves on to the P projects.
#
# Each directory under protocol/models with a .pproj is a P project. Its
# README says how it is run; this script runs the same commands for every
# test case the project declares, so a case added to the model is checked
# without an edit here.
#
# Two kinds of test case, told apart by name. A case named `tcProbe*` is
# a reachability probe: it asserts that a situation never happens, and the
# checker failing it is the evidence that the model reaches the situation.
# A probe that passes means the model has become vacuous there, so this
# script requires every probe to fail and every other case to pass. `p
# check` exits non-zero exactly when it finds a bug, which is what both
# readings rest on.
#
# A project whose mutate.py accepts `--check` also has its mutants run, after
# its cases: each mutant applies one text replacement to the model, and the
# gate requires the test case that mutant names to fail on the rule it names.
# A mutant that survives means the model stopped depending on the rule the
# mutation removes, which is the same reading as a TLA+ Mutant*.cfg. Another
# project's mutate.py, which is run by hand, is left alone.
#
# The schedule counts are smaller than the README's 30,000 because this is
# a gate run on every model change, not the recorded result. The default
# of 1,000 schedules takes about six seconds a case. Every probe in the
# tree finds its witness within 230 schedules, so 2,000 leaves a margin.
#
# The P 3.0 dotnet tool must be on PATH or in ~/.dotnet/tools. The model
# check is not part of `make check` or CI, which do not install it; this
# gate is run by `make check-affected` when a model changes.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
schedules="${MODEL_SCHEDULES:-1000}"
probe_schedules="${MODEL_PROBE_SCHEDULES:-2000}"
failed=0

# --- the TLA+ model --------------------------------------------------------

# java_major prints the major version of the java binary given.
java_major() {
	"$1" -XshowSettings:properties -version 2>&1 |
		sed -n 's/^ *java.specification.version = //p' | sed 's/^1\.//'
}

# find_java prints the first java binary that is Java 11 or later, which is
# what a current tla2tools.jar needs.
find_java() {
	local candidate major
	for candidate in "${TLA_JAVA:-}" "$(command -v java || true)" \
		/opt/homebrew/opt/openjdk*/bin/java /usr/local/opt/openjdk*/bin/java; do
		[ -n "$candidate" ] && [ -x "$candidate" ] || continue
		major="$(java_major "$candidate" || true)"
		if [ -n "$major" ] && [ "$major" -ge 11 ] 2>/dev/null; then
			echo "$candidate"
			return 0
		fi
	done
	return 1
}

# run_tla runs TLC on one configuration of one specification, leaving its
# output in the log file. TLC exits 0 for a pass and 12 for an invariant
# violation.
run_tla() {
	local java="$1" jar="$2" spec="$3" cfg="$4" metadir="$5" log="$6"
	rm -rf "$metadir"
	mkdir -p "$metadir"
	"$java" -Xmx1g -cp "$jar" tlc2.TLC -workers 1 -metadir "$metadir" \
		-config "$tla/$cfg.cfg" "$tla/$spec.tla" >"$log" 2>&1
}

# tla_counts prints "N states, M distinct, depth D" from a TLC log.
tla_counts() {
	local found distinct depth
	found="$(sed -n 's/^\([0-9,]*\) states generated.*/\1/p' "$1" | tail -1)"
	distinct="$(sed -n 's/^[0-9,]* states generated, \([0-9,]*\) distinct.*/\1/p' "$1" | tail -1)"
	depth="$(sed -n 's/^The depth of the complete state graph search is \([0-9]*\).*/\1/p' "$1" | tail -1)"
	echo "${found:-?} states, ${distinct:-?} distinct, depth ${depth:-?}"
}

check_tla() {
	local jar java name expected code out log
	tla="$root/protocol/models/session-move"
	jar="${TLA2TOOLS:-$HOME/tools/tla2tools.jar}"
	echo "==> session-move (TLA+)"
	[ -r "$jar" ] || {
		echo "SKIP tla_models: no tla2tools.jar at $jar (set TLA2TOOLS)"
		return 0
	}
	java="$(find_java)" || {
		echo "SKIP tla_models: no Java 11 or later (set TLA_JAVA)"
		return 0
	}
	out="$root/build/tla"
	mkdir -p "$out"

	# A specification's mutant configurations are named for it: Mutant*.cfg
	# for Move, which came first, and KhepriMutant*.cfg for KhepriMove.
	local spec prefix
	for spec in Move KhepriMove; do
		prefix="${spec%Move}"
		log="$out/$spec.log"
		if run_tla "$java" "$jar" "$spec" "$spec" "$out/$spec.states" "$log"; then
			echo "   ok   $spec ($(tla_counts "$log"))"
		else
			echo "   FAIL $spec: see $log"
			failed=1
		fi

		for cfg in "$tla/${prefix}Mutant"*.cfg; do
			name="$(basename "$cfg" .cfg)"
			expected="$(sed -n 's/^\\\* expect-violation: *//p' "$cfg")"
			log="$out/$name.log"
			code=0
			run_tla "$java" "$jar" "$spec" "$name" "$out/$name.states" "$log" || code=$?
			if [ "$code" -eq 12 ] && grep -q "Invariant $expected is violated" "$log"; then
				echo "   ok   $name (violates $expected: $(tla_counts "$log"))"
			elif [ "$code" -eq 13 ] && grep -q "Temporal properties were violated" "$log" &&
				sed -n '/^PROPERT/,$p' "$cfg" | grep -qw "$expected"; then
				echo "   ok   $name (violates $expected: $(tla_counts "$log"))"
			else
				echo "   FAIL $name: TLC exited $code, expected a violation of $expected, see $log"
				failed=1
			fi
		done
	done
}

check_tla

# --- the P projects --------------------------------------------------------

PATH="$PATH:$HOME/.dotnet/tools:$HOME/.dotnet"
command -v p >/dev/null || {
	echo "model_check: the P tool is not installed (dotnet tool install --global P)" >&2
	exit 2
}

for project in "$root"/protocol/models/*/*.pproj; do
	model="$(dirname "$project")"
	echo "==> $(basename "$model")"
	(cd "$model" && p compile >/dev/null) || {
		echo "   FAIL compile" >&2
		exit 1
	}
	cases="$(sed -n 's/^test \([A-Za-z0-9_]*\).*/\1/p' "$model"/PTst/*.p)"
	for case in $cases; do
		case $case in
		tcProbe*)
			if (cd "$model" && p check -tc "$case" -s "$probe_schedules" >/dev/null 2>&1); then
				echo "   FAIL $case: the probe found no witness, so the model no longer reaches it"
				failed=1
			else
				echo "   ok   $case (witness found)"
			fi
			;;
		*)
			if (cd "$model" && p check -tc "$case" -s "$schedules" >/dev/null 2>&1); then
				echo "   ok   $case ($schedules schedules)"
			else
				echo "   FAIL $case: see $model/PCheckerOutput/BugFinding"
				failed=1
			fi
			;;
		esac
	done
	if [ -f "$model/mutate.py" ] && grep -q -- '--check' "$model/mutate.py"; then
		(cd "$model" && python3 mutate.py --check) || failed=1
	fi
done
exit "$failed"
