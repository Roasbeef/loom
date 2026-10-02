//// `mcp/codegen` — the generator behind issue #106: a server's
//// `tools/list` becomes a Gleam module `cap/mcp/<server>` of thin typed
//// façades over `cap/internal/mcp.invoke`, plus the rendered description
//// surface the `code_mode` tool carries for that server.
////
//// The invariant everything leans on is **wire fidelity**: every
//// generated body closes over the *original* tool name and the
//// *original* parameter names as escaped string literals. The Gleam-side
//// names (`mcp/name`) are display artifacts; renaming can never change
//// what crosses the wire. String-literal escaping is total — `\` and `"`
//// escaped, every codepoint outside printable ASCII emitted as a
//// `\u{...}` escape — so server-chosen text reaches the module only as
//// inert literal content.
////
//// The adversarial surface is a hostile `tools/list`, and it is held by
//// three mechanisms. First, sanitization: any server text bound for a
//// doc comment loses every control and direction-changing codepoint and
//// is capped (400 characters for a tool description, 120 for a
//// parameter note), so attacker prose cannot fabricate source lines or
//// reorder what a reader sees. Second, the emitted comment discipline:
//// every comment line the generator writes begins `/// ` (or `//// `),
//// and line breaks come only from the generator's own wrap. Third, a
//// backstop *assertion* that the first two held: after rendering,
//// `scan_for_at` proves the module contains no `@` outside comments and
//// string literals — generated code needs no attribute, so a stray `@`
//// means the sanitizer failed and generation fails loudly rather than
//// handing the compiler an `@external`.
////
//// Refusals bound schema nodes, depth and text before planning, then source
//// and surface bytes after rendering. There are at most 256 tools. A residual
//// function-name collision after mangling (`mcp/name`'s digest rule
//// makes this an engineered event, not an accident), or a rendered
//// surface past 64 KiB after doc truncation, or source past 512 KiB. A label collision inside
//// one tool degrades that one function to its whole-value form instead
//// of refusing the server.
////
//// The digest is injected (`fn(String) -> String`, lowercase hex of
//// SHA-256 over the input's UTF-8 bytes): this package is pure over
//// `gleam_stdlib` and `core`, and the tree's SHA-256 implementations
//// live behind FFI in packages this one must not depend on. Production
//// supplies the real hash; tests supply any injective stub.

import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam_mcp/json
import gleam_mcp/protocol
import mcp/internal/render_text
import mcp/internal/typed_codegen
import mcp/name
import mcp/schema

/// The most tools one server module will carry; a longer listing refuses
/// the whole server.
pub const max_tools = 256

/// The ceiling, in bytes, on one server's rendered description surface.
/// Doc caps truncate first; a surface still past this is a structural
/// overflow and refuses the server.
pub const max_surface_bytes = 65_536

/// A tool description is capped at this many characters in a doc comment.
pub const description_cap = 400

/// A parameter note (and any other short server text quoted into a doc
/// comment) is capped at this many characters.
pub const note_cap = 120

/// One generated server module: the module name the façade lives under,
/// its Gleam source, and the rendered description surface for the
/// `code_mode` tool. The surface's `pub fn` lines state exactly the
/// signatures the source declares, in `scripts/gen-prelude.py`'s one-line
/// `label: Type` form.
pub type Generated {
  Generated(module_name: String, source: String, surface: String)
}

/// Why a server's listing was refused whole. Every variant carries the
/// numbers or names the refusal is worded with; `describe` does the
/// wording.
pub type GenerateError {
  /// The server listed more than `max_tools` tools.
  TooManyTools(count: Int)

  /// Two tools' names mangled to the same Gleam function name. Carries
  /// both *original* names. With the digest rule this cannot happen by
  /// accident — byte-identical originals or an engineered digest
  /// near-miss — and a server doing either is refused, not repaired.
  ToolNameCollision(first: String, second: String)

  /// The rendered surface exceeded `max_surface_bytes` even after doc
  /// truncation: structural overflow, refused rather than clipped.
  SurfaceTooLarge(bytes: Int)

  /// The rendered source failed the `@` backstop — the sanitizer did not
  /// hold. This is an internal assertion, surfaced loudly by design.
  SanitizerBreach(detail: String)

  /// Structural input was refused before recursive generation.
  SchemaTooLarge(detail: String)

  /// Escaped literal content exceeded the generated source ceiling.
  SourceTooLarge(bytes: Int)
}

/// The refusal, worded. Server-chosen names are sanitized and capped
/// before they are quoted.
pub fn describe(error: GenerateError) -> String {
  case error {
    TooManyTools(count:) ->
      "refusing the server module: it lists "
      <> int.to_string(count)
      <> " tools and the per-server cap is "
      <> int.to_string(max_tools)
    ToolNameCollision(first:, second:) ->
      "refusing the server module: tool names "
      <> quoted(clean(first, note_cap))
      <> " and "
      <> quoted(clean(second, note_cap))
      <> " collide after renaming"
    SurfaceTooLarge(bytes:) ->
      "refusing the server module: its rendered surface is "
      <> int.to_string(bytes)
      <> " bytes and the per-server ceiling is "
      <> int.to_string(max_surface_bytes)
    SchemaTooLarge(detail:) -> "refusing the server module: " <> detail
    SourceTooLarge(bytes:) ->
      "refusing the server module: generated source exceeds 524288 bytes ("
      <> int.to_string(bytes)
      <> ")"
    SanitizerBreach(detail:) ->
      "refusing the server module: generated source failed the @ backstop ("
      <> detail
      <> ")"
  }
}

/// Generates the `cap/mcp/<server>` module and its rendered surface from
/// one server's tool listing.
///
/// `digest` is the injected hash `mcp/name` suffixes renamed identifiers
/// with: lowercase hex over the input's UTF-8 bytes, SHA-256 in
/// production. The module-name segment is the server name put through
/// the same mangle, so a hostile server name still yields a loadable
/// module; the original server string is what every body passes to
/// `invoke`.
///
/// ## Examples
///
/// ```gleam
/// // codegen.generate("github", tools, digest)
/// ```
///
pub fn generate(
  server: String,
  tools: List(protocol.ToolDescriptor),
  digest: fn(String) -> String,
) -> Result(Generated, GenerateError) {
  let count = list.length(tools)
  use <- bool.guard(
    when: count > max_tools,
    return: Error(TooManyTools(count:)),
  )
  use Nil <- result.try(
    schema.check_budget([
      json.String(server),
      ..list.flat_map(tools, fn(tool) {
        let output = case tool.output_schema {
          None -> []
          Some(output) -> [output]
        }
        let description = case tool.description {
          None -> []
          Some(text) -> [json.String(text)]
        }
        list.flatten([
          [json.String(tool.name), tool.input_schema],
          output,
          description,
        ])
      })
    ])
    |> result.map_error(fn(reason) { SchemaTooLarge(detail: reason) }),
  )

  // Schema budgets and identity collisions are settled before the renderer
  // can allocate escaped source or recursive type declarations.
  let names = list.map(tools, fn(t) { #(t.name, name.mangle(t.name, digest)) })
  use Nil <- result.try(
    name.first_collision(names)
    |> result.map_error(fn(pair) {
      ToolNameCollision(first: pair.0, second: pair.1)
    }),
  )
  let segment = name.mangle(server, digest)
  let rendered = typed_codegen.render(server, segment, tools, digest)
  let source = rendered.source
  let source_bytes = string.byte_size(source)
  use <- bool.guard(
    when: source_bytes > 524_288,
    return: Error(SourceTooLarge(bytes: source_bytes)),
  )
  use Nil <- result.try(
    scan_for_at(source)
    |> result.map_error(fn(detail) { SanitizerBreach(detail:) }),
  )

  // Source and discovery have distinct byte ceilings; neither is clipped,
  // because a clipped declaration would misrepresent the callable module.
  let surface = rendered.surface
  let bytes = string.byte_size(surface)
  use <- bool.guard(
    when: bytes > max_surface_bytes,
    return: Error(SurfaceTooLarge(bytes:)),
  )
  Ok(Generated(module_name: "cap/mcp/" <> segment, source:, surface:))
}

// Rich rendering owns structural declarations and the matching discovery text.
// Its identifiers and literals pass through this module's same hygiene layer.
// --- server text hygiene -----------------------------------------------------

/// Flattens controls and directional characters in untrusted prose.
///
/// ## Examples
///
/// ```gleam
/// assert codegen.sanitize("a\nb") == "a b"
/// ```
pub fn sanitize(text: String) -> String {
  render_text.sanitize(text)
}

/// Caps prose on a character boundary, counting the ellipsis inside the cap.
///
/// ## Examples
///
/// ```gleam
/// assert codegen.truncate("abcdef", 4) == "abc…"
/// ```
pub fn truncate(text: String, max: Int) -> String {
  render_text.truncate(text, max)
}

/// Escapes all non-ASCII content, quotes and backslashes for an inert literal.
///
/// ## Examples
///
/// ```gleam
/// assert codegen.escape("名") == "\\u{540D}"
/// ```
pub fn escape(text: String) -> String {
  render_text.escape(text)
}

fn clean(text: String, cap: Int) -> String {
  render_text.clean(text, cap)
}

fn quoted(text: String) -> String {
  "\"" <> text <> "\""
}

// --- the backstop --------------------------------------------------------

/// Asserts that rendered source carries `@` only where the generator may
/// legitimately put one: inside a `///`/`////` comment line or inside a
/// string literal. Everywhere else `@` opens an attribute — `@external`
/// being the payload a hostile `tools/list` would want — and generated
/// code needs no attribute at all, so a hit means the sanitizer failed
/// and names the line.
///
/// The scan leans on two facts about the emitter: every comment line it
/// writes is a `///` line, allowing indentation inside type declarations, and every string literal it
/// writes is single-line and double-quoted with escaped internals — which
/// is what makes a line-by-line state machine exact rather than
/// approximate.
///
/// ## Examples
///
/// ```gleam
/// assert codegen.scan_for_at("/// e-mail me @ example\n") == Ok(Nil)
/// assert codegen.scan_for_at("@external(erlang, \"os\", \"cmd\")")
///   == Error("stray @ outside comments and string literals on line 1")
/// ```
///
pub fn scan_for_at(source: String) -> Result(Nil, String) {
  string.split(source, "\n")
  |> list.index_map(fn(line, index) { #(index + 1, line) })
  |> list.try_each(fn(numbered) {
    let #(line_number, line) = numbered
    case
      string.starts_with(string.trim_start(line), "///") || line_clear(line)
    {
      True -> Ok(Nil)
      False ->
        Error(
          "stray @ outside comments and string literals on line "
          <> int.to_string(line_number),
        )
    }
  })
}

type Scan {
  Outside
  Inside
  Escaped
  Found
}

fn line_clear(line: String) -> Bool {
  let final =
    list.fold_until(string.to_graphemes(line), Outside, fn(state, grapheme) {
      case advance(state, grapheme) {
        Found -> list.Stop(Found)
        next -> list.Continue(next)
      }
    })
  final != Found
}

fn advance(state: Scan, grapheme: String) -> Scan {
  case state, grapheme {
    Outside, "\"" -> Inside
    Outside, "@" -> Found
    Outside, _ -> Outside
    Inside, "\\" -> Escaped
    Inside, "\"" -> Outside
    Inside, _ -> Inside
    Escaped, _ -> Inside
    Found, _ -> Found
  }
}
