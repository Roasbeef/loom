# lsp

## Purpose

Loom's client side of the Language Server Protocol (issue #25, ADR-013):
the wire layer that lets the harness ask a jailed language server for a
definition, references, hover, a file's outline, a rename and one level
of call hierarchy, and hear its diagnostics after an edit. It is
language-neutral on purpose — the server is each language's only oracle
for types, and Loom's agent works on Go, Rust and anything else a
workspace holds.

The package is the **protocol and the vocabulary**, not the wiring.
Starting a server in the jail, its policy, reading `[lsp.<name>]` from
`loom.toml`, and the `Door` closures are harness wiring and live in
`packages/client`; the `lsp_*` tools are `packages/tools`; the `lsp.*`
capabilities are `packages/codemode`. Nothing here performs I/O except
the client actor, and nothing here imports `broker` (ADR-013 §2).

The modules, in dependency order:

- `lsp/range` — the server's coordinates (zero-based, UTF-16 units).
- `lsp/query` — the harness's vocabulary and the `Door` contract every
  surface calls through. Types only.
- `lsp/framing` — the pure `Content-Length` framer, over bytes.
- `lsp/protocol` — total codecs for every structure consumed, capability
  gating, answers to server requests, and `file://` URI conversion.
- `lsp/text` (added by a sibling slice) — UTF-16 ↔ codepoint conversion
  and pure text-edit application.
- `lsp/client` — the client actor, a `weft/state_machine` over
  `mcp/transport.Transport`: one process owning one language server,
  its handshake, gated requests, document sync, the diagnostics store and
  settlement, and the stop sequence.

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
  ServerDiagnostic, ServerNotification(Published | Progressed | Ignored |
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
  StartError)` accepts only a `ChannelTransport` (the jail);
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
  DeadlineExpired), diagnostics}` — ADR-013 §3's two-rule settlement and
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

- **Depends on**: `gleam_stdlib`; `core` (`JsonValue`, its total parser
  and serializer); `mcp` for exactly two things — `mcp/jsonrpc` (the
  envelope, including its `response` and `error_response` encoders) and,
  from the client slice on, `mcp/transport` and `mcp/call` (the one
  monitored try-call outside the broker). `gleam_erlang`, `gleam_otp` and
  `weft` are declared for the client actor; `range`, `query`, `framing`,
  `protocol` and `text` import none of them and are pure functions of
  their arguments. The package as a whole is impure and not in the
  portable subset lint R6 gates.
- **Depended on by**: `client` (the manager that fills `query.Door`, and
  builds the production `ChannelTransport` over the broker's exec),
  `tools` (the `lsp_*` tools, over `Door`), `codemode` (`lsp.*` served
  here, over `Door`) — as those slices land.
- **FFI**: none, and ADR-013 needs none. The production transport is a
  `mcp/transport.ChannelTransport` over the broker's jailed exec.

## Traffic

- **Actor messages** (`lsp/client.Msg`, opaque): callers send
  `Handshake` (once, from `start`), `Ask(feature, build, deadline_ms,
  reply)`, `Sync(ops, reply)`, `Settle(uris, deadline_ms, reply)`,
  `Ready(quiet_ms, deadline_ms, reply)`, `Read(TextOf | OpenPaths |
  PublishedFor | CapabilitiesOf)` and `Stop(grace_ms, reply)`, every one
  through `mcp/call.try_call`. The transport sends
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
  — riding inside the broker's `exec_stdin`/`exec_out` (ADR-013 §1).
  `lsp/framing.frame` is the only place the outbound bytes are shaped.
  Sent: `initialize` (declaring `window.workDoneProgress`),
  `initialized`, `shutdown`, `exit`, `didOpen`,
  full-text `didChange`, `didClose`, `$/cancelRequest`, `definition`,
  `references` (declaration included), `hover`, `documentSymbol`,
  `prepareRename`, `rename`, `prepareCallHierarchy`,
  `callHierarchy/incomingCalls` and `outgoingCalls`, and answers to
  server requests. Consumed: those answers, `publishDiagnostics`,
  `$/progress` (work-done progress, tracked for readiness), and
  `window/logMessage`, `window/showMessage` (recognised and ignored).

## Invariants

- **Gate every request on advertised capabilities.** A measured server
  never answered an unadvertised request (ADR-013). `supports` is the
  gate; a `NotProvided` request is refused as `query.Unsupported` and
  never sent.
- **Framing is bounded before it buffers.** The header section is capped
  at 8 KiB; a declared length over 16 MiB is refused when the header is
  parsed, before a body byte is held. A push costs the chunk it carries:
  body chunks are kept unjoined and joined once. A faulted stream is not
  resumable — the transport is dead (ADR-013 §1).
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
  Edits land only through the hashline path (ADR-013 §4).
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
- **The client actor never blocks and never reads disk.** ADR-013 §1:
  the jailed exec path has no backpressure. Every wait is a pending entry
  plus a timer in actor state; the only I/O in a handler is
  `Connection.send`. Document texts arrive in `sync`, read by the caller.
- **Only a channel transport is accepted.** `start` refuses
  `PortTransport`, which would run the server unjailed (Rule Zero).
- **No caller is ever crashed by the client.** Every exchange is
  `mcp/call.try_call`; a dead or wedged client answers `Unavailable`.
- **Death settles everyone, then is reported.** A transport close, a
  framing fault, a body that is not JSON-RPC or a failed write answers
  every pending caller and settle-waiter `Unavailable(reason)`, closes
  the transport, and ends the actor abnormally. Restart is the manager's.
- **A timed-out request is cancelled and forgotten.** `TimedOut` is
  answered, `$/cancelRequest` sent for the id, and a late answer
  dropped; the actor keeps serving.
- **At most 64 documents are open**, LRU by last sync: document versions
  come from one counter shared by every document, so the smallest version
  is the least recently synced, and a reopened document never reuses a
  version an old publication carries. `synced_text` is exactly the last
  text sent.
- **The diagnostics store is bounded**: 512 URIs (the oldest publication
  goes first) and 200 diagnostics per publication.
- **Settlement is ADR-013 §3's two rules, and never a guess.** (a) the
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

- [docs/adr/013-language-servers-as-jailed-leases.md](../../docs/adr/013-language-servers-as-jailed-leases.md)
  — the design ruling: the jail, the package split, settled diagnostics,
  rename through hashline, symbol addressing, and the measured behaviour
  of `gleam lsp` and `gopls` this package's tests replay.
- [packages/mcp/CLAUDE.md](../mcp/CLAUDE.md) — `mcp/jsonrpc`,
  `mcp/transport` and `mcp/call`, which this package reuses unchanged.
- [docs/weft.md](../../docs/weft.md) — the monitored try-call gap
  `mcp/call` stands in for.
- [docs/gleam-style.md](../../docs/gleam-style.md) — Part IV §2 (total
  decoders) and §4 (no FFI).
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc
  graph.
