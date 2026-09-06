# protocol-change/016: record human origin with admitted work

**Status**: ACCEPTED 2026-09-05 · **Affects**: Part 1.1 messages, Part 1.6 session events ·
**Raised by**: multiplayer implementation · **Implementation**: durable origin, exact-cell APIs, gateway and TUI integrated; release acceptance remains open

## Problem

`core/message.UserMessage` stores content and timestamp but no author.
The runtime queues complete messages for steers and follow-ups, so the
missing field also loses authorship when those queues become user turns.
An authenticated gateway cannot recover the author later from the transcript.

Escalation records retain the exact action, scope and grant, but not the
operator who approved or rejected the request. Current membership and
display names cannot reconstruct that historical decision: credentials
rotate and people rename themselves.

Protocol-change/015 defines authenticated attachments, presence and shared
configuration events. It explicitly leaves these durable additions to a
separate proposal. This proposal supplies them without changing admission
authority or the writer's ordering.

## Proposal

Add a pure origin type and extend user messages:

```gleam
pub type Origin {
  Origin(principal: String, name: String)
}

UserMessage(
  content: List(UserBlock),
  timestamp: Int,
  origin: Option(Origin),
)
```

The authenticated gateway supplies the stable principal ID and display name
at admission. A command cannot override them. Principal IDs contain 1 to
128 ASCII bytes from `[A-Za-z0-9_.-]`. Names contain at most 256 UTF-8 bytes,
are nonblank after trimming, and exclude U+0000 through U+001F and U+007F
through U+009F. These match the daemon's access records. The pure type imports no storage, process or
credential machinery.

The durable message encoding includes `origin: null` or
`origin: {principal: string, name: string}`. Missing or null origin means
no recorded human author. A present malformed origin is corruption, never
an anonymous fallback. Historical records remain readable without a rewrite;
this is not a legacy server protocol or launcher mode.

Steers and follow-ups retain origin inside the queued message. Queue
delivery, transcript conversion, branching and replay preserve it. The
provider projection renders the admitted author once, ahead of the first
content block, including an image-first message. The displayed name is
data, not an instruction or a claim to elevated authority. System-generated
turns use `None` unless their host caller has a real authenticated author.
One pure helper supplies that prefix to the OpenAI, Anthropic and Gemini
adapters. Stored content remains unchanged, and attribution never changes
a user message into a system or developer message.

Extend the durable escalation record with:

```gleam
origin: Option(Origin)
```

The runtime exposes exact-cell decision functions:

```gleam
approve_escalation_at(
  runtime: Runtime,
  cell: EscalationCell,
  grants: List(JsonValue),
  origin: Option(Origin),
) -> Result(Escalation, ApiError)

deny_escalation_at(
  runtime: Runtime,
  cell: EscalationCell,
  origin: Option(Origin),
) -> Result(Escalation, ApiError)
```

Both commit once with `Expect(cell.seq)`. They never reread and retry a
decision against a reopened question. A reread after conflict is only for
presentation; if it fails, the conflict carries no invented winning author.
Existing host helpers can call these functions with `None`. Pure
`escalation.approve(record, grants, origin)` and
`escalation.reject(record, origin)` produce the attributed record.

Approval and denial admission accept the server-resolved origin. The
conditional decision write stores status, selected grants and origin
together. Exactly one pending decision wins; a losing client receives the
resolved record rather than silently overwriting its author. Consumption
and same-action scope transfer retain the winning origin. Reopening a
question clears the prior origin until another decision wins.

The v2 `entry` body carries the stored message origin. Escalation events and
conflict details carry the stored decision origin. Shared configuration
registers carry origin alongside their authoritative value, and the v2
configuration event exposes both. The existing `strand.config` encoding
remains a bare `StrandConfiguration`; its readers do not receive a wrapper.
For a strand configuration change, the same CAS transaction also writes
`fact.custom/client/config_origin/<strand>` with `{origin: ...}`. The
snapshot reads both cells at one cut.

Session-wide run defaults use `fact.custom/client/run_settings`:

```json
{"queue_mode":"consume_all","tool_execution":"parallel","origin":null}
```

The other accepted values are `one_at_a_time` and `sequential`. A change
compares the previous cell's sequence and writes the complete value and
origin together. New run admission reads these defaults; absent state uses
the host defaults, while malformed state refuses admission. Existing runs
retain their already-admitted settings. Presence remains ephemeral and
does not write conversation entries.

Both cells sit under a `client/` prefix that `runtime/api.reserved_fact_key`
adds to the reserved set, so `put_fact` refuses a model-supplied key there
and `facts` hides the namespace. The reservation is what makes the two cells
safe to trust: without it a forged `client/config_origin/<strand>` would
misattribute a shared configuration change to somebody who never made it,
and a forged `client/run_settings` would change the queue and
tool-execution defaults the next admitted run reads.

## Alternatives considered

A connection ID alone was rejected because connections disappear on
reconnect and several windows can belong to one principal. Resolving the
current display name during replay was rejected because it rewrites the
meaning of an old transcript after a rename. A separate attribution table
was rejected because every queue, branch, exact read and export would then
need an additional join to keep authorship attached to its message.

## Impact

Core message constructors and total codecs change together. Runtime queue
and escalation fixtures, prompt projection, gateway admission and encoding,
TUI decoding/rendering, recordings and E2E fixtures must follow. Existing
host-generated constructors explicitly supply `None`; they do not mint a
fictional owner. No SQLite table change is required because messages and
escalations are already encoded payloads.

The regression gates cover codec round trips, malformed origins, queued
steer/follow-up delivery, author retention after rename and reconnect,
approval-versus-denial races and two real TUI clients rendering the same
admitted records. Pure packages retain their portable, process-free subset.

## Decision

**Accepted.** The owner approved the origin addition. Independent critique
confirmed that existing queued messages already preserve the added field.
It identified three necessary corrections: explicit validation bounds,
exact-cell denial without stale-answer retries, and configuration metadata
that preserves the existing typed payload. Source verification confirmed
each correction, and the proposal includes them above. The review also
located model projection in provider adapters, not the prompt package.

No attribution table, new queue, migration or authority-bearing author
prefix is introduced. Regression coverage includes same-action approval
transfer, consumption, reopening after a stale answer, and retained turns
through branching and compaction.

### Addendum: bind the answer to the displayed revision

**Accepted 2026-09-05.** Integration review found that an exact-cell host API
alone does not bind a remote answer to the question the person saw. The old
approval command echoes the action and grants but no register sequence;
denial echoes only the request ID. If the same question reopens before the
answer arrives, reading its current cell at admission could apply an old
answer to that new pending revision. An unchanged action digest cannot
distinguish those two questions.

Every v2 escalation record therefore includes its durable register `seq`.
Both `approve` and `deny` require `expected_seq`, copied from the displayed
record. The gateway checks that the current cell has exactly that sequence,
then applies existing action/grant validation and calls the exact-cell API.
The writer's expectation closes the remaining race after that read. A
mismatch returns conflict with the current record when readable; it never
retries the answer. Sequence values must be nonnegative integers and are
scoped to this attachment's session, not to a global counter.

The primary verified the review's claim against the existing wire fields
and gateway admission path. Tests must delay an answer across reopening of
the same action, not only across a changed action, and must cover both
approval and denial. This adds no approval ledger or retry mechanism.
