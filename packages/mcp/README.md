# mcp

This package adapts the standalone `gleam_mcp` library to Loom's code-mode
capabilities. Its adapter modules perform no I/O:

| Module | Responsibility |
|---|---|
| `mcp/codegen` | Generate one `cap/mcp/<server>` module and its rendered surface from a tool listing. |
| `mcp/schema` | Plan recursive input and output shapes, retaining unsupported fields as explicit raw-value fallbacks. |
| `mcp/internal/typed_codegen` | Render matching types, options, encoders, result decoders and model-visible declarations. |
| `mcp/internal/render_text` | Sanitize server prose and escape wire literals for generated source. |
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

Usable input schemas produce labelled required arguments, nested records,
enum and boolean variants, lists and typed `Options` records. Start with a
tool's declared defaults constant (normally `<function>_defaults`) and update
optional fields with `Some`.
`None` omits a field; nullable fields retain a second option layer so
`Some(None)` sends explicit null. Unsupported shapes fall back at the field
that needs it, with their reason exposed in the surface. An unusable top-level
input still accepts the complete arguments value.

An advertised `outputSchema` produces a typed return and a decoder composed
from the fixed total combinators in `cap/internal/mcp_codec`. A mismatch
returns `cap/mcp.ResultSchemaMismatch` with a path and the original result.
Without an output schema the existing `ToolResult` return remains available.
The types and decoders enforce represented shapes, enums, literals and closed
objects; numeric bounds and other JSON Schema refinements stay with the
server's admission checks.

A tool call travels from the capability router through `interchange` to
the library client. Its result returns through the same boundary. The
library preserves non-text blocks, while `client/mcp` reduces them to their
kind before sending Loom's existing capability result. The typed return
projects the existing structured content; no new wire envelope or generic
dispatcher is introduced.

The generation invariants remain local: every wire name is escaped verbatim,
server descriptions stay in bounded doc comments, an unexpected attribute
refuses generation, and schema, source and surface budgets bound generation.
Trusted ordinal prefixes own generated type and constructor identity.
Bounded descriptive suffixes keep names within the BEAM atom limit. Union
decoders are emitted only while rendered branches remain structurally disjoint.
MessagePack integer, binary and map-key disagreements are settled by total
conversion errors, never guessed encodings.

Run `make check-mcp` for format, warning-free compilation and adapter tests.
Run `make lint-mcp` for the house-rule lint. The local suites cover name mangling, schema planning,
generation and value conversion. The external library owns the transferred
protocol, framing, client, transport and custody suites. Loom's client tests
still drive the production library over both a scripted channel and a real
stdio fixture; its code-mode E2E compiles a generated facade inside the jail
and calls the fixture through the capability wire.

The official Go SDK fixture is captured output from typed Go structs, with
its pinned SDK version and reproduction commands in
[test/mcp/fixtures/go_sdk_provenance.md](test/mcp/fixtures/go_sdk_provenance.md).
The client suite compiles its facade and decodes its nested output in the jail.

[The package reference](CLAUDE.md) records types and invariants.
[The MCP architecture](../../docs/architecture/mcp.md) follows the complete
production path and its trust boundaries.
