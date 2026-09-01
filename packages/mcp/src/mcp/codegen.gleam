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
//// Refusals are per-server and worded: more than 256 tools, a residual
//// function-name collision after mangling (`mcp/name`'s digest rule
//// makes this an engineered event, not an accident), or a rendered
//// surface past 64 KiB after doc truncation. A label collision inside
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
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mcp/name
import mcp/protocol
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

// Doc-comment content wraps at this width; with the `/// ` prefix the
// emitted line stays at ~76 columns.
const doc_width = 72

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
  let facades =
    tools
    |> list.map(facade(server, _, digest))
    |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
  use Nil <- result.try(
    name.first_collision(list.map(facades, fn(f) { #(f.original, f.name) }))
    |> result.map_error(fn(pair) {
      ToolNameCollision(first: pair.0, second: pair.1)
    }),
  )
  let segment = name.mangle(server, digest)
  let source = render_module(server, segment, facades)
  use Nil <- result.try(
    scan_for_at(source)
    |> result.map_error(fn(detail) { SanitizerBreach(detail:) }),
  )
  let surface = render_surface(server, segment, facades)
  let bytes = string.byte_size(surface)
  use <- bool.guard(
    when: bytes > max_surface_bytes,
    return: Error(SurfaceTooLarge(bytes:)),
  )
  Ok(Generated(module_name: "cap/mcp/" <> segment, source:, surface:))
}

// --- one façade ----------------------------------------------------------

// One generated function, rendered far enough that the module emitter and
// the surface renderer draw the same signature from the same fields.
type Facade {
  Facade(
    original: String,
    name: String,
    doc: List(String),
    params: List(#(String, String)),
    body: String,
    uses_list: Bool,
  )
}

fn facade(
  server: String,
  tool: protocol.ToolDescriptor,
  digest: fn(String) -> String,
) -> Facade {
  let fn_name = name.mangle(tool.name, digest)
  case schema.plan(tool.input_schema) {
    schema.WholeValue(reason:) -> whole_facade(server, tool, fn_name, reason)
    schema.Typed(params:, optionals:) ->
      case labelled(params, digest) {
        // A label collision degrades this one tool to its whole-value
        // form; the rest of the server generates as usual.
        Error(#(first, second)) ->
          whole_facade(
            server,
            tool,
            fn_name,
            "parameters "
              <> quoted(clean(first, note_cap))
              <> " and "
              <> quoted(clean(second, note_cap))
              <> " collide after renaming",
          )
        Ok(pairs) -> typed_facade(server, tool, fn_name, pairs, optionals)
      }
  }
}

fn labelled(
  params: List(schema.Param),
  digest: fn(String) -> String,
) -> Result(List(#(schema.Param, String)), #(String, String)) {
  let pairs =
    list.map(params, fn(param) {
      #(param, name.mangle_label(param.original, digest))
    })
  name.first_collision(
    list.map(pairs, fn(pair) {
      let #(param, label) = pair
      #(param.original, label)
    }),
  )
  |> result.replace(pairs)
}

fn typed_facade(
  server: String,
  tool: protocol.ToolDescriptor,
  fn_name: String,
  pairs: List(#(schema.Param, String)),
  optionals: List(schema.Optional),
) -> Facade {
  let params =
    list.append(
      list.map(pairs, fn(pair) {
        let #(param, label) = pair
        #(label, type_name(param.kind))
      }),
      [#("options", "List(#(String, report.Value))")],
    )
  Facade(
    original: tool.name,
    name: fn_name,
    doc: typed_doc(server, tool, pairs, optionals),
    params:,
    body: typed_body(server, tool.name, pairs),
    // `list.append` marshals the required pairs, and any `list.map` for
    // a scalar-list parameter sits inside them, so one fact covers both.
    uses_list: pairs != [],
  )
}

fn whole_facade(
  server: String,
  tool: protocol.ToolDescriptor,
  fn_name: String,
  reason: String,
) -> Facade {
  Facade(
    original: tool.name,
    name: fn_name,
    doc: whole_doc(server, tool, reason),
    params: [#("arguments", "report.Value")],
    body: string.join(
      [
        "  internal.invoke(",
        "    " <> lit(server) <> ",",
        "    " <> lit(tool.name) <> ",",
        "    arguments,",
        "  )",
      ],
      "\n",
    ),
    uses_list: False,
  )
}

// --- typed bodies ----------------------------------------------------------

fn typed_body(
  server: String,
  tool: String,
  pairs: List(#(schema.Param, String)),
) -> String {
  let arguments = case pairs {
    [] -> ["    report.object(options),"]
    _ ->
      list.flatten([
        ["    report.object(list.append(", "      ["],
        list.map(pairs, pair_line),
        ["      ],", "      options,", "    )),"],
      ])
  }
  string.join(
    list.flatten([
      [
        "  internal.invoke(",
        "    " <> lit(server) <> ",",
        "    " <> lit(tool) <> ",",
      ],
      arguments,
      ["  )"],
    ]),
    "\n",
  )
}

fn pair_line(pair: #(schema.Param, String)) -> String {
  let #(param, label) = pair
  "        #("
  <> lit(param.original)
  <> ", "
  <> marshal(param.kind, label)
  <> "),"
}

fn marshal(kind: schema.ParamType, label: String) -> String {
  case kind {
    schema.Simple(scalar:) ->
      "report." <> builder(scalar) <> "(" <> label <> ")"
    schema.ListOf(scalar:) ->
      "report.list(list.map(" <> label <> ", report." <> builder(scalar) <> "))"
    schema.Structured(..) -> label
  }
}

fn builder(scalar: schema.Scalar) -> String {
  case scalar {
    schema.ScalarString -> "string"
    schema.ScalarInt -> "int"
    schema.ScalarFloat -> "float"
    schema.ScalarBool -> "bool"
  }
}

fn type_name(kind: schema.ParamType) -> String {
  case kind {
    schema.Simple(scalar:) -> scalar_type(scalar)
    schema.ListOf(scalar:) -> "List(" <> scalar_type(scalar) <> ")"
    schema.Structured(..) -> "report.Value"
  }
}

fn scalar_type(scalar: schema.Scalar) -> String {
  case scalar {
    schema.ScalarString -> "String"
    schema.ScalarInt -> "Int"
    schema.ScalarFloat -> "Float"
    schema.ScalarBool -> "Bool"
  }
}

// --- doc comments ----------------------------------------------------------

fn typed_doc(
  server: String,
  tool: protocol.ToolDescriptor,
  pairs: List(#(schema.Param, String)),
  optionals: List(schema.Optional),
) -> List(String) {
  let intro =
    wrap(
      "Tool "
        <> quoted(clean(tool.name, note_cap))
        <> " on MCP server "
        <> quoted(clean(server, note_cap))
        <> ". Optional parameters travel in `options` by wire name; pass []"
        <> " when none.",
      doc_width,
    )
  let required = list.flat_map(pairs, param_bullet)
  let optional = list.flat_map(optionals, optional_bullet)
  join_doc(description_lines(tool), list.flatten([intro, required, optional]))
}

fn whole_doc(
  server: String,
  tool: protocol.ToolDescriptor,
  reason: String,
) -> List(String) {
  let explanation =
    wrap(
      "Tool "
        <> quoted(clean(tool.name, note_cap))
        <> " on MCP server "
        <> quoted(clean(server, note_cap))
        <> ". Its input schema could not be rendered as typed arguments ("
        <> clean(reason, note_cap)
        <> "); pass the whole arguments object as one `report.Value`.",
      doc_width,
    )
  join_doc(description_lines(tool), explanation)
}

fn description_lines(tool: protocol.ToolDescriptor) -> List(String) {
  case tool.description {
    None -> []
    Some(text) -> wrap(clean(text, description_cap), doc_width)
  }
}

fn join_doc(description: List(String), rest: List(String)) -> List(String) {
  case description {
    [] -> rest
    _ -> list.flatten([description, [""], rest])
  }
}

fn param_bullet(pair: #(schema.Param, String)) -> List(String) {
  let #(param, label) = pair
  bullet(
    "- "
    <> label
    <> ": wire "
    <> quoted(clean(param.original, note_cap))
    <> ", "
    <> kind_prose(param.kind)
    <> enum_prose(param.one_of)
    <> "."
    <> note_prose(param.note),
  )
}

fn optional_bullet(optional: schema.Optional) -> List(String) {
  let note = case optional.note {
    None -> "."
    Some(text) -> ": " <> clean(text, note_cap)
  }
  bullet(
    "- " <> quoted(clean(optional.original, note_cap)) <> " (optional)" <> note,
  )
}

fn kind_prose(kind: schema.ParamType) -> String {
  case kind {
    schema.Simple(scalar:) -> scalar_prose(scalar)
    schema.ListOf(scalar:) -> "list of " <> scalar_prose(scalar)
    schema.Structured(reason:) ->
      "structured value (" <> clean(reason, note_cap) <> ")"
  }
}

fn scalar_prose(scalar: schema.Scalar) -> String {
  case scalar {
    schema.ScalarString -> "string"
    schema.ScalarInt -> "integer"
    schema.ScalarFloat -> "number"
    schema.ScalarBool -> "boolean"
  }
}

fn enum_prose(one_of: List(String)) -> String {
  case one_of {
    [] -> ""
    values ->
      "; one of "
      <> truncate(
        string.join(
          list.map(values, fn(value) { quoted(sanitize(value)) }),
          ", ",
        ),
        note_cap,
      )
  }
}

fn note_prose(note: Option(String)) -> String {
  case note {
    None -> ""
    Some(text) -> " " <> clean(text, note_cap)
  }
}

fn bullet(text: String) -> List(String) {
  case wrap(text, doc_width) {
    [] -> []
    [first, ..rest] -> [first, ..list.map(rest, fn(line) { "  " <> line })]
  }
}

// --- the module ------------------------------------------------------------

fn render_module(
  server: String,
  segment: String,
  facades: List(Facade),
) -> String {
  let header =
    list.map(
      wrap(
        "`cap/mcp/"
          <> segment
          <> "` — a generated façade over the MCP server "
          <> quoted(clean(server, note_cap))
          <> ": one function per listed tool, each marshaling its typed"
          <> " arguments under the original wire names into"
          <> " `cap/internal/mcp.invoke`. Generated from the server's own"
          <> " tools/list; the doc comments below are the server's text, not"
          <> " Loom's.",
        doc_width,
      ),
      fn(line) { "//// " <> line },
    )
  let blocks = case facades {
    // A tool-less server still gets its module, but with nothing to
    // reference no import may be emitted: `--warnings-as-errors` turns an
    // unused import into a failed build.
    [] -> [header]
    _ -> [header, imports(facades), ..list.map(facades, render_fn)]
  }
  string.join(list.map(blocks, string.join(_, "\n")), "\n\n") <> "\n"
}

fn imports(facades: List(Facade)) -> List(String) {
  let base = [
    "import cap/internal/mcp as internal", "import cap/mcp", "import cap/report",
  ]
  case list.any(facades, fn(facade) { facade.uses_list }) {
    True -> list.append(base, ["import gleam/list"])
    False -> base
  }
}

fn render_fn(facade: Facade) -> List(String) {
  list.flatten([
    list.map(facade.doc, doc_line),
    ["pub fn " <> facade.name <> "("],
    list.map(facade.params, fn(param) {
      "  " <> param.0 <> " " <> param.0 <> ": " <> param.1 <> ","
    }),
    [") -> Result(mcp.ToolResult, mcp.McpError) {", facade.body, "}"],
  ])
}

fn doc_line(content: String) -> String {
  case content {
    "" -> "///"
    _ -> "/// " <> content
  }
}

// --- the rendered surface ----------------------------------------------------

fn render_surface(
  server: String,
  segment: String,
  facades: List(Facade),
) -> String {
  let heading = [
    "### cap/mcp/" <> segment,
    "`cap/mcp/"
      <> segment
      <> "` — the tools of the MCP server "
      <> quoted(clean(server, note_cap))
      <> ", as typed calls.",
    "Descriptions below are the server's own text, not Loom's.",
    "Optional parameters travel in `options` by wire name, e.g.",
    "`options: [#(\"page\", report.int(2))]`; pass `[]` when none.",
  ]
  let blocks = [heading, ..list.map(facades, surface_block)]
  string.join(list.map(blocks, string.join(_, "\n")), "\n\n") <> "\n"
}

fn surface_block(facade: Facade) -> List(String) {
  list.append(list.map(facade.doc, doc_line), [surface_signature(facade)])
}

// The one-line `label: Type` signature form `scripts/gen-prelude.py`
// renders the rest of the prelude in. Labels alone, because the label is
// all a caller may write — and the generator makes every parameter's name
// its label, so this line and the module's declaration state the same
// signature.
fn surface_signature(facade: Facade) -> String {
  "pub fn "
  <> facade.name
  <> "("
  <> string.join(
    list.map(facade.params, fn(param) { param.0 <> ": " <> param.1 }),
    ", ",
  )
  <> ") -> Result(mcp.ToolResult, mcp.McpError)"
}

// --- server text hygiene -----------------------------------------------------

/// Replaces every invisible or direction-changing codepoint with one
/// space: C0 and C1 controls (`\n`, `\r`, `\t` included), U+00AD,
/// U+061C, U+2028/U+2029, U+200B–U+200F, U+202A–U+202E, U+2060–U+2069,
/// U+FE00–U+FE0F, U+FEFF and the tag-character plane U+E0000–U+E007F.
/// All other Unicode passes. This is what keeps attacker prose inside
/// the one comment line the generator wrote it into.
///
/// ## Examples
///
/// ```gleam
/// assert codegen.sanitize("a\nb") == "a b"
/// ```
///
pub fn sanitize(text: String) -> String {
  string.to_utf_codepoints(text)
  |> list.map(fn(codepoint) {
    case invisible(string.utf_codepoint_to_int(codepoint)) {
      True -> " "
      False -> string.from_utf_codepoints([codepoint])
    }
  })
  |> string.concat
}

// C0/C1 controls, line/paragraph separators, the zero-width and
// direction-control sets (bidi overrides, the Arabic letter mark, the
// word joiner and invisible operators), the soft hyphen, variation
// selectors, the BOM, and the tag-character plane — the last being the
// classic vector for instructions visible to a model and invisible to a
// human reading the same rendered text.
fn invisible(code: Int) -> Bool {
  code < 0x20
  || code == 0x7F
  || { code >= 0x80 && code <= 0x9F }
  || code == 0xAD
  || code == 0x061C
  || code == 0x2028
  || code == 0x2029
  || { code >= 0x200B && code <= 0x200F }
  || { code >= 0x202A && code <= 0x202E }
  || { code >= 0x2060 && code <= 0x2069 }
  || { code >= 0xFE00 && code <= 0xFE0F }
  || code == 0xFEFF
  || { code >= 0xE0000 && code <= 0xE007F }
}

/// Caps text at `max` characters, cutting on a codepoint boundary and
/// ending a cut text with `…` (counted inside the cap).
///
/// ## Examples
///
/// ```gleam
/// assert codegen.truncate("abcdef", 4) == "abc…"
/// assert codegen.truncate("abcd", 4) == "abcd"
/// ```
///
pub fn truncate(text: String, max: Int) -> String {
  // `drop_start` against `""` answers "longer than max?" without
  // `string.length`'s walk of a possibly 10 KiB description (lint R5).
  case string.drop_start(text, max) == "" {
    True -> text
    False -> string.slice(text, 0, max - 1) <> "…"
  }
}

// Greedy word wrap. Every line break in an emitted comment comes from
// here — never from the server's text, whose breaks `sanitize` already
// flattened. A word longer than the width gets its own (long) line
// rather than a mid-word cut.
fn wrap(text: String, width: Int) -> List(String) {
  let words = list.filter(string.split(text, " "), fn(word) { word != "" })
  let #(lines, last, _) =
    list.fold(words, #([], "", 0), fn(state, word) {
      let #(lines, current, length) = state
      let word_length = string.length(word)
      case current {
        "" -> #(lines, word, word_length)
        _ ->
          case length + 1 + word_length <= width {
            True -> #(lines, current <> " " <> word, length + 1 + word_length)
            False -> #([current, ..lines], word, word_length)
          }
      }
    })
  case last {
    "" -> list.reverse(lines)
    _ -> list.reverse([last, ..lines])
  }
}

fn clean(text: String, cap: Int) -> String {
  truncate(sanitize(text), cap)
}

fn quoted(text: String) -> String {
  "\"" <> text <> "\""
}

/// Escapes text for the inside of a Gleam string literal. Total: `\` and
/// `"` are escaped, and any codepoint outside printable ASCII
/// (0x20–0x7E) is emitted as Gleam's `\u{...}` escape, so a literal can
/// never carry a raw newline, control character, or bidi override.
///
/// ## Examples
///
/// ```gleam
/// assert codegen.escape("a\"b\\c") == "a\\\"b\\\\c"
/// assert codegen.escape("名") == "\\u{540D}"
/// ```
///
pub fn escape(text: String) -> String {
  string.to_utf_codepoints(text)
  |> list.map(escape_codepoint)
  |> string.concat
}

fn escape_codepoint(codepoint: UtfCodepoint) -> String {
  let code = string.utf_codepoint_to_int(codepoint)
  case code {
    0x5C -> "\\\\"
    0x22 -> "\\\""
    _ if code >= 0x20 && code <= 0x7E -> string.from_utf_codepoints([codepoint])
    _ -> "\\u{" <> int.to_base16(code) <> "}"
  }
}

fn lit(text: String) -> String {
  quoted(escape(text))
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
/// writes starts at column zero with `///`, and every string literal it
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
    case string.starts_with(line, "///") || line_clear(line) {
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
