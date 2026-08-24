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
| `steer`        | `entry`                                    |
| `follow_up`    | `entry`                                    |
| `abort`        | `op_transition` (phase `cancel_requested`) |
| `approve`      | `escalation` (status `approved`)           |
| `deny`         | `escalation` (status `rejected`)           |
| `fork`         | `snapshot` (mode `strands`)                |
| `create_strand`| `snapshot` (mode `strands`)                |
| `navigate`     | `snapshot` (mode `strands`)                |
| `compact`      | `op_transition` (phase `compacting`)       |
| `models`       | `snapshot` (mode `models`)                 |
| `set_config`   | `snapshot` (mode `config`)                 |

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
- `steer` `{strand, text}` — inject into the live run (picked up at the
  next checkpoint). Refused with `conflict` when idle.
- `follow_up` `{strand, text}` — queue a turn to run after the live op
  settles.
- `abort` `{strand}` — cancel the strand's live op.
- `approve` `{escalation_id: string, grants?: [Grant]}` — `grants` must
  be a subset of the denial's `wanted` (partial approval narrows the
  re-execution); absent means everything wanted. Wider grants are
  refused (`bad_request`); non-pending escalations refuse with
  `not_pending`.
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
"pending"|"approved"|"rejected"|"consumed", denial?}`

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

### `strand_result`

`{strand, op, status: "done"|"aborted"|"failed", error?: {code,
message}}` — the strand's operation settled terminally.

### `error`

`{code, message, details?}` — with `reply_to`: the command failed; the
command had no effect. Without `reply_to`: a connection-scoped fault.
Defined codes: `bad_request`, `unknown_session`, `unknown_strand`,
`unknown_escalation`, `not_pending`, `conflict`, `unsupported`,
`internal`. Open set; clients display unknown codes.

## Open questions for the gateway

The fixtures pin everything above; these are the known gaps this
document does not yet decide.

1. **Local auth transport** — unix-socket peer credentials imply a
   `ws+unix` dial path; the TUI currently dials TCP only. Decide the
   local endpoint shape.
2. **Rich user turns** — `prompt`/`steer`/`follow_up` carry `text`
   only. Images (core codec `UserImage`) need an additive optional
   `blocks` field.
3. **`set_config` keys** — answered above (the "Command bodies" entry
   is normative): `queue_mode`, `tool_execution`, `model_name`,
   `model`, `thinking_level`, `active_tools`. The set stays
   gateway-extensible; the TUI still passes an opaque object. Still
   open within this item: per-role switching (`model_name` moves a
   strand's — or every strand's — model, not one role's chain).
4. **Event seq durability** — catch_up across gateway restarts
   requires the seq assignment to be rebuildable from `scan_*`; confirm
   whether entry/usage events reuse storage seqs or a materialized
   gateway stream (this doc assumes the latter, one unified stream).
5. **Transcript paging** — snapshots carry a recent-entry window only;
   a transcript-browser client needs a way to pull older entries
   (candidate: `catch_up` semantics over entry storage seqs, or a new
   command in v2).
6. **`strand_result` scope** — emitted for run operations; whether
   navigation/compaction also emit one (or only `op_transition`
   `done`) is open. The fake emits it for runs only.
7. **`follow_up` on an idle strand** — queue-or-refuse is open; the
   fake appends it like a prompt.
8. **`escalation` `consumed`** — assumed broadcast after the single
   re-execution begins; confirm timing against the broker's durable
   event order.
