# mcp

## Purpose

Loom's whole client side of the Model Context Protocol (issue #106):
JSON-RPC 2.0 and MCP codecs, newline-delimited stdio framing, the
supervised actor that owns one server process over a transport seam, and
the generator that turns a server's `tools/list` into a `cap/mcp/<server>`
Gleam module plus the description surface `code_mode` carries for it. MCP
reaches a model through code mode only — per-server generated modules,
never a registered harness tool and never a generic dispatcher. What is
*not* here: reading `[mcp.<name>]` out of `loom.toml`
(`client/catalog`), starting a client per configured server, widening
the workspace seam, and routing `mcp.<server>` capability calls. That is
harness wiring and it lives in `client/mcp`; this package is the
protocol, the client, the generator and the value translation it is
built out of.

## Key Types

- `mcp/jsonrpc.{Id, Inbound, RpcError, MessageFault}` — the envelope. We
  mint `IdInt`; the decoder accepts `IdString` too because the peer picks
  its own ids. `Inbound` is discriminated the way JSON-RPC discriminates:
  `Response(id, Result(JsonValue, RpcError))` for a message with no
  `method`, `ServerRequest(id, method, params)` for a method with an id,
  `Notification(method, params)` for one without. A hostile line settles
  as `MalformedMessage(CorruptionReport)` or `BadMessage(reason)`.
- `mcp/protocol.{requested_version, supported_versions}` — `"2025-06-18"`
  asked for, and the closed newest-first list accepted (`2025-06-18`,
  `2025-03-26`, `2024-11-05`).
- `mcp/protocol.{InitializeResult, ToolsCapability, ToolDescriptor,
  ToolsPage, CallToolResult, ContentBlock, ProtocolFault}` — the decoded
  handshake (its `protocol_version` is a member of `supported_versions`
  by construction), one listed tool with its `input_schema` carried
  **raw**, one `tools/list` page with its optional `next_cursor`, and a
  `tools/call` result whose `Text` blocks survive and whose every other
  block kind reduces to `Other(kind)`.
- `mcp/stdio.{Buffer, push, frame, max_line_bytes, FramingFault}` — line
  framing both ways. `push` feeds a chunk in and returns completed lines;
  `frame` renders compact single-line JSON plus `\n`; a line past 16 MiB
  is `LineTooLong`.
- `mcp/transport.{Transport, PortTransport, ChannelTransport, Spawn,
  Connection, TransportEvent, open, utf8_prefix}` — the seam the client
  is written against. `Spawn` is executable plus argv (never a shell
  string), explicit env pairs, optional cwd. `utf8_prefix` splits a byte
  chunk into its valid-UTF-8 prefix and a held tail of at most three
  bytes, since the pipe cuts characters in half.
- `mcp/client.{Client, Options, Msg, ClientError, StartError, start,
  list_tools, call_tool, stop}` — the actor. `Client` and `Msg` are both
  opaque, so nothing outside can forge a settlement or an expiry.
  `ClientError` is `Unavailable | CallTimedOut | ServerError |
  ResultMalformed | TooManyPages`; `StartError` is `TransportFailed |
  HandshakeFailed | VersionUnsupported | ToolsNotDeclared`.
- `mcp/schema.{Plan, Typed, WholeValue, Param, ParamType, Optional,
  plan}` — the total three-tier reading of a raw `inputSchema`.
  `Simple`/`ListOf` are the typed subset, `Structured(reason)` is
  anything else required, `WholeValue(reason)` is an unusable top level.
  No parameter is ever dropped.
- `mcp/name.{mangle, mangle_label, first_collision}` — a server-chosen
  name into a Gleam identifier, with the injected
  `digest: fn(String) -> String` (lowercase hex over UTF-8 bytes;
  SHA-256 in production) supplying the eight-character suffix.
- `mcp/interchange.{InterchangeFault, to_json, to_msgpack, describe,
  max_msgpack_int, min_msgpack_int}` — the value translation between the
  capability wire and the MCP wire, total both ways. A msgpack integer
  always fits `core/json.Int`; a JSON integer outside `[-2^63, 2^64 - 1]`
  fails the **whole** conversion rather than being wrapped or clamped; a
  msgpack binary and a non-string map key are refused in an argument
  (JSON has neither, and both encodings a caller might expect are
  guesses); `NilValue` and `Null` are each other. A fault names the path
  it was found at. Depth needs no ceiling here: both parsers bound
  nesting at the same `max_depth`.
- `mcp/codegen.{Generated, GenerateError, generate, describe, sanitize,
  truncate, escape, scan_for_at}` — the generator.
  `Generated(module_name, source, surface)`; `GenerateError` is
  `TooManyTools | ToolNameCollision | SurfaceTooLarge | SanitizerBreach`.

## Relationships

- **Depends on**: `gleam_stdlib`; `core` (the `JsonValue` ADT with its
  total parser and serializer, and `CorruptionReport`); `gleam_erlang`
  (`Subject`, `Selector`, `Port`, monitors — the client actor and the
  port transport); `gleam_otp` (`actor`). `mcp/{jsonrpc, protocol, stdio,
  schema, name, codegen, interchange}` import none of the last two and are pure
  functions of their arguments, but the package as a whole is impure and
  is **not** in the portable subset lint R6 gates.
- **Depended on by**: `client`, through `client/mcp` — the wiring that
  starts a client per configured server, generates its module, widens
  the workspace seam's allowlist and description, and answers
  `mcp.<server>` capability calls. `packages/cap` is the counterpart the
  generated modules import, and this package does not depend on it (the
  generator emits import lines as text).
- **FFI**: `mcp/internal/ffi_port` over `src/mcp_ffi.erl` — the package's
  complete inventory of impurity. `erlang:open_port/2` with
  `spawn_executable` (binary stream mode, `exit_status`, deliberately no
  `stderr_to_stdout`), `port_command/2`, `port_close/1`, `port_info/2`
  for the OS pid, `os:cmd` running `kill -KILL`, and the shim that takes
  a raw port message apart into `PortBytes | PortClosed | PortJunk`.

## Traffic

- **Actor messages**: `mcp/client.Msg`, all sent to the one client actor.
  `Request(build, deadline_ms, reply)` is a call — `build` receives the
  actor-minted `Id` and returns the whole JSON-RPC message — sent by
  `start`'s handshake, `list_tools` and `call_tool`. `Notify(message)` is
  a cast, used for `notifications/initialized`. `FromTransport(event)`
  arrives from the port selector or a `ChannelTransport` peer.
  `Expire(id)` is the actor's own `process.send_after` timer. `Shutdown`
  is a cast from `stop`.
- **Commits**: none. Nothing here touches a session store.
- **Registers**: none.
- **Wire**: the MCP stdio wire — newline-delimited JSON-RPC 2.0, one
  message per line, `\r\n` tolerated inbound, written to the child's
  stdin and read from its stdout. v1 sends exactly `initialize`,
  `notifications/initialized`, `tools/list`, `tools/call`, `ping`, and
  the `-32601` error response to any server-initiated request.
  `mcp/stdio.frame` is the only place the bytes-on-the-wire shape is
  decided.
- **Generated artifacts**: `codegen.generate` returns Gleam source for
  `cap/mcp/<segment>` — importing `cap/internal/mcp as internal`,
  `cap/mcp`, `cap/report`, and `gleam/list` only when a body needs it —
  and a surface rendered in `scripts/gen-prelude.py`'s one-line
  `label: Type` form.

## Invariants

- **Every decoder is total.** Wrong `jsonrpc`, missing fields, wrong
  types anywhere, a float or null id, `result` and `error` both present
  or both absent, a non-object list entry, an oversized line — each
  settles as `MessageFault`, `ProtocolFault` or `FramingFault`, never a
  crash. `mcp/schema.plan` goes further and has no error case at all:
  tier 3 *is* the failure mode, carried as data.
- **Strict envelope, tolerant content** (the `client/protocol` posture).
  Discriminators are refused when wrong; unknown extra fields inside
  known shapes are ignored; `params`, `result`, error `data`, tool input
  and output schemas and `structuredContent` cross raw and
  uninterpreted, to be treated downstream as untrusted data.
- **The declared client capabilities are an empty object, and that is a
  security decision.** No `sampling` (a server must not spend our model),
  no `roots` (a server learns nothing about the filesystem), no
  `elicitation` (a server must not put questions to a human through us).
  A test pins the emptiness, so widening it is a deliberate,
  test-breaking act.
- **A negotiated version outside `supported_versions` is refused** as
  `UnsupportedVersion` carrying both sides — never a connection limping
  along on a revision this client cannot speak.
- **One lying tool fails the whole listing.** A `tools/list` entry that
  is not an object, lacks a non-empty string `name`, or lacks its
  `inputSchema` fails the entire page with a fault naming the index: a
  server lying about one tool is not a server to half-trust.
- **Wire names travel verbatim.** Every generated body closes over the
  original tool name and the original parameter names as escaped string
  literals; `mcp/name`'s output is a display artifact. Renaming can never
  change what crosses the wire, and `escape` is total — `\` and `"`
  escaped, every codepoint outside printable ASCII emitted as `\u{...}` —
  so server text reaches the module only as inert literal content.
- **Mangling digests on any change, and a residual collision refuses the
  server.** Whenever mangling altered anything (or the name ran past 32
  characters) the result carries eight hex characters of
  `digest(original)`, so `createIssue` and `create_issue` stay distinct.
  What survives that is byte-identical originals or an engineered digest
  near-miss, and `codegen` refuses the whole module naming both
  originals rather than repairing it. A *label* collision inside one tool
  degrades that one function to its whole-value form instead.
- **The sanitizer cage plus the `@` backstop.** Server text bound for a
  doc comment loses every control and direction-changing codepoint and is
  capped (400 characters for a description, 120 for a note); every
  comment line the generator writes begins `/// `, and every line break
  comes from the generator's own wrap. `scan_for_at` then proves it held:
  generated code needs no attribute, so an `@` outside a comment or a
  string literal means the sanitizer failed, and generation fails loudly
  rather than handing the compiler an `@external`.
- **Every death path settles the in-flight calls.** `die` answers every
  waiting caller `Unavailable(reason)`, closes the transport, and latches
  the reason, idempotently — reached from a failed write, a closed
  transport, non-UTF-8 bytes, a framing fault, a malformed or non-JSON-RPC
  line, and `Shutdown`. A well-formed message the client merely does not
  act on (an unknown or forgotten response id, a notification, a string
  id) is dropped and the channel stays open. `handle_closed` swaps in an
  inert connection first, so a port close never chases an exited child's
  possibly recycled OS pid with a kill.
- **Callers never `process.call` the actor.** Every public call is a
  monitored send-and-select (the `broker/internal/call.try_call` shape,
  reproduced here because this package does not depend on the broker):
  `process.call` panics on a timeout and on a dead callee, and a caller
  holding a tool-call verdict must answer `Unavailable` instead of dying.
  The cost is one possible stale reply in the caller's mailbox.
- **Pagination and listing size are capped.** `list_tools` follows
  `nextCursor` for at most `max_tool_pages` (64) pages before
  `TooManyPages`, and `codegen` refuses a listing past `max_tools` (256)
  or a surface past `max_surface_bytes` (64 KiB) after truncation — so a
  hostile server cannot loop or flood the harness.
- **Framing is bounded on both sides of the newline.** A pending line
  grown past `max_line_bytes` and a completed line larger than it are
  both `LineTooLong`; the cap matches the cap channel's frame cap, so one
  hostile message has one cost ceiling everywhere. `frame`'s output can
  never contain a literal newline, because `core/json` escapes every
  control character inside strings.
- **The transport seam is where jailing will attach.** `PortTransport` is
  the production primitive and spawns unjailed; **who may spawn a real
  server binary is harness wiring's decision, made elsewhere**. Do not
  read the current spawn as the final security posture, and do not
  collapse the seam — `ChannelTransport` is what makes every client
  behaviour provable in-process.
- **stderr is never merged into stdout.** `stderr_to_stdout` would
  interleave the server's diagnostics into the JSON-RPC line stream and
  corrupt framing, so the child inherits the BEAM's stderr.
- **v1 speaks five methods and subscribes to nothing.** Resources,
  prompts, logging, sampling, roots, elicitation, progress, cancellation,
  completion, `listChanged` handling, HTTP/SSE transports and the
  2026-07-28 stateless mode are refused rather than deferred. A dead peer
  is not restarted or reconnected; that substrate grows teeth in phase 5
  with the LSP client (#25).

## Deep Docs

- [README.md](README.md) — the design stance in prose: why MCP is
  code-mode only, how a hostile `tools/list` is held, and what the module
  map looks like.
- [docs/architecture/mcp.md](../../docs/architecture/mcp.md) — the
  subsystem end to end, including the half this package does not hold:
  one `[mcp.<name>]` table through boot and codegen to one
  `mcp.<server>` capability call, the denial codes a program reads, and
  the worked surface and program a model sees.
- [docs/architecture/code-mode.md](../../docs/architecture/code-mode.md)
  — the vetting theorem the per-server module granularity rests on, and
  what each layer confines.
- [packages/cap/CLAUDE.md](../cap/CLAUDE.md) — the other end: `cap/mcp`'s
  result vocabulary and the `cap/internal/mcp.invoke` seam every
  generated façade calls.
- [packages/client/CLAUDE.md](../client/CLAUDE.md) — `client/protocol`,
  the house pattern for strict-envelope, tolerant-content wire codecs.
- [docs/gleam-style.md](../../docs/gleam-style.md) — Part IV §2 (total
  decoders) and §4 (FFI confinement), the rules this package is shaped
  by.
- [docs/next.md](../../docs/next.md) — the #106 design rulings and what
  the work still owes: the adversarial corpus for hostile `tools/list`
  input, and the open decision about jailing a server.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc
  graph.
