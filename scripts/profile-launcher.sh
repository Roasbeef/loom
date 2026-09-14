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

  # These client subcommands own their complete argument tail. In particular,
  # `loom ext` forwards every word to the server, so a server-side --profile
  # must not be mistaken for a launcher option.
  if [[ "$role" == client && ( "${1:-}" == ext || "${1:-}" == replay || "${1:-}" == sessions ) ]]; then
    LOOM_PROFILE_ARGS=("$@")
    return 0
  fi

  local state_root=""
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
      *)
        LOOM_PROFILE_ARGS+=("$option")
        if loom_profile_value_option "$role" "$option" && (( $# > 0 )); then
          LOOM_PROFILE_ARGS+=("$1")
          shift
        fi
        ;;
    esac
  done

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
  LOOM_PROFILE_COOKIE_HOME="$(mktemp -d "$tokens/loom-${role}-profile.XXXXXXXX")"
  umask "$old_umask"

  local cookie
  cookie="$(loom_profile_random)"
  printf '%s\n' "$cookie" >"$LOOM_PROFILE_COOKIE_HOME/.erlang.cookie"
  chmod 700 "$LOOM_PROFILE_COOKIE_HOME"
  chmod 600 "$LOOM_PROFILE_COOKIE_HOME/.erlang.cookie"

  LOOM_PROFILE_NODE="loom_${role}_profile_$$_$(loom_profile_random)@127.0.0.1"
  printf 'Loom profiling enabled for %s.\n' "$role" >&2
  printf '  node: %s\n' "$LOOM_PROFILE_NODE" >&2
  printf '  attach: %q %q %q\n' "${LOOM_PROFILE_TOOL:?}" "$LOOM_PROFILE_NODE" "$LOOM_PROFILE_COOKIE_HOME" >&2
  printf '  remove the credential directory after the profiled process exits.\n' >&2
}
