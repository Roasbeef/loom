# mcp

This package adapts the standalone `gleam_mcp` library to Loom's code-mode
capabilities. It contains four pure modules:

| Module | Responsibility |
|---|---|
| `mcp/codegen` | Generate one `cap/mcp/<server>` module and its rendered surface from a tool listing. |
| `mcp/schema` | Read input schemas into typed, structured or whole-value argument plans without dropping parameters. |
| `mcp/name` | Convert wire names into collision-checked Gleam names while preserving wire identity. |
| `mcp/interchange` | Convert capability MessagePack values directly to and from `gleam_mcp/json.JsonValue`. |

The external library owns JSON-RPC and MCP codecs, bounded stdio framing,
the client state machine, native transport and process retirement. Its
client/server API is independent of Loom. The local adapter retains all
references to `cap/internal/mcp`, `cap/report` and `core/msgpack`.

`client/mcp` prepares the library's clients, publishes cleanup custody,
connects to configured servers, and passes each listing to `codegen`.
It explicitly sets the client name to `loom`. The generated source remains
in memory until a vetted code-mode program imports that server's module;
`codemode/build` then compiles it inside the execution's jailed build.
Each generated function calls the unimportable `cap/internal/mcp` seam,
so model-visible authority remains scoped by the program's imports.

A tool call travels from the capability router through `interchange` to
the library client. Its result returns through the same boundary. The
library preserves non-text blocks, while `client/mcp` reduces them to their
kind before sending Loom's existing capability result. No generic dispatcher
or additional result payload becomes visible to the jailed program.

The generation invariants remain local: every wire name is escaped verbatim,
server descriptions stay in bounded doc comments, an unexpected attribute
refuses generation, and tool-count and surface-size ceilings bound output.
MessagePack integer, binary and map-key disagreements are settled by total
conversion errors, never guessed encodings.

Run `make check-mcp` for format, warning-free compilation and adapter tests.
Run `make lint-mcp` for the house-rule lint. The local suites cover name mangling, schema planning,
generation and value conversion. The external library owns the transferred
protocol, framing, client, transport and custody suites. Loom's client tests
still drive the production library over both a scripted channel and a real
stdio fixture; its code-mode E2E compiles a generated facade inside the jail
and calls the fixture through the capability wire.

[The package reference](CLAUDE.md) records types and invariants.
[The MCP architecture](../../docs/architecture/mcp.md) follows the complete
production path and its trust boundaries.
