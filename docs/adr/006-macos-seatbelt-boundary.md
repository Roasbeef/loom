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
only when the current account-wide process count is below the requested limit;
otherwise it is skipped rather than making every subsequent jailed fork fail
immediately. The report names these as address-space and per-user process
rlimits, never as cgroups or per-execution ceilings.

Lifecycle containment is explicitly incomplete. The helper combines a fresh
process group with a birth-time-qualified process-table tracker, which reaches
observed descendants after `setsid(2)`. It cannot prove ownership across the
sampling interval: a rapid daemonizing double-fork can be reparented to
`launchd` before the tracker records it. Every Darwin execution therefore
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
