#!/usr/bin/env bash
# Attach a local Observer GUI to an existing Loom profiling node. Discovery
# reads process arguments, but reports only the node and PID; credentials stay
# in their existing private directory and never enter an argument vector.
set -euo pipefail

here="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
source "$here/profile-launcher.sh"

usage() {
  cat <<'USAGE'
Usage: loom observer [--pid PID] [--state-dir DIR] [--erl PATH]
       loomd observer [--pid PID] [--state-dir DIR] [--erl PATH]

Open Erlang Observer on the running profiled daemon. Use --pid to select a
profiled daemon or terminal client. The state directory defaults to ~/.loom.
Start the target with --profile (or daemon.profile = true) before attaching.
A local Erlang/OTP installation with Observer and wx is required; --erl selects
its erl executable. Close the Observer window to finish this command.
USAGE
}

fail() { printf 'loom observer: %s\n' "$1" >&2; exit 2; }

operator_home="${HOME:?loom observer needs HOME}"
state_root="$HOME/.loom"
target_pid=""
erl="erl"
while (( $# > 0 )); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --pid|--state-dir|--erl)
      option="$1"
      (( $# >= 2 )) || fail "$option needs a value"
      case "$option" in
        --pid) target_pid="$2" ;;
        --state-dir) state_root="$2" ;;
        --erl) erl="$2" ;;
      esac
      shift 2
      ;;
    *) fail "unknown option: $1 (see --help)" ;;
  esac
done
[[ -z "$target_pid" || "$target_pid" =~ ^[1-9][0-9]*$ ]] || fail '--pid must be a positive integer'
command -v "$erl" >/dev/null 2>&1 || fail 'erl is unavailable; install Erlang/OTP with Observer and wx, or use --erl PATH'

# The generated node embeds the launcher's PID, which exec preserves. Matching
# both fields rejects stale credentials and unrelated emulators, including
# code-mode satellites. An explicit PID also permits terminal client nodes.
if [[ -n "$target_pid" ]]; then
  processes="$(ps -ww -p "$target_pid" -o pid=,command=)" || fail 'the selected process is not running'
else
  processes="$(ps -ww -axo pid=,command=)" || fail 'cannot read the process table'
fi
node=""
cookie_home=""
matched_pid=""
node_pattern='(^| )-name (loom_(daemon|client)_profile_([0-9]+)_[0-9a-f]{32}@127\.0\.0\.1)( |$)'
while read -r pid command; do
  [[ "$command" =~ $node_pattern ]] || continue
  candidate_node="${BASH_REMATCH[2]}"
  role="${BASH_REMATCH[3]}"
  [[ "$pid" == "${BASH_REMATCH[4]}" ]] || continue
  [[ -n "$target_pid" || "$role" == daemon ]] || continue

  # Enumerating the selected private root avoids parsing a -home path on
  # whitespace: state directories may contain spaces. The literal argument
  # must match a directory that already holds this emulator's cookie.
  for candidate_home in "$state_root"/tokens/loom-"$role"-profile.*; do
    [[ -r "$candidate_home/.erlang.cookie" ]] || continue
    [[ " $command " == *" -home $candidate_home "* ]] || continue
    [[ -z "$node" ]] || fail 'multiple profiled daemons found; choose one with --pid PID'
    node="$candidate_node"
    cookie_home="$candidate_home"
    matched_pid="$pid"
  done
done <<< "$processes"
[[ -n "$node" ]] || fail 'no matching profiled process found; check --state-dir and start the target with --profile'

# The distribution cookie is read by Erlang from HOME. Its application-facing
# HOME remains the operator's, matching the profiling launcher's separation.
# Preflight catches stripped/runtime-only installations before opening a GUI.
if ! /usr/bin/env "HOME=$cookie_home" ERL_CRASH_DUMP=/dev/null "$erl" +S 2:2 -noshell -noinput \
  -env HOME "$operator_home" -eval 'case {code:which(observer), code:which(wx)} of {non_existing, _} -> halt(2); {_, non_existing} -> halt(2); _ -> halt(0) end.'; then
  fail 'the selected Erlang installation needs Observer and wx; use --erl PATH to select a GUI-capable installation'
fi
printf 'Opening Observer on PID %s (%s).\n' "$matched_pid" "$node" >&2
unset LOOM_DAEMON_PROFILE
exec /usr/bin/env "HOME=$cookie_home" ERL_CRASH_DUMP=/dev/null "$erl" +S 2:2 \
  -name "loom_observer_$$_$(loom_profile_random)@127.0.0.1" -hidden \
  -env HOME "$operator_home" -kernel inet_dist_use_interface '{127,0,0,1}' \
  -noshell -run observer start_and_wait "$node" -s init stop
