# protocol-change/020 — a minimal jail root

**Status**: PROPOSED 2026-09-08 · **Affects**: the helper's base view (not a
Part 1 interface; the wire vocabulary this needs is
[`protocol-change/004`](004-sandbox-policy-explicit-mounts.md)) ·
**Raised by**: issue #242 (per-session filesystem confinement) ·
**Implemented**: no

## Problem

The helper binds the whole host filesystem read-only as the least specific
grant: `grant(readableOp("/"))` at
`packages/sandbox/internal/jail/bwrap.go:230`, and the session base names the
same thing again with `readable_roots: ["/"]`
(`packages/client/src/client/serve.gleam:4358`). On Darwin the profile carries
an unconditional `(allow file-read*)`
(`packages/sandbox/internal/jail/seatbelt.go:33`), so reads are not restricted
at all.

Under one shared daemon that is now the boundary that matters. A model in
session A can read every other workspace on the account, every other session's
scratch, and every dotfile the user owns, including `~/.ssh` and `~/.aws`.
What confines the daemon's own credentials today is `protected` masking, which
is a denylist: it covers the paths the harness thought to name, and it cannot
cover the ones it does not know about. Issue #242's point 1 asks for the other
shape, an allowlist, and that is what this proposes.

004 changed no behaviour on its own, and said so: under `--ro-bind / /` an
explicit mount renders argv that grants what was already granted. 004 exists so
that a narrowed base view *refuses* a missing dependency by name instead of
producing a satellite that never connects. This proposal is the narrowing.

## Proposal

Replace the base view with `--tmpfs /` plus explicit read-only binds. Every
path class below is derived from a value the harness already holds. No
host-wide configuration file appears anywhere in the list.

**Already emitted.** `/proc` and `/dev` (`bwrap.go:254`, `bwrap.go:255`) and
the scratch tmpfs at `/tmp` (`bwrap.go:45`).

**System roots, a per-OS constant in the helper.** On Linux `/usr`, `/bin`,
`/sbin`, `/lib`, `/lib64`, `/etc`, each with the tolerant `--ro-bind-try` form
(`readableRootOp`, `bwrap.go:313`) so that merged-usr and non-merged
distributions are one code path. On Darwin `/System`, `/usr`, `/bin`, `/sbin`,
`/Library`, `/private/etc`, plus both Homebrew prefixes, `/opt/homebrew` and
`/usr/local`.

**The toolchain, from `Toolchain`.** `Toolchain(gleam_path, erl_path,
seed_root)` (`packages/client/src/client/codemode.gleam:781`) is discovered at
boot by `discover` (`codemode.gleam:826`), so the paths are values, not
configuration. The binary is not enough: `erl` resolves an ERTS `ROOTDIR` and
loads an install tree, and `toolchain_path` (`codemode.gleam:910`) only ever
needed the containing directory because the whole host was bound. The mount is
the install prefix, derived by canonicalizing the resolved binary and taking the
parent of its `bin/`. `go` is mounted the same way when present. That derivation
is a heuristic, so each toolchain mount is `MountRequired`: a wrong prefix
refuses the dispatch by name instead of producing an `erl` that fails to boot.

**The seed root**, read-only: `Toolchain.seed_root`, located by
`--codemode-seed` or beside a release at `install.seed()`
(`packages/client/src/client/install.gleam:164`).

**The workspace**, read-write, from the admission record. The cap socket and
the cap token need no separate entry: both are already inside it.
`work_root` is `workspace <> "/" <> work_directory` (`codemode.gleam:752`),
`blob_root` is under the same workspace (`codemode.gleam:758`), and
`socket_path` is `<root> <> "/s"` (`codemode.gleam:1548`). The explicit mounts
state that rather than rescue it.

**Out-of-workspace git directories**, from `widening_linked_worktree`
(`serve.gleam:3499`), which already derives them by reading the workspace's own
`.git`. **The tool tmpdir** grant stays as it is
(`allowing_tool_tmpdir`, `serve.gleam:3574`).

`node_requirements` (`packages/codemode/src/codemode/launch.gleam:941`) today
asks for three roots: the socket directory, the token directory and the
artifact `beam_dir`. The toolchain and the seed are absent. That omission is
exactly the silent break 004 predicted, and the launcher must state them before
the base view moves.

### The default readable set under `$HOME`

Baseline behaviour must work with no configuration edits. A new user gets what
Claude Code or Codex give by default; they do not edit a config to run an
ordinary build. So the narrowing ships with a fixed list of well-known per-user
toolchain and cache roots, bound when present, `MountOptional`:

`.cargo`, `.rustup`, `go` and `go/pkg`, `.nvm`, `.npm`, `.pnpm`, `.yarn`,
`.cache` (which covers gleam, hex, pip, go-build and uv), `.hex`, `.mix`,
`.local/share` and `.local/bin`, `.asdf`, `.pyenv`, `.rbenv`, `.gem`, `.m2`,
`.gradle`, `.opam`, `.ghcup`, `.cabal`, `.stack`, `.deno`, `.bun`, `.sdkman`,
`.nix-profile` with `/nix/store`, the Homebrew prefixes, and the shim
directories the version managers put on `PATH`.

**Read-only is not enough for some of these.** A Go build writes
`~/.cache/go-build`, cargo writes `~/.cargo/registry`, npm writes `~/.npm`,
gleam and rebar write under `~/.cache` and `~/.hex`. Bound read-only, an
ordinary build fails. The ruling is that the cache subset is granted
**read-write**: `.cache`, `.cargo/registry`, `.npm`, `.pnpm`, `.yarn`, `.hex`,
`.mix`, `.m2`, `.gradle`, `.gem`, `.stack`, `.cabal`, `.deno`, `.bun`. The
remainder (installed toolchains, shims, `/nix/store`) stays read-only.

A per-session overlay over those caches was considered and rejected for now. It
would make one session's writes invisible to another, which is the stronger
property, but it costs an overlay per session on Linux, has no Seatbelt
equivalent on Darwin, and defeats the caches it copies: a cold cargo registry
per session is minutes of network per build. The cost of the read-write grant
is stated plainly: a hostile payload can poison a shared build cache, which is
a real attack and is not closed here. It is closed later by a per-session
overlay, or by the caches moving under the workspace, and it is worth an issue
of its own rather than a config knob nobody sets.

**Not in the default**, and readable only through a configuration line:
`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.netrc`, `~/.config` except the named
subdirectories a toolchain owns, browser profiles, and every other checkout on
the account.

The daemon's own secrets stay masked as a second layer regardless. PR #319
declared that mask as the required self-test probe `daemon state root
unreachable from a session jail` and extended it to the extension install's
build plane. Masking survives a state root placed inside a workspace, which
omission from a minimal root does not, so both layers stay.

### Sibling checkouts

Derived first, configured second. A `path = "../weft"` line in `gleam.toml` is
the same shape as a linked worktree's git directory, so it is handled the same
way: read the manifest, canonicalize the path dependencies, mount them
read-only. The equivalents in other ecosystems are `go.work` and `replace`
directives, `Cargo.toml` `path =`, and npm `file:` specifiers.

For what no manifest describes, a `[workspace] mounts` list in the launch
configuration, admitted into the session's base policy. Read-write comes only
from that line. Loom's own intra-repo path dependencies are inside the
workspace already, and `weft` is a hex dependency today, so nothing fires until
weft development switches those lines.

### Enforcement

One new probe, `host path outside the mount plan unreadable`, built like the
existing probes in `packages/sandbox/internal/selftest/selftest.go`, with the
unmasked control pattern from #320: the probe fails if its own control read,
inside the plan, does not succeed, so a jail that refuses everything cannot
read as a pass. The `.github/enforcement-expectations` line is `required` on
Linux when the narrowing lands.

On Darwin it is `required` only once `(allow file-read*)`
(`seatbelt.go:33`) is replaced by per-root `(allow file-read* (subpath (param
...)))` under the existing deny-default. Whether SBPL subpath read allows behave
that way on current macOS is an empirical question: `sandbox-exec` is
undocumented, and ADR-006 claims only what stage 2 witnesses. If the probe
cannot be made to pass, the line is
`known-gap|host path outside the mount plan unreadable|Seatbelt profile grants unconditional file-read*`,
with a filed issue and an addendum inside ADR-006. It is never deleted.

### Rollout

The narrowing lands **all at once, behind no feature negotiation**. A helper
feature flag read in `hello` was considered and rejected: the harness and the
helper ship from one tree, the policy version bump to `v: 2` already makes an
older helper refuse the frame rather than widen silently, and a negotiated
flag would add a second widening path that nothing exercises. A helper without
the narrowing cannot decode a v2 policy at all, which is the degraded report
the flag was meant to provide.

Before the default flips: `make e2e-codemode` green against a real toolchain
and a real satellite, `make selftest` reporting the new probe enforced on
Linux, and the shipped bootstrap fixtures green under
`LOOM_BOOTSTRAP_E2E_SERVER`, which is where an ordinary jailed `bash` tool
running `git` and a build is actually exercised.

## Impact and cost

The enumeration is a list somebody has to maintain, and a toolchain missing
from it is a build that fails inside a jail. Two things keep that honest.
`MountRequired` makes a missing source refuse the execution **naming the path**,
so the failure is a sentence rather than a mystery; and the follow-up is a
`loom doctor`-style report that prints the composed mount plan for a session,
so an operator can see what the jail will contain before running anything. The
optional per-user entries never refuse; they are simply absent, which is the
right behaviour for a cache root the account does not have.

Two files in this directory are numbered 019
(`019-session-display-names.md` and `019-sessions-delete.md`). Both are merged,
so the collision is recorded rather than repaired; 020 is the next free number.

## Decision

Proposed. The alternative, keeping `--ro-bind / /` and extending `protected`
until it covers the interesting paths, is what the tree does today and it
cannot be finished: a denylist over a shared account has no closing condition,
and every new dotfile is a hole nobody filed.
