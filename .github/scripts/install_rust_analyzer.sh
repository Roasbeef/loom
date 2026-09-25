#!/usr/bin/env bash
# install_rust_analyzer.sh — give a runner what the language-server tests'
# Rust variants need to run rather than skip: rust-analyzer, rust-src, and
# the standard library's own dependencies in the Cargo registry.
#
# Two jobs run such tests, and both call this so the two cannot drift: the
# jailed Linux lane (`make e2e` checks the first-party lsp_rust profile,
# ADR-014 §6) and the Linux client bucket (the language-server manager's
# live rust-analyzer fixture).
#
# Why each piece:
#
#   - rustup's default layout. The lsp_rust profile grants ~/.rustup and
#     ~/.cargo/registry, read-only, and the manager fixture runs
#     ~/.cargo/bin/rust-analyzer, so the toolchain has to be exactly there.
#     The runner's own rustup is used when it already lives there; a
#     fresh, minimal one is installed otherwise.
#   - rust-analyzer and rust-src. rustup puts a `rust-analyzer` link in
#     ~/.cargo/bin whether or not the component is installed, so the
#     component is what makes it run; rust-src is the standard library it
#     loads.
#   - The sysroot fetch. rust-analyzer resolves std as a Cargo workspace,
#     which needs std's dependencies (hashbrown, libc, ...) from the
#     registry. The jail has no network, so they are fetched here, once,
#     online; without them no call inside println! is ever found.
#     RUSTC_BOOTSTRAP=1 because std's manifest uses an unstable Cargo
#     feature a stable cargo otherwise refuses to parse, and --target
#     limits the fetch to the host, which is all rust-analyzer resolves.
#
# Exports RUSTUP_HOME, CARGO_HOME and the PATH entry to later steps through
# $GITHUB_ENV and $GITHUB_PATH when those are set.
set -euo pipefail

export RUSTUP_HOME="$HOME/.rustup" CARGO_HOME="$HOME/.cargo"
if [ ! -x "$CARGO_HOME/bin/rustup" ]; then
	curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs |
		sh -s -- -y --no-modify-path --profile minimal --default-toolchain none
fi
export PATH="$CARGO_HOME/bin:$PATH"
if [ -n "${GITHUB_ENV:-}" ]; then
	echo "RUSTUP_HOME=$RUSTUP_HOME" >>"$GITHUB_ENV"
	echo "CARGO_HOME=$CARGO_HOME" >>"$GITHUB_ENV"
fi
if [ -n "${GITHUB_PATH:-}" ]; then
	echo "$CARGO_HOME/bin" >>"$GITHUB_PATH"
fi

rustup default stable
rustup component add rust-analyzer rust-src
RUSTC_BOOTSTRAP=1 cargo fetch \
	--target "$(rustc -vV | sed -n 's/^host: //p')" \
	--manifest-path "$(rustc --print sysroot)/lib/rustlib/src/rust/library/Cargo.toml"
rust-analyzer --version
test -d "$(rustc --print sysroot)/lib/rustlib/src/rust/library"
