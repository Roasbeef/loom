#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
source "$ROOT/scripts/profile-launcher.sh"

mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

state="$(mktemp -d "${TMPDIR:-/tmp}/loom-profile-launcher.XXXXXXXX")"
trap 'rm -rf "$state"' EXIT
export HOME="$state/home"
export LOOM_PROFILE_TOOL="/profile-tool"

loom_profile_consume client --workspace /workspace --profile --state-dir "$state/client" -- --profile
[[ "$LOOM_PROFILE_ENABLED" == 1 ]]
[[ "$LOOM_PROFILE_NODE" == loom_client_profile_*@127.0.0.1 ]]
[[ -f "$LOOM_PROFILE_COOKIE_HOME/.erlang.cookie" ]]
[[ "$(mode "$LOOM_PROFILE_COOKIE_HOME")" == 700 ]]
[[ "$(mode "$LOOM_PROFILE_COOKIE_HOME/.erlang.cookie")" == 600 ]]
[[ "$(mode "$state/client/tokens")" == 700 ]]
[[ "${LOOM_PROFILE_ARGS[*]}" == "--workspace /workspace --state-dir $state/client -- --profile" ]]
[[ -s "$LOOM_PROFILE_COOKIE_HOME/.erlang.cookie" ]]

loom_profile_consume daemon --bind 127.0.0.1:0 --profile --state-dir "$state/daemon"
[[ "$LOOM_PROFILE_ENABLED" == 1 ]]
[[ "${LOOM_PROFILE_ARGS[*]}" == "--bind 127.0.0.1:0 --state-dir $state/daemon" ]]

profile_config="$state/daemon-profile.toml"
cat > "$profile_config" <<'EOF'
[daemon]
profile = true
EOF
loom_profile_consume daemon --config "$profile_config" --state-dir "$state/configured"
[[ "$LOOM_PROFILE_ENABLED" == 1 ]]
[[ "${LOOM_PROFILE_ARGS[*]}" == "--config $profile_config --state-dir $state/configured" ]]

cat > "$profile_config" <<'EOF'
["daemon"]
profile = true
EOF
loom_profile_consume daemon --config "$profile_config" --state-dir "$state/quoted-configured"
[[ "$LOOM_PROFILE_ENABLED" == 1 ]]

cat > "$profile_config" <<'EOF'
daemon.profile = true
EOF
loom_profile_consume daemon --config "$profile_config" --state-dir "$state/dotted-configured"
[[ "$LOOM_PROFILE_ENABLED" == 1 ]]
cat > "$profile_config" <<'EOF'
[daemon]
profile = false
EOF
loom_profile_consume daemon --config "$profile_config" --state-dir "$state/not-configured"
[[ "$LOOM_PROFILE_ENABLED" == 0 ]]

mkdir -p "$state/default-config"
cat > "$state/default-config/loom.toml" <<'EOF'
[daemon]
profile = true
EOF
loom_profile_consume daemon --state-dir "$state/default-config"
[[ "$LOOM_PROFILE_ENABLED" == 1 ]]
[[ "${LOOM_PROFILE_ARGS[*]}" == "--state-dir $state/default-config" ]]

loom_profile_consume daemon --config --profile
[[ "$LOOM_PROFILE_ENABLED" == 0 ]]
[[ "${LOOM_PROFILE_ARGS[*]}" == "--config --profile" ]]

loom_profile_consume client --token --profile
[[ "$LOOM_PROFILE_ENABLED" == 0 ]]
[[ "${LOOM_PROFILE_ARGS[*]}" == "--token --profile" ]]

loom_profile_consume client ext profile --profile
[[ "$LOOM_PROFILE_ENABLED" == 0 ]]
[[ "${LOOM_PROFILE_ARGS[*]}" == "ext profile --profile" ]]

mkdir -p "$state/bin"

cat > "$state/bin/erl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$FAKE_ERL_ARGS"
printf '%s\n' "$HOME" > "$FAKE_ERL_HOME"
printf '%s\n' "${LOOM_DAEMON_PROFILE:-}" > "$FAKE_ERL_DAEMON_PROFILE"
EOF
chmod +x "$state/bin/erl"

export PATH="$state/bin:$PATH"
export FAKE_ERL_ARGS="$state/erl.args"
export FAKE_ERL_HOME="$state/erl.home"
export FAKE_ERL_DAEMON_PROFILE="$state/erl.daemon-profile"

# Exercise the Makefile-generated slim launcher through macOS's Bash 3. An
# empty-array expansion under `set -u` differs from newer Bash.
/bin/bash "$ROOT/bin/loom"
[[ "$(head -n 1 "$FAKE_ERL_ARGS")" == +Bd ]]
[[ "$(cat "$FAKE_ERL_HOME")" == "$HOME" ]]
[[ -z "$(cat "$FAKE_ERL_DAEMON_PROFILE")" ]]

/bin/bash "$ROOT/bin/loom" --profile --state-dir "$state/slim"
! rg -F -- '--profile' "$FAKE_ERL_ARGS"
[[ "$(cat "$FAKE_ERL_HOME")" == "$state/slim/tokens"/* ]]
[[ "$(cat "$FAKE_ERL_DAEMON_PROFILE")" == 1 ]]

/bin/bash "$ROOT/bin/loom" --token --profile
rg -Fx -- --profile "$FAKE_ERL_ARGS"

echo "profile launcher: argument and credential checks passed"
