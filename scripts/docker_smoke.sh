#!/usr/bin/env bash
# docker_smoke.sh — build the runtime image, run it in the plain posture,
# and prove a client can reach the daemon inside it.
#
# Usage: scripts/docker_smoke.sh [image-tag]
#
# This is the body of `make docker-smoke`, moved out of the Makefile so
# the exit code the caller sees is this script's own rather than a
# pipeline's last stage (docs/execution.md's warning about backgrounding
# `make ... ; echo $?` applies just as much to a shell pipeline here).
#
# What it proves, in order: the image builds; a container boots and the
# daemon becomes ready, observed by polling the discovery record under
# its own state directory rather than sleeping a fixed duration; a client
# run with `docker exec` lists sessions against the running daemon
# (`loom sessions list`, docs/architecture/sessions.md); and
# `loom-exec --self-test` runs inside the container and exits zero or
# reports only skips the plain posture is expected to leave (never a
# probe that should have enforced and did not). The container is always
# stopped, success or failure.
#
# This only exercises the plain posture — no docker run flags removing
# Docker's own confinement. docs/docker.md's full-isolation line and its
# measured self-test counts are recorded by hand against the machine they
# were run on, not by this script, because that machine's identity (the
# LOOM_SIGNOFF_HOST box, or a developer's own Linux host) is deliberately
# not something a checked-in script should assume it can reach.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
image="${1:-loom-runtime:dev}"
container="loom-docker-smoke-$$"

if ! command -v docker >/dev/null 2>&1; then
	echo "docker_smoke: no docker on PATH; skipping (this check needs Docker)" >&2
	exit 0
fi
if ! docker info >/dev/null 2>&1; then
	echo "docker_smoke: docker daemon not reachable; skipping (this check needs Docker)" >&2
	exit 0
fi

cleanup() {
	docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== building $image"
DOCKER_BUILDKIT=1 docker build -t "$image" "$root"

echo "== starting $container"
docker run -d --name "$container" \
	-v "$root:/work:ro" \
	"$image" >/dev/null

# The daemon writes its discovery record (docs/architecture/sessions.md,
# "Implemented shared endpoint boundary"; encoding in
# packages/host/src/host/endpoint.gleam) to daemon.endpoint under the
# state root only after its listener is actually accepting connections. A
# `status: "starting"` record with no `"ready"` status means not yet, and
# a missing file means not yet either. Polling that file is the event
# this waits on — no fixed sleep, and no assumption about how long a cold
# start takes on the machine running this script.
echo "== waiting for the daemon to become ready"
ready=0
for _ in $(seq 1 60); do
	if docker exec "$container" sh -c \
		'test -f /var/lib/loom/daemon.endpoint && grep -q "\"ready\"" /var/lib/loom/daemon.endpoint' \
		2>/dev/null; then
		ready=1
		break
	fi
	if ! docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -q true; then
		echo "docker_smoke: container exited before the daemon became ready" >&2
		docker logs "$container" >&2 || true
		exit 1
	fi
	sleep 1
done
if [ "$ready" != 1 ]; then
	echo "docker_smoke: daemon did not become ready within 60s" >&2
	docker logs "$container" >&2 || true
	exit 1
fi

echo "== loom sessions list"
docker exec "$container" loom sessions list --state-dir /var/lib/loom

echo "== loom-exec --self-test"
# The plain posture withholds unprivileged user namespaces and a
# writable, delegated cgroup v2 base (issue #384), so a probe needing
# either legitimately prints SKIPPED rather than ENFORCED. What must
# never happen is a nonzero exit for a reason other than that; --self-test
# itself exits nonzero only when a probe whose layer *is* available fails
# to enforce, so trusting its exit code here is exactly right rather than
# a shortcut.
docker exec "$container" loom-exec --self-test

echo "== docker_smoke: ok ($image)"
