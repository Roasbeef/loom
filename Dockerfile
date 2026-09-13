# Dockerfile — a runnable image for loomd, the Loom multi-session daemon.
#
# Two stages. The build stage installs the same toolchain
# scripts/signoff/Dockerfile (branch build/signoff-container) installs for
# the test signoff — Ubuntu 24.04, OTP 29, Gleam 1.18.1 built from source
# with the CI patch for issue #248, Go, the C toolchain esqlite3_nif.so
# needs — and runs `make codemode-seed` and `make install` the same way a
# developer building from source would (docs/distribution.md,
# "Installing from a checkout"). The runtime stage starts over from a slim
# Ubuntu base and copies in only the installed tree: `make release-smoke`
# is the proof that the release needs no Erlang, no Gleam and no Go once
# built, so the runtime stage installs none of them.
#
# What this image does not solve: issue #384 measured that a default
# `docker run` withholds unprivileged user namespaces and a writable,
# delegated cgroup v2 base, so loom-exec's self-test enforces fewer of its
# nine probes there than on a bare host. This image does not paper over
# that with a fabricated "container mode" — it ships the same helper the
# release always ships and reports what the kernel actually gives it.
# docs/docker.md documents both postures and the traded-off boundary that
# comes with the flags that close the gap.
#
# Versions below track the same four files scripts/signoff/Dockerfile
# tracks: .github/workflows/ci.yml (GLEAM_PATCHES) and
# .github/actions/setup-toolchain/action.yml (OTP_VERSION, REBAR3_VERSION,
# GLEAM_VERSION, GO_VERSION). A bump to any of those is a deliberate edit
# here, not something a `latest`-tagged base image would discover on its
# own.
#
# Both stages pin --platform=linux/amd64. `make release` refuses a
# GOOS/GOARCH that is not the build host (docs/distribution.md,
# "Cross-compilation: there is none") because `esqlite3_nif.so` and the
# copied ERTS are both native to it, and the OTP tarball this Dockerfile
# fetches is the ubuntu-24.04 x86_64 build builds.hex.pm publishes — there
# is no arm64 counterpart at that path. Pinning the platform makes the
# image buildable on an arm64 workstation through emulation rather than
# silently producing a release for whatever architecture happened to run
# `docker build`, which would fail this same way inside the build stage
# but later and less clearly.

# ------------------------------------------------------------- build stage
FROM --platform=linux/amd64 ubuntu:24.04 AS build

ARG OTP_VERSION=29.0.5
ARG REBAR3_VERSION=3.27.0
ARG GLEAM_VERSION=1.18.1
ARG GLEAM_PATCHES=860f8224ddb7e1ecb7f983fb622ede12466225e5
ARG GO_VERSION=1.26.3

ENV DEBIAN_FRONTEND=noninteractive

# build-essential, pkg-config and libssl-dev build esqlite's C NIF
# (ADR-002) and Gleam itself below; strip is what scripts/release.sh uses
# to shrink the copied ERTS and the bundled gleam; git and ca-certificates
# are what `make codemode-seed` needs for its one allowed network step.
# python3 drives scripts/with_timeout.py, which release-smoke's watchdog
# uses; the image does not run release-smoke itself (that needs `erl` and
# `gleam` off PATH, which this build stage never satisfies), but `make
# check`-style local debugging inside the build stage benefits from it
# being present.
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
		build-essential \
		pkg-config \
		libssl-dev \
		python3 \
		git \
		ca-certificates \
		curl \
		xz-utils \
	&& rm -rf /var/lib/apt/lists/*

# --- Erlang/OTP + rebar3 ------------------------------------------------
# The same precompiled ubuntu-24.04 build from builds.hex.pm that
# erlef/setup-beam installs in CI, so this stage runs the OTP CI actually
# runs rather than a distribution package at whatever version Ubuntu
# ships.
RUN curl -fsSL -o /tmp/otp.tar.gz \
		"https://builds.hex.pm/builds/otp/ubuntu-24.04/OTP-${OTP_VERSION}.tar.gz" \
	&& mkdir -p /usr/local/otp \
	&& tar -xzf /tmp/otp.tar.gz -C /usr/local/otp --strip-components=1 \
	&& rm /tmp/otp.tar.gz \
	&& (cd /usr/local/otp && ./Install -minimal /usr/local/otp) \
	&& for f in /usr/local/otp/bin/*; do ln -sf "$f" "/usr/local/bin/$(basename "$f")"; done \
	&& erl -noinput -noshell -eval 'io:format("~s~n",[erlang:system_info(otp_release)]), halt().'
RUN curl -fsSL -o /usr/local/bin/rebar3 \
		"https://github.com/erlang/rebar3/releases/download/${REBAR3_VERSION}/rebar3" \
	&& chmod +x /usr/local/bin/rebar3 \
	&& rebar3 --version

# --- Gleam, built from source with the same patch CI applies ------------
# Mirrors .github/actions/setup-toolchain/action.yml's "Build Gleam ...
# from source" step: the released 1.18.1 binary silently heals a stale
# manifest.toml path-dependency line that a tree with many path
# dependencies needs re-checked against Hex on every invocation
# (issue #248, gleam-lang/gleam#6244); GLEAM_PATCHES cherry-picks the
# upstream fix (#6246) onto the release tag. A Rust toolchain is needed
# only for this step and is removed once gleam is built.
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
ENV PATH="/root/.cargo/bin:${PATH}"
RUN set -eux; \
	src=/tmp/gleam-src; \
	rm -rf "$src"; mkdir -p "$src"; \
	git -C "$src" init -q; \
	git -C "$src" remote add origin https://github.com/gleam-lang/gleam; \
	git -C "$src" fetch --depth 1 origin "refs/tags/v${GLEAM_VERSION}"; \
	git -C "$src" checkout -q FETCH_HEAD; \
	for patch in ${GLEAM_PATCHES}; do \
		git -C "$src" fetch --depth 2 origin "$patch"; \
		git -C "$src" -c user.name=docker-image -c user.email=docker-image@localhost \
			cherry-pick -X ours "$patch"; \
	done; \
	(cd "$src/gleam-bin" && cargo build --release); \
	cp "$src/target/release/gleam" /usr/local/bin/gleam; \
	chmod +x /usr/local/bin/gleam; \
	rm -rf "$src" /root/.cargo/registry /root/.cargo/git; \
	gleam --version

# --- Go ------------------------------------------------------------------
RUN curl -fsSL -o /tmp/go.tar.gz \
		"https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
	&& tar -C /usr/local -xzf /tmp/go.tar.gz \
	&& rm /tmp/go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}"
RUN go version

WORKDIR /work
COPY . .

# The Hex/gleam package cache and the Go module cache are BuildKit cache
# mounts rather than baked into a layer: resolving either from cold trips
# Hex's per-address rate limit within minutes on a tree with this many
# path dependencies (issue #248), the way the first parallel `make
# signoff` run did, and a cache mount survives across image rebuilds on
# the same builder without appearing in the final image. `make
# codemode-seed` is the one step this build allows the network for;
# `make install` (codemode-seed release release-client) does not reach it
# again. PREFIX puts the installed tree at a fixed, known path the
# runtime stage copies whole.
RUN --mount=type=cache,target=/root/.cache/gleam \
	--mount=type=cache,target=/root/go/pkg/mod \
	--mount=type=cache,target=/root/.cache/go-build \
	PREFIX=/opt/loom make install

# ----------------------------------------------------------- runtime stage
# ubuntu:24.04, not a distroless or -slim base: the sandbox helper's own
# jail (docs/architecture/effects.md) execs bubblewrap and reads
# /sys/fs/cgroup directly, and the full-isolation posture in docs/docker.md
# needs an AppArmor-aware userland to reproduce issue #384's 11-of-11
# measurement. ERTS travels inside /opt/loom/server (make release bundles
# it), so no Erlang, Gleam or Go is installed here.
FROM --platform=linux/amd64 ubuntu:24.04 AS runtime

# bubblewrap is loom-exec's own namespace-and-mount layer — without it the
# jail degrades to rlimits/pgroup only, which is exactly the posture
# docs/docker.md's "plain" run line documents rather than hides. sqlite3
# is the CLI the durability plane's own tooling shells out to; ripgrep
# backs the code-mode search tool; git lets a session's sandbox run git
# inside a workspace; ca-certificates is needed for the broker's outbound
# HTTPS egress path; tini is PID 1, reaping the daemon's own spawned
# children (the helper, code-mode satellites) on exit rather than leaving
# the container's init to do a job it does not do.
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
		bubblewrap \
		sqlite3 \
		ripgrep \
		git \
		ca-certificates \
		tini \
	&& rm -rf /var/lib/apt/lists/*

# A non-root user for the daemon and every process it directly spawns.
# loom-exec's own jail drops privileges further inside the sandbox
# regardless of the caller's uid; running the daemon itself as root would
# make that inner drop the only thing standing between a hostile program
# and this container's root, rather than a second, redundant layer.
RUN useradd --create-home --uid 10000 --shell /usr/sbin/nologin loom

COPY --from=build /opt/loom /opt/loom
ENV PATH="/opt/loom/bin:${PATH}"

# install.sh puts loom-exec inside the copied release tree
# (lib/loom/server/bin/loom-exec) rather than on $PREFIX/bin, since it is
# not a thing an operator runs directly in the normal case. It is exactly
# what `loom-exec --self-test` in docs/docker.md needs, so a symlink on
# PATH saves every reader of that doc from typing the full release path.
RUN ln -s /opt/loom/lib/loom/server/bin/loom-exec /opt/loom/bin/loom-exec

# The daemon's state directory: the durable catalogue, session databases,
# the owner token, and the discovery record a client reads to find an
# already-running daemon (docs/architecture/sessions.md,
# "Implemented shared endpoint boundary"). Declared as a VOLUME so an
# operator's own persistence choice — a named volume or a bind mount —
# survives a container replacement instead of being silently discarded
# with it. The token is never baked into the image: it is written under
# this directory by the daemon itself on first boot, so reaching it means
# reading the volume (owner.token) or running a client inside the same
# container, never an image layer or a build argument.
RUN mkdir -p /var/lib/loom /work && chown loom:loom /var/lib/loom /work
VOLUME ["/var/lib/loom"]

# The workspace a session's jail actually operates on. Bind-mounted by
# the operator at `docker run` time (`-v $PWD:/work`); the daemon itself
# takes no opinion on what lives here.
WORKDIR /work

# main.gleam's bind_address parser accepts only 127.0.0.1 or [::1] —
# loomd refuses to bind 0.0.0.0 (packages/client/src/client/daemon/main.gleam,
# `bind_address`). That is not a container-specific restriction lifted for
# this image: it is a property of the daemon regardless of where it runs,
# and docs/docker.md explains what it means for how a client reaches this
# container (in short: `docker exec`, not a published port). EXPOSE
# documents the port; it is not itself the mechanism a published port
# would need.
EXPOSE 7331

USER loom

ENTRYPOINT ["tini", "--", "loomd"]
CMD ["--state-dir", "/var/lib/loom", "--bind", "127.0.0.1:7331"]
