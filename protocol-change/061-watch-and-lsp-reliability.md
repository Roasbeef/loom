# protocol-change/061 — retain watcher consent and report LSP load failures

**Status**: ACCEPTED 2026-10-01; implemented on the reliability branch.
**Affects**: Part 1.6 remembered approvals, protocol 058 job custody, and
the LSP lease's readable workspace boundary.

## Problem

The live `loom` session launched two explicitly approved session-lifetime
mail watchers. Both durable job records ended with `operation_abort`, after
28.6 and 54.6 seconds. A third identical launch requested wall authority
again. The terminal offers session consent only for filesystem and network
grants, so a watcher cannot retain consent across launches.

A second failure made Gleam semantic queries misleading. Denying read access
to MCP's sibling `core` path dependency reproduces empty symbols and a null
definition. The same binary resolves 51 symbols and the definition with that
read allowed. Gleam reports its dependency load failure through
`window/showMessage`; Loom discards that notification and calls the empty
diagnostics settled and clean.

## Decision

**Accepted. Session-lifetime jobs belong to the session, and remembering
their wall consent authorizes only the same action on the same strand.**
The owner requested these fixes on October 1. A session approval containing
only `wall_s = 0` stores a reserved action grant keyed by strand, tool and
the digest of the complete effective arguments. Dispatch reads that exact
grant. It never adds unlimited wall time to the session's general policy.
Filesystem and full-network persistence retain protocol 041's behavior.
Other resource grants remain once-only; mixed requests are refused for
persistence rather than silently remembered in part.

No client frame changes: `approve {scope: "session", ...}` still echoes the
captured action, grants and sequence. The approval and reserved grant commit
atomically. Session identity binds the workspace. A different strand, tool
or effective argument cannot spend the grant. The existing escalation
question and ask ceilings bound the number of human-authored records.

A job requesting session lifetime clears under a freshly minted custody
operation rather than the initiating model operation. Its durable
`started_by` still names the initiating operation for attribution. Aborting
that model operation leaves the watcher running. Explicit job kill, session
shutdown, runner death and daemon loss retain their existing cleanup rules.
Finite jobs retain originating-operation abort semantics. This supersedes
only protocol 058's originating-operation cancellation of session jobs.

**The LSP lease may read the session-authorized portion of its workspace,
while writes and answer admission remain rooted at the selected package.**
This supports sibling path dependencies without parsing language manifests
in the harness or trusting a server-supplied path. Existing session grants
bound the read; protected paths, network-off and private caches remain in
force. Dependencies outside that workspace still require explicit profile
authority. An arbitrary dependency does not enlarge the lease.

The protocol client decodes error-level window messages and retains a bounded
server error. An empty semantic answer or diagnostics barrier after that
failure returns `Unavailable` with the server's words, including when
settlement expires. A nonempty result validated by the feature's existing
decoder establishes recovery. Empty hover content, empty rename edits and
malformed replies cannot clear the failure. Call hierarchy shares a capability
across three methods; its nonempty replies retain the failure while reaching
the method-specific decoder. Another typed semantic query establishes
recovery. Informational
messages do not turn an ordinary empty answer into failure. No LSP or capability
wire field changes are required.

## What was considered

A global remembered `wall_s = 0` would authorize unrelated commands, so it
was rejected. String matching on `substrate watch` would hide policy in shell
syntax. Automatic watcher restart could repeat effects. The session custody
and exact action grant express the intended authorization directly.

Adding Hex cache access was not supported by the evidence: a PATH-only raw
probe succeeds. Removing the jail or enabling network would not fix the
identified sibling dependency boundary. Reimplementing each language's path
dependency graph would add language-specific authority discovery to Loom.

## Impact and verification

The client gateway, shared approval surface, invocation wiring, jobs owner,
LSP protocol client and lease policy change together. Old saved approvals
remain valid; no helper protocol or generated capability prelude changes.
Regression checks must cover exact action and strand isolation, atomic
approval, ordinary versus session-job abort, explicit cleanup, error versus
legitimate empty LSP answers, recovery, sibling reads and protected/outside
workspace refusal. Actual jailed LSP and compiled code-mode calls remain
required before claiming end-to-end correction.

The completed local affected gate passed in 495 seconds at the final
executable tree `0372d301b`, including the fresh code-mode seed, native
session proofs and a clean undeclared-skip census. The independent review's
settlement-expiry and empty-object recovery findings were fixed and
regression-tested. [The review record](../docs/review/watch-and-lsp-reliability.md)
records the validation boundary; hosted CI and Linux signoff remain pending.
