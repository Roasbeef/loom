# ADR-006: macOS uses Seatbelt, with explicit lifecycle limits

**Status**: accepted · **Date**: 2026-08-29 · **Supersedes**: nothing ·
**Spec ref**: WP-H phase 2

## The question

WP-H requires a macOS jail that turns the frozen `SandboxPolicyV1` into real
filesystem, network, resource, and lifecycle restrictions. Darwin has no
mount or PID namespace and no cgroup hierarchy. It does ship Seatbelt through
the system `sandbox-exec`, plus POSIX rlimits and process groups. Which claims
can Loom make from those mechanisms without translating a Linux design into
names Darwin does not actually provide?

## Decision

Loom uses the pinned system `/usr/bin/sandbox-exec` with a generated
deny-default profile. The profile receives every model-influenced path through
`-D` parameters. It grants a read-only host view, explicit writable roots, a
fresh private mode-0700 scratch directory, and AF_UNIX sockets. Protected
logical and resolved paths are final subtractive denies. Internet bind and
outbound access are absent unless the policy selects `NetworkFull`.

The fd-4 stage-2 report is the witness for the outer profile. `seatbelt`,
`seatbelt-fs`, and `seatbelt-net` are not published merely because
`sandbox-exec` was found or started. They appear only after stage 2 reports
from inside the profile.

Resource limits use the mechanism Darwin actually has. CPU and file size use
their ordinary inherited rlimits. A requested finite `RLIMIT_AS` is attempted
and reported as skipped when the kernel rejects it. `RLIMIT_NPROC` is installed
only when the current account-wide process count leaves a 16-process reserve
below the requested limit; otherwise it is skipped rather than making every
subsequent jailed fork fail immediately. The sample and `setrlimit` cannot be
atomic with unrelated same-user forks, so the reserve narrows rather than
eliminates that race. The report names these as address-space and per-user
process rlimits, never as cgroups or per-execution ceilings.

Lifecycle containment is explicitly incomplete. The helper combines a fresh
process group with a birth-time-qualified process-table tracker, which reaches
observed descendants after `setsid(2)`. It cannot prove ownership across the
sampling interval: a rapid daemonizing double-fork can be reparented to
`launchd` before the tracker records it. Darwin also has no stable process
handle that makes a birth check and subsequent signal atomic. Output drains
for a bounded interval after cleanup, then the helper closes its read ends so
a missed descendant cannot hold the execution result open forever. Every
Darwin execution therefore
reports `skip:darwin-process-lifecycle`, and `FullEnforcement` rejects the
result. Seatbelt still follows the missed descendant across fork, so this is a
lifetime and resource-cleanup gap rather than a filesystem or network escape.

## Why

Seatbelt is the only unprivileged kernel confinement backend already present
on supported macOS hosts. A profile assembled as data keeps the helper's
trusted surface small, and parameter definitions keep policy strings out of
SBPL source. The deny-default shape also makes omitted network grants fail
closed.

The Linux resource vocabulary does not transfer. Darwin exposes
`RLIMIT_NPROC`, but the kernel compares it with all processes owned by the
real user. Applying a policy value already below that count does not create a
tight sandbox; it creates a command that cannot fork once. Darwin exposes
`RLIMIT_AS`, but current kernels reject finite values. Reporting either as an
applied per-execution ceiling would be false.

Polling faster does not close the lifecycle race. `kqueue` does not provide a
supported child-tracking primitive that survives reparenting, and a janitor
inside the same Seatbelt instance can be killed by the payload under the same
signal authority. A complete design needs a kernel-backed ownership boundary
that the payload cannot leave or kill. Until that exists, the enforcement
report, broker demand, tests, and documentation all preserve the distinction
between observed cleanup and guaranteed containment.

## Consequences

macOS can run the real sandbox and code-mode end-to-ends with filesystem and
network policy enforced. Best-effort callers receive the exact resource and
lifecycle gaps with every result. Strict callers cannot mistake the current
Darwin backend for Linux-equivalent descendant ownership.

The private scratch directory provides isolation and cleanup, but it is not a
tmpfs and must not be reported as one. The readable host view also remains the
same broad contract as Linux's read-only root: protected paths hide selected
data, while `readable_roots` does not form an allowlist for all reads.

A future macOS hardening change may replace sampled tracking with a privileged
executor or another kernel-backed process container. It may not delete the
lifecycle skip until an adversarial rapid double-fork test proves that a
reparented survivor is killed, while concurrent sandboxes and unrelated host
processes remain untouched.

## Addendum: the production demand follows the platform boundary

**Date**: 2026-08-30

The original decision made `FullEnforcement` the production default. That
demand was truthful, but it also made every default code-mode call on Darwin
fail before compilation: every execution reports the lifecycle gap, and common
hosts also report the two resource gaps above. A working Darwin jail was thus
available only through the much broader `BestEffort` override.

The production default is now `PlatformEnforcement`. On Linux it is identical
to `FullEnforcement`. On Darwin it requires Seatbelt filesystem and network
confinement, CPU and file-size rlimits when requested, and an explicit report
for every layer. It may accept only these three applied-or-skipped tags:
`rlimit-address-space`, `rlimit-processes`, and
`darwin-process-lifecycle`. A degraded helper, a missing mandatory layer, an
unexpected `skip:`, or silence for any required or tolerated tag still refuses
the execution.

`FullEnforcement` remains available through `--full-enforcement` for callers
that need Linux-equivalent resource and lifecycle containment. `BestEffort`
also remains explicit through `--best-effort`; it accepts gaps beyond this
ADR's narrow Darwin set. This split lets the default use the kernel boundary
Darwin can enforce without turning a missing Seatbelt layer into a successful
execution.

## Addendum: reads are an allowlist

**Date**: 2026-09-08

The Consequences above say that the Darwin filesystem view is "the same broad
contract as Linux's read-only root": every host path readable, `protected` the
only subtraction, `readable_roots` not an allowlist. That is no longer what the
profile does. Under protocol-change/020 the unconditional `(allow file-read*)`
is gone, and reads are granted per region: the system view
(`jail.DarwinSystemRoots`), the policy's readable and writable roots, its
explicit mounts, the per-execution scratch, the per-user temp and cache
directories, and the helper's own binary. The trailing protected denies are
unchanged and still final.

The open question when 020 was written was whether SBPL subpath read allows
behave that way on current macOS, since `sandbox-exec` is undocumented and this
ADR claims only what stage 2 witnesses. They do. On macOS 15 with the profile
above, `make selftest` reports eleven of eleven probes enforced, including the
new `host path outside the mount plan unreadable`, and the existing probes are
unchanged: `/bin/sh` runs, the dyld shared cache maps, a Homebrew `erl` boots a
node and loads a hand-compiled `.beam`, and `command -v rg` still resolves
through the inherited PATH. So the `known-gap` line 020 held in reserve was not
needed, and the probe is `required` on both platforms.

Three things had to be granted that a reading of the profile alone would not
predict, and each is recorded in the code beside the rule it justifies. The
root directory needs `file-read*` rather than `file-read-metadata`: with every
system subpath allowed and `/` denied, `/bin/sh` aborts with exit 134 and no
diagnostic at all, because path resolution walks the root. The three top-level
symlinks into `/private` — `/etc`, `/tmp`, `/var` — need metadata reads,
because profile paths are normalized to their resolved form while the paths a
caller hands the payload are not, and an unresolvable `argv[0]` is reported as
`execvp() ... Operation not permitted` for a binary the profile does grant. And
the process now starts in the working directory the request named rather than
in the helper's own, since an inherited working directory outside the profile
makes every `getcwd(3)` fail and stops an `erl` launcher script that cds to its
own directory.

What this addendum does not change: the lifecycle gap, the two resource gaps,
and the enforcement demands the previous addendum settled. The private scratch
directory is still not a tmpfs. What it does change is the last sentence of
Consequences: `readable_roots` on Darwin now restricts reads, as it does on
Linux, and a path named by no part of the policy is not visible to a jailed
payload.

## Addendum: ancestor metadata is granted on Darwin

**Date**: 2026-09-08

The allowlist addendum above is complete about which regions are readable and
silent about the directories leading to them, and that gap broke a real build.
`realpath(3)` stats every ancestor of the path it canonicalizes, so a readable
root nested several levels below `/` was granted while the path down to it was
not. A jailed `gleam build` of a project with a `path` dependency failed with
`Operation not permitted` while canonicalizing a file the profile did grant.
Under the pre-020 whole-host view the ancestors were covered by the same
unconditional read that covered everything else, so the narrowing is what
introduced the failure.

The profile therefore emits `(allow file-read-metadata (literal ...))` for
every proper ancestor of every granted region: each writable root, each
readable root, each explicit mount, the per-execution scratch, the helper's own
binary, the per-user temp and cache directories, and each entry of
`DarwinSystemRoots`. Both spellings are emitted, the policy's own and the
symlink-resolved one, for the reason the protected denies emit both. The rules
are placed before the trailing protected denies, so a protected ancestor is
still denied by the final word of the profile.

What this exposes is the existence, mode and modification time of directories
whose names the payload was already given, and no contents: the verb is
`file-read-metadata` and never `file-read-data`. Linux exposes the same shape
without anyone deciding to, because bwrap creates the parents of every
mountpoint in the root tmpfs and a jailed process can stat them. The eleven
self-test probes are unchanged and all eleven remain enforced, including `host
path outside the mount plan unreadable`, which reads a file rather than
stat-ing a directory.
