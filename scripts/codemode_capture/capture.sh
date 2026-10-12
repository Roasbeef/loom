#!/usr/bin/env bash
# capture.sh: regenerate docs/images/code-mode.png from the current terminal UI.
#
#   make binaries server-shipment      # bin/loom, bin/loomd, build/codemode-seed
#   scripts/codemode_capture/capture.sh [OUT.png]
#
# Rerun it whenever the terminal's code-mode rendering changes, then copy the
# image to site/public/img/code-mode.png (the two files are identical).
#
# Everything lives under a scratch directory (default /var/tmp/loom-codemode-
# capture; set CAPTURE_DIR to move it, and keep it off /tmp because the jail
# replaces /tmp). HOME points there too, so no operator hooks or settings are
# read. A scripted Anthropic endpoint (fake_anthropic.py) plays the model: it
# answers the prompt with a code_mode call carrying a fixed Gleam program.
# The daemon vets, compiles and runs that program in the real sandbox against
# three sample documents. The terminal is the real bin/loom in a tmux pane
# (private socket, so no other tmux server is touched), and its frame is
# rasterized by docs/design-notes/tui-agent-workspace/render_capture.py from
# `tmux capture-pane -e -p`. Nothing is composited or rewritten.
#
# Ctrl+G expands the tool details so the whole program is visible, which needs
# a taller pane than the old 116x48; CAPTURE_ROWS sets it.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=${1:-$root/docs/images/code-mode.png}
dir=${CAPTURE_DIR:-/var/tmp/loom-codemode-capture}
rows=${CAPTURE_ROWS:-70}
port=${CAPTURE_PORT:-18761}
sock=loom-codemode-capture
prompt="Use code mode to read the three project docs in parallel and report their line counts."

for tool in tmux python3; do
	command -v "$tool" >/dev/null || {
		echo "capture.sh: $tool is required" >&2
		exit 1
	}
done
for built in bin/loom bin/loomd build/codemode-seed; do
	[ -e "$root/$built" ] || {
		echo "capture.sh: $built is missing; run make binaries server-shipment" >&2
		exit 1
	}
done

# Stop what a previous run left behind: only this script's own tmux socket and
# the daemon whose state directory is ours.
stop() {
	tmux -L "$sock" kill-server 2>/dev/null || true
	[ -f "$dir/fake.pid" ] && kill "$(cat "$dir/fake.pid")" 2>/dev/null || true
	for pid in $(pgrep -f "state-dir $dir/state" 2>/dev/null || true); do
		kill "$pid" 2>/dev/null || true
	done
	for pid in $(pgrep -f "$dir/state/daemon.lock" 2>/dev/null || true); do
		kill "$pid" 2>/dev/null || true
	done
}
stop
trap stop EXIT
rm -rf "$dir"
mkdir -p "$dir/home/readme-demo/build" "$dir/state"
chmod 700 "$dir/state"
dir=$(cd "$dir" && pwd -P)

# The sample documents are three lines each, so the program counts four
# elements after splitting on a trailing newline.
for doc in durability multiplayer code-mode; do
	printf '# %s\nSample document.\nFour lines.\n' "$doc" >"$dir/home/readme-demo/$doc.md"
done

# The TUI looks for the seed at <workspace>/build/codemode-seed.
ln -s "$root/build/codemode-seed" "$dir/home/readme-demo/build/codemode-seed"

cat >"$dir/state/loom.toml" <<EOF
[models.scripted-demo]
dialect = "anthropic"
base_url = "http://127.0.0.1:$port"
api_key_env = "CAPTURE_KEY"
model_id = "scripted-demo"
context_window = 200000
max_output_tokens = 8000

[roles]
main = ["scripted-demo"]
EOF

python3 "$here/fake_anthropic.py" "$port" >"$dir/fake.log" 2>&1 &
echo $! >"$dir/fake.pid"

tmux -L "$sock" new-session -d -x 116 -y "$rows" -c "$dir/home" \
	"env HOME=$dir/home CAPTURE_KEY=scripted $root/bin/loom --workspace $dir/home/readme-demo --state-dir $dir/state --config $dir/state/loom.toml 2>$dir/loom.err"

pane() { tmux -L "$sock" capture-pane -p -t 0; }
wait_for() {
	local pattern=$1 _
	for _ in $(seq 1 100); do
		pane | grep -q -- "$pattern" && return 0
		sleep 0.3
	done
	echo "capture.sh: timed out waiting for '$pattern'" >&2
	pane >&2
	return 1
}

# The first screen is the session picker; `n` creates the session.
wait_for "No saved sessions"
tmux -L "$sock" send-keys -t 0 n
wait_for "code mode enabled"
tmux -L "$sock" send-keys -t 0 -l "$prompt"
tmux -L "$sock" send-keys -t 0 Enter
wait_for "stayed out of the conversation"

# Expand the tool details and let the redraw settle before capturing.
tmux -L "$sock" send-keys -t 0 C-g
wait_for "details expanded"
sleep 1
tmux -L "$sock" capture-pane -e -p -t 0 >"$dir/frame.ansi"

python3 "$root/docs/design-notes/tui-agent-workspace/render_capture.py" \
	"$dir/frame.ansi" "$out" dark
echo "wrote $out"
