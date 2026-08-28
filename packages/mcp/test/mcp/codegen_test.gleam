import core/json.{type JsonValue}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import mcp/codegen
import mcp/fixtures/github
import mcp/protocol
import mcp/schema

// --- the injected digest -------------------------------------------------

// Lowercase hex over the original's UTF-8 bytes: injective over full
// strings, deliberately weak in its first 8 characters, which is what the
// engineered near-miss cases lean on. Production injects SHA-256.
fn stub_digest(text: String) -> String {
  bit_array.base16_encode(bit_array.from_string(text))
  |> string.lowercase
}

fn tag8(text: String) -> String {
  string.slice(stub_digest(text), 0, 8)
}

fn gen(
  server: String,
  tools: List(protocol.ToolDescriptor),
) -> Result(codegen.Generated, codegen.GenerateError) {
  codegen.generate(server, tools, stub_digest)
}

// --- fixtures --------------------------------------------------------------

fn tool(
  name: String,
  description: Option(String),
  input_schema: JsonValue,
) -> protocol.ToolDescriptor {
  protocol.ToolDescriptor(
    name:,
    title: None,
    description:,
    input_schema:,
    output_schema: None,
  )
}

fn object_schema(
  properties: List(#(String, JsonValue)),
  required: List(String),
) -> JsonValue {
  json.Object([
    #("type", json.String("object")),
    #("properties", json.Object(properties)),
    #("required", json.Array(list.map(required, json.String))),
  ])
}

fn typed(kind: String) -> JsonValue {
  json.Object([#("type", json.String(kind))])
}

fn array_of(items: JsonValue) -> JsonValue {
  json.Object([#("type", json.String("array")), #("items", items)])
}

fn no_params() -> JsonValue {
  object_schema([], [])
}

// The list [1, 2, ..., count].
fn upto(count: Int) -> List(Int) {
  int.range(from: count, to: 0, with: [], run: list.prepend)
}

fn github_generated() -> codegen.Generated {
  let assert Ok(value) = json.parse(github.tools_json())
    as "the fixture must parse"
  let assert Ok(page) = protocol.decode_tools_page(value)
    as "the fixture must decode as a tools page"
  let assert Ok(generated) = gen("github", page.tools)
    as "the fixture must generate"
  generated
}

// --- the realistic fixture ---------------------------------------------------

pub fn github_fixture_generates_test() {
  let generated = github_generated()
  assert generated.module_name == "cap/mcp/github"
  assert string.contains(generated.source, "pub fn create_issue(")
  assert string.contains(generated.source, "pub fn push_files(")
}

// Tier distribution over a plausible mainstream server: 30 of the 31
// required parameters fit the typed subset (tier 1); one — `push_files`'s
// `files`, an array of objects — falls back to a structured value
// (tier 2); no tool degrades to its whole-value form (tier 3). The design
// ruling's falsifier: if mainstream servers push tier 2 above 25% of
// required parameters, that is the trigger to revisit the subset and
// generate nested-object records.
pub fn github_fixture_tier_distribution_test() {
  let assert Ok(value) = json.parse(github.tools_json())
    as "the fixture must parse"
  let assert Ok(page) = protocol.decode_tools_page(value)
    as "the fixture must decode as a tools page"
  let counts =
    list.fold(page.tools, #(0, 0, 0), fn(acc, descriptor) {
      case schema.plan(descriptor.input_schema) {
        schema.WholeValue(..) -> #(acc.0, acc.1, acc.2 + 1)
        schema.Typed(params:, ..) ->
          list.fold(params, acc, fn(acc, param) {
            case param.kind {
              schema.Structured(..) -> #(acc.0, acc.1 + 1, acc.2)
              schema.Simple(..) -> #(acc.0 + 1, acc.1, acc.2)
              schema.ListOf(..) -> #(acc.0 + 1, acc.1, acc.2)
            }
          })
      }
    })
  assert counts == #(30, 1, 0)
}

// The golden pin: the surface's `pub fn` lines state byte-for-byte the
// signatures the module source declares, once the module's two-line
// `label name: Type` form is folded to the surface's `label: Type` form
// (the generator makes every parameter's name its label, so the fold
// loses nothing).
pub fn github_surface_signatures_match_module_test() {
  let generated = github_generated()
  let surface_lines =
    string.split(generated.surface, "\n")
    |> list.filter(string.starts_with(_, "pub fn "))
  assert surface_lines == module_signatures(generated.source)
  assert list.length(surface_lines) == 10
}

fn module_signatures(source: String) -> List(String) {
  string.split(source, "\npub fn ")
  |> list.drop(1)
  |> list.map(fn(chunk) {
    let assert Ok(#(head, _)) =
      string.split_once(chunk, ") -> Result(mcp.ToolResult, mcp.McpError) {")
      as "every generated function has the pinned return type"
    let assert Ok(#(fn_name, params)) = string.split_once(head, "(")
      as "every generated function has a parameter list"
    let flattened =
      string.split(params, "\n")
      |> list.filter_map(fn(line) {
        case string.trim(line) {
          "" -> Error(Nil)
          trimmed -> Ok(strip_label(trimmed))
        }
      })
    "pub fn "
    <> fn_name
    <> "("
    <> string.join(flattened, ", ")
    <> ") -> Result(mcp.ToolResult, mcp.McpError)"
  })
}

// "label name: Type," -> "name: Type" (label and name are always equal).
fn strip_label(line: String) -> String {
  let bare = case string.ends_with(line, ",") {
    True -> string.drop_end(line, 1)
    False -> line
  }
  case string.split_once(bare, " ") {
    Ok(#(_, rest)) -> rest
    Error(Nil) -> bare
  }
}

// --- wire fidelity -----------------------------------------------------------

pub fn typed_body_marshals_by_wire_name_test() {
  let issue =
    tool(
      "createIssue",
      None,
      object_schema(
        [
          #("issueNumber", typed("integer")),
          #("labels", array_of(typed("string"))),
          #("ratio", typed("number")),
          #("draft", typed("boolean")),
          #("payload", typed("object")),
        ],
        ["issueNumber", "labels", "ratio", "draft", "payload"],
      ),
    )
  let assert Ok(generated) = gen("srv", [issue])
  let source = generated.source
  // The Gleam name is a display artifact...
  assert string.contains(
    source,
    "pub fn create_issue_" <> tag8("createIssue") <> "(",
  )
  // ...and every wire name crosses verbatim, whatever the label became.
  assert string.contains(source, "    \"createIssue\",")
  assert string.contains(
    source,
    "#(\"issueNumber\", report.int(issue_number_"
      <> tag8("issueNumber")
      <> ")),",
  )
  assert string.contains(
    source,
    "#(\"labels\", report.list(list.map(labels, report.string))),",
  )
  assert string.contains(source, "#(\"ratio\", report.float(ratio)),")
  assert string.contains(source, "#(\"draft\", report.bool(draft)),")
  assert string.contains(source, "#(\"payload\", payload),")
  assert string.contains(
    source,
    "  options options: List(#(String, report.Value)),",
  )
  assert string.contains(source, "import gleam/list")
}

pub fn unicode_tool_name_is_escaped_into_the_literal_test() {
  let named = tool("名前", None, no_params())
  let assert Ok(generated) = gen("srv", [named])
  assert string.contains(generated.source, "pub fn t_e5908de5(")
  assert string.contains(generated.source, "    \"\\u{540D}\\u{524D}\",")
}

pub fn hostile_server_name_mangles_the_segment_only_test() {
  let assert Ok(generated) = gen("My Server", [tool("t", None, no_params())])
  assert generated.module_name == "cap/mcp/my_server_" <> tag8("My Server")
  // The wire keeps the original server string.
  assert string.contains(generated.source, "    \"My Server\",")
}

// --- signature shapes ----------------------------------------------------

pub fn optional_only_tool_skips_the_list_import_test() {
  let bare = tool("ping", None, object_schema([#("page", typed("number"))], []))
  let assert Ok(generated) = gen("srv", [bare])
  assert string.contains(generated.source, "report.object(options),")
  assert !string.contains(generated.source, "import gleam/list")
  assert !string.contains(generated.source, "list.append")
  // The optional parameter is documented, never an argument.
  assert string.contains(generated.source, "- \"page\" (optional)")
  assert !string.contains(generated.source, "page page:")
}

pub fn empty_listing_emits_no_imports_test() {
  let assert Ok(generated) = gen("srv", [])
  assert !string.contains(generated.source, "import")
  assert string.contains(generated.surface, "### cap/mcp/srv")
}

pub fn whole_value_tool_passes_arguments_through_test() {
  let blob = tool("blob", None, json.Null)
  let assert Ok(generated) = gen("srv", [blob])
  assert string.contains(
    generated.source,
    "pub fn blob(\n  arguments arguments: report.Value,\n"
      <> ") -> Result(mcp.ToolResult, mcp.McpError) {",
  )
  assert string.contains(generated.source, "    arguments,")
  assert string.contains(generated.source, "could not be rendered")
  assert !string.contains(generated.source, "import gleam/list")
}

pub fn options_parameter_is_relabelled_test() {
  let clash =
    tool("t", None, object_schema([#("options", typed("string"))], ["options"]))
  let assert Ok(generated) = gen("srv", [clash])
  let relabelled = "options_" <> tag8("options")
  assert string.contains(
    generated.source,
    "  " <> relabelled <> " " <> relabelled <> ": String,",
  )
  assert string.contains(
    generated.source,
    "#(\"options\", report.string(" <> relabelled <> ")),",
  )
}

pub fn enum_values_render_as_doc_prose_test() {
  let state =
    json.Object([
      #("type", json.String("string")),
      #("enum", json.Array([json.String("open"), json.String("closed")])),
    ])
  let filter =
    tool("filter", None, object_schema([#("state", state)], ["state"]))
  let assert Ok(generated) = gen("srv", [filter])
  assert string.contains(generated.source, "; one of \"open\", \"closed\".")
  assert string.contains(generated.source, "  state state: String,")
}

// --- adversarial names ---------------------------------------------------

pub fn adversarial_tool_names_settle_test() {
  let names = [
    "create_issue", "createIssue", "Create-Issue!", "名前", "fn", "import", "type",
    "use", "main", "options",
  ]
  let tools = list.map(names, tool(_, None, no_params()))
  let assert Ok(generated) = gen("srv", tools)
  let expected = [
    "pub fn create_issue(",
    "pub fn create_issue_" <> tag8("createIssue") <> "(",
    "pub fn create_issue_" <> tag8("Create-Issue!") <> "(",
    "pub fn t_e5908de5(",
    "pub fn fn_" <> tag8("fn") <> "(",
    "pub fn import_" <> tag8("import") <> "(",
    "pub fn type_" <> tag8("type") <> "(",
    "pub fn use_" <> tag8("use") <> "(",
    "pub fn main(",
    "pub fn options(",
  ]
  assert list.all(expected, string.contains(generated.source, _))
}

pub fn two_hundred_char_tool_name_settles_test() {
  let long = string.repeat("ab", 100)
  let assert Ok(generated) = gen("srv", [tool(long, None, no_params())])
  assert string.contains(
    generated.source,
    "pub fn " <> string.slice(long, 0, 32) <> "_" <> tag8(long) <> "(",
  )
}

// --- collisions ---------------------------------------------------------

pub fn byte_identical_tool_names_refuse_the_server_test() {
  let tools = [tool("dup", None, no_params()), tool("dup", None, no_params())]
  assert gen("srv", tools)
    == Error(codegen.ToolNameCollision(first: "dup", second: "dup"))
}

pub fn engineered_digest_near_miss_refuses_the_server_test() {
  let tools = [
    tool("aaaa!", None, no_params()),
    tool("aaaa?", None, no_params()),
  ]
  let assert Error(codegen.ToolNameCollision(first:, second:)) =
    gen("srv", tools)
  assert { first == "aaaa!" && second == "aaaa?" }
    || { first == "aaaa?" && second == "aaaa!" }
}

// The mutation sentinel for the digest-on-change rule: drop the digest
// suffix and both of these fold to `foo`, turning this Ok into a
// ToolNameCollision refusal.
pub fn case_only_tool_names_do_not_collide_test() {
  let tools = [tool("Foo", None, no_params()), tool("foo", None, no_params())]
  let assert Ok(generated) = gen("srv", tools)
  assert string.contains(generated.source, "pub fn foo(")
  assert string.contains(generated.source, "pub fn foo_" <> tag8("Foo") <> "(")
}

// A label collision inside one tool degrades that one function to its
// whole-value form; the rest of the server still generates typed.
pub fn label_collision_degrades_one_tool_test() {
  let clash =
    tool(
      "clash",
      None,
      object_schema([#("aaaa!", typed("string")), #("aaaa?", typed("string"))], [
        "aaaa!",
        "aaaa?",
      ]),
    )
  let fine = tool("fine", None, object_schema([#("a", typed("string"))], ["a"]))
  let assert Ok(generated) = gen("srv", [clash, fine])
  assert string.contains(
    generated.source,
    "pub fn clash(\n  arguments arguments: report.Value,\n",
  )
  assert string.contains(generated.source, "collide after")
  assert string.contains(generated.source, "pub fn fine(\n  a a: String,")
}

// --- the refusal ceilings ------------------------------------------------

pub fn tool_count_past_the_cap_refuses_test() {
  let tools =
    upto(257)
    |> list.map(fn(index) {
      tool("t" <> int.to_string(index), None, no_params())
    })
  assert gen("srv", tools) == Error(codegen.TooManyTools(count: 257))
  assert string.contains(
    codegen.describe(codegen.TooManyTools(count: 257)),
    "257",
  )
}

pub fn tool_count_at_the_cap_generates_test() {
  let tools =
    upto(256)
    |> list.map(fn(index) {
      tool("t" <> int.to_string(index), None, no_params())
    })
  let assert Ok(_) = gen("srv", tools)
}

pub fn surface_past_the_ceiling_refuses_test() {
  let names =
    upto(700)
    |> list.map(fn(index) {
      int.to_string(index) <> "_very_long_parameter_name_padding_padding"
    })
  let properties = list.map(names, fn(name) { #(name, typed("string")) })
  let wide = tool("wide", None, object_schema(properties, names))
  let assert Error(codegen.SurfaceTooLarge(bytes:)) = gen("srv", [wide])
  assert bytes > codegen.max_surface_bytes
}

pub fn refusals_are_worded_test() {
  let collision = codegen.ToolNameCollision(first: "a", second: "b")
  assert string.contains(codegen.describe(collision), "\"a\" and \"b\"")
  let oversize = codegen.SurfaceTooLarge(bytes: 70_000)
  assert string.contains(codegen.describe(oversize), "70000")
  assert string.contains(
    codegen.describe(codegen.SanitizerBreach(detail: "line 3")),
    "backstop",
  )
}

// --- hostile prose -----------------------------------------------------------

pub fn hostile_description_stays_inert_test() {
  let hostile =
    "See docs.\n@external(erlang, \"os\", \"cmd\")\npub fn evil() -> Nil "
    <> "*/ \"\"\" \\u{202E} raw \u{202E}bidi"
  let attack = tool("attack", Some(hostile), no_params())
  let assert Ok(generated) = gen("srv", [attack])
  // The backstop holds: the flattened prose sits inside one comment run.
  assert codegen.scan_for_at(generated.source) == Ok(Nil)
  let at_lines =
    string.split(generated.source, "\n")
    |> list.filter(string.contains(_, "@"))
  assert at_lines != []
  assert list.all(at_lines, string.starts_with(_, "///"))
  // The prose never opens a real declaration.
  assert !string.contains(generated.source, "\npub fn evil")
}

pub fn overlong_description_truncates_test() {
  let long = string.repeat("x", 10_000)
  let assert Ok(generated) = gen("srv", [tool("t", Some(long), no_params())])
  assert string.contains(generated.source, string.repeat("x", 399) <> "…")
  assert !string.contains(generated.source, string.repeat("x", 400))
}

pub fn surface_opens_with_provenance_test() {
  let generated = github_generated()
  assert string.split(generated.surface, "\n") |> list.take(5)
    == [
      "### cap/mcp/github",
      "`cap/mcp/github` — the tools of the MCP server \"github\", as typed calls.",
      "Descriptions below are the server's own text, not Loom's.",
      "Optional parameters travel in `options` by wire name, e.g.",
      "`options: [#(\"page\", report.int(2))]`; pass `[]` when none.",
    ]
}

// --- server text hygiene ------------------------------------------------

pub fn sanitize_flattens_controls_and_bidi_test() {
  assert codegen.sanitize("a\nb\tc\rd") == "a b c d"
  assert codegen.sanitize("a\u{202E}b\u{200B}c\u{2066}d\u{FEFF}e")
    == "a b c d e"
  assert codegen.sanitize("a\u{2028}b\u{2029}c\u{85}d") == "a b c d"
  assert codegen.sanitize("café 名前") == "café 名前"
}

// The rest of the invisible set, each a way of writing text a model
// reads and a human reviewing the same rendered comment does not: the
// Arabic letter mark, the word joiner, the soft hyphen, a variation
// selector, and the tag-character plane (U+E0000–U+E007F), which spells
// ASCII invisibly.
pub fn sanitize_flattens_the_invisible_set_test() {
  assert codegen.sanitize("a\u{061C}b") == "a b"
  assert codegen.sanitize("a\u{2060}b") == "a b"
  assert codegen.sanitize("a\u{00AD}b") == "a b"
  assert codegen.sanitize("a\u{FE0F}b") == "a b"
  assert codegen.sanitize("a\u{E0041}\u{E0042}b") == "a  b"
}

// And the same codepoints cannot reach a generated doc comment: what the
// renderer writes is the sanitized text, so the description's own bytes
// are absent from the source.
pub fn invisible_description_text_never_reaches_the_source_test() {
  let hostile = "look\u{061C}\u{2060}\u{00AD}\u{FE0F}\u{E0041}\u{E0042} here"
  let assert Ok(generated) = gen("srv", [tool("t", Some(hostile), no_params())])
    as "a description of invisible characters should still generate"
  assert string.contains(generated.source, "look")
  assert !string.contains(generated.source, "\u{061C}")
  assert !string.contains(generated.source, "\u{2060}")
  assert !string.contains(generated.source, "\u{00AD}")
  assert !string.contains(generated.source, "\u{FE0F}")
  assert !string.contains(generated.source, "\u{E0041}")
  assert !string.contains(generated.source, "\u{E0042}")
}

pub fn escape_is_total_over_hostile_text_test() {
  assert codegen.escape("a\"b\\c") == "a\\\"b\\\\c"
  assert codegen.escape("名") == "\\u{540D}"
  assert codegen.escape("\n") == "\\u{A}"
  assert codegen.escape("\u{202E}") == "\\u{202E}"
  assert codegen.escape("plain ASCII 0-9~") == "plain ASCII 0-9~"
}

pub fn truncate_cuts_on_a_codepoint_boundary_test() {
  assert codegen.truncate("abcdef", 4) == "abc…"
  assert codegen.truncate("abcd", 4) == "abcd"
  assert codegen.truncate("åéîøü!", 5) == "åéîø…"
}

// --- the backstop --------------------------------------------------------

pub fn backstop_accepts_comment_and_literal_at_test() {
  assert codegen.scan_for_at(
      "/// mail me @ example\n//// header @\nlet x = \"@\"\n",
    )
    == Ok(Nil)
}

pub fn backstop_rejects_a_bare_at_test() {
  assert codegen.scan_for_at("@external(erlang, \"os\", \"cmd\")")
    == Error("stray @ outside comments and string literals on line 1")
}

pub fn backstop_rejects_at_after_a_closed_literal_test() {
  assert codegen.scan_for_at("let x = \"a\" @external")
    == Error("stray @ outside comments and string literals on line 1")
}

pub fn backstop_tracks_escaped_quotes_test() {
  // The @ sits inside a literal whose closing quote is escaped past it.
  assert codegen.scan_for_at("let x = \"a\\\"@\"") == Ok(Nil)
}

pub fn backstop_names_the_line_test() {
  assert codegen.scan_for_at("fine\nfine\nbad @ here")
    == Error("stray @ outside comments and string literals on line 3")
}
