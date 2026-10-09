#!/usr/bin/env bash
# Shared launch-time support for Loom's opt-in BEAM profiling nodes.
#
# A profile node is deliberately assembled in the process that needs it. The
# resulting cookie stays below the daemon/client state root, which session
# tools cannot read, and it never enters the application argument vector or a
# child emulator's environment.

loom_profile_random() {
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}

loom_profile_value_option() {
  local role="$1"
  local option="$2"

  case "$role:$option" in
    client:--workspace | client:--session | client:--server | client:--state-dir | client:--config | client:--addr | client:--token-file | client:--token | client:--record | client:--width | client:--height | client:--at)
      return 0
      ;;
    daemon:--state-dir | daemon:--owner-name | daemon:--capacity | daemon:--bind | daemon:--read-scope | daemon:--network | daemon:--helper | daemon:--config | daemon:--codemode-seed | daemon:--codemode-seams)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# A profile node has to be named before the application emulator starts. The release
# supplies its existing TOML parser as this reader: reimplementing TOML in the
# shell would silently disagree about equivalent key spellings.
#
# The reader is a second emulator, and booting one cost about 150 ms on every
# daemon start: a third of the daemon's whole startup, paid by everyone with a
# loom.toml to answer a question almost every file answers no to. A file can
# only enable profiling by naming the key, and TOML spells a key either
# literally or as a quoted key whose escapes are \u or \U, so a file holding
# none of `profile`, `\u` or `\U` cannot set it and the reader is not asked.
# Every other file still goes to the reader, which stays the only judge of
# what the file says. Bash reads the file itself, so no outside tool on PATH
# can change the answer.
loom_profile_config_enabled() {
  local config="$1"

  [[ -r "$config" ]] || return 1

  [[ -n "${LOOM_PROFILE_CONFIG_READER:-}" ]] || return 1
  local text
  text="$(<"$config")" || return 1
  [[ "$text" == *profile* || "$text" == *'\u'* || "$text" == *'\U'* ]] || return 1
  "$LOOM_PROFILE_CONFIG_READER" "$config"
}

# A profiling node exists to be attached to, so it only makes sense for an
# invocation that starts a long-lived daemon or client node. Help requests and
# the subcommands that run and exit never start one; creating a credential
# directory and printing a node name for them would be misleading, and with
# `[daemon] profile = true` it would happen on every `loomd --help`.
#
# The recognition mirrors the applications' own dispatch: `--help` and `-h`
# win wherever they appear, `help` only in first position, and the
# subcommand words only in first position. The client's `ui` command and older
# `--ui` spelling print a web link and exit; the daemon owns the web view.
loom_profile_is_exit_only() {
  local role="$1"
  shift

  local word=""
  for word in "$@"; do
    case "$word" in
      --help | -h)
        return 0
        ;;
      --ui)
        [[ "$role" == client ]] && return 0
        ;;
    esac
  done

  case "$role:${1:-}" in
    client:help | client:ui | client:ext | client:replay | client:sessions | client:version | client:--version | client:claim | client:enroll | client:access | client:update)
      return 0
      ;;
    daemon:help | daemon:access | daemon:peer | daemon:ext | daemon:codex)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Reports whether the process table text names the credential directory as a
# running emulator's -home argument. That argument is how observer.sh pairs a
# node with its credentials, and it is equally good evidence of liveness here.
loom_profile_directory_in_use() {
  local processes="$1"
  local directory="$2"

  [[ "$processes" == *" -home $directory "* || "$processes" == *" -home $directory"$'\n'* ]]
}

# Removes credential directories whose profiled process is gone. A launcher
# that was killed outright, or a machine that rebooted, leaves its directory
# behind, and older releases left every directory behind.
#
# Only names of the exact shape mktemp gives them are candidates, and only
# real directories: nothing else under tokens/ is ever touched. A directory
# is stale when no process was started with it as its HOME. One created in the
# last two minutes is spared regardless, because a concurrent launcher creates
# its directory before it execs the emulator that will claim it. When the
# process table cannot be read, nothing is removed.
loom_profile_sweep() {
  local tokens="$1"

  local processes
  processes="$(ps -ww -axo command= 2>/dev/null)" || return 0

  local directory=""
  local name=""
  for directory in "$tokens"/loom-daemon-profile.???????? "$tokens"/loom-client-profile.????????; do
    if [[ -L "$directory" || ! -d "$directory" ]]; then
      continue
    fi

    name="${directory##*/}"
    if [[ ! "$name" =~ ^loom-(daemon|client)-profile\.[A-Za-z0-9]{8}$ ]]; then
      continue
    fi

    if [[ -n "$(find "$directory" -maxdepth 0 -mmin -2 2>/dev/null)" ]]; then
      continue
    fi

    if loom_profile_directory_in_use "$processes" "$directory"; then
      continue
    fi

    rm -rf -- "$directory"
  done
}

# Removes the credential directory once the launcher's process has exited.
#
# The launchers exec the emulator, so the launcher's PID becomes the
# emulator's PID and no shell remains to run a trap afterwards. Keeping that
# PID is also what lets observer.sh recognise the node, whose name embeds it.
# A detached watcher therefore polls the PID and removes the directory when it
# disappears, which covers a normal exit, a signal and SIGKILL alike. The
# watcher ignores HUP, INT and QUIT so a terminal interrupt aimed at the
# foreground client does not take it down first, and it holds none of the
# caller's descriptors.
loom_profile_watch() {
  local owner="$$"
  local directory="$1"
  local interval="${LOOM_PROFILE_WATCH_INTERVAL:-2}"

  (
    trap '' HUP INT QUIT
    while kill -0 "$owner" 2>/dev/null; do
      sleep "$interval"
    done
    rm -rf -- "$directory"
  ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

# Removes this launcher's --profile option while retaining the application's
# original argument boundaries in LOOM_PROFILE_ARGS. It recognises options
# only before -- and skips known option values, so a value named --profile is
# still delivered to the application as its value.
loom_profile_consume() {
  local role="$1"
  shift

  LOOM_PROFILE_ARGS=()
  LOOM_PROFILE_ENABLED=0
  LOOM_PROFILE_NODE=""
  LOOM_PROFILE_COOKIE_HOME=""
  LOOM_PROFILE_ORIGINAL_HOME="${HOME:-}"

  # These invocations own their complete argument tail. In particular,
  # `loomd codex` owns its credential --profile and `loom ext` forwards every
  # word to the server, so neither is a launcher profiling option.
  if loom_profile_is_exit_only "$role" "$@"; then
    LOOM_PROFILE_ARGS=("$@")
    return 0
  fi

  local state_root=""
  local config_path=""
  local parsing=1
  local option=""

  while (( $# > 0 )); do
    option="$1"
    shift

    if (( parsing == 0 )); then
      LOOM_PROFILE_ARGS+=("$option")
      continue
    fi

    case "$option" in
      --)
        parsing=0
        LOOM_PROFILE_ARGS+=("$option")
        ;;
      --profile)
        if (( LOOM_PROFILE_ENABLED == 1 )); then
          echo "loom: --profile may be specified only once" >&2
          return 2
        fi
        LOOM_PROFILE_ENABLED=1
        ;;
      --state-dir)
        LOOM_PROFILE_ARGS+=("$option")
        if (( $# == 0 )); then
          continue
        fi
        state_root="$1"
        LOOM_PROFILE_ARGS+=("$1")
        shift
        ;;
      --config)
        LOOM_PROFILE_ARGS+=("$option")
        if (( $# == 0 )); then
          continue
        fi
        config_path="$1"
        LOOM_PROFILE_ARGS+=("$1")
        shift
        ;;
      *)
        LOOM_PROFILE_ARGS+=("$option")
        if loom_profile_value_option "$role" "$option" && (( $# > 0 )); then
          LOOM_PROFILE_ARGS+=("$1")
          shift
        fi
        ;;
    esac
  done

  if [[ -z "$state_root" ]]; then
    state_root="${HOME:+$HOME/.loom}"
  fi

  if [[ -z "$config_path" && -n "$state_root" ]]; then
    config_path="$state_root/loom.toml"
  fi

  if [[ "$LOOM_PROFILE_ENABLED" == 0 ]] \
    && loom_profile_config_enabled "$config_path"; then
    LOOM_PROFILE_ENABLED=1
  fi

  if (( LOOM_PROFILE_ENABLED == 0 )); then
    return 0
  fi

  if [[ -z "$LOOM_PROFILE_ORIGINAL_HOME" ]]; then
    echo "loom: --profile needs HOME to preserve the application's environment" >&2
    return 2
  fi

  if [[ -z "$state_root" ]]; then
    state_root="$HOME/.loom"
  fi

  local tokens="$state_root/tokens"
  local old_umask
  old_umask="$(umask)"
  umask 077
  mkdir -p "$tokens"
  chmod 700 "$tokens"
  loom_profile_sweep "$tokens"
  LOOM_PROFILE_COOKIE_HOME="$(mktemp -d "$tokens/loom-${role}-profile.XXXXXXXX")"
  umask "$old_umask"

  local cookie
  cookie="$(loom_profile_random)"
  printf '%s\n' "$cookie" >"$LOOM_PROFILE_COOKIE_HOME/.erlang.cookie"
  chmod 700 "$LOOM_PROFILE_COOKIE_HOME"
  chmod 600 "$LOOM_PROFILE_COOKIE_HOME/.erlang.cookie"
  loom_profile_watch "$LOOM_PROFILE_COOKIE_HOME"

  LOOM_PROFILE_NODE="loom_${role}_profile_$$_$(loom_profile_random)@127.0.0.1"
  printf 'Loom profiling enabled for %s.\n' "$role" >&2
  printf '  node: %s\n' "$LOOM_PROFILE_NODE" >&2
  printf '  attach: %q %q %q\n' "${LOOM_PROFILE_TOOL:?}" "$LOOM_PROFILE_NODE" "$LOOM_PROFILE_COOKIE_HOME" >&2
  printf '  the credential directory is removed when the process exits.\n' >&2
}
