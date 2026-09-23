# Protocol 048: own async executions and grant peer messaging

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

Peer provenance is retained as structured receipt data and as
`PeerOrigin(session, strand)` on the placed conversation entry. The new origin
variant uses a tagged encoding; existing human `{principal, name}` origins keep
their untagged representation. Malformed peer origins fail the total decoder.
Provider and terminal rendering identify the source as a peer agent. `GuardedMark` checks grant sequence in the recipient's admission
transaction. Unlinking an unavailable recipient removes outgoing authority
and reports the unremoved recipient grant. Git metadata is a timestamped
activation observation, not a live branch assertion.


The default server offers the full program capability set on both workspace
and orchestration modes. One program may combine filesystem or process calls,
child operations, execution input and peer delivery. The owner still grants
peer delivery in an exact direction, and the recipient checks that grant before
admitting a message. Import access alone does not grant peer, filesystem or
child authority; each call retains its broker and Agency checks.

An explicitly workspace-only host lacks Agency custody and keeps an effect-only
allowlist. Extension tools and resident hooks retain their own policies.
`workflow.step` is serviced only in a background execution, where an immutable
execution owner and original child operation exist. The cost of the wider
default is a larger advertised capability surface and the ability for one
program to compose workspace effects with child operations. The model-facing
tool description renders the actual host allowlist and serviced capabilities;
the shipped prompt names this combined default.

Operation abort and child reaping share a durable launch fence. Execution
creation compares both its own absence and fence absence atomically. Async
child admission compares that fence with its execution record. Parent execution
settlement includes backgrounds launched by owned children, including children
whose own model turns already ended.

## Authenticated control delivery

The v2 control endpoint also accepts owner-only `peers.send`. The owner selects
the source session and strand on whose behalf a script sends. The server checks
the epoch before routing, then reuses the ordinary peer sender and recipient
handlers. Existing directional grants, wake permission, residency, and receipt
semantics apply unchanged. The control request cannot supply provenance metadata.

The command carries source and target coordinates, `message_id`, `text`, and
`epoch`. Its success event returns the recipient's admission receipt. It is a
control mutation and is refused during daemon drain. Session members cannot use
it to impersonate another strand. The [client protocol](../docs/client-protocol.md#319-peerssend)
specifies field bounds.

## Readiness, typed endpoints and observation

Launch admission and input readiness are distinct. The durable execution phase
is unchanged; `client/async/ready/{id}` records an immutable endpoint set and
idle interval. `check` extends its existing flat record with `readiness`,
`endpoints` when ready, and optional volatile `progress` and `latest_delivery`.
A send adds an optional `endpoint` field, defaulting to `default`, and is
refused before readiness or for an unregistered name.

The capability channel gains `execution.ready`, `execution.receive_enveloped`,
`execution.progress` and `execution.delivery`. `cap/execution.endpoint` couples
a decoder and typed delivery closure within the satellite; `serve` registers
names and dispatches the ordered journal. Legacy `execution.receive` publishes
raw readiness for `default`. It cannot consume a typed endpoint journal.
No host-side actor subject or new exec-helper frame is introduced.

Progress retains only current and pending bounded snapshots, coalesced at
100 ms. Delivery records only the latest callback outcome. Neither observation
is durable or evidence that actor work completed. The API guide specifies
payload bounds. Typed idle expiry fences and reaps the execution; only a
successful delivery renews its idle anchor. The absolute deadline is unchanged.
A cumulative ceiling of 32 launches per initiating operation complements the
eight-live-execution session ceiling and is reconstructed from durable records.

`tool.Exclusive` covers the launching tool invocation, not the lifetime of an
admitted background satellite. Backgrounds may overlap other calls after
admission returns. The [architecture](../docs/architecture/async-collaboration.md)
explains custody, callback delivery and recovery boundaries.
