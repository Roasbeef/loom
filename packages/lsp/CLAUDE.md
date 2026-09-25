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
- `lsp/client` (a later slice) — the client actor, a `weft/state_machine`
  over `mcp/transport.Transport`.

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
  ServerDiagnostic, ServerNotification(Published | Ignored |
  Unrecognised), WorkspaceFolder, ProtocolFault, UriFault}` — decoded
  answers, one type per question whatever dialect the server used.
- `lsp/protocol.{answer_server_request, classify_notification,
  path_to_uri, uri_to_path, symbol_kind_name}` — pure policy the actor
  sends without deciding anything.

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
- **Depended on by**: `client` (the manager that fills `query.Door`),
  `tools` (the `lsp_*` tools, over `Door`), `codemode` (`lsp.*` served
  here, over `Door`) — as those slices land.
- **FFI**: none, and ADR-013 needs none. The production transport is a
  `mcp/transport.ChannelTransport` over the broker's jailed exec.

## Traffic

- **Actor messages**: none yet; `lsp/client` will own them.
- **Commits**: none. **Registers**: none.
- **Wire**: LSP base protocol — `Content-Length: <bytes>\r\n\r\n<json>`
  — riding inside the broker's `exec_stdin`/`exec_out` (ADR-013 §1).
  `lsp/framing.frame` is the only place the outbound bytes are shaped.
  Sent: `initialize`, `initialized`, `shutdown`, `exit`, `didOpen`,
  full-text `didChange`, `didClose`, `$/cancelRequest`, `definition`,
  `references` (declaration included), `hover`, `documentSymbol`,
  `prepareRename`, `rename`, `prepareCallHierarchy`,
  `callHierarchy/incomingCalls` and `outgoingCalls`, and answers to
  server requests. Consumed: those answers, `publishDiagnostics`, and
  `window/logMessage`, `window/showMessage`, `$/progress` (recognised and
  ignored).

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
