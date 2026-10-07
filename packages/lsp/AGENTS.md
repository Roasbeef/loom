# lsp

## Purpose

Loom's client side of the Language Server Protocol (issue #25, ADR-015):
the wire layer that lets the harness ask a jailed language server for a
definition, references, hover, a file's outline, a rename and one level
of call hierarchy, and hear its diagnostics after an edit. It is
language-neutral on purpose — the server is each language's only oracle
for types, and Loom's agent works on Go, Rust and anything else a
workspace holds.

The package is the **protocol and the vocabulary**, not the wiring.
`packages/codemode/src/codemode/lsp_host` owns project roots, document reads,
server leases, jailed transport and the `Door` closures. `packages/client`
loads `[lsp.<name>]` from `loom.toml` and checks approved profiles; shared
landing and write diagnostics are `packages/tools`, and the `lsp.*`
capabilities are `packages/codemode`. I/O is confined to
the client actor and the consumed channel owner, and nothing here imports `broker` (ADR-015 §2).

The modules, in dependency order:

- `lsp/range` — the server's coordinates (zero-based, UTF-16 units).
- `lsp/query` — the harness's vocabulary and the `Door` contract every
  surface calls through. Types only.
- `lsp/jsonrpc` — the JSON-RPC 2.0 envelope over `core/json`: request,
  notification, response and error_response encoders, total `decode`, and
  additive `decode_profile` selecting the core JSON allocation profile.
  Ported from the codec `packages/mcp` carried before #669.
- `lsp/transport` — `Transport(ChannelTransport | ConsumedChannelTransport)`,
  ordinary `Connection` and `TransportEvent`; both variants are local seams.
- `lsp/internal/consumed_channel` — the original actor-owned writer window,
  two fixed output-credit slots, opaque `Sink` and one-shot `Grant`.
- `lsp/framing` — the pure `Content-Length` framer, over bytes.
- `lsp/protocol` — total codecs for every structure consumed, capability
  gating, answers to server requests, and `file://` URI conversion.
- `lsp/text` (added by a sibling slice) — UTF-16 ↔ codepoint conversion
  and pure text-edit application.
- `lsp/client` — the client actor, a `weft/state_machine` over
  `lsp/transport.Transport`: one process owning one language server,
  its handshake, gated requests, document sync, the diagnostics store and
  settlement, and the stop sequence. Its module doc carries the phase
  transition table and a `## Flow` sketch; read those before the handlers.

Each module over about 300 lines (`client`, `protocol`, `text`, `framing`)
opens with a `## Flow` section naming the functions of its main path in
order. `protocol` is laid out in sections, one per codec family, each
section a family's types, its public decoder, then its private helpers;
the shared decoding helpers close the file.

## Key Types

- `lsp/range.{Position, Range, TextEdit}` — positions exactly as the
  server states them. Held only inside this package; converted once, in
  `lsp/text`, against the text they were computed on.
- `lsp/query.{SymbolQuery, Site, QueryError, Served, Warmth, Hover,
  SymbolEntry, CallDirection, Call, Severity, Diagnostic, Diagnostics,
  FileEdit, Landing, RenameReport, Door}` — the cross-slice contract.
  The model addresses a symbol by name (optionally a path and a 1-based
  line), never a UTF-16 position. `Diagnostics` is `Settled | Unsettled`,
  and an unsettled block is never reported as clean code.
- `lsp/framing.{Buffer, new, push, frame, FramingFault, max_frame_bytes,
  max_header_bytes}` — `push(Buffer, BitArray)` returns completed UTF-8
  bodies in order. `FramingFault` is `HeaderTooLong | FrameTooLong |
  MissingContentLength | DuplicateContentLength | BadContentLength |
  MalformedHeader | BodyNotUtf8`.
- `lsp/protocol.{ServerCapabilities, Provided, RenameSupport, SyncKind,
  OpenClose, Feature, supports, InitializeResult}` — what a server
  advertised, each provider a two-variant type; `supports` is the gate
  every request passes.
- `lsp/protocol.{Location, HoverResult, DocumentSymbols(Hierarchical |
  Flat), DocumentSymbol, SymbolInformation, WorkspaceEdit, DocumentEdits,
  WorkspaceEditFault(EditMalformed | ResourceOperationRefused),
  PrepareRename(CanRename | CanRenameDefault | CannotRename),
  CallHierarchyItem, IncomingCall, OutgoingCall, PublishDiagnostics,
  ServerDiagnostic, ServerNotification(Published | Progressed | ServerFailure | Ignored |
  Unrecognised), ProgressToken(IntToken | StringToken),
  WorkDoneProgress(ProgressBegin | ProgressReport | ProgressEnd),
  WorkspaceFolder, ProtocolFault, UriFault}` — decoded answers, one type
  per question whatever dialect the server used.
- `lsp/protocol.{answer_server_request, classify_notification,
  decode_work_done_progress, path_to_uri, uri_to_path, symbol_kind_name}`
  — pure policy the actor sends without deciding anything.
- `lsp/client.{Client, Options, options, start, stop, pid,
  request_deadline, capabilities, feature_method}` — the opaque handle
  and its lifecycle. `start(Transport, Options) -> Result(Client,
  StartError)` accepts either trusted local channel variant;
  `StartError` is `BadRoot | TransportRefused | HandshakeFailed(
  RequestError) | EncodingUnsupported`. `stop(client, grace_ms) ->
  StopReport` is `Graceful | Forced | AlreadyGone | Unconfirmed`.
- `lsp/client.{request, definition, references, hover, document_symbol,
  prepare_rename, rename, prepare_call_hierarchy, incoming_calls,
  outgoing_calls}` — gated requests taking absolute paths and protocol
  `Position`s, answering `protocol`'s decoded types. `RequestError` is
  `Unsupported(Feature) | ServerError(code, message) | TimedOut(after_ms)
  | Unavailable(reason) | Malformed(reason) | InvalidPath(path) |
  EditRefused(kind, uri)`.
- `lsp/client.{DocOp(Open | Change | Close), sync, synced_text,
  open_paths}` — full-text document sync computed by the caller, and the
  exact last text sent (the rename base).
- `lsp/client.{settle, Settlement, SettleOutcome(Settled |
  DeadlineExpired), diagnostics}` — ADR-015 §3's two-rule settlement and
  the latest-publication store, both in the server's coordinates
  (`protocol.ServerDiagnostic`); converting to `query.Diagnostic` is the
  manager's, which holds the text.
- `lsp/client.{ready, Readiness(Quiet | StillBusy(titles)),
  max_progress_tokens}` — `ready(client, quiet_ms:, deadline_ms:) ->
  Result(Readiness, RequestError)`: `Quiet` once no work-done progress
  token has been active for a continuous `quiet_ms` (measured from the
  later of the call and the last token's end), `StillBusy` with the
  active titles, oldest first, when the deadline lapses first. The
  manager asks it only for the query that started a server; warm queries
  never wait.

## Relationships

- **Depends on**: `gleam_stdlib`; `core`, for the JSON value type with its
  total parser and serializer (`core/json`) and the corruption report
  (`core/corruption`). It depends on neither `mcp` nor `gleam_mcp`: the
  JSON-RPC envelope and the transport seam are `lsp/jsonrpc` and
  `lsp/transport`, so the MCP SDK's HTTP stack stays out of the manifest of
  every package that imports `lsp` (#678, ADR-015's third addendum). The
  monitored try-call is `lsp/call`, which this package keeps itself
  because `gleam_mcp` carries it only privately inside its own client.
  `gleam_erlang`, `gleam_otp` and `weft` are declared for the client actor; `range`, `query`, `framing`,
  `protocol` and `text` import none of them and are pure functions of
  their arguments. The package as a whole is impure and not in the
  portable subset lint R6 gates.
- **Depended on by**: `codemode` (the physical `lsp_host` manager fills
  `query.Door` and `observation.Door`, and builds the production
  `ChannelTransport` over the broker's jailed exec; `lsp.*` capabilities
  call those doors), `client` (profile loading and checks), and `tools`
  (shared rename landing and observed-write diagnostics, over `Door`).
- **FFI**: none, and ADR-015 needs none. The production transport is a
  `lsp/transport.ChannelTransport` over the broker's jailed exec.

## Traffic

- **Actor messages** (`lsp/client.Msg`, opaque): callers send
  `Handshake` (once, from `start`), `Ask(feature, build, deadline_ms,
  reply)`, `Sync(ops, reply)`, `Settle(uris, deadline_ms, reply)`,
  `Ready(quiet_ms, deadline_ms, reply)`, `Read(TextOf | OpenPaths |
  PublishedFor | CapabilitiesOf)` and `Stop(grace_ms, reply)`, every one
  through `lsp/call.try_call`. The transport sends
  `FromTransport(TransportData | TransportClosed)`. The actor sends
  itself `Expire(id)`, `SettleExpired(token)`, `ReadyExpired(token)` and
  `ReadyQuiet(token, epoch)` (per-key `send_after` timers, stale-checked
  against the pending, waiter and readier tables — the per-key deadline
  table `docs/weft.md` keeps hand-rolled; a quiet timer is also stale
  once `quiet_epoch` has moved) and the state timeouts
  `HandshakeExpired`, `GraceExpired`, `RetireExpired`. The owner's DOWN
  arrives as `Abandoned`.
- **Phases**: `Initializing → Serving → ShuttingDown(grace_ms) →
  Retiring(ending, reason)`; the actor exits from `Retiring` on the
  transport's `TransportClosed` (normal after a requested stop, abnormal
  after a fault) or after `retire_ms` without it, and at once, abnormally,
  when the transport closes under `Initializing` or `Serving`.
- **Commits**: none. **Registers**: none.
- **Wire**: LSP base protocol — `Content-Length: <bytes>\r\n\r\n<json>`
  — riding inside the broker's `exec_stdin`/`exec_out` (ADR-015 §1).
  `lsp/framing.frame` is the only place the outbound bytes are shaped.
  Sent: `initialize` (declaring `window.workDoneProgress`),
  `initialized`, `shutdown`, `exit`, `didOpen`,
  full-text `didChange`, `didClose`, `$/cancelRequest`, `definition`,
  `references` (declaration included), `hover`, `documentSymbol`,
  `prepareRename`, `rename`, `prepareCallHierarchy`,
  `callHierarchy/incomingCalls` and `outgoingCalls`, and answers to
  server requests. Consumed: those answers, `publishDiagnostics`,
  `$/progress` (work-done progress, tracked for readiness), and
  `window/logMessage`, `window/showMessage` (error-level messages retained;
  other valid severities ignored).

## Invariants

- **Gate every request on advertised capabilities.** A measured server
  never answered an unadvertised request (ADR-015). `supports` is the
  gate; a `NotProvided` request is refused as `query.Unsupported` and
  never sent.
- **Framing is bounded before it buffers.** The header section is capped
  at 8 KiB; a declared length over 16 MiB is refused when the header is
  parsed, before a body byte is held. A push costs the chunk it carries:
  body chunks are kept unjoined and joined once. A faulted stream is not
  resumable — the transport is dead (ADR-015 §1).
- **Bodies are bytes until they are whole.** The pipe splits characters;
  a body becomes a `String` only once all its bytes arrived, and is
  refused if it is not UTF-8.
- **Every decoder is total and every dialect lands in one type.**
  `Location` / `Location[]` / `LocationLink[]` / `null`; four hover
  shapes; hierarchical or flat symbols; `changes` or `documentChanges`;
  three prepare-rename shapes and `null`. Unknown extra fields are
  ignored; one lying list entry fails the list, naming the index.
- **Servers never write.** `workspace/applyEdit` is answered
  `applied: false`, the initialize request declares `applyEdit: false`
  and no resource operations, and a `WorkspaceEdit` carrying a create,
  rename or delete is `ResourceOperationRefused` — never partly applied.
  Edits land only through the hashline path (ADR-015 §4).
- **Positions are never converted here.** Decoders carry the server's
  UTF-16 coordinates untouched; `lsp/text` is the only converter. A
  negative line or character is refused at decode.
- **Call-hierarchy items are echoed verbatim.** `CallHierarchyItem.raw`
  is what the follow-up requests send, because its `data` is the
  server's own state.
- **An omitted diagnostic severity is an error.** The costly mistake is a
  real problem shown as a hint; a severity outside 1–4 is refused.
- **URIs decode strictly.** `uri_to_path` refuses a bad `%` escape, a
  remote authority, a query or fragment, non-UTF-8 bytes and NUL; it
  never passes a malformed escape through.
- **The actor reads no disk.** Document texts arrive in `sync` from the caller.
  Ordinary writes preserve the cast channel. Consumed writes wait only on
  admission; physical input waits run in the original managed pump. Consumed
  output waits only on the completed local credit task's drain.
- **Both variants are trusted local channels.** Neither transport creates an
  unjailed server. Ordinary `ChannelTransport` preserves the local behavior;
  `ConsumedChannelTransport` selects the checked original window and Registered
  state profile. Native ServerLease validation remains its adapter's job.
- **No caller is ever crashed by the client.** Every exchange is
  `lsp/call.try_call`; a dead or wedged client answers `Unavailable`.
- **Death settles everyone, then is reported.** A transport close, a
  framing fault, a body that is not JSON-RPC or a failed write answers
  every pending caller and settle-waiter `Unavailable(reason)`, closes
  the transport, and ends the actor abnormally. Restart is the manager's.
- **A timed-out request is cancelled and forgotten.** `TimedOut` is
  answered, `$/cancelRequest` sent for the id, and a late answer
  dropped; the actor keeps serving.
- **At most 64 local documents are open**, LRU by last sync: document versions
  come from one counter shared by every document, so the smallest version
  is the least recently synced, and a reopened document never reuses a
  version an old publication carries. `synced_text` is exactly the last
  text sent.
- **The ordinary diagnostics store is bounded**: 512 URIs (the oldest publication
  goes first) and 200 diagnostics per publication.
- **Settlement is ADR-015 §3's two rules, and never a guess.** (a) the
  `documentSymbol` barrier on the first changed URI answered; (b) once the
  server has ever versioned a publication, every changed open document
  has one at a version ≥ its synced version. A server with no
  `documentSymbol` settles only by (b), so an unversioned one never
  settles. The answer collects every URI published since the earliest
  changed document's last sync, plus each changed path's stored
  publication. A lapsed deadline answers `DeadlineExpired` and cancels
  the barrier.

- **Readiness is standard work-done progress, never a per-server key.**
  The actor holds the active tokens (`Data.progress`, token → title and
  arrival order): `begin` adds, `end` removes, a `report` for an unknown
  token adds it under the token's own text, and a malformed `$/progress`
  is dropped. At most `max_progress_tokens` (64) are held, the earliest
  begun evicted first. Every change to the set moves `quiet_epoch`; a
  quiet timer armed while the set was empty answers `Quiet` only if the
  epoch has not moved, and a set that empties re-arms every readier's
  window from that moment (answering a `quiet_ms: 0` readier at once).
  A server that reports no progress is `Quiet` after the window alone.
  `rust-analyzer` answers loading queries with empty results, not
  errors, which is why this exists.

## Deep Docs

- [docs/adr/015-language-servers-as-jailed-leases.md](../../docs/adr/015-language-servers-as-jailed-leases.md)
  — the design ruling: the jail, the package split, settled diagnostics,
  rename through hashline, symbol addressing, and the measured behaviour
  of `gleam lsp` and `gopls` this package's tests replay.
- [packages/mcp/CLAUDE.md](../mcp/CLAUDE.md) — where the MCP runtime went;
  `lsp/jsonrpc` and `lsp/transport` are the cut-down copies of its
  envelope and channel seam that this package keeps for itself.
- [docs/weft.md](../../docs/weft.md) — the monitored try-call gap
  `lsp/call` stands in for.
- [docs/gleam-style.md](../../docs/gleam-style.md) — Part IV §2 (total
  decoders) and §4 (no FFI).
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc
  graph.

## Server-reported analysis failures

The actor retains at most 2048 UTF-8 bytes from an error-level window message.
A server can report a failed project load that way and then answer a semantic
request with null or an empty array; those answers become `Unavailable` with
the retained reason. Diagnostics reads and settlement cannot call that state
clean, including when settlement reaches its deadline. Recovery requires a
nonempty result from the feature's existing typed decoder; empty hover content,
empty rename edits and malformed replies cannot clear the failure. Nonempty
hierarchy replies reach their method-specific decoder while retaining the
failure, because three methods share one capability. Another typed semantic
query must establish recovery. Informational messages do not poison ordinary
misses.
Ordinary channels drop malformed notifications through the existing total decoder;
Registered channels fail before acknowledging them.

## Finite semantic observations

`lsp/observation` carries a separate `Door.collect(Request, Control)` contract.
A request names one configured server and root, at most 16 outline files and
32 explicit reference seeds. Seeds require a path; a missing line resolves
through that file's outline and counts as a protocol request. The batch keeps
outline symbols and reference targets separate, so an outlined symbol never
implies that its references were collected. Raw references have no implicit
container queries. Diagnostics and rename remain on the interactive door.

`lsp/client.observation_state` reads the actor's incarnation token, document
versions and text, active progress, retained failure and change epochs in one
message. The client monitors each semantic request's reply owner. Owner death
removes that pending id and sends `$/cancelRequest`; a late reply is ignored
and the shared server keeps serving. Cancellation is a protocol request, so
it does not prove that a server which ignores cancellation stopped computing.

## Registered consumed channel (protocol 076)

`ConsumedChannelTransport.connect(Sink)` installs one trusted original `Session`
in its window owner. `Session.feed` must return only after the actual native
input credit settles, and `Session.close` must request original cancellation
without waiting on this client's output. The actor checks the actual client PID,
original window subject, stream and current nonce before one-shot consumption.
The sole output-credit worker owns its wait subject; a checked `CreditReady`
message establishes that wait before delivery. Publisher success and the client
consumption reply follow the matching task's `AllDelivered`, preventing a later
close from cancelling an acknowledgment that was merely queued.

Client sends acknowledge admission only. The window reserves each entire framed
logical message before its first physical effect and retains that reservation
until its last feed and managed task drain. It holds at most 16,785,408 bytes and
128 messages, splits feeds at 8192 bytes and owns one pending input credit. Its
30,000 ms weft deadline fences and cancels the original attachment on failure.
The original lifetime allowance is at most 64 MiB and 8192 frames including a
reserved EOF frame; completed writes never replenish it. The conservative local
frame reservation permits 8191 full data feeds, or 67,100,672 bytes. Actual helper
input and producer output limits remain independently enforced by the adapter.

Only this transport selects `core/json.RegisteredLspJson`: 200,000 aggregate
nodes including keys and values, depth 256, existing 16 MiB body and 8192-byte
header bounds. Retained document texts, diagnostic strings/sites and other
metadata/progress each have a separate 4 MiB ceiling. Diagnostics charge URI and
path strings plus 128 bytes per publication and 128 per site. Before retaining
Registered publications, all four diagnostic coordinates must be LSP `uinteger`
values (0 through 2,147,483,647), and an optional publication version must be an
LSP signed `integer` (-2,147,483,648 through 2,147,483,647). This bounds the numeric
representation covered by those fixed charges. The shared decoder and ordinary
channel retain their previous arbitrary-precision integer behavior. These ranges
come from the [LSP base types](https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/_specifications/lsp/3.17/specification.md),
[Position](https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/_specifications/lsp/3.17/types/position.md)
and [PublishDiagnostics](https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/_specifications/lsp/3.17/language/publishDiagnostics.md). Metadata charges
document URI/path plus 128, progress token/title plus 128, settlement waiter plus
128 and target URI plus 64, pending/readier plus 128, stopper plus 64 and workspace
folder URI/name plus 64; retained configuration/failure/encoding strings are also
charged. These conservative logical charges are not heap, RSS or disk accounting.

Registered state preserves 64 documents, 512 diagnostic URIs, 200 diagnostics per
URI and 64 progress tokens, and permits at most 128 pending protocol requests.
Prospective document, diagnostic, progress and waiter state is checked before its
write or clean settlement/readiness effect. Overflow fails the protocol, retaining
the reason; it does not evict or truncate registered evidence. Ordinary local
channels keep their prior LRU, truncation, malformed-notification and parser
behavior.

Stdout is acknowledged only after framing, total bounded JSON parsing and state
updates. Partial frames remain in the bounded framer. Stderr enters a private
8192-byte tail ring before acknowledgment; no public stderr readback is added.
Truncation, invalid credit, malformed protocol or exhaustion closes the original
attachment. There is no stdout archive, callback-selected command, helper ID,
replacement lookup or fabricated native retirement permission.

The broker/executor ServerLease assembly is a later join: it must install only an
exact validated original native session, preserve actual input/output credits,
producer caps and independent close/retirement evidence, and retain uncertainty
when any physical witness is missing. `Closed` reports attachment closure only;
credit expiry, local actor DOWN and `AllDelivered` cannot prove helper retirement.

The deterministic consumed peer tests drive this real client actor through blocked
input, request timeout/cancellation, fragmented output, original one-shot grants,
exact window/lifetime/state limits and failure closure. It supplies no native
retirement proof. The stderr append/slice boundary is structurally reviewed and
consumption-tested; there is no existing typed actor-state inspector in this package.

The supplemental core JavaScript gate does not establish exact-limit JSON runtime
success. Both Standard and Registered profiles hit the pre-existing sibling-stack
limit on a 199,999-null array probe. Registered LSP executes on BEAM, where exact
node edges pass; the approved additive parser seam preserves the existing sibling
implementation.
