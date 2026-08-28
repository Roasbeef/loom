# mcp

## Purpose

The pure protocol layer for Model Context Protocol clients: JSON-RPC 2.0
codecs, the MCP lifecycle and tool messages (revision 2025-06-18, the
initialize-based lifecycle), and newline-delimited stdio framing — all as
plain values with total codecs over `core/json`. Phase-3 work for issue
#106 (MCP through code mode). The client actor that owns a server
process and its pipes is a separate, later slice; nothing in this package
spawns, connects, or performs I/O of any kind.

## Key Types

- `mcp/jsonrpc.{Id, IdInt, IdString}` — a message id. We mint integer
  ids; the decoder accepts both integer and string forms because the
  peer picks its own for server-initiated requests.
- `mcp/jsonrpc.Inbound` — one decoded inbound message, discriminated the
  way JSON-RPC 2.0 discriminates: `Response(id, Result(JsonValue,
  RpcError))` when no `method` is present, `ServerRequest(id, method,
  params)` for a method with an id, `Notification(method, params)` for a
  method without one. `RpcError` is the `{code, message, data?}` error
  member, `data` carried raw.
- `mcp/jsonrpc.MessageFault` — what a hostile line settles as:
  `MalformedMessage(CorruptionReport)` when it is not JSON at all,
  `BadMessage(reason)` when it parsed but is not a JSON-RPC 2.0 message.
- `mcp/jsonrpc.{request, notification, decode}` — the two encoders (to
  `JsonValue`, ready for `stdio.frame`) and the one total inbound
  decoder.
- `mcp/protocol.{requested_version, supported_versions}` — the revision
  this client asks for (`"2025-06-18"`) and the closed, newest-first
  list it accepts (`2025-06-18`, `2025-03-26`, `2024-11-05`).
- `mcp/protocol.{InitializeResult, ToolsCapability}` — the decoded
  handshake: negotiated version (always a member of
  `supported_versions`, by construction), whether the server declares
  tools (and `listChanged`, decoded but ignored by v1), optional
  serverInfo name/version, optional `instructions` carried verbatim.
- `mcp/protocol.{ToolDescriptor, ToolsPage}` — one listed tool (required
  non-empty `name`; optional title/description; `input_schema` and
  `output_schema` carried **raw**) and one `tools/list` page with its
  optional `next_cursor`.
- `mcp/protocol.{CallToolResult, ContentBlock}` — a `tools/call` result:
  `Text(String)` blocks kept, every other block kind reduced to
  `Other(kind)` with its payload dropped, `is_error` defaulting absent
  to `False`, `structured_content` raw.
- `mcp/protocol.ProtocolFault` — `UnsupportedVersion(server, supported)`
  or `BadResult(reason)`, the reason naming the field (and index, inside
  a list) that broke.
- `mcp/protocol` builders — `initialize_request`, `initialized`,
  `list_tools_request`, `call_tool_request`, `ping_request`, each
  returning the full JSON-RPC message as a `JsonValue`.
- `mcp/stdio.{Buffer, new, push, frame, max_line_bytes, FramingFault}` —
  pure line framing: `push` feeds a chunk in and returns completed lines
  (splitting on `\n`, trimming a trailing `\r`); `frame` renders compact
  single-line JSON plus `\n`; any line past `max_line_bytes` (16 MiB,
  matching the cap channel's frame cap) is a `LineTooLong` fault instead
  of unbounded growth.

## Relationships

- **Depends on**: `core` (the `JsonValue` ADT with its total parser and
  serializer, and `CorruptionReport`) and `gleam_stdlib`. Nothing else —
  no `gleam_erlang`, no `gleam_otp`, no `@external` of any target. The
  package is pure by the same structural rule as `core`: every function
  is a function of its arguments.
- **Depended on by**: nothing yet. The MCP client actor (the later
  slice of #106) will sit in an impure package and drive these codecs
  over a real child process; code mode's capability router is the
  intended consumer after that.
- **FFI**: none, and there must not be any.

## Traffic

- **Actor messages**: none. This package spawns nothing.
- **Commits**: none. Nothing here touches a session store.
- **Registers**: none.
- **Wire**: defines (but never carries) the MCP stdio wire form —
  newline-delimited JSON-RPC 2.0, one message per line, `\r\n`
  tolerated inbound. Builders produce `JsonValue`s; `stdio.frame` is
  the only place bytes-on-the-wire shape is decided.

## Invariants

- **Every decoder is total.** Hostile input — wrong `jsonrpc`, missing
  fields, wrong types at any field, a float or null id, result and
  error both present or both absent, non-object list entries, oversized
  lines — settles as a typed fault value (`MessageFault`,
  `ProtocolFault`, `FramingFault`), never a crash.
- **Strict envelope, tolerant content** (the `client/protocol` posture).
  Discriminators are refused when wrong; unknown extra fields inside
  known shapes are ignored; payloads this slice does not interpret —
  `params`, `result`, error `data`, tool input/output schemas,
  `structuredContent` — cross raw and uninterpreted.
- **The declared client capabilities are an empty object, and that is a
  security decision** (issue #106), not an unfinished list: no
  `sampling` (a server must not spend our model), no `roots` (a server
  learns nothing about the filesystem), no `elicitation` (a server must
  not put questions to a human through us). A test pins the emptiness so
  widening it is a deliberate, test-breaking act.
- **A negotiated version outside `supported_versions` is refused**, as
  `UnsupportedVersion` carrying both sides — never a connection limping
  along on a revision this client cannot speak.
- **One lying tool fails the whole listing.** A `tools/list` entry that
  is not an object, lacks a string non-empty `name`, or lacks its
  `inputSchema` fails the entire page with a fault naming the index — a
  server lying about one tool is not a server to half-trust.
- **Tool schemas are carried raw.** Deep JSON-Schema interpretation is a
  later slice's job; this layer neither validates nor normalizes what a
  server declares, and consumers must treat it as untrusted data.
- **Non-text content is reduced to its kind.** v1 has no safe channel
  for image/audio/resource payloads from an untrusted server; the block
  kind survives so a result that was mostly pictures reads as such
  rather than as empty.
- **Framing is bounded on both sides of the newline.** A pending line
  grown past `max_line_bytes` and a completed line larger than it are
  both `LineTooLong` faults; the cap matches the cap channel's frame cap
  so one hostile message has one cost ceiling everywhere. `frame`'s
  output can never contain a literal newline because `core/json`
  escapes every control character inside strings.
- **v1 speaks exactly five methods** — `initialize`,
  `notifications/initialized`, `tools/list`, `tools/call`, `ping` — and
  deliberately omits resources, prompts, logging, sampling, roots,
  elicitation, progress, cancellation, completion, `listChanged`
  handling, and the 2026-07-28 stateless mode. Server-initiated
  requests still *decode* (so nothing hostile hides in one); answering
  them method-not-found is the client actor's job.

## Deep Docs

- [docs/loom-design.md](../../docs/loom-design.md) — Rule Zero and the
  effect plane this protocol layer will eventually be dispatched under.
- [docs/gleam-style.md](../../docs/gleam-style.md) — Part IV §2 (total
  decoders) and §5 (purity layering), the rules this package is shaped
  by.
- [packages/core/CLAUDE.md](../core/CLAUDE.md) — the `JsonValue` ADT and
  `CorruptionReport` these codecs build on.
- [packages/client/CLAUDE.md](../client/CLAUDE.md) — `client/protocol`,
  the house pattern for strict-envelope/tolerant-content wire codecs
  this package follows.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc
  graph.
