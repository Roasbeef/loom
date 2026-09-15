# scripts/signoff/Dockerfile — the toolchain a containerised signoff runs
# against, built to match .github/actions/setup-toolchain/action.yml
# exactly rather than to whatever the base image happens to carry.
#
# Why this exists. `make signoff-remote` used to clone once into
# ~/loom-signoff and re-fetch for every run, so anything a run left behind
# — a shipment directory, a stale build/ tree — was inherited by the next
# run and could make its prep step refuse to overwrite what was there
# (PR #378, 2026-09-13). This image carries only the toolchain; the
# working tree is a fresh clone made fresh for every container (see
# scripts/signoff_remote.sh), so there is nothing left in the checkout for
# a later run to trip over. What *does* persist on purpose is named
# below, and it is exactly two things: the Hex/gleam package cache and
# the Go module cache, both mounted from named Docker volumes, because
# resolving either from cold on every run trips Hex's per-address rate
# limit (issue #248) inside minutes, the way the very first parallel
# `make signoff` run did.
#
# Versions are read out of .github/workflows/ci.yml and
# .github/actions/setup-toolchain/action.yml, not guessed: this file
# tracks GLEAM_VERSION, GLEAM_PATCHES, OTP_VERSION, REBAR3_VERSION and
# GO_VERSION from there, and a bump to any of those is a deliberate edit
# here, not something this build discovers on its own the way a
# `latest`-tagged base image would.
#
# The base image is ubuntu:24.04, matching runs-on: ubuntu-24.04 in
# ci.yml — the jail job whose enforcement-expectations this container is
# held to. The remote box itself runs Ubuntu 22.04 (kernel 5.15); only
# the kernel crosses that boundary; the toolchain's userland is CI's, not
# the host's, which is the whole point of building an image instead of
# reusing what happens to be installed on the box.
FROM ubuntu:24.04

# GLEAM_PATCHES pins gleam-lang/gleam#6246's fix for issue #248 (path
# dependencies re-resolving through the Hex API on every invocation),
# cherry-picked onto the GLEAM_VERSION tag; see ci.yml's own comment for
# why the released compiler cannot be substituted here. The released
# 1.18.1 binary silently heals a stale path-dependency line in
# manifest.toml that this patched build refuses to touch — which is
# exactly what turned PR #378's manifest drift into a red run instead of
# a quiet no-op, and exactly why this image builds the compiler from
# source rather than installing the release tarball.
ARG OTP_VERSION=29.0.5
ARG REBAR3_VERSION=3.27.0
ARG GLEAM_VERSION=1.18.1
ARG GLEAM_PATCHES=860f8224ddb7e1ecb7f983fb622ede12466225e5
ARG GO_VERSION=1.26.3

ENV DEBIAN_FRONTEND=noninteractive

# build-essential, pkg-config and libssl-dev are here for esqlite's C NIF
# (ADR-002, rebar3 needs a compiler on PATH to build it) and for Cargo
# building Gleam from source below. bubblewrap is the sandbox's own
# namespace-and-mount layer (packages/sandbox/CLAUDE.md: "bwrap owns all
# namespace and mount work"); sqlite3 is the CLI the storage package's
# tests shell out to; ripgrep backs the code-mode search tool; python3
# runs scripts/*.py and the scripts/ unittest suite; git, ca-certificates,
# curl and openssh-client are what a fresh clone and a Hex/GitHub fetch
# need. tmux is packages/client/test/support/terminal.gleam's own
# dependency for driving a real terminal — without it that suite
# declares a skip rather than failing, which is honest but would mean
# the container never actually proves what the bare host and the hosted
# jail both do.
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
		build-essential \
		pkg-config \
		libssl-dev \
		bubblewrap \
		sqlite3 \
		libsqlite3-dev \
		ripgrep \
		python3 \
		tmux \
		git \
		gnupg \
		ca-certificates \
		curl \
		openssh-client \
		locales \
		xz-utils \
	&& rm -rf /var/lib/apt/lists/* \
	&& locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# --- Erlang/OTP + rebar3 ----------------------------------------------
# erlef/setup-beam, the action ci.yml uses, installs OTP from precompiled
# builds published for ubuntu-24.04 at builds.hex.pm — the same tarball
# this step fetches directly, so the binary in the image is the one CI
# actually runs, not a distribution package at whatever version Ubuntu
# ships. rebar3 is erlang/rebar3's self-contained release escript.
# The tarball unpacks one level deep as OTP-<version>/, matching what
# builds.hex.pm serves for every published OS/arch combination. Its
# Install script patches the absolute paths baked into the generated
# scripts (erl, erlc, ...) to match wherever it is run from, so the
# tarball has to land at its own final location first — extracting to a
# staging directory and asking Install for a different destination
# leaves it looking for an erts tree relative to the wrong root, which
# is exactly the "Bad location" error a first version of this step hit.
RUN curl -fsSL -o /tmp/otp.tar.gz \
		"https://builds.hex.pm/builds/otp/ubuntu-24.04/OTP-${OTP_VERSION}.tar.gz" \
	&& mkdir -p /usr/local/otp \
	&& tar -xzf /tmp/otp.tar.gz -C /usr/local/otp --strip-components=1 \
	&& rm /tmp/otp.tar.gz \
	&& (cd /usr/local/otp && ./Install -minimal /usr/local/otp) \
	&& for f in /usr/local/otp/bin/*; do ln -sf "$f" "/usr/local/bin/$(basename "$f")"; done \
	&& erl -noshell -eval 'io:format("~s~n",[erlang:system_info(otp_release)]), halt().'
RUN curl -fsSL -o /usr/local/bin/rebar3 \
		"https://github.com/erlang/rebar3/releases/download/${REBAR3_VERSION}/rebar3" \
	&& chmod +x /usr/local/bin/rebar3 \
	&& rebar3 --version

# --- Gleam, built from source with the same patch CI applies -----------
# This mirrors .github/actions/setup-toolchain/action.yml's
# "Build Gleam ... from source" step line for line: clone the release
# tag at depth 1, cherry-pick each patch commit in order with -X ours (the
# only conflict in practice is CHANGELOG.md, whose unreleased-notes
# section neither CI nor a developer reads from), then build gleam-bin —
# the workspace member that produces the `gleam` executable — in release
# mode. A Rust toolchain is needed only for this step; it is not part of
# Loom's own build and nothing downstream of this layer depends on cargo
# or rustc being on PATH.
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
		git -C "$src" -c user.name=signoff-image -c user.email=signoff-image@localhost \
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

# The Hex and Go module caches are the two things scripts/signoff_remote.sh
# says are allowed to persist across runs, named here at fixed, mountable
# paths rather than left at whatever HOME resolves to, so the run script
# can bind each one to its own named Docker volume: GOMODCACHE for `go`
# (gleam's default of `$HOME/.cache/gleam`, i.e. /root/.cache/gleam since
# the container runs as root, is left alone and mounted directly rather
# than redirected). packages/*/manifest.toml checksums every Hex tarball,
# so a warm cache cannot serve different bytes than a cold download would
# — the same argument setup-toolchain's own comment makes for the CI
# cache. Everything else this build produces — build/, bin/,
# packages/tui/build/erlang-shipment, the code-mode seed — lives under
# the working tree a fresh clone provides and never under a path named
# here, so it cannot survive past the container's own lifetime.
ENV GOPATH=/var/cache/loom-signoff/go
ENV GOMODCACHE=/var/cache/loom-signoff/go/pkg/mod

WORKDIR /work
