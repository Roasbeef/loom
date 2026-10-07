#!/usr/bin/env bash
# gate.sh — the one command a signoff key may run on the box that hosts
# the gate.
#
# Usage: loom-signoff-gate [request]   (the request defaults to
#        SSH_ORIGINAL_COMMAND; the grammar is below)
#
# Why this exists. scripts/signoff_remote.sh, left to itself, streams the
# driver to `bash -s` on the box, so any key that may run a signoff may
# run anything at all as the account it logs in to. That is right for a
# developer's own login and wrong for a key handed to agents. A key pinned
# here can ask for exactly two things — run the gate for a pushed commit
# and post its verdict, or read what an earlier run logged — in a request
# read as data, word by word, against a grammar small enough to check by
# eye:
#
#   signoff <40-hex sha> [--dry-run] [--parallel <1-64>]
#   logs <40-hex sha> [<lane>] [--tail <1-100000>]
#
# `logs` exists because a red mark names the lanes that failed and the
# logs that say why live in this script's root-owned state, where the
# key's account cannot read them; without it, whoever asked for the run
# could see that it failed and never why. With no lane it prints the
# run's own output and lists the lanes it kept; `image-build` is the
# image build's log.
#
# Anything else is refused before a process is started. stdin is never
# read, so a client still speaking the driver protocol gets a refusal
# rather than an interpreter.
#
# --- How it is installed ---
#
# The key's account holds nothing: no checkout, no token, no docker group
# (which is root by another name). Its authorized_keys entry forces this
# script through one sudo rule, passing the request as an argument
# because sudo does not carry SSH_ORIGINAL_COMMAND across:
#
#   restrict,command="sudo -n /usr/local/sbin/loom-signoff-gate \"$SSH_ORIGINAL_COMMAND\"" ssh-ed25519 ...
#   <account> ALL=(root) NOPASSWD: /usr/local/sbin/loom-signoff-gate
#
# Everything a run touches lives under one root-owned state directory,
# /var/lib/loom-signoff, which is also HOME for the run:
#
#   loom-signoff/   the checkout, cloned once by whoever installs this; the
#                   gate never clones, so it never chooses an origin
#   gh-token        a fine-grained token that may write commit statuses
#   config          optional, sourced: LOOM_CPUS and LOOM_MEMORY ceilings
#   .gitconfig      user.name, which gh-signoff requires to post
#   .local/share/gh the gh-signoff extension
#
# and the driver it runs is an installed copy of scripts/signoff/driver.sh
# at /usr/local/libexec/loom-signoff/driver.sh, so the code that decides
# what runs as root is a reviewed commit's, not the commit under test's.
# LOOM_SIGNOFF_STATE and LOOM_SIGNOFF_DRIVER move both for the tests;
# neither can reach a real run, because sudo resets the environment and a
# `restrict` key cannot set one.
#
# --- What the key still grants ---
#
# The driver builds scripts/signoff/Dockerfile and runs scripts/signoff.sh
# from the commit under test, as root in a container whose flags
# (signoff_remote.sh's header has them) are far from a sandbox. Pinning
# the key bounds what can be typed at the box, not what a pushed commit
# can do once its gate runs: the commit, not the key, is the trust
# boundary. That is why a commit must be on one of origin's branches,
# and why only branches are fetched to find it: GitHub serves any object
# in a fork network by SHA, so a fetch by SHA would run code nobody with
# push access ever pushed.
#
# One run at a time. The checkout is shared between runs, and two runs
# detaching it at different commits would each build what the other
# checked out, so a run waits on a lock for the one before it.
set -euo pipefail

refuse() {
	echo "loom-signoff-gate: $*" >&2
	echo "usage: signoff <40-hex sha> [--dry-run] [--parallel <1-64>]" >&2
	echo "       logs <40-hex sha> [<lane>] [--tail <1-100000>]" >&2
	exit 2
}

# `read -a` splits on whitespace without globbing or expanding anything,
# so a `$(...)` or a `;` in the request is only an unrecognised word. It
# also stops at the first newline, so a request holding one is refused
# outright rather than having its tail silently dropped.
request=${1-${SSH_ORIGINAL_COMMAND:-}}
[[ $request != *$'\n'* ]] || refuse "a request is one line"
read -r -a words <<<"$request" || true
[ "${#words[@]}" -ge 2 ] || refuse "no request"
verb=${words[0]}
case $verb in
signoff | logs) ;;
*) refuse "unknown request '$verb'" ;;
esac
sha=${words[1]}
[[ $sha =~ ^[0-9a-f]{40}$ ]] || refuse "not a full commit sha: '$sha'"
state=${LOOM_SIGNOFF_STATE:-/var/lib/loom-signoff}

# Reading a log. The lanes directory is copied out of the container, so
# its contents are whatever the commit under test left there, a symbolic
# link to the token included; this runs as root, so a file is printed
# only if it is a regular file whose real path is inside the run's own
# logs directory, and a link is refused rather than followed.
if [ "$verb" = logs ]; then
	lane=""
	tail_lines=""
	i=2
	while [ "$i" -lt "${#words[@]}" ]; do
		case ${words[$i]} in
		--tail)
			i=$((i + 1))
			tail_lines=${words[$i]:-}
			if ! [[ $tail_lines =~ ^[1-9][0-9]{0,4}$ ]] && [ "$tail_lines" != 100000 ]; then
				refuse "--tail needs a number from 1 to 100000"
			fi
			;;
		*)
			[ -z "$lane" ] || refuse "unknown argument '${words[$i]}'"
			lane=${words[$i]}
			[[ $lane =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || refuse "not a lane name: '$lane'"
			;;
		esac
		i=$((i + 1))
	done
	exec </dev/null

	run="$state/loom-signoff-container/logs/${sha:0:12}"
	[ -d "$run" ] && [ ! -L "$run" ] ||
		{ echo "loom-signoff-gate: no logs for $sha" >&2; exit 4; }
	case $lane in
	"") file="$run/signoff.log" ;;
	image-build) file="$run/image-build.log" ;;
	*) file="$run/lanes/$lane.log" ;;
	esac
	real=$(realpath -e -- "$file" 2>/dev/null) || real=""
	if [ -z "$real" ] || [ -L "$file" ] || [ ! -f "$real" ] || [[ $real != "$(realpath -- "$run")"/* ]]; then
		echo "loom-signoff-gate: no such log '${lane:-signoff}' for $sha" >&2
		lane=""
		file=""
	fi
	if [ -n "$file" ]; then
		if [ -n "$tail_lines" ]; then tail -n "$tail_lines" -- "$real"; else cat -- "$real"; fi
	fi
	if [ -z "$lane" ] && [ -d "$run/lanes" ] && [ ! -L "$run/lanes" ]; then
		echo "== lanes: $(cd "$run/lanes" && ls -1 -- *.log 2>/dev/null | sed 's/\.log$//' | tr '\n' ' ')"
	fi
	[ -n "$file" ] || exit 4
	exit 0
fi

post=yes
parallel=""
i=2
while [ "$i" -lt "${#words[@]}" ]; do
	case ${words[$i]} in
	--dry-run) post=no ;;
	--parallel)
		i=$((i + 1))
		parallel=${words[$i]:-}
		if ! [[ $parallel =~ ^[1-9][0-9]?$ ]] || [ "$parallel" -gt 64 ]; then
			refuse "--parallel needs a number from 1 to 64"
		fi
		;;
	*) refuse "unknown argument '${words[$i]}'" ;;
	esac
	i=$((i + 1))
done
exec </dev/null

driver=${LOOM_SIGNOFF_DRIVER:-/usr/local/libexec/loom-signoff/driver.sh}
checkout="$state/loom-signoff"
if [ ! -d "$checkout/.git" ]; then
	echo "loom-signoff-gate: no checkout at $checkout; the installer clones it" >&2
	exit 3
fi

# A request that gives up while it waits must not run once the lock comes
# free, so the wait writes to the client every thirty seconds, with
# SIGPIPE ignored so that a session that has gone fails the write rather
# than killing this script, and a failed write ends the request. The
# driver keeps the same watch over the run itself.
trap '' PIPE
exec 9>"$state/lock"
if ! flock -n 9; then
	echo "== another signoff is running; waiting for it"
	until flock -w 30 9; do
		echo "== still waiting for the signoff ahead of this one" 2>/dev/null || exit 130
	done
fi

cd "$checkout"
git fetch --quiet --prune origin
if ! git cat-file -e "$sha^{commit}" 2>/dev/null ||
	[ -z "$(git branch -r --contains "$sha" 2>/dev/null)" ]; then
	echo "loom-signoff-gate: $sha is on none of origin's branches; push it first" >&2
	exit 2
fi

LOOM_CPUS=""
LOOM_MEMORY=""
# shellcheck source=/dev/null
if [ -r "$state/config" ]; then . "$state/config"; fi

# The token is read only when the run will post, so a dry run never has
# it in its environment at all.
if [ "$post" = yes ]; then
	GH_TOKEN=$(<"$state/gh-token")
	export GH_TOKEN
fi

export HOME="$state"
export LOOM_DIR="$checkout"
export LOOM_ORIGIN
LOOM_ORIGIN=$(git remote get-url origin)
export LOOM_SHA="$sha"
export LOOM_POST="$post"
export LOOM_URL=""
export LOOM_PARALLEL="$parallel"
export LOOM_CPUS LOOM_MEMORY
export LOOM_LOGS_HINT="read the logs with \`logs $sha [lane]\`"
exec bash "$driver"
