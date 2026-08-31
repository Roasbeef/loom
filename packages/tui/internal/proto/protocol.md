# ClientGateway wire bodies — v1

The envelope is frozen by the implementation spec, Part 1.6. This
document is the normative definition of every **body** under that
envelope, version `v: 1`. The Gleam gateway (WP-L) builds to this
document and to the golden fixtures in `testdata/` (which double as the
gateway's conformance fixtures). Changing anything here is a protocol
change and follows the `protocol-change/NNN.md` process.

Transport: websocket, text frames, one JSON envelope per frame.
Endpoint: `/v1/ws`. Auth: local connections authenticate by unix-socket
peer credentials; remote connections send `Authorization: Bearer
<token>` on the upgrade request.

## Conventions

- Gateway-defined field names are `snake_case`. Wherever a body embeds
  a value that already has a durable JSON form in the harness —
  entries, messages, usage — that value is carried **verbatim** in the
  core codec's vocabulary (`core/codec`, pi field names, camelCase).
  The gateway serializes those with the codec it already has; clients
  treat them as a nested document.
- Envelope decoding is strict: `v` must be `1`; `cmd`/`event` and the
  command `id` must be present. Unknown `cmd`/`event` **names** are
  tolerated: a server answers an unknown cmd with `error`
  (`unsupported`); a client ignores an unknown event, keeping its raw
  body. Unknown **fields** inside known bodies are ignored by both
  sides (forward compatibility within v1: new optional fields may be
  added; nothing may be removed or change meaning).
- `id` is client-assigned, non-zero, unique per connection.
- `seq` is a per-session, gateway-assigned, strictly increasing
  sequence over the **durable event stream**: `entry`, `op_transition`,
  `usage`, `escalation`, `strand_result`. These are rebuildable from
  storage scans and replayable. `snapshot`, `stream_delta`, and `error`
  are connection-scoped and never carry `seq`.
- Every command receives exactly one reply on the issuing connection —
  an event with `reply_to` set (table below), or `error` with
  `reply_to` on failure. Reply events that are also durable-stream
  events (e.g. the `entry` acking a `prompt`) are broadcast to all
  connections with their `seq`; only the issuing connection's copy
  carries `reply_to`.

### Reply table

| cmd            | success reply                              |
|----------------|--------------------------------------------|
| `subscribe`    | `snapshot` (mode `full` or `resume`)       |
| `catch_up`     | `snapshot` (mode `resume` or `full`)       |
| `prompt`       | `entry` (the appended user entry)          |
| `prompt_content` | `entry` (the appended user entry)        |
| `steer`        | `entry` (queued — see below)               |
| `follow_up`    | `entry` (queued — see below)               |
| `abort`        | `op_transition` (phase `cancel_requested`) |
| `approve`      | `escalation` (status `approved`)           |
| `deny`         | `escalation` (status `rejected`)           |
| `fork`         | `snapshot` (mode `strands`)                |
| `create_strand`| `snapshot` (mode `strands`)                |
| `navigate`     | `snapshot` (mode `strands`)                |
| `compact`      | `op_transition` (phase `compacting`)       |
| `models`       | `snapshot` (mode `models`)                 |
| `set_config`   | `snapshot` (mode `config`)                 |

**Queued versus placed.** Not every `entry` reply describes an entry
that is in the tree. The `entry` acking a `steer` or a `follow_up` is
the **queued** case: the item is durable as a pending register and not
yet placed, so the nested entry carries the reserved entry id and the
message with no parent and a storage `seq` of `0`, and the envelope
carries no event `seq`. The placed entry broadcasts later — same entry
id, real parent, real storage seq, and an event `seq` of its own — when
the run consumes the item. Anything still queued when the run reaches a
terminal boundary is dropped instead — after an `abort`, or when the
run settles without ever reaching that item — and is never placed. A
client must therefore treat a queued ack as a pending marker keyed by
the reserved id, replaced by the broadcast that shares that id, and
must not assume the replacement arrives. The `entry` acking a `prompt`
is the **placed** case and carries both seqs.

## Subscription, catch-up, reconnect

A connection is scoped to one session by its first (and only)
`subscribe`:

- `subscribe {session, from_seq?}` — `from_seq` absent or `0`: reply is
  a **full snapshot** and live events follow. `from_seq > 0` (a
  reconnecting client that was at seq `from_seq - 1`): reply is
  `snapshot {mode: "resume", next_seq}`, then the durable events with
  `from_seq <= seq < next_seq` are **replayed in order with their
  original seqs**, then live events continue seamlessly. If the gateway
  cannot rebuild from `from_seq` (e.g. after a precise rewrite), it
  replies with a full snapshot instead; the client discards its state
  and rebuilds.
- `catch_up {from_seq}` — same resume semantics on an
  already-subscribed connection. Clients use it when they observe a seq
  gap (bus events are hints and may be dropped server-side; pulls are
  truth). Overlap is legal: clients deduplicate by `seq`.

The invariant the client test-suite enforces: across any number of
drops and reconnects, the client observes every durable event **exactly
once, in seq order**.

## Command bodies

- `subscribe` `{session: string, from_seq?: uint}`
- `catch_up` `{from_seq: uint}`
- `prompt` `{strand: string, text: string}` — start a run on an idle
  strand. Refused with `conflict` while the strand has a live op.
- `prompt_content` `{strand: string, content: [UserBlock]}` — start a run on
  an idle strand from one non-empty ordered list of the core codec's user
  blocks. Every block uses the core codec verbatim. An unknown block type,
  invalid base64 image, empty image MIME type, wrong field type, or empty list
  refuses the whole command as `bad_request`; no partial message is admitted.
  The gateway appends exactly one `UserMessage`, preserving block order.
  Older gateways see an unknown command and refuse it as `unsupported`.
- `steer` `{strand, text}` — inject into the live run (picked up at the
  next checkpoint). Refused with `conflict` when idle.
- `follow_up` `{strand, text}` — queue a turn to run after the live op
  settles.
- `abort` `{strand}` — cancel the strand's live op.
- `approve` `{escalation_id: string, grants: [Grant], action: string}` —
  both `grants` and `action` are **required**, and both are echoes of
  what the client actually displayed: the policy diff it drew, and the
  `action` digest it drew beside it. The server checks the pair against
  the record it is about to commit and refuses a mismatch with
  `stale_approval`, handing the record back rather than reconciling
  (see below). `grants` may be a subset of the denial's `wanted` —
  partial approval narrows the re-execution — and may never exceed it.
  `action` is the empty string exactly when the record names no action.
  Non-pending escalations refuse with `not_pending`.

  An earlier revision made `grants` optional, absent meaning "everything
  this record wants", resolved when the commit ran. A pending record's
  denial is refreshed by whichever call currently holds the claim, so
  that resolved a diff the human never read; requiring the echo is what
  makes consent a statement about a specific widening of a specific
  action rather than about a record id.
- `deny` `{escalation_id}`
- `fork` `{strand, scope: "branch"|"tree", name?}` — the new strand
  appears in the `strands` snapshot reply.
- `navigate` `{strand, to_entry: entry-id}` — move the strand's leaf.
- `compact` `{strand, instructions?: string}`
- `create_strand` `{name?: string}`
- `models` `{}` — request the gateway's model catalogue; the reply is
  a `models` snapshot. The body is deliberately empty in v1.
- `set_config` `{strand?: string, config: object}` — gateway-defined
  keys; unknown keys are refused (`bad_request`), never ignored. The
  defined keys: `queue_mode` (`"consume_all"`|`"one_at_a_time"`) and
  `tool_execution` (`"sequential"`|`"parallel"`) are session-wide run
  settings; `model_name` (a catalogue name from the `models` listing —
  the gateway resolves it, an unknown name is refused) switches the
  named strand's model, or every strand's when `strand` is absent;
  `model` (`{provider, model_id}`), `thinking_level`, and
  `active_tools` require a `strand` and set that strand's durable
  configuration directly.

## Event bodies

### `snapshot`

`{mode, session?, next_seq?, strands?, entries?, escalations?, usage?,
config?, models?}`

- `mode: "full"` — `session`, `next_seq`, `strands`, `entries` (recent
  window, oldest first, each in the `entry` body shape), `escalations`
  (pending only), `usage` (session running total, core codec `Usage`,
  camelCase). The client rebuilds from scratch.
- `mode: "resume"` — `next_seq` only; replay follows (see above).
- `mode: "strands"` — `strands` only (full replacement list).
- `mode: "config"` — `config` only (the effective config object; it
  carries the defined `set_config` keys, plus `model_name` when the
  strand's model identity is one the catalogue knows).
- `mode: "models"` — `models` only: the model catalogue, one row per
  entry, `{name, dialect, model_id, roles: [role], active: [role]}`.
  `name` is the handle `set_config`'s `model_name` accepts; `dialect`
  is `"anthropic"` or `"openai"` (open set — display unknown values
  verbatim); `roles` are the roles whose fallback chain lists the
  model and `active` the subset it currently resolves for (both always
  present, possibly empty). A gateway with no configured catalogue
  answers an empty list.

Strand: `{id, name?, leaf?: entry-id, live_op?: {op, phase}}`.

### `entry`

`{strand: string, entry: <core codec entry, verbatim>}` — one appended
entry. The nested entry is exactly what `core/codec.encode_entry`
produces (`id`, `parentId`, `seq`, `timestamp`, `type:
message|compaction|branch_summary|custom`, then per-type fields;
messages discriminate on `role: user|assistant|toolResult|custom`).
Note the nested `seq` is the **storage** seq, distinct from the
envelope's event seq.

### `op_transition`

`{op: string, strand: string, phase: string}` — a display label (the
`op.state` register is the truth). Defined labels: `starting`,
`assistant`, `tools`, `compacting`, `awaiting_deferred`,
`failure_drain`, `cancel_requested`, `done`. The set is open; clients
display unknown phases verbatim.

### `stream_delta`

`{strand, op, ephemeral: true, kind: "text"|"thinking"|"tool_call",
text?, call_id?, tool_name?, arguments_fragment?}` — live streaming
fragments, `ephemeral` always `true`, never persisted, never seq'd,
never replayed; wholly superseded by the settled `entry` for the same
`op`. `text` carries `text`/`thinking` fragments;
`call_id`/`tool_name`/`arguments_fragment` carry `tool_call` fragments
(`arguments_fragment` is a fragment of the arguments JSON, not
necessarily parseable alone).

### `usage`

`{strand, op?, usage: <core codec Usage, verbatim>}` — one ledger
append (`input`, `output`, `cacheRead`, `cacheWrite`, `cacheWrite1h?`,
`reasoning?`, `totalTokens`, `cost: {input, output, cacheRead,
cacheWrite, total}`). Clients accumulate onto the snapshot baseline.

### `escalation`

`{escalation_id, op, strand, status:
"pending"|"approved"|"rejected"|"consumed", tool?, action?, preview?,
asked?, denial?}`

`op` and `strand` are the record's own call scope — the operation and
strand the denial was raised for. They are empty together exactly when
the record names no call (an escalation raised out of band); they are
never inferred from which strand happens to be busy.

`tool`, `action` and `preview` describe the **action** an approval would
authorize, as opposed to the policy diff it would authorize it under:
the tool's name, a stable digest of the call's effective arguments, and
a bounded rendering of those arguments. `asked` counts the questions the
record has put to a human — one for the raise that opened it, one more
for each re-opening.

All four are additive within v1 and each is omitted when it says
nothing, so a record raised through a door that names no action is
byte-identical to one written before the fields existed. A reader treats
an absent `tool`/`action`/`preview` as the empty string and an absent
`asked` as `0`; such a record must still render and must still be
approvable, with `action: ""` as its echo. A field that is *present* and
of the wrong type is a malformed body, not an absent one.

`action` is compared for equality and never interpreted. `preview` is
bounded (2 KB in this harness) and carries the harness's own truncation
marker — `… [2,048 of 41,203 bytes]` — when the arguments did not fit.

#### Rendering the preview (normative for every client)

`preview` is **model-controlled untrusted display data**, shown inside
the one prompt whose purpose is to be answered truthfully. A client that
prints it raw has handed the model a forgery primitive: a `bash` command
line carrying ANSI sequences can clear the screen, address the cursor
over the client's own words, and repaint a different question above the
approve/deny it is about to be answered with. This section binds any
client, not only the reference TUI; the protocol can state the rule but
cannot enforce it, which is the point of stating it here.

1. **Neutralise, do not strip.** Escape every C0 control (`U+0000`–
   `U+001F`, ESC above all), `U+007F`, every C1 control (`U+0080`–
   `U+009F`), and the bidirectional formatting characters (`U+200E`,
   `U+200F`, `U+202A`–`U+202E`, `U+2066`–`U+2069`) into a visible form.
   Dropping a byte hides that it was there; `npm install left-pad` and
   `npm install\b\b\b\b evil` must not print identically. Invalid
   UTF-8 becomes `U+FFFD`.
2. **Fence it.** The preview is rendered in a block visually separated
   from the client's own words, so nothing inside it can be read as
   chrome.
3. **Bound it on screen.** An unbounded block of model-authored text can
   push the wanted lines and the decision keys out of the viewport,
   which forges a prompt as effectively as a cursor move does.
4. **Always name the tool, and always say the preview is a window.**
   Print `tool` even when it is empty — "this record names no tool" is
   something the person deciding needs to know, and a silently missing
   line reads as an ordinary prompt. Render the truncation marker when
   the preview carries one, and state the size the client holds
   regardless: the approval binds the whole action through `action`,
   while the screen shows at most a 2 KB window of it.

`denial` is present when `status` is `"pending"` (and in snapshots):
`{reason: string, source: "policy"|"execution", enforcement?:
[string], wanted: [Grant]}` — the exact widening that would satisfy the
denial, mirroring `broker/escalation.Denial`. The UI shows `wanted`
verbatim; approvals answer this diff and nothing wider.

Grant (mirrors `broker/policy.Grant`), discriminated by `type`:

- `{type: "writable_root", path}`
- `{type: "readable_root", path}`
- `{type: "network", network: {mode: "off"|"proxy"|"full", allow?:
  [host-glob], proxy?: string}}`
- `{type: "env", name}`
- `{type: "limit", field: "cpu_seconds"|"wall_seconds"|"mem_bytes"|
  "pids"|"fsize_bytes"|"output_bytes", value: int}`
- `{type: "scratch", scratch: {mode: "tmpfs"|"path", path?}}`

Grants echo back byte-comparable on `approve`; the gateway matches them
structurally against `wanted`.

**A refused `approve`.** When the echoed `grants` or `action` are not
the record's own, the reply is `error` with code `stale_approval`, and
its `details` carry the record as the server now holds it:

```json
{"escalation": {"escalation_id": "esc-1", "op": "op-1", "strand": "main",
                "status": "pending", "tool": "bash", "action": "...",
                "preview": "...", "asked": 2, "denial": {...}}}
```

The body under `escalation` is exactly an `escalation` event body. The
command had no effect — the record is untouched and still pending — and
a client re-renders its prompt from these details and asks again. The
check and the commit are made against one read of the record, at the
register seq that read saw, so a claim landing in between loses the
commit rather than passing unseen.

### `strand_result`

`{strand, op, status: "done"|"aborted"|"failed", error?: {code,
message}}` — the strand's operation settled terminally.

### `error`

`{code, message, details?}` — with `reply_to`: the command failed; the
command had no effect. Without `reply_to`: a connection-scoped fault.
Defined codes: `bad_request`, `unknown_session`, `unknown_strand`,
`unknown_escalation`, `not_pending`, `stale_approval`, `conflict`,
`unsupported`, `internal`. Open set; clients display unknown codes.

## Open questions for the gateway

The fixtures pin everything above; these are the known gaps this
document does not yet decide.

1. **Local auth transport** — unix-socket peer credentials imply a
   `ws+unix` dial path; the TUI currently dials TCP only. Decide the
   local endpoint shape.
2. **`set_config` keys** — answered above (the "Command bodies" entry
   is normative): `queue_mode`, `tool_execution`, `model_name`,
   `model`, `thinking_level`, `active_tools`. The set stays
   gateway-extensible; the TUI still passes an opaque object. Still
   open within this item: per-role switching (`model_name` moves a
   strand's — or every strand's — model, not one role's chain).
3. **Event seq durability** — catch_up across gateway restarts
   requires the seq assignment to be rebuildable from `scan_*`; confirm
   whether entry/usage events reuse storage seqs or a materialized
   gateway stream (this doc assumes the latter, one unified stream).
4. **Transcript paging** — snapshots carry a recent-entry window only;
   a transcript-browser client needs a way to pull older entries
   (candidate: `catch_up` semantics over entry storage seqs, or a new
   command in v2).
5. **`strand_result` scope** — emitted for run operations; whether
   navigation/compaction also emit one (or only `op_transition`
   `done`) is open. The fake emits it for runs only.
6. **`follow_up` on an idle strand** — queue-or-refuse is open; the
   fake appends it like a prompt.
7. **`escalation` `consumed`** — assumed broadcast after the single
   re-execution begins; confirm timing against the broker's durable
   event order.
