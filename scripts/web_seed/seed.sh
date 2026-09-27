#!/usr/bin/env bash
# seed.sh — a throwaway daemon whose session exercises the whole web view.
#
#   scripts/web_seed/seed.sh [DIR]     start it (default build/web_seed)
#   scripts/web_seed/seed.sh stop [DIR]
#
# It starts, all under DIR and with HOME pointed there too, so nothing of
# yours is read: a scripted Anthropic endpoint (fake_anthropic.py), a
# catalogue that routes main, subagent, advisor and summarize to it with
# prices, and `bin/loomd --ui` (build it with `make server-shipment`). It
# creates two sessions, "vetting lint" and "lint census", opens both, links
# census/main to vetting/main, and prints an operator's and an observer's
# page link for "vetting lint".
#
# Then, on the operator's page for "vetting lint":
#
# 1. Send "review the patch". Main reasons, spawns a reviewer (sub-agent
#    chip, spawn row), writes two notes (approve them if the policy asks),
#    waits on the reviewer (result card), and streams a long answer. The
#    advisor reviews the run and its nudge is delivered (advisor row).
# 2. Run `scripts/web_seed/seed.sh peer [DIR]` to send a message from
#    "lint census" (peer card, stored).
# 3. Wait more than a minute, then send "after the break": main reads its
#    prefix again (cache-miss row; the rings show an idle age or a TTL).
#
# The scripted endpoint answers by role and by what the last message says;
# see fake_anthropic.py.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)

action=start
case "${1-}" in
stop | peer)
	action=$1
	shift
	;;
esac
dir=$(mkdir -p "${1:-$root/build/web_seed}" && cd "${1:-$root/build/web_seed}" && pwd)
state="$dir/state"
fake_port=${WEB_SEED_FAKE_PORT:-18744}
port=${WEB_SEED_PORT:-18745}

stop() {
	for pidfile in "$dir"/*.pid; do
		[ -f "$pidfile" ] || continue
		kill "$(cat "$pidfile")" 2>/dev/null || true
		rm -f "$pidfile"
	done
}

case $action in
stop)
	stop
	echo "stopped"
	exit 0
	;;
peer)
	vetting=$(cat "$dir/vetting.id")
	census=$(cat "$dir/census.id")
	python3 "$here/control.py" "$state" "$port" send "$census" "$vetting" \
		"census-$(date +%s)" "R8 census is 14 on main; three in packages/tui."
	exit 0
	;;
esac

stop
mkdir -p "$state" "$dir/home" "$dir/workspace/src"
chmod 700 "$state"
printf 'pub fn main() { Nil }\n' >"$dir/workspace/src/a.gleam"
cat >"$state/loom.toml" <<EOF
[models.fake-main]
dialect = "anthropic"
base_url = "http://127.0.0.1:$fake_port"
api_key_env = "WEB_SEED_KEY"
model_id = "fake-main"
context_window = 200000
max_output_tokens = 8000
[models.fake-main.pricing]
input = 3.0
output = 15.0
cache_read = 0.3
cache_write = 3.75

[models.fake-sub]
dialect = "anthropic"
base_url = "http://127.0.0.1:$fake_port"
api_key_env = "WEB_SEED_KEY"
model_id = "fake-sub"
context_window = 200000
max_output_tokens = 8000

[models.fake-advisor]
dialect = "anthropic"
base_url = "http://127.0.0.1:$fake_port"
api_key_env = "WEB_SEED_KEY"
model_id = "fake-advisor"
context_window = 200000
max_output_tokens = 8000

[models.fake-summarize]
dialect = "anthropic"
base_url = "http://127.0.0.1:$fake_port"
api_key_env = "WEB_SEED_KEY"
model_id = "fake-summarize"
context_window = 200000
max_output_tokens = 2000

[roles]
main = ["fake-main"]
subagent = ["fake-sub"]
advisor = ["fake-advisor"]
summarize = ["fake-summarize"]
EOF

python3 "$here/fake_anthropic.py" "$fake_port" >"$dir/fake.log" 2>&1 &
echo $! >"$dir/fake.pid"
HOME="$dir/home" WEB_SEED_KEY=scripted "$root/bin/loomd" --state-dir "$state" \
	--bind "127.0.0.1:$port" --config "$state/loom.toml" --ui --best-effort \
	>"$dir/loomd.log" 2>&1 &
echo $! >"$dir/loomd.pid"

for _ in $(seq 1 100); do
	[ -f "$state/owner.token" ] && python3 "$here/control.py" "$state" "$port" ui \
		00000000-0000-7000-8000-000000000000 observer >/dev/null 2>&1 && break
	grep -q '"daemon.listening"' "$dir/loomd.log" 2>/dev/null && break
	sleep 0.2
done

vetting=$(python3 "$here/control.py" "$state" "$port" create "vetting lint" "$dir/workspace")
census=$(python3 "$here/control.py" "$state" "$port" create "lint census" "$dir/workspace")
echo "$vetting" >"$dir/vetting.id"
echo "$census" >"$dir/census.id"
python3 "$here/control.py" "$state" "$port" open "$vetting" >/dev/null
python3 "$here/control.py" "$state" "$port" open "$census" >/dev/null

# A link needs both sessions resident, which an open reports before it is
# finished; the daemon says `unavailable` until then.
for _ in $(seq 1 40); do
	python3 "$here/control.py" "$state" "$port" link "$census" "$vetting" \
		>/dev/null 2>&1 && break
	sleep 0.5
done

echo "vetting lint: $vetting"
echo "lint census:  $census"
echo "operator: http://127.0.0.1:$port$(python3 "$here/control.py" "$state" "$port" ui "$vetting" operator)"
echo "observer: http://127.0.0.1:$port$(python3 "$here/control.py" "$state" "$port" ui "$vetting" observer)"
