# mcp

The pure protocol layer for Model Context Protocol clients: JSON-RPC 2.0
codecs, the MCP lifecycle and tool messages (revision 2025-06-18), and
newline-delimited stdio framing, all over `core/json`'s `JsonValue`.

Nothing in this package performs I/O. It is the sans-io half of an MCP
client — builders produce message values, decoders settle inbound bytes
as typed values or typed faults — and the actor that owns a server
process and its pipes is a separate slice. Every decoder is total:
hostile input becomes a fault value naming what was wrong, never a
crash.

Three modules:

- `mcp/jsonrpc` — the JSON-RPC 2.0 envelope: request and notification
  encoders, and a total decoder for the three inbound shapes (response,
  server-initiated request, notification).
- `mcp/protocol` — the five methods v1 needs and nothing more:
  `initialize` / `notifications/initialized` (with version negotiation
  against a closed supported list, and a deliberately empty client
  capabilities object), `tools/list`, `tools/call`, and `ping`. Tool
  input schemas cross this layer raw and untrusted.
- `mcp/stdio` — pure line framing: a push buffer that assembles
  newline-delimited messages from arbitrary chunks (tolerating `\r\n`,
  bounded at 16 MiB per line), and `frame`, which renders one message
  as compact single-line JSON plus its newline.

See `CLAUDE.md` for the full type inventory and invariants.
