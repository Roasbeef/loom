# Dockerfile: the linux/arm64 guest root filesystem for the microVM tier.
#
# `loom-vm run --root-dir DIR` boots a libkrun guest whose root is a host
# directory (ADR-022, D1: a VM holds a whole executor). This image is where
# that directory comes from: `make vmm-guest-root` builds it and exports the
# runtime stage's filesystem to packages/vmm/build/guest-root. The guest
# runs the self-contained server release (`loomd` with its bundled ERTS) and
# `loom-exec` unchanged, so the jail's layer tags stay true against the
# guest's own kernel.
#
# The build mirrors the root Dockerfile: the same `make install` a developer
# runs from a checkout (docs/distribution.md, "Installing from a checkout"),
# and the same toolchain versions (OTP, rebar3, Gleam, Go), which track
# .github/workflows/ci.yml and .github/actions/setup-toolchain/action.yml.
# What differs is the architecture. `make release` refuses to cross-compile
# because esqlite3_nif.so and the copied ERTS are native to the build host
# (docs/distribution.md, "Cross-compilation: there is none"), so this build
# runs natively on arm64, inside a Linux container.
#
# OTP source. The root Dockerfile fetches an OTP tarball from builds.hex.pm,
# which publishes no arm64 build at that path. This image starts from the
# official multi-arch erlang image instead, which carries exactly OTP 29.0.5
# for linux/arm64 and saves compiling OTP from source. That image is Debian
# trixie, so the runtime stage is debian:trixie-slim too: the release
# bundles an ERTS built against trixie's glibc and libcrypto, and the
# runtime must provide a glibc and libcrypto at least as new.
#
# Build from the repository root:
#
#   podman build -f packages/vmm/guest/Dockerfile .

# ------------------------------------------------------------- build stage
FROM docker.io/library/erlang:29.0.5 AS build

ARG REBAR3_VERSION=3.27.0
ARG GLEAM_VERSION=1.19.0
ARG GO_VERSION=1.26.3

ENV DEBIAN_FRONTEND=noninteractive

# The erlang image is built on buildpack-deps, which already carries the C
# toolchain, git, curl and libssl-dev that esqlite's NIF and Gleam need. The
# list is repeated so that this stage does not depend on that detail.
# python3 drives scripts/with_timeout.py; strip (binutils) shrinks the copied
# ERTS.
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

# The erlang image ships a rebar3, but not necessarily the pinned version.
RUN curl -fsSL -o /usr/local/bin/rebar3 \
		"https://github.com/erlang/rebar3/releases/download/${REBAR3_VERSION}/rebar3" \
	&& chmod +x /usr/local/bin/rebar3 \
	&& rebar3 --version \
	&& erl -noinput -noshell -eval 'io:format("OTP ~s~n",[erlang:system_info(otp_release)]), halt().'

# --- Gleam, built from source with the same patches CI applies ----------
# See scripts/toolchain/gleam/README.md and the root Dockerfile. The Rust
# toolchain is needed only for this step and its caches are removed after.
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
ENV PATH="/root/.cargo/bin:${PATH}"
COPY scripts/toolchain/gleam/ /opt/loom-gleam-patches/
RUN set -eux; \
	src=/tmp/gleam-src; \
	rm -rf "$src"; mkdir -p "$src"; \
	git -C "$src" init -q; \
	git -C "$src" remote add origin https://github.com/gleam-lang/gleam; \
	git -C "$src" fetch --depth 1 origin "refs/tags/v${GLEAM_VERSION}"; \
	git -C "$src" checkout -q FETCH_HEAD; \
	for patch in /opt/loom-gleam-patches/*.patch; do \
		git -C "$src" apply "$patch"; \
	done; \
	(cd "$src/gleam-bin" && cargo build --locked --release); \
	cp "$src/target/release/gleam" /usr/local/bin/gleam; \
	chmod +x /usr/local/bin/gleam; \
	rm -rf "$src" /root/.cargo/registry /root/.cargo/git; \
	gleam --version; \
	python3 /opt/loom-gleam-patches/check_cache.py --runs 4; \
	python3 /opt/loom-gleam-patches/check_native_git.py

# --- Go ------------------------------------------------------------------
RUN curl -fsSL -o /tmp/go.tar.gz \
		"https://go.dev/dl/go${GO_VERSION}.linux-arm64.tar.gz" \
	&& tar -C /usr/local -xzf /tmp/go.tar.gz \
	&& rm /tmp/go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}"
RUN go version

WORKDIR /work
COPY . .

# The same installation the root Dockerfile performs. The module caches are
# BuildKit cache mounts so that resolving them from cold, which trips Hex's
# rate limit on a tree with this many path dependencies (issue #248), happens
# once per builder rather than once per build.
#
# DIST_VM=0 keeps `loom-vm`, the host-side launcher the release otherwise
# carries, out of the guest, which holds an executor and boots nothing.
RUN --mount=type=cache,target=/root/.cache/gleam \
	--mount=type=cache,target=/root/go/pkg/mod \
	--mount=type=cache,target=/root/.cache/go-build \
	DIST_VM=0 PREFIX=/opt/loom make install

# ----------------------------------------------------------- runtime stage
FROM docker.io/library/debian:trixie-slim AS runtime

ENV DEBIAN_FRONTEND=noninteractive

# bubblewrap is loom-exec's namespace and mount layer. sqlite3, ripgrep and
# git serve the tools a session runs; ca-certificates covers outbound TLS.
# iproute2 supplies `ip`, which the guest init uses to configure the
# network, because the hosted network stack serves no DHCP. libssl3t64 is
# the libcrypto the bundled ERTS's crypto NIF links against. util-linux, in
# the base image, provides setpriv and mountpoint, which the init uses.
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
		bubblewrap \
		sqlite3 \
		ripgrep \
		git \
		ca-certificates \
		iproute2 \
		libssl3t64 \
		zlib1g \
	&& rm -rf /var/lib/apt/lists/*

# The same non-root user the root Dockerfile creates. The init drops to it
# before running the workload; running as root would leave loom-exec's inner
# drop as the only boundary between a hostile program and the guest's root.
RUN useradd --create-home --uid 10000 --shell /bin/sh loom

COPY --from=build /opt/loom /opt/loom

# The installer publishes owner-private trees; root installs them here for
# the unprivileged user, so the published roots must be traversable.
RUN chmod a+rx /opt/loom/lib/loom/server.* /opt/loom/lib/loom/client.*
ENV PATH="/opt/loom/bin:${PATH}"

# install.sh keeps loom-exec inside the release tree, where the server finds
# it beside its own binary. A symlink on PATH lets the guest's checks run
# `loom-exec --self-test` by name.
RUN ln -s /opt/loom/lib/loom/server/bin/loom-exec /opt/loom/bin/loom-exec

RUN mkdir -p /var/lib/loom /work && chown loom:loom /var/lib/loom /work

COPY packages/vmm/guest/loom-guest-init /usr/local/sbin/loom-guest-init
COPY packages/vmm/guest/loom-guest-executor /usr/local/sbin/loom-guest-executor
RUN chmod 0755 /usr/local/sbin/loom-guest-init /usr/local/sbin/loom-guest-executor

WORKDIR /work

# The identity of the image, read back by `loom-vm setup`. The guest holds an
# exact-revision executor, and the orchestrator that talks to it must be the
# same build (docs/distribution.md), so setup reads `revision` to record which
# loom commit these bytes came from and `version` to refuse an image pulled
# under a tag it was not built for. The labels sit at the end of the stage
# because the arguments change on every commit and would otherwise invalidate
# the layers above them.
ARG LOOM_REVISION=unknown
ARG LOOM_VERSION=dev
LABEL org.opencontainers.image.source="https://github.com/roasbeef/loom" \
	org.opencontainers.image.revision="${LOOM_REVISION}" \
	org.opencontainers.image.version="${LOOM_VERSION}"
