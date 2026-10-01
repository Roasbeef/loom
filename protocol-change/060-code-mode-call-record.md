# protocol-change/060 — a per-call record for code-mode programs

**Status**: ACCEPTED 2026-10-01 (PR #673); slices 1 to 3 and the terminal
half of slice 4 implemented, the web Trace tab and the live feed (slice 5)
not yet · proposed 2026-09-30 · **Affects**: the `details` object of the
`code_mode` tool result (an open JSON value, not a Part 1 interface);
`codemode/satellite`'s `Run`; `codemode/codemode`'s `Execution`;
`tools/codemode`'s `Execution`; `session_view` (a new fold) · **Raised by**:
issues #656 and #672 · **Owner ruling**: 2026-09-30, #672: the call record
and per-call timing land together as one protocol change.

## Problem

A client cannot tell what a `code_mode` program did. It can show the
program's source, because the call's `program` argument holds it
(`packages/session_view/src/session_view/transcript_lines.gleam:2371`), and
its final value. It cannot show how many capability calls the program made,
which failed, in what order, or how long each took.

The data is not on the page, and not in the store either:

- The result's `details` carry the value, or the message and details of a
  controlled failure, plus `status`, `manifest_hash` and `sandbox`
  (`packages/tools/src/tools/codemode.gleam:1668` `ran_outcome`; `:1336`
  `execution_value` serves the background path). The `run_failed` variant
  carries `kind`, `detail` and `sandbox` (`:1619`).
- Capability calls are serviced inside the satellite host actor, which
  forwards each to the broker or answers it in the harness
  (`packages/codemode/src/codemode/satellite.gleam:980` `handle_cap_call`,
  `:1032` `route_cap_call`, `:1090` `dispatch_cap_call`). No transcript entry
  is written for a call. The tool is `replay: tool.Never`
  (`tools/codemode.gleam:627`) because each call is an effect with nothing
  to reconcile onto, and the result is one `ToolOutcome` per execution
  (`tools/codemode.gleam:1370` comment on `render`).
- The bus carries a running call's output tail (`Outputs`,
  `docs/architecture/events.md:84`, `protocol-change/031`). It carries
  nothing per capability call.

Issue #656 planned step one, an untimed call list "drawn from what the page
already receives", and step two, per-call times as a protocol change.
Step one's premise is wrong: there is no call list to draw. The two steps
are one change, and this document is that change.

## Display the record must support

For the terminal (owner's choice) and the web Trace tab:

1. A titled code-mode block showing a fragment of the program source.
2. A summary line: the call count and the number of failures.
3. An expandable list of calls. Each row has the capability name, a short
   argument summary, a status (ok, or failed with an error class), and a
   start time and duration.

## Decision

### Where the record originates

The record is made by the satellite host actor, the trusted harness-side
end of the capability channel. It already sees every call, in order: it
checks the token, routes, admits or refuses, and later emits the settlement
(`satellite.gleam:980`, `:1074` `admit_cap_call`, `:891` `handle_cap_done`,
`:1416` `emit`). It already owns an injected `Clock` that reads Unix
milliseconds (`satellite.gleam:721` `State.clock`;
`packages/core/src/core/clock.gleam`). Rule Zero holds because nothing in
the record is read from the satellite beyond what the host already decodes
to route the call: the capability name and the arguments of an
authenticated `cap_call`. The status and error class are the host's own
`CapOutcome` for that call. The satellite's terminal `outcome` frame is not
consulted, so a program cannot write, edit or suppress a record by what it
returns.

A call that fails the token check is not recorded
(`satellite.gleam:1006`). It is not a call of this execution.

The frame `id` is chosen by the satellite, so it is untrusted.
`dispatch_cap_call` inserts it into `state.inflight` without checking for a
live entry (`satellite.gleam:1097`), and a program that reused an `id` would
overwrite the first call's entry and have the second settlement finalise the
wrong record. The host therefore refuses a `cap_call` whose `id` is already
in flight, after the token check, as a channel fault
(`FrameDone(state, Error(ChannelFaulted("duplicate cap_call id")))`, the
form used at `:956` and `:1016`). The execution ends as a failed run. An
honest cap runtime allocates each `id` once, so this costs nothing in
practice, and it makes the record's finalisation unambiguous without a second
key. An `id` whose call has settled may be reused.

### The record

`State` gains a `calls: CallLog`. For each authenticated `cap_call` the host
appends one `CallRecord` at admission or refusal and finalises it at
settlement.

```gleam
pub type CallRecord {
  CallRecord(
    cap: String,           // capability name, bounded and sanitised
    args: Option(String),  // redacted summary, or None
    status: CallStatus,
    error: Option(String), // the CapErr code, never its message
    start_ms: Int,         // offset from the execution start
    duration_ms: Int,      // end minus start, never negative
  )
}

pub type CallStatus { CallOk CallFailed CallCancelled CallUnsettled }

pub type CallLog {
  CallLog(
    started_unix_ms: Int,   // the execution's own zero
    elapsed_ms: Int,        // execution start to settlement
    total: Int, failed: Int, cancelled: Int, unsettled: Int,
    items: List(CallRecord) // the first max_call_records, in admission order
  )
}
```

The types live in `packages/tools` (a new `tools/call_record` module),
because `codemode` depends on `tools` and the result is rendered there
(`packages/codemode/gleam.toml:9`). `session_view` decodes the JSON itself,
as it does for every other tool result (below).

Statuses:

- `CallOk`: the settlement was `CapOk`.
- `CallFailed`: the settlement was `CapErr`, or the host refused the call
  before dispatch (router denial, admission ceiling, pooled cap;
  `satellite.gleam:1032`, `:1124`, `:1155`). Refused calls have
  `duration_ms == 0`.
- `CallCancelled`: the satellite sent `Cancel` for the call before it
  settled, and the call settled before the execution ended. A cancelled call
  still open at the end of the execution is recorded as `CallUnsettled` (`satellite.gleam:1317` `handle_cancel`).
- `CallUnsettled`: the call was still in flight when the execution ended,
  by program return, wall deadline or satellite death. Its end is the
  settlement instant of the execution.

`error` is the `CapErr.code`: `policy`, `budget`, `aborted`,
`unsupported_cap`, `invalid_argument`, `exec_failed`, `unsettled`,
`cap_failed`, the broker refusal codes `invalid_policy`, `mint`, `no_helper`
and `broker`, and the per-capability ceiling codes (`satellite.gleam:1157`,
`:1305`, `:1312`, `:1548`, `:1559`, `:1665`, `:1828`-`:1851`). All are in
`[a-z0-9_.]`. The code is a short token chosen by the host. The message is
not recorded: it can carry paths and output text from the effect.

`cap` is the name from the frame. It is limited to 64 bytes and to
`[a-z0-9_.]`; any other character is replaced with `_`. A name that is
refused as `unsupported_cap` is still recorded under the sanitised form.

### No parent field

The call list is flat and ordered by admission. There is no parent link.
The host cannot learn nesting without trusting the satellite to say which
call a call belongs to, and a claim like that would be program output
(Rule Zero). Concurrency is visible from the overlap of
`[start_ms, start_ms + duration_ms)`, which is also what the Trace tab
draws. The "tree" in the display is the program as the root and the calls
as its children, in admission order. If the owner wants nesting later, it can
be added as an explicitly program-asserted display hint and labelled as
such. It is not added here.

### How it reaches the transcript and the client

**Settled record, in the tool result's `details`, foreground only.** When
the host settles,
`Run` carries the `CallLog`:

```gleam
pub type Run { Run(outcome: ..., node: Report, calls: CallLog) }
```

`codemode.Execution` (`packages/codemode/src/codemode/codemode.gleam:64`)
gains `calls`, set from `Run` in `run_and_report` (`:231`) and an empty
log for vet and compile failures. `client/codemode.translate`
(`packages/client/src/client/codemode.gleam:3288`) carries it into
`tools/codemode.Execution` (`:406`). The record belongs on `Execution`,
beside `enforcement`, and not on `Ran`, because a deadline or a dead
satellite is exactly when the calls made so far matter, and those
settle as `RunFailed` (`tools/codemode.gleam:1619`). It is attached as a
`calls` key through `tool.with_details` (`tools/tool.gleam:706`) in
`ran_outcome` and `run_failed_outcome`, which covers the foreground path.
The vet and compile results have no `calls` key.

The record is deliberately not added to `execution_value`. On the background
path that value is stored as `Finished(result)`
(`packages/client/src/client/async_codemode.gleam:113`), and the model reads
it: `completion_text` quotes `json.to_string(result)`, clipped at 2,048 bytes,
into a `[loom]` message (`packages/client/src/client/async_runs.gleam:1014`
to `:1030`), and `check` and `join` return the whole result. A `calls` key
there would spend the notice's clip and add tens of KiB of context to every
`check`. Background executions therefore carry no call record in v1. Carrying
one for them, in a field the model does not read, is future work and not part
of this change.

Provider adapters never project `details`. They ignore the field when they
encode a tool result for the model
(`packages/provider/src/provider/adapter/anthropic.gleam:201` to `:209`,
`gemini.gleam:318`, `openai.gleam:278`,
`internal/responses_request.gleam:112`), so by default the record adds no
context tokens. Two other readers do receive the stored entry whole,
`details` included: `history read` (`packages/tools/src/tools/history.gleam`)
and the `context` and `tool_result` hook programs of installed extensions
(`packages/client/src/client/extension/hooks.gleam`). The record is built to
be safe in both places: it holds codes, redacted summaries and counts only.
Because `details` is stored in the entry, the record is
durable and is part of what a client receives when it reads the transcript:
a reconnecting terminal or a fresh web page sees it with no live feed.

**Wire shape** (JSON, added key; encoding in `tools`, decoding in
`session_view`):

```text
"calls": {
  "started_unix_ms": 1790000000000,
  "elapsed_ms": 1840,
  "total": 7, "failed": 1, "cancelled": 0, "unsettled": 0,
  "items": [
    {"cap": "fs.read", "args": "src/app.gleam", "status": "ok",
     "start_ms": 12, "duration_ms": 3},
    {"cap": "proc.run", "args": "gleam +2 args", "status": "failed",
     "error": "exec_failed", "start_ms": 20, "duration_ms": 1511}
  ]
}
```

`args` and `error` are omitted when absent. A call's position in `items` is
its admission order, and `total - length(items)` is the number of calls not
itemised, so neither is a field.

**Rejected: a durable entry per call.** Each call would be a store write
from the satellite host actor, which has no storage dependency, and the
entry kinds are a frozen interface (spec Part 1). A program with thousands
of calls would put thousands of rows into a store that projections and
compaction scan. The record is display and audit data about one tool
result, and one result already has a place for it.

**Cost of settling only.** The record lives in the host actor until the
program settles. If the harness crashes mid-execution, the tool synthesises
its interrupted result (`replay: tool.Never`, `tools/codemode.gleam:567`)
and the calls so far are lost with the host. This is accepted: the effects
themselves are not replayed either, and a crash is rare.

**Live calls while a program runs.** This proposal does not include them.
The need is real, because a long program shows "awaiting result" with no
progress. The cost is also real. It would be a second display-only feed on
the `Outputs` precedent (`protocol-change/031`, `docs/architecture/events.md:84`):
a new bus topic and a pushed frame, a new observer threaded from the tool
context into the host as `observe_output` is
(`packages/tools/src/tools/tool.gleam:274`), and a coalescing timer in the
host so that a program making thousands of calls does not publish thousands
of events. Each event would carry the complete bounded state (counts and
the last few records), not a delta, so that a lost event costs nothing, as
for `ToolOutput`. It is affordable per event (a `pg` lookup and a send) and
it is not needed for the settled display. It is slice 5 below and a
separate decision for the owner.

### Bounds

| Bound | Value | Marker |
|---|---|---|
| Retained records | 128, the first 128 admitted | `total` exceeds the item count |
| Counters | exact for every call, retained or not | none |
| `args` summary | 96 bytes including the marker, cut on a UTF-8 boundary | ends with `…` (U+2026, 3 bytes) |
| `cap` | 64 bytes, `[a-z0-9_.]` | other characters become `_` |
| `error` | 48 bytes, same character set | cut without a marker |

The truncation marker counts toward the 96 bytes, so a cut summary holds at
most 93 bytes of content. Worst case is about 300 to 400 bytes per item (a
64-byte `cap`, a 96-byte `args` that JSON escaping can double, a 48-byte
`error`, and keys and integers), so about 40 to 50 KiB for 128 items per
program result. Nothing gates the size of `details` today (the tool bounds
only the text, and the presentation limit is 4 MiB), so this is a cost, not
a failure mode. A program that makes 5,000 calls has `total: 5000`, 128
items, and exact `failed`. Failures past the 128th are counted and not
itemised. Keeping failures preferentially would need a second retention
rule, and the count already says they exist.

The host holds at most 128 records plus counters, so memory is bounded
whatever the program does. The record adds one list insert per call.

### Redaction

The summary is built by the host from the decoded arguments, by an
allowlist keyed on capability name. A capability not on the list has no
summary (`args` absent). This covers MCP servers and extension capabilities
by default, because their argument shapes are not known to the host.

| Capability | Summary |
|---|---|
| `fs.read`, `fs.write`, `fs.edit`, `fs.list` | the `path` argument only |
| `proc.run` | basename of `argv[0]`, then ` +N args`; `cwd`, `env` and `stdin` are not read |
| `job.start` | the first whitespace-separated token of `command`, then nothing |
| `job.poll`, `job.kill`, `job.send` | the `job_id` argument only |
| `kv.get`, `kv.set`, `kv.delete` | the `key` argument only |
| everything else | none |

Never summarised: file bodies and edit text, `stdin`, `env`, the rest of
`argv`, HTTP headers and bodies, MCP tool arguments, message bodies, and
anything in `CapErr.message`. The capability token is a separate field of
the frame (`framing.CapCall(token:, cap:, args:, ...)`,
`satellite.gleam:962`) and is not part of `args`, so the record cannot
contain it. Summaries have control characters (below U+0020 and U+007F)
removed before the length cut. Clients draw them as text, never as markup
or terminal control sequences, which matters because `cap` and the summary
derive from program-controlled strings.

Reducing `proc.run` to the executable and an argument count is deliberate:
secrets travel as command-line arguments (`curl -H ...`, `--token=...`)
far more often than as the program name. `job.start` has no `argv`. Its
argument is a `command` shell string (`packages/cap/src/cap/job.gleam:485`
to `:492`), which can hold the same secrets inline, so only its first token is
kept. The keys above are the ones the `cap` encoders write: `job_id`, `path`
and `key` for the single-value rows, and `argv`, `cwd`, `env` and `stdin`
for `proc.run`. The summariser reads them from the decoded `args` map, and a
call whose `args` lack the expected key has no summary.

### Timing

The clock is the host's injected `Clock`, which reads Unix milliseconds
(`core/clock.gleam`). The monotonic clock is negative on the BEAM and must
not reach the wire, so it is not used. The record carries one absolute
instant, `started_unix_ms`, taken when the host starts, and every call
carries offsets in whole milliseconds from it:

- `start_ms` is the clock read at admission or refusal minus
  `started_unix_ms`.
- `duration_ms` is the clock read at settlement minus the call's start.
- Both are clamped at zero, because a wall clock can step backwards. A
  call shorter than a millisecond has `duration_ms: 0`.
- `elapsed_ms` is the settlement of the execution minus
  `started_unix_ms`, so a client can scale bars to the whole program.

Offsets keep the numbers small and make them comparable across a host
whose wall clock moves between records. Tests use `clock.stepping`, so the
numbers are deterministic.

### Encoding, total decoders and back-compatibility

Nothing is removed or renamed. Results written before this change have no
`calls` key, and they decode and render as they do today. The key is read
by `session_view`'s fold with a total decoder that returns `Result`:

- Absent key: no record. The renderer shows what it shows now.
- Present and well-formed: a `CallLog`.
- Present and malformed (wrong type, missing field, unknown `status`,
  negative offset, `items` longer than `total`): a decode error. The
  renderer treats it as no record. It is not an error to the user, because
  a transcript must never fail to render over a display field.
- Unknown extra keys in `calls` or in an item are ignored, so a later
  version can add fields. A later change that cannot be read by this
  decoder takes a new key rather than a version number.

No frame version, database schema or capability signature changes. The
cap-channel protocol, `broker/framing`, and the generated prelude are
untouched, so `make prelude-check` is unaffected.

Two source-level changes follow: `satellite.Run` and
`codemode.Execution` gain a field, and every construction site must set
it. Pattern matches that name all fields will fail to compile until they
are updated, which is the intended check.

### Consumers

A new `session_view/call_tree` module, pure and portable (lint R6 applies),
owns the decoder and the fold:

```gleam
pub fn read(details: JsonValue) -> Option(CallLog)          // total
pub fn summary(log: CallLog) -> String                      // "7 calls · 1 failed"
```

Both hosts call it, so the numbers and wording cannot differ. Rows and bars
are host display shapes, so each host computes its own from the `CallLog`
until both exist and the shared part is known.

- **Terminal.** `code_mode_result_lines` (`transcript_lines.gleam:2808`)
  prints the summary line beside the status, and the expanded form prints
  one row per call under the program block. It is reached today only when
  `is_error` is false (`:2560`); an error result takes the generic
  `_, True, _` failure arm (`:2573`). A program that fails, or hits its
  deadline, is where the record matters most, so the match is widened to
  an `is_error: True` `code_mode` result that carries a readable `calls`
  record. An error result with no record renders exactly as it does now.
  Rows reuse the existing bounded expansion rule
  (`view/expansion.capped`): at most the retained 128, cut with a fixed
  line.
- **Web Trace tab (#656).** The tab reads `call_tree.read` on the latest
  program's result and draws timing bars computed from the offsets. There is
  no untimed first step. The design note's §6.3 premise (the page "already receives" the calls,
  `docs/design-notes/web-design.md:700-730`, and the tab row at `:600`)
  is corrected by this proposal. Rows are text nodes, and the status class
  comes from the closed `CallStatus`, never from a string built from the
  record.

## What was considered

**Recording in the broker.** The broker sees every effect that goes through
`clear_call`, but harness-served calls (`ServedHere`: `fs.read`, `kv.*`,
`report.emit`, the orchestration calls, `satellite.gleam:288`) never reach
it, and refusals before dispatch do not either. The host actor is the one
place that sees all of them.

**Recording in the satellite.** The cap runtime could log each call and
ship the log in the `outcome` frame. That is program output. A hostile
`.beam` that slipped vetting can write any log it likes, and an honest one
would lose its log when it is killed at the deadline.

**A durable entry kind per call**, and **a live feed only.** Rejected above:
the first is a frozen-interface change and a store-growth problem, and the
second leaves a reconnecting client with nothing.

**Keeping every failure first.** A second retention rule for little gain,
since `failed` is exact.

**Per-call messages.** More useful to a human than a code, but a message
carries paths, output text and arguments that the allowlist deliberately does
not summarise, and the allowlist is the only place the host decides what is
safe to show. The code is the class the display needs.

## Cost and limits

- A host-actor field and a record per call. Memory is bounded at 128
  records, CPU is one clock read pair and one summary per call.
- Up to about 40 to 50 KiB added to a stored foreground tool result, for
  programs with 128 or more calls. No model tokens.
- Background executions carry no record in v1.
- A source-level migration for `satellite.Run` and `codemode.Execution`
  constructors, and the test fixtures that build them.
- Settled-only: the record of a program that the harness loses mid-run is
  lost, and a running program shows no calls until it ends.
- Wall-clock timing has millisecond resolution and can show zero for fast
  calls.
- Persistent-satellite hook invocations (`satellite.invoke`,
  `protocol-change/012`) are not recorded. They are not the `code_mode`
  tool.
- Programs run by the orchestration seam record the `agent_spawn` call
  itself, not the child's own calls. A child strand has its own
  transcript.

## Tests and gates

- **Host unit tests** (`packages/codemode`), with a fake router and
  `clock.stepping`: admission order; ok, failed, refused-before-dispatch,
  cancelled and unsettled statuses; overlapping calls; calls refused by a
  ceiling or the pooled cap; a bad token records nothing; the retention cap
  (`total` above 128, item count 128, counters exact); a `cap_call` that
  reuses a live `id` faults the channel, while reuse after settlement is
  accepted; deadline and satellite-death settlement keep the calls so far.
- **Redaction tests**: the `args` for each case are built with the `cap`
  package's own encoders (`cap/fs`, `cap/proc`, `cap/job`, `cap/kv`, through
  `wire.args`), never as hand-built maps, so a key mismatch such as `job`
  against `job_id`, or `argv` against `command`, fails here and not as a
  silent `args: None` in production. For each allowlist row the summary is
  exactly the stated field, and `job.start` keeps only the first token of
  `command`; `env`, `stdin`, bodies, extra `argv` and the token never
  appear anywhere in the encoded record; control characters are removed;
  the cut falls on a UTF-8 boundary, ends with `…`, and totals at most 96
  bytes; an unlisted
  capability has no `args`.
- **Codec tests**: a golden JSON fixture shared by the `tools` encoder and
  the `session_view` decoder, so the two cannot drift. Old results with no
  `calls` decode and render byte-for-byte as before, including old
  `is_error: True` results; malformed variants
  decode to no record; a property test that `read` is total over arbitrary
  JSON.
- **Render tests**: the terminal summary and expanded rows, with the
  `is_error: True` and `run_failed` cases.
- **Jailed end to end**: `make e2e-codemode` runs a real program and asserts
  the stored result's `calls` match the program's known calls, including a
  failed one and at least one `args` summary.
- Gates: `make check` (R6 on `session_view`, R10 for comments), `make
  doc-check` (the code-mode, events and package docs gain the new type), and
  a signoff run.

## Implementation slices, in order

1. `tools/call_record`: the types, the bounds, the summary allowlist and
   the encoder, with the golden fixture. Pure.
2. `session_view/call_tree`: the total decoder and `summary`, tested
   against the same fixture, including old and malformed results.
3. The host: `CallLog` in `satellite.State`, `Run.calls`, threaded through
   `codemode.Execution`, `client/codemode.translate`, `tools/codemode.Execution`
   and the two foreground result writers, plus the duplicate-`id` refusal. The host and redaction tests, and the
   jailed end-to-end.
4. The terminal block, then the web Trace tab with timing bars. Terminal
   first, since the owner chose that display.
5. Optional, separately decided: the live feed.

Docs updated with slice 3: `docs/architecture/code-mode.md`,
`docs/architecture/events.md` (only if slice 5 lands),
`packages/codemode/CLAUDE.md`, `packages/session_view/CLAUDE.md`,
`docs/next.md` item 2 and `docs/design-notes/web-design.md` §6.3.

## Open questions for the owner

1. Is settled-only acceptable for the first release, with the live feed
   deferred, or should the feed ship in the same change?
2. Is a flat list enough, with no parent link?
3. Are 128 records and 96-byte summaries the right bounds, and is the
   `proc.run` summary (executable and argument count) the right level of
   redaction?
4. Should the capability allowlist grow to MCP calls (tool name only), or
   stay default-deny?
5. Should background executions get a call record later, in a field the model
   does not read, or stay without one?
6. Bidirectional override characters (U+202A to U+202E, U+2066 to U+2069)
   survive the control-character strip and could reorder a drawn summary.
   Stripping them is a follow-up.
