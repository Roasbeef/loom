# protocol-change/105: versioned peer exchange

**Status:** approach accepted by the owner on 2026-10-29; implementation and
verification in progress. **Affects:** the orchestrator transport assumptions
in 078 and the page operations in 094. Part of issue #1137.

## Problem and alternatives

A new constructor sent to an older orchestrator port can raise `case_clause`
and kill its actor. Port death neither identifies a release nor establishes
that an earlier request had no effect. The original same-build rule avoids
this only when operators coordinate every upgrade.

A feature probe followed by a request to the legacy named port is insufficient:
a replacement can take that name between discovery and dispatch. A build or
epoch string in the discovery answer does not fence that later legacy send.

We considered retaining coordinated same-build upgrades and probing an existing
constructor. The former preserves the operational restriction; the latter has
no compatible constructor that establishes future support. We use a separate
stable endpoint, with discovery and migrated operations inside the same envelope.

## Decision and trust

The separately registered `loom_peer_v1` service has one permanent outer shape:

```gleam
Exchange(payload: String, reply: Subject(String))
```

Future operations extend versioned JSON data, not this constructor. The legacy
port remains for unmigrated protocols; its same-build restriction remains.
Migrated 094 operations never probe or dispatch to that name.

Pinned distributed Erlang membership retains its existing fully trusted VM
model. The reply subject owner's node supplies the same attribution used by the
legacy host; it is not a new proof of the transport sender. Discovery grants no
authority. The existing `TopHost` judges spawner membership, top-level permission,
placement, capacity, session ownership and approval sequence on every operation.
No owner-created session or child transcript becomes accessible through discovery.

## Envelope

Every request carries integer `v: 1` and a nonempty `request_id`. Identifiers,
including epochs and revision names, are at most 256 UTF-8 bytes. Discovery is:

```json
{"v":1,"op":"features","request_id":"r1"}
```

Its answer has `v`, the same `request_id`, `kind: "features"`, the serving
`epoch`, a diagnostic `build`, and an array `revisions`. The epoch identifies the
actual serving daemon incarnation; the build string alone is not an incarnation
or a compatibility test. At most 64 literal operation revisions are advertised.

A caller requires a positive advertisement for its exact operation revision,
then sends to this same stable endpoint:

```json
{"v":1,"op":"operation","request_id":"r2","epoch":"observed-epoch","revision":"094.stop.1","body":["session-id"]}
```

Before invoking a callback, the receiver checks its serving epoch, the exact
revision and the complete operation body. A replacement returns `stale` or
`unsupported` rather than receiving a constructor selected for its predecessor.
There is no discovery cache or legacy fallback.

Replies always carry `v`, `request_id` and `kind`. An ordinary success is
`kind: "ok"` with `body`; a host refusal is `kind: "refused"` with the existing
refusal represented as data. Bounded control errors are `unsupported`, `stale`,
`malformed` and `oversized`. Unsupported versions or operations never invoke a
host callback. Missing endpoint is unsupported; disconnection and timeout do not
establish that the endpoint is absent. Invalid correlation, version or payload
cannot authorize dispatch.

Discovery and dispatch share the original call budget. An unavailable discovery
answer establishes that this attempt sent no operation. Once an operation may
have reached its receiver, a missing, unreadable or oversized reply retains
uncertainty. A later discovery failure cannot settle an earlier unanswered
mutation. Existing creation/message IDs, resend windows, approval sequence checks
and request-specific refusal meanings remain unchanged.

## Migrated operations

Each revision below begins with `094.` and ends with `.1`. Body arrays have the
exact arity shown. Placement, grant, escalation record and page values reuse the
existing total codecs and semantics.

| Revision | Request body | Successful reply body |
| --- | --- | --- |
| `094.placements.1` | `[]` | Existing offers object. |
| `094.create.1` | `[request_id, placement, profile, model_or_null]` | Session ID string. |
| `094.sessions.1` | `[after, limit]` | Existing sessions page. |
| `094.history.1` | `[session, cursor, limit]` | Existing transcript page. |
| `094.send.1` | `[session, message_id, text]` | Existing landing. |
| `094.stop.1` | `[session]` | `null`, acknowledging the stop request. |
| `094.archive.1` | `[session]` | `null`. |
| `094.resolve.1` | `[session, escalation_id, decision, seq, principal, name]` | Decision answer below. |

A decision is `["deny"]`, `["forget", grant]`, or
`["approve", [grant...], action, "once"|"session"]`. The answer is
`["decided", record]`, `["forgotten"]`, `["stale", record, reason]`, or
`["refused", reason]`. Grants and records use the current protocol codecs.

A host refusal is `[kind, value, number]`. Kinds are `unknown_spawner`,
`top_level_off`, `not_offered`, `cap_reached`, `not_relayed`, `invalid_argument`,
`not_yet_open` and `store_failure`. The last two retain their operation-specific
meaning from the 094 addendum. `not_offered` carries `kind:name`, split once;
`cap_reached` carries `sessions` or `hour` and its integer limit. Other refusals
carry their existing text or empty string, with integer zero.

## Bounds and cost

The entire input is checked against 1,048,576 bytes before parsing. Feature
requests are additionally limited to 4,096 bytes and feature replies to 16,384
bytes. Operation request and reply envelopes are each limited to 1,048,576 bytes;
individual field and page limits still apply. A request that cannot fit is
refused before dispatch. An oversized reply becomes a bounded error, never a
truncated successful page; a mutation caller still treats its effect as unknown.

The operation ceiling preserves ordinary 094 text and page bounds after JSON
escaping, including a 32,768-byte send. A pathological valid offers configuration
can exceed it and gets a clear size error. We choose that explicit failure over
a new paging mechanism or tens of megabytes for one control reply. These bounds
limit processing after Erlang distribution has received the term; they do not
bound transport or mailbox allocation by an already trusted VM.

Older installations without this endpoint need an initial upgrade before serving
migrated 094 requests. This protocol does not make old in-flight legacy messages
safe. Repository transfer, full component relay and other future operation
contracts are separate work; the feature-control limits do not define their
content limits. The owner's approval covers implementation and isolated tests,
not a live upgrade.

## Verification

Use actual actor boundaries for an old-shape receiver and the new endpoint.
Prove the old unsafe send fails the survival assertion, the new caller leaves
the old actor alive, and a legacy caller can coexist with the new service. Force
replacement between discovery and dispatch, and verify no replacement callback
acts under the previous epoch. Malformed versions, correlations, bodies and
revisions, byte/revision-count bounds, lost mutation replies and unchanged total
call budget need behavioral tests. Verify authorization through a real TopHost.
These actor fixtures do not establish old/new released-daemon or live TLS proof;
record those limits and applicable shipped tests before readiness.
