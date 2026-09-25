# protocol-change/050 — refuse a read-only mount over a writable root

**Status**: accepted for implementation at the owner's request, 2026-09-25 · **Affects**: Part 1.4 `SandboxPolicyV1`
(which documents are valid, not their shape) · **Raised by**: a
review of the language-server jail, which measured a mount of `/` produced
by `client/codemode.install_prefix` · **Implemented**: yes, broker + sandbox +
client

## Problem

[protocol-change/004](004-sandbox-policy-explicit-mounts.md) gave the policy
explicit `mounts` and stated their ordering as the property: every mount is
emitted after every grant, after the scratch tmpfs and after the protected
masks, so that the cap socket stays visible where the scratch would shadow
it. 004 then refused every overlap that ordering could not resolve the same
way on both platforms — a mount against a protected entry in either
direction, and the three spellings of one region named twice. It did not
consider a mount against a *writable root*, and that pair is exactly as
contradictory.

A read-only mount at or above a writable root lands on top of the writable
bind in the bwrap argv, so on Linux the root comes out read-only. Every write
under it fails with `EROFS`, and nothing says why. On Darwin a mount is an
allow rule over a subpath and Seatbelt unions allow rules, so the root stays
writable. One document, two jails — the situation 004's refusals exist to
make unreachable. A mount of `/` is the extreme of it: it covers every
writable root there is, and because it is emitted after `--proc` and `--dev`
it binds the host's procfs and device tree back over the fresh ones, which
is issue #37's confinement gap and hang reproduced through a new door.

Nothing reported it either. Both decoders accepted the policy.
`jail.AuditMounts` counted the shadowed root out of `rw=` and emitted no
skip — "narrower, counted out, not a skip" is its rule for a writable root
that did not survive — and the broker does not compare `rw=` against the
policy it sent. So the execution satisfied a full-enforcement demand.

The shape is not hypothetical. `client/codemode.install_prefix` takes the
parent of a binary's `bin` directory and resolves no symlink. `discover`
looks for `erl` beside the ERTS the harness runs on first and falls back to
`PATH`; on a merged-usr host whose `PATH` lists `/bin` before `/usr/bin`,
that fallback finds `/bin/erl` and the prefix is `/`; `discover`'s ERTS check passes it, because
`//lib/erlang` is `/usr/lib/erlang` through the same link. A `~/bin/gleam`
that is a symlink keeps its prefix mounted, and that prefix is the home
directory the workspace usually sits in. Either way the base carries a
read-only mount covering the writable root. What happened next depended on
an accident. A session base protects the workspace's blob store, which the
mount also covers, so the session refused to boot — naming "mount `/`
overlaps protected entry `…/.blobs`", a sentence about the wrong thing. An
extension build plane on a host whose state root holds nothing yet has no
protected entry under the mount at all, so it started, and every compile
ran with its build root read-only. And `tools/bash`, `client/jobs` and the
code-mode launcher copy a base's mounts into their requirements, so any
base that lacked the mask would have carried the shadow into every one of
those jails.

## What was considered

**Resolve it in the emitters.** Order a read-only mount before the writable
roots it covers, or skip it. Rejected for the reason 004 rejected a
tie-break for protected overlaps: the two emitters order a mount in
opposite directions against the masks already, a second exception on one of
them is a second thing the other has to agree with, and the mount-precedence
model is decided (`packages/sandbox/CLAUDE.md`, "Mount precedence is
decided") rather than open to a per-shape carve-out.

**Report it and do not refuse.** Make the audit emit a skip and leave the
policy valid. That turns a silent failure into a degraded execution, but a
policy that can only ever be carried out wrongly would still be accepted
everywhere, and on Darwin the report would have nothing to say because the
root really is writable there. The skip is kept, as the audit's half, but as
a second line and not the rule.

**Have the broker compare `rw=`.** The broker holds the policy it sent and
could refuse a report whose `rw=` falls short of its writable roots. It
cannot tell this shortfall from the legitimate ones without re-deriving the
plan — a writable root at exactly `/tmp` loses its tie to the scratch
tmpfs, and a protected entry over a root is masked — and Darwin reports its
counts inside `seatbelt-fs:` on different terms. That is a second
implementation of the mount plan in Gleam, which is larger than the thing it
would check.

**Refuse only `/`.** A mount of `/` is the worst case and the measured one,
but a mount of `/home/o` over `/home/o/work` is the same contradiction with
a smaller blast radius, and the same `~/bin/gleam` host produces it.

## Decision

A **read-only** entry of `mounts` whose path covers an entry of
`writable_roots` — the same path, or a component-wise ancestor, with `/`
covering everything — makes the policy invalid. Both halves refuse it with
the same words, in the same place they make 004's refusals:

- `broker/policy.validate` returns `MountShadowsWritableRoot(mount:,
  writable_root:)`. It runs on the composed policy before every dispatch and
  on the session base at boot (`client/serve.base_policy_fault`).
- The helper's decoder, `internal/policy.checkMounts`, returns `policy:
  mounts: read-only path "<mount>" covers writable root "<root>"`.

Only that direction is refused. A read-only mount *under* a writable root
narrows a subtree the sender named on purpose — a build seed prepared inside
a checkout is the ordinary case — and both platforms honour it alike. A
read-write mount above a writable root leaves the root writable. The
host-path `scratch` and the tmpfs scratch are not writable roots for this
rule; the audit already reports a tmpfs scratch that something shadowed.

The wire shape does not change, so `v` stays 2 and `hello.proto` stays 3:
017's rule moves `proto` for a key added, removed or made required on an
exec-channel frame, and this adds none. What changes is which documents of
the frozen shape are valid, and that is a change to a Part 1 contract, which
is why it is written here rather than landed as a fix. 004's own refusals
were stated in 004 for the same reason.

Two follow-ons land with it:

- **The audit reports the shape anyway.** `jail.AuditMounts` emits
  `skip:mounts: writable root <root> is read-only: <op> is the last mount
  operation covering it` when the effective view of a writable root is an
  explicit read-only mount, and keeps counting every other unwritable root
  out without a skip. Reaching that line means a policy got past the
  decoder, which is exactly when the report must not read as fully
  enforced. The `mounts:` entry's fields are unchanged, and a skip is an
  existing entry form, so the report's wire shape is unchanged too.
- **Code mode refuses a toolchain that would trip it.**
  `client/codemode.clear_of` refuses a toolchain one of whose mounts covers a
  writable root, `/proc` or `/dev`, and `client/serve.admissible_toolchain`
  applies it before the session base and before the build plane's base are
  built. The host then registers no `code_mode` tool and logs why, which is
  what `discover` does for a missing toolchain. Without that step a
  toolchain layout would go on refusing the whole server's boot, now in
  the right words instead of the protected-overlap ones.

## What it costs

A policy that validated yesterday can be refused today, and three kinds of
sender can meet that:

- **An operator's `[workspace] mounts` line** naming a read-only ancestor of
  the workspace now refuses the boot, naming both paths. The same line used
  to boot a server whose every shell ran with the workspace read-only, so
  the refusal replaces a failure the operator had no sentence for.
- **An escalation grant** of a writable root under a region the base mounts
  read-only now refuses the dispatch it was granted for. It used to be
  granted and then silently not writable on Linux.
- **A code-mode host** whose toolchain prefix is `/` or covers a writable
  root now boots without code mode, with the reason in the boot log.
  Before, the session refused to boot over the blob-store mask with a
  sentence that did not mention the toolchain, and a fresh host's build
  plane ran its compiles against a read-only build root — under `/`, also
  against the host's `/proc` and `/dev`, which is where #37's `/dev/null`
  hang came from.

Resolving the symlink would have kept code mode on the two hosts that were
measured, by naming `/usr/lib/erlang` or the checkout the link points into
instead of `/` or `$HOME`. That needs a `read_link` the standard library does
not offer, so it would cost an `@external`, and a resolved target can still
be `/` or a home directory. The refusal holds whatever the derivation guessed;
resolution is a later improvement to the guess, and the refusal stays in
front of it.
