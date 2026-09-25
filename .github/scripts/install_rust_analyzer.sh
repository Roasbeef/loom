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
#     fresh one is installed otherwise, from a pinned rustup-init checked
#     against its published SHA-256 rather than a script piped to sh.
#   - A pinned toolchain, 1.94.1. It is the version the lsp_rust profile
#     and the manager fixture were measured with (ADR-014 §7: the
#     readiness wait, the registry grant, the println! reference), as
#     gopls@v0.23.0 is pinned for the Go variants. `stable` would move
#     under both on the next release, and a rust-analyzer that answered
#     differently would read as a profile that broke. Moving it is a
#     deliberate change: bump the version and re-measure.
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

# The toolchain the language-server tests were measured with.
toolchain=1.94.1

# The rustup that installs it when the runner has none. 1.29.0 is the
# release current when this was pinned; the archive keeps every version at
# a fixed URL, with the SHA-256 beside it.
rustup_version=1.29.0

# The host's Rust target triple, from uname alone: there is no rustc to
# ask yet. Only the hosts CI runs this on, and the developer machines it
# is likely to meet, are named; anything else stops here rather than
# guess.
host_triple() {
	case "$(uname -s)/$(uname -m)" in
	Linux/x86_64) echo x86_64-unknown-linux-gnu ;;
	Linux/aarch64 | Linux/arm64) echo aarch64-unknown-linux-gnu ;;
	Darwin/arm64) echo aarch64-apple-darwin ;;
	Darwin/x86_64) echo x86_64-apple-darwin ;;
	*)
		echo "install_rust_analyzer.sh: no rustup-init for $(uname -s)/$(uname -m)" >&2
		return 1
		;;
	esac
}

sha256_of() {
	if command -v sha256sum >/dev/null; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

# Downloads the pinned rustup-init and its published digest, refuses a
# binary that does not match, and runs it with no toolchain: the pinned
# one is installed below, the same way as on a runner that had rustup.
install_rustup() {
	local triple url expected actual
	triple="$(host_triple)"
	url="https://static.rust-lang.org/rustup/archive/$rustup_version/$triple/rustup-init"
	work="$(mktemp -d)"
	trap 'rm -rf "$work"' EXIT
	curl --proto '=https' --tlsv1.2 -sSfL -o "$work/rustup-init" "$url"
	curl --proto '=https' --tlsv1.2 -sSfL -o "$work/rustup-init.sha256" "$url.sha256"
	expected="$(cut -d' ' -f1 "$work/rustup-init.sha256")"
	actual="$(sha256_of "$work/rustup-init")"
	if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
		echo "install_rustup: rustup-init $rustup_version for $triple has SHA-256 $actual, published $expected" >&2
		return 1
	fi
	chmod +x "$work/rustup-init"
	"$work/rustup-init" -y --no-modify-path --profile minimal --default-toolchain none
}

export RUSTUP_HOME="$HOME/.rustup" CARGO_HOME="$HOME/.cargo"
if [ ! -x "$CARGO_HOME/bin/rustup" ]; then
	install_rustup
fi
export PATH="$CARGO_HOME/bin:$PATH"
if [ -n "${GITHUB_ENV:-}" ]; then
	echo "RUSTUP_HOME=$RUSTUP_HOME" >>"$GITHUB_ENV"
	echo "CARGO_HOME=$CARGO_HOME" >>"$GITHUB_ENV"
fi
if [ -n "${GITHUB_PATH:-}" ]; then
	echo "$CARGO_HOME/bin" >>"$GITHUB_PATH"
fi

# Installed with its components before it becomes the default, so the
# rust-analyzer link never points at a toolchain that lacks the component.
# --no-self-update because an install otherwise ends by updating rustup
# itself to whatever is newest, which would unpin the rustup-init above.
rustup toolchain install "$toolchain" --profile minimal --no-self-update \
	--component rust-analyzer --component rust-src
rustup default "$toolchain"
rustup component add rust-analyzer rust-src
RUSTC_BOOTSTRAP=1 cargo fetch \
	--target "$(rustc -vV | sed -n 's/^host: //p')" \
	--manifest-path "$(rustc --print sysroot)/lib/rustlib/src/rust/library/Cargo.toml"
rust-analyzer --version
test -d "$(rustc --print sysroot)/lib/rustlib/src/rust/library"
