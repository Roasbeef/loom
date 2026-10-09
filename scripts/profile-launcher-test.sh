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
export LOOM_PROFILE_WATCH_INTERVAL=1

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
reader="$state/profile-reader"
cat > "$reader" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" > "$PROFILE_READER_PATH"
if rg -q '=[[:space:]]*true' "$1"; then
  exit 0
fi
exit 1
EOF
chmod +x "$reader"
export LOOM_PROFILE_CONFIG_READER="$reader"
export PROFILE_READER_PATH="$state/profile-reader.path"
loom_profile_consume daemon --profile --config "$profile_config" --state-dir "$state/explicit-configured"
[[ "$LOOM_PROFILE_ENABLED" == 1 ]]
[[ ! -e "$PROFILE_READER_PATH" ]]

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
[ "daemon" ]
profile = true
EOF
loom_profile_consume daemon --config "$profile_config" --state-dir "$state/reader-configured"
[[ "$LOOM_PROFILE_ENABLED" == 1 ]]
[[ "$(cat "$PROFILE_READER_PATH")" == "$profile_config" ]]

cat > "$profile_config" <<'EOF'
[daemon]
profile = false
EOF
loom_profile_consume daemon --config "$profile_config" --state-dir "$state/not-configured"
[[ "$LOOM_PROFILE_ENABLED" == 0 ]]

# A file that never spells the key cannot enable profiling, so the reader,
# a second emulator boot, is not started for it.
rm -f "$PROFILE_READER_PATH"
cat > "$profile_config" <<'EOF'
[daemon]
capacity = true
EOF
loom_profile_consume daemon --config "$profile_config" --state-dir "$state/unnamed-key"
[[ "$LOOM_PROFILE_ENABLED" == 0 ]]
[[ ! -e "$PROFILE_READER_PATH" ]]

# A quoted key may spell the name with escapes alone, so a file holding one
# still goes to the reader.
cat > "$profile_config" <<'EOF'
[daemon]
"profile" = true
EOF
loom_profile_consume daemon --config "$profile_config" --state-dir "$state/escaped-key"
[[ "$LOOM_PROFILE_ENABLED" == 1 ]]
[[ "$(cat "$PROFILE_READER_PATH")" == "$profile_config" ]]

mkdir -p "$state/default-config"
cat > "$state/default-config/loom.toml" <<'EOF'
[daemon]
profile = true
EOF
loom_profile_consume daemon --state-dir "$state/default-config"
[[ "$LOOM_PROFILE_ENABLED" == 1 ]]
[[ "${LOOM_PROFILE_ARGS[*]}" == "--state-dir $state/default-config" ]]

# The same validated setting names a client node without a command-line flag.
loom_profile_consume client --state-dir "$state/default-config"
[[ "$LOOM_PROFILE_ENABLED" == 1 ]]
[[ "$LOOM_PROFILE_NODE" == loom_client_profile_*@127.0.0.1 ]]
[[ "$(cat "$PROFILE_READER_PATH")" == "$state/default-config/loom.toml" ]]
[[ "${LOOM_PROFILE_ARGS[*]}" == "--state-dir $state/default-config" ]]

loom_profile_consume client --config "$profile_config" --state-dir "$state/client-configured"
[[ "$LOOM_PROFILE_ENABLED" == 1 ]]
[[ "${LOOM_PROFILE_ARGS[*]}" == "--config $profile_config --state-dir $state/client-configured" ]]

cat > "$profile_config" <<'EOF'
[daemon]
profile = false
EOF
loom_profile_consume client --config "$profile_config" --state-dir "$state/client-disabled"
[[ "$LOOM_PROFILE_ENABLED" == 0 ]]
[[ ! -e "$state/client-disabled/tokens" ]]
loom_profile_consume client --profile --config "$profile_config" --state-dir "$state/client-explicit"
[[ "$LOOM_PROFILE_ENABLED" == 1 ]]

unset LOOM_PROFILE_CONFIG_READER PROFILE_READER_PATH

loom_profile_consume daemon --config --profile
[[ "$LOOM_PROFILE_ENABLED" == 0 ]]
[[ "${LOOM_PROFILE_ARGS[*]}" == "--config --profile" ]]

loom_profile_consume client --token --profile
[[ "$LOOM_PROFILE_ENABLED" == 0 ]]
[[ "${LOOM_PROFILE_ARGS[*]}" == "--token --profile" ]]

loom_profile_consume client ext profile --profile
[[ "$LOOM_PROFILE_ENABLED" == 0 ]]
[[ "${LOOM_PROFILE_ARGS[*]}" == "ext profile --profile" ]]

loom_profile_consume daemon codex status --profile work
[[ "$LOOM_PROFILE_ENABLED" == 0 ]]
[[ "${LOOM_PROFILE_ARGS[*]}" == "codex status --profile work" ]]

# Version arguments reach application validation without creating credentials.
for command in version --version; do
  HOME="$state/version-home" loom_profile_consume client "$command" --profile
  [[ "$LOOM_PROFILE_ENABLED" == 0 ]]
  [[ "${LOOM_PROFILE_ARGS[*]}" == "$command --profile" ]]
  [[ ! -e "$state/version-home" ]]
done

# Exercise the generated reader with the actual bundled parser before the
# fake emulator below takes over launcher argument inspection.
real_reader="$ROOT/build/tui-erlang-shipment/bin/loom-profile-config"
"$real_reader" "$state/default-config/loom.toml"
cat > "$profile_config" <<'EOF'
[ "daemon" ]
"profile" = true
EOF
"$real_reader" "$profile_config"

# The existing parser preserves Unicode escapes in keys. Match the daemon
# reader's conservative result rather than interpreting the key in shell.
cat > "$profile_config" <<'EOF'
["daemon"]
"\u0070rofile" = true
EOF
if "$real_reader" "$profile_config"; then exit 1; fi
cat > "$profile_config" <<'EOF'
[daemon]
profile = false
EOF
if "$real_reader" "$profile_config"; then exit 1; fi
cat > "$profile_config" <<'EOF'
[daemon]
profile = "invalid"
EOF
if "$real_reader" "$profile_config"; then exit 1; fi
cat > "$profile_config" <<'EOF'
[daemon
profile = true
EOF
if "$real_reader" "$profile_config"; then exit 1; fi

mkdir -p "$state/bin"

cat > "$state/bin/erl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *'tom:get_bool'* ]]; then
  config="${!#}"
  if rg -q 'profile[[:space:]]*=[[:space:]]*true' "$config"; then exit 0; fi
  exit 1
fi
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

/bin/bash "$ROOT/bin/loom" --state-dir "$state/default-config"
rg -Fx -- -name "$FAKE_ERL_ARGS"
[[ "$(cat "$FAKE_ERL_DAEMON_PROFILE")" == 1 ]]
[[ "$(cat "$FAKE_ERL_HOME")" == "$state/default-config/tokens"/* ]]

/bin/bash "$ROOT/bin/loom" --token --profile
rg -Fx -- --profile "$FAKE_ERL_ARGS"

# Observer dispatch happens before ordinary client argument parsing. Help must
# not start the application emulator or create a profiling credential.
cp "$FAKE_ERL_ARGS" "$state/erl.before-observer"
/bin/bash "$ROOT/bin/loom" observer --help > "$state/observer.help"
rg -q 'Usage: loom observer' "$state/observer.help"
cmp "$FAKE_ERL_ARGS" "$state/erl.before-observer"

# The profiled launch above exec'd the fake emulator, so its credential
# directory must disappear once that process has exited. The watcher polls, so
# allow it a few intervals.
wait_for_empty() {
  local directory="$1"
  local attempt=0
  while (( attempt < 50 )); do
    if [[ -z "$(ls -A "$directory")" ]]; then
      return 0
    fi
    sleep 0.2
    attempt=$((attempt + 1))
  done
  return 1
}
wait_for_empty "$state/slim/tokens"

# Help and the subcommands that run and exit never start a node, so they must
# not create credentials, name a node or print the banner, even when the
# daemon's configuration asks for profiling.
profile_config="$state/exit-only.toml"
cat > "$profile_config" <<'EOF'
[daemon]
profile = true
EOF
export LOOM_PROFILE_CONFIG_READER="$reader"
export PROFILE_READER_PATH="$state/exit-only-reader.path"
exit_state="$state/exit-only"
for invocation in \
  "daemon --help" "daemon -h" "daemon help" "daemon access list" "daemon peer list" \
  "daemon ext list" "daemon access --help" "daemon --state-dir $exit_state --help" \
  "client --help" "client -h" "client help" "client --profile --help" \
  "client access list" "client claim --profile" "client enroll" "client update" \
  "client sessions" "client replay x.jsonl" "client ui" "client --ui" \
  "client --state-dir $exit_state --ui"; do
  read -r -a words <<< "$invocation"
  role="${words[0]}"
  banner="$(loom_profile_consume "$role" "${words[@]:1}" --state-dir "$exit_state" --config "$profile_config" 2>&1)"
  loom_profile_consume "$role" "${words[@]:1}" --state-dir "$exit_state" --config "$profile_config" 2>/dev/null
  [[ "$LOOM_PROFILE_ENABLED" == 0 ]]
  [[ -z "$LOOM_PROFILE_NODE" && -z "$LOOM_PROFILE_COOKIE_HOME" ]]
  [[ -z "$banner" ]]
  [[ ! -e "$exit_state/tokens" ]]
done

# A daemon launch with the same configuration still profiles, so the rule is
# about the invocation rather than the configuration being ignored.
loom_profile_consume daemon --state-dir "$exit_state" --config "$profile_config" 2>/dev/null
[[ "$LOOM_PROFILE_ENABLED" == 1 ]]
[[ -d "$LOOM_PROFILE_COOKIE_HOME" ]]
unset LOOM_PROFILE_CONFIG_READER PROFILE_READER_PATH

# The same holds through the generated client launcher.
before="$(ls -A "$state/slim/tokens" | wc -l | tr -d ' ')"
/bin/bash "$ROOT/bin/loom" --profile --state-dir "$state/slim" --help > /dev/null
/bin/bash "$ROOT/bin/loom" access list --state-dir "$state/slim"
[[ "$(ls -A "$state/slim/tokens" | wc -l | tr -d ' ')" == "$before" ]]

# The stale-directory sweep removes only dead directories of the exact shape
# the launchers create, and leaves live, young and unrelated entries alone.
sweep="$state/sweep/tokens"
mkdir -p "$sweep/loom-daemon-profile.deadDEAD" "$sweep/loom-client-profile.dead0000" \
  "$sweep/loom-daemon-profile.liveLIVE" "$sweep/loom-daemon-profile.young000" \
  "$sweep/loom-other-profile.abcdefgh" "$sweep/loom-daemon-profile.short" \
  "$sweep/loom-daemon-profile.toolong123" "$sweep/unrelated"
: > "$sweep/loom-daemon-profile.fileFILE"
: > "$sweep/notes.txt"
ln -s "$sweep/unrelated" "$sweep/loom-client-profile.symlink"
for old in loom-daemon-profile.deadDEAD loom-client-profile.dead0000 loom-daemon-profile.liveLIVE \
  loom-other-profile.abcdefgh loom-daemon-profile.short loom-daemon-profile.toolong123 \
  loom-daemon-profile.fileFILE; do
  touch -t 200001010000 "$sweep/$old"
done

mkdir -p "$state/ps-bin"
cat > "$state/ps-bin/ps" <<'EOF'
#!/usr/bin/env bash
cat "$FAKE_PS_OUTPUT"
EOF
chmod +x "$state/ps-bin/ps"
export FAKE_PS_OUTPUT="$state/ps.output"
printf '%s\n' \
  "/usr/bin/some-process --unrelated" \
  "/erts/bin/beam.smp -name loom_daemon_profile_1_x@127.0.0.1 -home $sweep/loom-daemon-profile.liveLIVE -noshell" \
  > "$FAKE_PS_OUTPUT"

PATH="$state/ps-bin:$PATH" loom_profile_sweep "$sweep"
[[ ! -e "$sweep/loom-daemon-profile.deadDEAD" ]]
[[ ! -e "$sweep/loom-client-profile.dead0000" ]]
[[ -d "$sweep/loom-daemon-profile.liveLIVE" ]]
[[ -d "$sweep/loom-daemon-profile.young000" ]]
[[ -d "$sweep/loom-other-profile.abcdefgh" ]]
[[ -d "$sweep/loom-daemon-profile.short" ]]
[[ -d "$sweep/loom-daemon-profile.toolong123" ]]
[[ -f "$sweep/loom-daemon-profile.fileFILE" ]]
[[ -L "$sweep/loom-client-profile.symlink" && -d "$sweep/unrelated" ]]
[[ -f "$sweep/notes.txt" ]]

# An unreadable process table must remove nothing.
cat > "$state/ps-bin/ps" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
mkdir "$sweep/loom-daemon-profile.deadDEAD"
touch -t 200001010000 "$sweep/loom-daemon-profile.deadDEAD"
PATH="$state/ps-bin:$PATH" loom_profile_sweep "$sweep"
[[ -d "$sweep/loom-daemon-profile.deadDEAD" ]]

# A profiled launch sweeps its own state root: the next launch removes what an
# older release, or a killed launcher, left behind.
mkdir -p "$state/leftover/tokens/loom-daemon-profile.oldOLD00"
touch -t 200001010000 "$state/leftover/tokens/loom-daemon-profile.oldOLD00"
loom_profile_consume client --state-dir "$state/leftover" --profile 2>/dev/null
[[ ! -e "$state/leftover/tokens/loom-daemon-profile.oldOLD00" ]]
[[ -d "$LOOM_PROFILE_COOKIE_HOME" ]]

echo "profile launcher: argument and credential checks passed"
