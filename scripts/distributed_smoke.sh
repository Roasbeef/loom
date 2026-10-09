#!/usr/bin/env bash
# distributed_smoke.sh: bring up the docker/distributed/compose.yaml pair and
# check that both containers run a TLS distribution node.
#
# Usage: scripts/distributed_smoke.sh [image-tag]
#
# This is the body of `make docker-distributed-smoke`. In order it:
#
#   1. skips, visibly and with exit 0, when Docker is missing or unreachable,
#      or when the image is absent on an arm64 host (the image is amd64 only,
#      and building it under emulation crashes the BEAM, docs/docker.md);
#   2. mints a throwaway orchestrator/executor pair with openssl
#      (scripts/distributed/mint-fixture.sh), so it needs neither the
#      provision command nor any credential;
#   3. starts the pair under a compose project of its own, waits for both
#      daemons to report ready, and requires epmd in each container to list
#      the node, which only happens when the VM booted with TLS distribution
#      and the daemon accepted the [distribution] table;
#   4. looks for an established distribution connection between them. The
#      daemon does not connect at boot until the executor role lands, so this
#      only fails the run when DISTRIBUTED_SMOKE_REQUIRE_CONNECTION=1;
#   5. removes only the compose project and the fixture directory it created.
#
# It never touches a container, volume or network it did not start.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
image="${1:-loom-runtime:dev}"
project="loom-dist-smoke-$$"
compose_file="$root/docker/distributed/compose.yaml"
fixture="$root/build/distributed-smoke-$$"
port=9100

skip() {
	echo "distributed_smoke: SKIPPED: $1" >&2
	exit 0
}

command -v docker >/dev/null 2>&1 || skip "no docker on PATH"
docker info >/dev/null 2>&1 || skip "docker daemon not reachable"
docker compose version >/dev/null 2>&1 || skip "docker compose plugin not available"

if ! docker image inspect "$image" >/dev/null 2>&1; then
	case "$(uname -m)" in
	arm64 | aarch64)
		skip "image $image is absent and cannot be built on an arm64 host (amd64 only; see docs/docker.md). Build it on a Linux x86_64 host, or load it, then rerun"
		;;
	esac
	echo "== building $image"
	DOCKER_BUILDKIT=1 docker build -t "$image" "$root"
fi

dc() {
	LOOM_IMAGE="$image" \
		ORCHESTRATOR_BUNDLE="$fixture/orchestrator" \
		EXECUTOR_BUNDLE="$fixture/executor" \
		LOOM_CLIENT_PORT=0 \
		docker compose -p "$project" -f "$compose_file" "$@"
}

cleanup() {
	status=$?
	if [ "$status" != 0 ]; then
		dc logs --no-color --tail 60 >&2 || true
	fi
	dc down -v --remove-orphans >/dev/null 2>&1 || true
	rm -rf "$fixture"
	exit "$status"
}
trap cleanup EXIT

echo "== minting a fixture pair"
mkdir -p "$root/build"
ORCH_LISTEN_PORT=$port EXEC_LISTEN_PORT=$port \
	"$root/scripts/distributed/mint-fixture.sh" "$fixture" \
	orchestrator@orchestrator.loom.internal /home/loom \
	executor@executor.loom.internal /home/loom \
	proj /work/project

echo "== starting $project"
dc up -d

echo "== waiting for both daemons to become ready"
for service in orchestrator executor; do
	ready=0
	for _ in $(seq 1 90); do
		cid=$(dc ps -q "$service")
		state=$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$cid")
		case "$state" in
		"running healthy") ready=1; break ;;
		exited* | dead*)
			echo "distributed_smoke: $service exited before it became ready" >&2
			exit 1
			;;
		esac
		sleep 1
	done
	if [ "$ready" != 1 ]; then
		echo "distributed_smoke: $service was not ready within 90s" >&2
		exit 1
	fi
	echo "   $service ready"
done

# epmd lists a node only when the VM runs distribution. A daemon that has the
# [distribution] table but was not booted for it exits at startup, so reaching
# ready already implies the boot flags worked; this check makes it visible.
epmd='/opt/loom/lib/loom/server/erts-*/bin/epmd'
echo "== epmd registrations"
for pair in orchestrator:orchestrator executor:executor; do
	service=${pair%%:*}
	node=${pair##*:}
	names=$(dc exec -T "$service" sh -c "$epmd -names")
	echo "$names" | sed "s/^/   $service: /"
	if ! echo "$names" | grep -q "^name $node at port $port"; then
		echo "distributed_smoke: $service does not list node $node on port $port" >&2
		exit 1
	fi
done

# An established connection to the distribution port, read from /proc because
# the image carries neither ss nor netstat. Hex 238C is port 9100.
echo "== distribution connection"
hex=$(printf '%04X' "$port")
connections=$(dc exec -T executor sh -c \
	"awk -v p=$hex 'NR>1 && \$4==\"01\" {split(\$2,a,\":\"); if (a[2]==p) n++} END{print n+0}' /proc/net/tcp")
if [ "$connections" -ge 1 ]; then
	echo "   orchestrator is connected to executor ($connections established)"
elif [ "${DISTRIBUTED_SMOKE_REQUIRE_CONNECTION:-0}" = 1 ]; then
	echo "distributed_smoke: no established distribution connection to the executor" >&2
	exit 1
else
	echo "   no connection yet (the daemon connects when the executor role is available; set DISTRIBUTED_SMOKE_REQUIRE_CONNECTION=1 to require it)"
fi

echo "== distributed_smoke: ok ($image)"
