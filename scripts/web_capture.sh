#!/usr/bin/env bash
# web_capture.sh — photograph the web view from a live daemon, before and
# after a visual change, from the same seeded sessions.
#
#   scripts/web_capture.sh seed  <state-dir>
#   scripts/web_capture.sh shoot <state-dir> [<out-dir>]
#   scripts/web_capture.sh stop  <state-dir>
#
# A stylesheet change is judged by looking at the page, and the page looks
# like itself only with real content on it: a transcript with a model's
# prose and tool rows, a diff, an approval card, a sub-agent strand. This
# script builds that content once, against a real model, and then shoots it
# as often as you like. It is a drive aid and not part of `make check`: it
# needs a daemon, a model key, tmux and a browser. Compare with
# `web_narrow_check.sh`, which measures layouts and fails; this one only
# takes pictures.
#
# ## The two phases
#
# `seed` is slow and needs the model. It boots a dev daemon from this
# checkout on a fresh `<state-dir>` (the daemon's own state, a scratch git
# repository to work in, a private HOME and a copy of the model config all
# live under it), runs a handful of real prompts through `loom run --keep`,
# records each session's id in `<state-dir>/sessions.tsv`, and then stops
# the daemon. The state is left behind, stopped. Prompts leave durable
# state: the transcripts, the workspace's uncommitted edits, and the
# approvals the policy held (an escalation record is a durable fact, so a
# restarted daemon shows the card again when the session is opened).
#
# `shoot` is fast. It boots a daemon on the seeded state with whatever is
# built at that moment, opens every seeded session so each is resident,
# starts one more turn on the "working" session so Home has a session in
# each activity state, and captures the pages with `agent-browser` into
# `<out-dir>` (default `~/loom-drives/web-capture/shots-<timestamp>`).
# Each page state is shot at 1440x900 in both themes; Home is also shot at
# 390x844. It prints the page states it captured and the ones it could not
# reach, and always stops what it started. The model is needed only for the
# working turn, and that capture is reported as missed without it.
#
# `stop` tears down whatever a crashed run left: the daemon recorded in
# `<state-dir>/daemon.pid` and the tmux session `loom-capture`.
#
# ## Before and after a change
#
# The page's stylesheet is `packages/web_client/src/web_client.css`, built
# by `make gen-client` into `packages/web_view/priv/static/web_client.css`
# and copied into the server shipment that `bin/loomd` runs. So between a
# before set and an after set, and only then:
#
#   make -C <repo> gen-client        # the bundle and the stylesheet
#   make -C <repo> server-shipment   # bin/loomd serves the shipment's copy
#   scripts/web_capture.sh shoot <state-dir> <after-dir>
#
# `shoot` starts a fresh daemon every time, so nothing else is needed; the
# same `<state-dir>` serves both sets. A change to Gleam view code needs the
# same two make targets. The first build of a checkout needs
# `make codemode-seed`, `make binaries` and `make server-shipment`.
#
# ## What it does to keep the drive honest
#
# Each of these has cost a drive before, so the script does them for you:
#
#   - HOME is `<state-dir>/home` for the daemon and every `loom` call, so
#     the owner's real `~/.claude` hooks are not loaded.
#   - The scratch workspace is its own git repository holding a small Python
#     project, and every client call runs from inside it, since a session
#     takes the launch directory's git root as its workspace. The code-mode
#     seed is symlinked at `<workspace>/build/codemode-seed`, which is where
#     the daemon looks; seed fails if the log never says `codemode.ready`.
#   - `--server <repo>/bin/loomd` is passed so the client never launches an
#     installed loomd, and `/usr/local/bin` leads PATH so the daemon finds
#     gleam 1.19 and not an older Homebrew one.
#   - The model is Kimi K3 on Baseten from `~/.loom/loom-glm.toml`, with the
#     jail's network off so a `curl` holds for approval. The key never
#     passes through this script: the daemon runs in a tmux session of its
#     own, and the pane copies `BASETEN_GLM_5_2` from the tmux server's
#     global environment into `BASETEN_API_KEY` itself.
#   - Only processes this script started are killed: the daemon by the pid
#     its launcher wrote, then by its own `--state-dir` argument, and the
#     one tmux session by name. Never `tmux kill-server`.
#   - The browser is Chrome for Testing in its own `agent-browser` session,
#     never the installed Google Chrome, and it is closed on every exit.
#
# ## Environment
#
#   WEB_CAPTURE_CONFIG   model config to copy (default ~/.loom/loom-glm.toml)
#   WEB_CAPTURE_CHROME   Chrome for Testing executable (default: the
#                        playwright cache's chromium-1223)
#   AGENT_BROWSER_SESSION  the browser session's name (default capture)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOOM=$ROOT/bin/loom
LOOMD=$ROOT/bin/loomd
REAL_HOME=$HOME
TMUX_SESSION=loom-capture
CONFIG_SRC=${WEB_CAPTURE_CONFIG:-$REAL_HOME/.loom/loom-glm.toml}
CHROME=${WEB_CAPTURE_CHROME:-$REAL_HOME/Library/Caches/ms-playwright/chromium-1223/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing}
export AGENT_BROWSER_SESSION=${AGENT_BROWSER_SESSION:-capture}
export AGENT_BROWSER_EXECUTABLE_PATH=$CHROME

die() {
  echo "web_capture: $*" >&2
  exit 1
}

usage() {
  sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# ---------------------------------------------------------------------------
# State layout. Everything one capture run owns lives under the state
# directory, so one path names it all and `stop` needs nothing else.
# ---------------------------------------------------------------------------

layout() {
  mkdir -p "$1"
  D=$(cd "$1" && pwd)
  DAEMON=$D/daemon
  WS=$D/ws
  HOMEDIR=$D/home
  CFG=$D/loom.toml
  LOG=$D/daemon.log
  PIDF=$D/daemon.pid
  IDS=$D/sessions.tsv
}

# `loomc <args>`: the `loom` client, from inside the scratch workspace, with
# the private HOME and the options that point it at this state and this
# checkout's daemon.
loomc() {
  (cd "$WS" && HOME=$HOMEDIR PATH=/usr/local/bin:$PATH \
    "$LOOM" "$@" --state-dir "$DAEMON" --config "$CFG" --server "$LOOMD")
}

daemon_alive() {
  [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null
}

# ---------------------------------------------------------------------------
# The daemon. It runs in a tmux pane because the model key lives in the tmux
# server's environment, and the launcher writes its own pid first and then
# execs, so the recorded pid is the daemon's.
# ---------------------------------------------------------------------------

start_daemon() {
  if daemon_alive; then
    return 0
  fi
  [ -x "$LOOMD" ] || die "$LOOMD is missing: run make binaries server-shipment"
  [ -x "$LOOM" ] || die "$LOOM is missing: run make binaries"
  tmux has-session -t "$TMUX_SESSION" 2>/dev/null ||
    tmux new-session -d -s "$TMUX_SESSION" -x 200 -y 50
  if ! tmux show-environment -g BASETEN_GLM_5_2 >/dev/null 2>&1; then
    echo "note: BASETEN_GLM_5_2 is not in the tmux environment; model calls will fail" >&2
  fi
  cat >"$D/run-daemon.sh" <<EOF
#!/usr/bin/env bash
echo \$\$ > "$PIDF"
export HOME="$HOMEDIR" PATH="/usr/local/bin:\$PATH"
cd "$WS"
exec "$LOOMD" --ui --state-dir "$DAEMON" --config "$CFG"
EOF
  : >"$LOG"
  rm -f "$PIDF"
  tmux send-keys -t "$TMUX_SESSION" \
    "export BASETEN_API_KEY=\"\$BASETEN_GLM_5_2\"; bash '$D/run-daemon.sh' > '$LOG' 2>&1" Enter
  for _ in $(seq 1 90); do
    grep -q 'web view on' "$LOG" && return 0
    sleep 1
  done
  die "the daemon did not report its web view; see $LOG"
}

stop_daemon() {
  if daemon_alive; then
    kill -TERM "$(cat "$PIDF")" 2>/dev/null || true
  fi
  for _ in $(seq 1 30); do
    pgrep -f "state-dir $DAEMON" >/dev/null || break
    sleep 1
  done
  # A daemon that ignored SIGTERM, matched by the state directory it was
  # given and by nothing else.
  pkill -f "state-dir $DAEMON" 2>/dev/null || true
  for _ in $(seq 1 15); do
    pgrep -f "$DAEMON" >/dev/null || break
    sleep 1
  done
  rm -f "$PIDF"
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# The browser, one `agent-browser` session of this script's own.
# ---------------------------------------------------------------------------

ab() {
  agent-browser "$@"
}

browser_close() {
  agent-browser close >/dev/null 2>&1 || true
}

# `mint [session-id]`: a single-use link to Home or to an operator's page of
# one session. Minting a session link also makes that session resident.
mint() {
  if [ $# -eq 0 ]; then
    loomc ui </dev/null 2>/dev/null | head -n 1
  else
    loomc ui --session "$1" --operate </dev/null 2>/dev/null | head -n 1
  fi
}

# `theme_to <light|dark>`: press the page's Theme button until the document
# root says so (it cycles system, light, dark), then check it.
theme_to() {
  local want=$1
  for _ in 1 2 3 4; do
    [ "$(ab get attr html data-theme 2>/dev/null || true)" = "$want" ] && return 0
    ab find role button click --name "Theme:" >/dev/null
    ab wait 300 >/dev/null
  done
  [ "$(ab get attr html data-theme 2>/dev/null || true)" = "$want" ]
}

# `panel_tab <name>`: open one of the right-hand panel's tabs. The names
# are matched whole, since "Strands" is also a substring of the button that
# hides the panel; the Strands tab's name grows a count when an approval
# waits ("Strands, 1 needs approval"), which the fallback matches. A panel
# that an earlier page left hidden is shown first, and the page remembers
# the chosen tab from one session to the next, so every state picks its own.
panel_tab() {
  ab find role button click --name "Show strands" >/dev/null 2>&1 || true
  ab find role button click --name "$1" --exact >/dev/null 2>&1 ||
    ab find role button click --name "$1," >/dev/null 2>&1 || return 1
  ab wait 900 >/dev/null
}

# `open_fold <summary-regex>`: open the first collapsed group whose summary
# matches, through every shadow root, since the groups are drawn inside the
# page's components. It reports whether one was found.
open_fold() {
  ab eval "(() => {
    const walk = (root) => {
      for (const s of root.querySelectorAll('summary')) {
        if (/$1/i.test(s.textContent)) { s.click(); return true; }
      }
      for (const el of root.querySelectorAll('*')) {
        if (el.shadowRoot && walk(el.shadowRoot)) return true;
      }
      return false;
    };
    return walk(document);
  })()" 2>/dev/null | grep -q true
  ab wait 700 >/dev/null
}

# ---------------------------------------------------------------------------
# Seeding. Each prompt is a real run through the model; `loom run --keep`
# leaves the session behind and prints one JSON object with its id.
# ---------------------------------------------------------------------------

prepare_state() {
  [ ! -e "$DAEMON" ] || die "$D already holds a daemon state; pick a fresh directory"
  [ -f "$CONFIG_SRC" ] || die "no model config at $CONFIG_SRC"
  mkdir -p "$HOMEDIR" "$WS/build" "$DAEMON"
  [ -d "$ROOT/build/codemode-seed" ] || die "run make codemode-seed first"
  ln -sfn "$ROOT/build/codemode-seed" "$WS/build/codemode-seed"

  # The model config, with the key read from the variable the daemon's pane
  # sets, the jail's network off so a network call holds for approval, and
  # the daemon's web view on.
  sed -e 's/^api_key_env = .*/api_key_env = "BASETEN_API_KEY"/' \
    -e '/^profile = /d' "$CONFIG_SRC" >"$CFG"
  grep -q '^\[tools\]' "$CFG" && die "$CONFIG_SRC already has a [tools] table"
  printf '\n[tools]\nnetwork = "off"\n\n[daemon]\nui = true\n' >>"$CFG"

  # A small project for the model to work on, committed so that every edit
  # shows as a diff against HEAD.
  (
    cd "$WS"
    git init -q
    printf 'def add(a, b):\n    return a + b\n\n\ndef greet(name):\n    return "hello " + name\n' >app.py
    printf '# demo\n\nA small Python project: arithmetic and a greeting.\n' >README.md
    printf 'build/\n__pycache__/\n' >.gitignore
    git add -A
    git -c user.name=capture -c user.email=capture@example.invalid commit -q -m init
  )
}

# `run_prompt <label> <prompt>`: one model run, its session id recorded.
run_prompt() {
  local label=$1 prompt=$2 out id outcome
  echo "seed: $label ..." >&2
  out=$(loomc run --keep --timeout 300 -p "$prompt" 2>/dev/null) ||
    echo "seed: $label exited non-zero (a held approval is not a failure)" >&2
  id=$(printf '%s' "$out" | sed -n 's/.*"session_id":"\([^"]*\)".*/\1/p')
  outcome=$(printf '%s' "$out" | sed -n 's/.*"outcome":"\([^"]*\)".*/\1/p')
  [ -n "$id" ] || die "$label produced no session: $out"
  printf '%s\t%s\n' "$label" "$id" >>"$IDS"
  echo "seed: $label -> $id ($outcome)" >&2
}

cmd_seed() {
  [ $# -eq 1 ] || usage
  layout "$1"
  [ ! -e "$IDS" ] || die "$D is already seeded"
  prepare_state
  trap 'stop_daemon' EXIT
  start_daemon

  # The edit session: a transcript with reads, edits and a shell run, and
  # the diff the Changes tab shows, with removed lines as well as added.
  run_prompt edit "Read app.py. Then, using your file edit tool, rewrite greet to use an f-string and give both functions docstrings, and add a multiply(a, b) function. Create tests.py with two assert statements covering add and multiply, run it with python3, and summarize what you changed in two sentences."

  # Text with no tools, for a transcript that is mostly prose.
  run_prompt explain "Without running any command, read README.md and app.py with your read tool and explain in three short bullet points what this project is, followed by one sentence on what you would improve first."

  # A sub-agent strand in the strands strip.
  run_prompt agents "Use your agent_spawn tool to start one sub-agent named reviewer. Ask it to read app.py and tests.py and report one risk in each in a single sentence. Wait for its report, then give me both sentences."

  # Two calls the policy holds for approval: a write outside the workspace,
  # and a network call with the jail's network off. The run ends when the
  # model gives up on the refusal; the escalation record stays pending.
  run_prompt approval-write "Use your file write tool to create $D/outside.txt containing the single word hi. Use only that tool, and do not change the path."
  run_prompt approval-network "Run curl -sI https://example.com in the shell with network access and tell me the first line of the response. Ask for the network permission the call needs."

  # The session Home will show as working: it only needs to exist and to be
  # idle, since `shoot` gives it a long turn.
  run_prompt working "Reply with the single word ready."

  grep -q 'codemode.ready' "$LOG" || die "the daemon never logged codemode.ready: is $WS/build/codemode-seed present? See $LOG"
  echo "seeded $D"
  echo "shoot it with: scripts/web_capture.sh shoot $D <out-dir>"
}

# ---------------------------------------------------------------------------
# Shooting. `saw <text>` asks the page's accessibility tree whether a state
# is on screen, so a page state is reported captured only when its marker
# was really there.
# ---------------------------------------------------------------------------

CAPTURED=()
MISSED=()

captured() { CAPTURED+=("$1"); }
missed() { MISSED+=("$1: $2"); }

saw() {
  ab snapshot 2>/dev/null | grep -q -i -- "$1"
}

session_id() {
  awk -F '\t' -v want="$1" '$1 == want { print $2 }' "$IDS"
}

# `shoot_both <name>`: the page as it stands, in each theme. A theme that
# cannot be verified on the document root is a miss and not a picture.
shoot_both() {
  local name=$1 theme
  for theme in light dark; do
    if theme_to "$theme"; then
      ab wait 500 >/dev/null
      ab screenshot "$OUT/$name-$theme.png" >/dev/null
    else
      missed "$name-$theme" "the Theme button did not reach $theme"
    fi
  done
}

# `open_session <label>`: open a seeded session's operator page at desktop
# size. Fails when the session is not in the sessions file or the page does
# not draw.
open_session() {
  local id link
  id=$(session_id "$1")
  [ -n "$id" ] || return 1
  link=$(mint "$id")
  [ -n "$link" ] || return 1
  ab open "$link" >/dev/null
  ab set viewport 1440 900 >/dev/null
  ab wait 3000 >/dev/null
  saw 'Panel views'
}

# `page_state <name> <session-label> <marker> <tab> [<summary-regex>
# [<fold-button>]]`: open a session and a panel tab, open a collapsed group
# of the panel and a fold of the transcript when asked, check the marker and
# shoot the page in both themes. The marker is text only the wanted state
# draws, so a page that did not reach it is a miss and not a wrong picture.
page_state() {
  local name=$1 label=$2 marker=$3 tab=$4 summary=${5:-} fold=${6:-}
  if ! open_session "$label"; then
    missed "$name" "session $label did not open"
    return 0
  fi
  panel_tab "$tab" || true
  [ -z "$summary" ] || open_fold "$summary" || true
  if [ -n "$fold" ]; then
    ab find role button click --name "$fold" >/dev/null 2>&1 || true
    ab wait 700 >/dev/null
  fi
  if saw "$marker"; then
    shoot_both "$name"
    captured "$name"
  else
    missed "$name" "no '$marker' on the $label page"
  fi
}

# Home, shot after every seeded session has been opened and the working
# turn has begun, at desktop and phone size.
home_states() {
  local link theme
  link=$(mint)
  ab open "$link" >/dev/null
  ab set viewport 1440 900 >/dev/null
  ab wait 3000 >/dev/null
  if saw 'Needs you' && saw 'Idle'; then
    if saw 'Working'; then
      captured "home-working"
    else
      missed "home-working" "no session reached the Working group"
    fi
    shoot_both home
    captured home
    ab set viewport 390 844 >/dev/null
    ab wait 800 >/dev/null
    for theme in light dark; do
      theme_to "$theme" && ab screenshot "$OUT/home-phone-$theme.png" >/dev/null
    done
    captured home-phone
    ab set viewport 1440 900 >/dev/null
  else
    missed home "no Needs you and Idle groups in the sidebar"
  fi
}

# The working session: one prompt typed into its composer, then Home is
# polled until the sidebar has a Working group. The turn runs on the daemon
# whether or not the page stays open.
start_working_turn() {
  open_session working || return 1
  ab find role textbox fill "Run the shell command sleep 600 and wait for it to finish, then reply done." \
    --name "Message the agent" >/dev/null 2>&1 || return 1
  ab find role button click --name "Send" >/dev/null 2>&1 || return 1
  ab wait 1500 >/dev/null
}

wait_for_working() {
  local link
  for _ in $(seq 1 12); do
    link=$(mint)
    ab open "$link" >/dev/null
    ab wait 2500 >/dev/null
    saw 'Working' && return 0
  done
  return 1
}

cmd_shoot() {
  [ $# -ge 1 ] && [ $# -le 2 ] || usage
  layout "$1"
  [ -f "$IDS" ] || die "$D is not seeded: run seed first"
  OUT=${2:-$REAL_HOME/loom-drives/web-capture/shots-$(date +%Y%m%d-%H%M%S)}
  mkdir -p "$OUT"
  OUT=$(cd "$OUT" && pwd)
  [ -x "$(command -v agent-browser)" ] || die "agent-browser is not on PATH"
  [ -x "$CHROME" ] || die "no Chrome for Testing at $CHROME"
  trap 'browser_close; stop_daemon' EXIT
  start_daemon

  # Every seeded session resident, so that each is in the group its state
  # puts it in: held approvals under Needs you, the rest under Idle.
  local label id
  while IFS=$'\t' read -r label id; do
    mint "$id" >/dev/null
  done <"$IDS"

  if ! start_working_turn; then
    echo "note: the working turn was not typed (the session may already be mid-turn)" >&2
  fi
  wait_for_working || true
  home_states

  page_state session-transcript edit 'Worked' Strands '' Worked
  page_state changes edit 'CHANGES' Changes
  page_state session-tab edit 'PEOPLE' Session
  page_state approval-write approval-write 'Approvals waiting' Strands
  page_state approval-network approval-network 'Approvals waiting' Strands
  page_state strands-subagent agents 'reviewer Finished' Strands settled

  echo
  echo "captured into $OUT:"
  local entry
  for entry in "${CAPTURED[@]}"; do echo "  $entry"; done
  if [ ${#MISSED[@]} -gt 0 ]; then
    echo "could not reach:"
    for entry in "${MISSED[@]}"; do echo "  $entry"; done
  fi
  ls "$OUT"
}

cmd_stop() {
  [ $# -eq 1 ] || usage
  layout "$1"
  browser_close
  stop_daemon
  echo "stopped $D"
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case $cmd in
seed) cmd_seed "$@" ;;
shoot) cmd_shoot "$@" ;;
stop) cmd_stop "$@" ;;
*) usage ;;
esac
