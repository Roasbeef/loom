# 040: Session directory access and explicit tool permissions

Status: accepted for implementation after independent design review.

## Problem

An operator cannot add a directory to a running session. Shell executions
inherit the session's filesystem policy, but native file tools and code-mode
filesystem capabilities enforce a separate workspace-only boundary. Existing
approval records bind consent to one exact action; ordinary kernel denials
do not create those records.

## Decision

`/add-dir PATH` adds read access to an existing directory for this session.
`/add-write-dir PATH` (also `/add-dir --write PATH`) adds read and write access. The server canonicalizes
the directory before saving it. The grant survives reconnect and reopening
the same session, and does not apply to other sessions. Duplicate additions
are idempotent; adding write access upgrades an existing read-only addition.

The authenticated `set_config` command accepts a session-only
`add_directory` object with `path` and `access` fields. Access is `read` or
`write`. This mutation cannot be combined with other settings or a strand
selector. Only principals permitted to approve escalations may add access.
The committed configuration reports the canonical directory additions.

Store additions in a reserved session fact, using the runtime writer's
compare-and-set operation. A missing fact means no additions. A malformed
fact or failed read refuses execution rather than substituting an empty
policy. Capture the additions once before each tool invocation. Existing
jobs and satellites retain their captured authority.

Keep native filesystem authority separate from the jail's readable roots.
Native tools start with workspace access and add only explicit session
directories and call-bound approvals. Host read access for jailed commands
must not implicitly widen native tools. All paths are canonicalized before
checking containment; protected paths remain enforced for writes.

Shell and code-mode calls may declare requested filesystem or network
permissions in their arguments. The server computes the missing grants and
uses the existing action-bound escalation before execution. Native file
tools can request the exact target's missing access before touching it.
Approval affects only the displayed invocation and does not modify the
session directory fact. Kernel failures after execution starts remain tool
results: the harness must not infer authority from stderr and replay a
partially executed program.

## Alternatives and costs

A mutable global policy actor would duplicate session state and introduce
restart ordering. The existing durable register and writer already provide
the required ownership and atomicity. Mounts are not directory grants:
their composition and protected-path interactions differ.

The cost is carrying one invocation's native filesystem authority alongside
its jail policy through native tools, code mode and background-job admission.
Resolving a path before ordinary filesystem I/O retains the existing race
with concurrent host renames; this proposal does not claim descriptor-based
filesystem confinement. Host-filtered shell networking remains dependent on
the separate network-proxy implementation.

## Review and verification

Independent read-only design review required preserving native workspace
defaults, capturing authority for each invocation, and updating background
jobs and code-mode filesystem capabilities as well as foreground bash.
Those findings are incorporated above.

Regression coverage must exercise one added directory through native file
tools, foreground bash, background bash and code mode; deny an ungranted
neighbor and protected writes; reopen the session; and prove that explicit
approval launches the requested execution exactly once. A kernel denial
after a marker write must never trigger an automatic second launch.
