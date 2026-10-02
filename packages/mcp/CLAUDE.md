# mcp

## Purpose

Loom's adapter for the standalone `gleam_mcp` library. This package turns
untrusted tool listings into `cap/mcp/<server>` Gleam source and translates
values between Loom's capability MessagePack wire and the library's JSON
vocabulary. Protocol codecs, stdio framing, the client state machine and
native process ownership belong to `gleam_mcp`.

MCP reaches a model through code mode only: one generated module per server.
`codegen.generate` returns source text and a rendered surface at boot. It
never compiles code, starts a process, or writes a file. The jailed build
compiles only the generated modules the submitted program imports.
`client/mcp` owns configuration, client startup, cleanup custody, and routing.

## Key Types

- `mcp/codegen.Generated(module_name, source, surface)` is the complete
  generated artifact. `GenerateError` refuses excessive tool counts,
  name collisions, schema budgets, excessive source or surface sizes, and
  sanitizer failures.
- `mcp/schema.Shape` is the recursive rendering plan: primitives, string
  enums, lists, records, mappings, nullable values, disjoint alternatives,
  raw object/array shapes, null and explicit `ValueFallback(reason)`.
  `Field` retains each original name, required/optional presence, note and
  default annotation; `Openness` records whether extra properties are allowed.
  `input_fields` plans a usable top-level object, while `shape` handles a
  recursive input or output value. The older `Plan` and `ParamType` remain
  for scalar accounting; the structural renderer consumes `Shape`.
  Every required name survives; an unusable input object becomes a whole
  arguments value.
- `mcp/name` maps wire names to Gleam identifiers, retaining an injected
  digest suffix whenever a name changes. Wire names themselves never change.
- `mcp/interchange.InterchangeFault` names an unrepresentable value's path.
  `to_json` converts `core/msgpack.MsgPackValue` directly to
  `gleam_mcp/json.JsonValue`; `to_msgpack` performs the reverse conversion.
- `gleam_mcp/protocol.ToolDescriptor` supplies the generator's tool name,
  descriptions and raw schemas. The library's JSON type is used directly
  throughout this adapter; Loom's frozen `core/json` remains independent.

## Relationships

- **Depends on**: `gleam_stdlib`; `core` for `core/msgpack`; `gleam_mcp`
  for protocol descriptors and JSON values. The local modules perform
  no I/O. The dependency includes an Erlang runtime, so this package does
  not claim the portable subset held by `core`, `machine` and `prompt`.
- **Depended on by**: `client`, through `client/catalog`'s name checks and
  `client/mcp`'s generation and capability conversion. Generated source
  imports `cap/internal/mcp`, the fixed `cap/internal/mcp_codec`, `cap/mcp`
  and `cap/report`, but this package has no dependency on `cap`: those
  imports are emitted as source text.
- **FFI**: none. Native stdio process operations belong to the external
  library's `gleam_mcp/internal/ffi_port` module.

## Traffic

- **Actor messages, commits and registers**: none in this package.
- **Wire values**: `interchange` translates the arguments and structured
  results crossing `client/mcp`'s `mcp.<server>` capability arm. It does
  not own either wire's transport or framing.
- **Generated artifacts**: `codegen.generate` returns source for
  `cap/mcp/<segment>` plus the surface shown to the model. `client/mcp`
  retains both. `codemode/build` writes selected modules inside the
  vendored capability package after seed cloning and before compilation.

## Invariants

- **Code-mode authority stays per server.** Generated functions close over
  the original server and tool names and call `cap/internal/mcp.invoke`.
  Typed output calls use `invoke_typed`; neither form exposes a generic
  model-callable dispatcher. The records and decoders grant no authority.
- **Wire names travel verbatim.** Mangling affects Gleam names only.
  Escaped literals preserve original tool and parameter names; a residual
  tool-name collision refuses the server. A parameter-label collision
  degrades that tool to whole-value arguments.
- **Server prose remains inert.** Descriptions lose control and direction
  changing codepoints and are capped. Every generated doc line starts
  `/// `. `scan_for_at` refuses an attribute outside a string or comment.
- **Generation is bounded.** Across input and output schemas, the precheck
  admits at most 16,384 JSON nodes, 262,144 text bytes and JSON depth 32.
  Recursive typed planning falls back beyond depth 12 or 32 union branches.
  `max_tools` is 256;
  generated source is capped at 524,288 bytes and the full surface at
  65,536 bytes. Aggregate overruns refuse the server; per-field depth
  fallback keeps the surrounding structure.
- **Generated identities are construction-owned.** Trusted tool, direction,
  node and variant keys identify declarations internally. A first rendering
  pass gathers bounded semantic candidates; `internal/type_name` reserves all
  candidates and imported names before adding compact ordinal suffixes to
  collisions. A second pass emits settled names, without replacing source
  text. Nearby property names replace recursive paths, and resulting BEAM
  atoms remain below 255 bytes. Exact enum wire literals stay in both the
  encoder and declaration comments. `type` escapes locally to `type_`; an
  explicit `type_` sibling follows the existing field-collision fallback.
- **Rendered unions preserve their proof.** `schema.branches_disjoint` checks
  the rendered child shapes, after field-name fallback. A lost discriminator
  makes the whole union a raw value; unrelated fallback does not erase a
  discriminator that still proves exclusive branches. A one-branch union
  renders its inner type directly. A tagged union flattens only when every
  rendered record shares a required singleton string field with a distinct
  literal. Constructors omit that field, encoders inject it, and total
  decoders still require its exact literal and retain object openness checks.
  Heterogeneous content unions and optional/null distinctions remain typed.
- **Source and surface describe the same types.** `internal/typed_codegen`
  derives declarations, options constants, encoders and total output decoders
  from one plan. Optional defaults omit keys so the server applies its own
  defaults. Unknown shapes carry explicit raw-value reasons, and generated
  booleans carry named variants rather than naked `Bool` fields.
- **Structural typing has a stated limit.** Types and the fixed satellite
  codec check represented shapes, enums, string literals and closed objects.
  Numeric bounds, patterns and general schema refinements remain server
  admission checks. Open-record output fields not in the declared projection
  are accepted and omitted from the typed record; raw-value fallback fields
  remain available for caller inspection.
- **Value translation is total.** JSON integers outside `[-2^63, 2^64 - 1]`
  fail the whole MessagePack conversion. Binary values and non-string map
  keys cannot become JSON arguments. No wrapping, clamping or guessed
  encoding is permitted. JSON and MessagePack parser nesting limits remain
  aligned, and the client separately checks the final capability envelope.
- **Loom owns result reduction.** The library retains non-text blocks as
  `Other(kind, raw)`. `client/mcp.content_block` sends only their kind to
  `cap/mcp.Other`; raw image, audio and resource payloads do not enter the
  capability result. Text and structured results retain existing handling.
- **Loom owns lifecycle policy.** `client/mcp` uses the library's parked
  `prepare_owned` clients, publishes every cleanup handle before connecting,
  and requires explicit native exit and normal actor retirement. Moving
  these primitives out of the tree does not weaken that custody boundary.
- **Client identity is caller-owned.** The external library defaults to
  `gleam-mcp`; `client/mcp.start_one` explicitly identifies Loom as `loom`.
  The declared client capabilities remain empty.

## Deep Docs

- [README.md](README.md) explains the extraction boundary and local tests.
- [MCP architecture](../../docs/architecture/mcp.md) follows configuration,
  startup, generation, compilation, calls and retirement end to end.
- [Code-mode architecture](../../docs/architecture/code-mode.md) describes
  import vetting and the jailed build that compiles generated modules.
- [Capability package](../cap/CLAUDE.md) owns the invocation envelope,
  result vocabulary and fixed structural codec.
- [Client package](../client/CLAUDE.md) owns lifecycle wiring and routing.
- [Root CLAUDE.md](../../CLAUDE.md) holds repository rules and the doc graph.
