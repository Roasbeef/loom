# Protocol 045: own async executions and grant peer messaging

**Status**: IMPLEMENTED, locally verified 2026-09-21 · **Affects**: code-mode tool and capability surface, child-run custody, daemon control · **Raised by**: #107, #382

## Problem

Before this extension, `code_mode` settled only after its satellite ended. Moving the same
execution to a background task without changing identity would share the
launching batch's broker ledger. Passing its original Agency into that task
would also let the parent run-end reaper cancel early children while missing
children created after that scan.

The existing `send_to_strand` API commits each retry as a new entry. Across session
stores an acknowledgement can be lost after the recipient commits, so a
retry needs an identity independent of the response. Lineage also deliberately
refuses siblings and supplies no cross-session authority.

## Decision

The default `code_mode` invocation remains synchronous. Additional modes are
`launch`, `send`, `check`, `join`, and `cancel`. Launch returns an admitted
handle and fixed deadline; it does not claim that compilation or node startup
has completed. Later calls name that handle and are checked against its owner
strand. Async records live under the reserved `client/async/` prefix.

```text
ExecutionState = Starting | Running | Draining | Finished(result) | Lost(reason)
ChildOwner = ParentRun(operation) | AsyncExecution(operation, execution)
```

Async execution uses a separate broker step under its initiating operation.
No interaction rebinds its token, extends its deadline, or lends it new grants.
Async child admissions must compare the durable execution's live generation
in the same transaction that establishes child custody. Draining fences new
admissions before collecting and cancelling the owned child operations.
Existing string-valued child owners decode as `ParentRun`; absent ownership
continues to mean detached.

Program input is data received over the existing capability channel. A
bounded durable inbox supports non-destructive cursor reads, so a lost read
response cannot silently consume a message. Programs decode each value before
sending it to their own typed actors. The model-facing interface remains the
execution handle, not an independently discoverable mailbox.

Peer messaging uses stable request identities, authenticated provenance and
recipient-side atomic admission marks. Directional operator grants separate
delivery from waking. The v2 control protocol gains owner-only `peers.link` and `peers.unlink`;
discovery and delivery are model tools and cap calls, without changing
existing session socket authority. Only resident target sessions accept delivery.

Named workflow steps record their inputs and program identity alongside their
child-operation handles. Recovery reuses those operations and validated
results; it never replays arbitrary workspace effects.

## Impact

Runtime decoders and admission, client services and daemon routing, tool
schemas, and capability stubs change together. The generated prelude and
code-mode seed must be rebuilt. No exec-helper frame change is required for
inbox calls over the existing capability request/result channel.

Independent review identified the shared broker ledger and premature child
cancellation hazards. The implementation gives each background execution its
own broker step and child ownership. The [design note](../docs/design-notes/async-collaboration.md)
records the resulting regressions and local validation. Terminal presentation
remains outside this proposal.


## Recovery and wire details

The final API and bounds are in [async collaboration](../docs/async-collaboration.md).
Initial async child admission also writes `client/child-initial/{strand}` with
its operation ID. This closes the crash window before lineage publication:
a later operator or peer run cannot become the recovered workflow step.
Named step intents retain original call-site coordinates and assignment digest;
the child operation's existing durable terminal is the result authority.

Peer provenance is retained as structured receipt data and rendered as
explicitly attributed message content. No new `AgentMessage` origin variant
is introduced. `GuardedMark` checks grant sequence in the recipient's admission
transaction. Unlinking an unavailable recipient removes outgoing authority
and reports the unremoved recipient grant. Git metadata is a timestamped
activation observation, not a live branch assertion.


The prior report-only intersection between the two code-mode seams is widened
explicitly to `cap/{report, execution, peer}`. Peer delivery can induce work
only under a recipient-owned directional grant; it does not confer workspace
access or child ownership. `cap/workflow` remains orchestration-only.

Operation abort and child reaping share a durable launch fence. Execution
creation compares both its own absence and fence absence atomically. Async
child admission compares that fence with its execution record. Parent execution
settlement includes backgrounds launched by owned children, including children
whose own model turns already ended.
