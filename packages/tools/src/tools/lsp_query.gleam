//// The opt-in `lsp_*` tools: the language-server queries a model calls
//// directly, without code mode.
////
//// # Why this module exists
////
//// The queries reach a program through `cap/lsp`. A consumer whose agents
//// call tools and never write programs has no path to them, and the one
//// measured on code mode found that three programs in about 27,000 used
//// the language server at all. This module is the same view as five
//// ordinary tools: `lsp_definition`, `lsp_references`, `lsp_hover`,
//// `lsp_symbols` and `lsp_diagnostics`.
////
//// # One door, one rule
////
//// Nothing here is a second language-server path. Each tool decodes its
//// arguments into a `lsp/query.SymbolQuery` (or a path), calls one closure
//// of the session's `lsp/query.Door`, and renders the answer. Symbol
//// resolution, document sync, the one server per session and the gate on
//// every path a server names (`client/lsp/resolve.admit`, called from the
//// manager) all sit on the far side of that door, so a path outside the
//// server's root is refused exactly as it is for `cap/lsp`. A tool keeps
//// only the closure it calls, not the whole door, so the registry does not
//// copy all eight handles into every tool.
////
//// # Off by default
////
//// The tool array is the cached prefix of every request, so a registry
//// built without the opt-in is byte for byte what it was. `client` adds
//// these tools only when the `[tools]` table says `lsp_tools = "on"` and a
//// language server is configured. Without a configured server there is no
//// door to ask and the tools are absent, as `cap/lsp` is.
////
//// # What is deliberately not offered
////
//// Workspace-wide symbol search is not a door operation: the door finds a
//// bare name by searching the server's root and asking where each hit is
//// defined, which `lsp_definition` already does. Rename and call hierarchy
//// are not offered either; rename writes files and stays a code-mode,
//// previewed operation.
////
//// # Names in, anchors out
////
//// A model never supplies a position. It names the symbol as code spells
//// it, optionally with a `path` and the 1-based `line` that `fs_read`
//// prints. Every site in an answer is `path:line:anchor|text`, a `grep`
//// hit with the hashline anchor spliced in, so a result feeds `fs_edit`
//// directly. Every list counts before it lists and says when it cut.
////
//// ## Flow
////
//// ```text
//// tools → definition_tool / references_tool / hover_tool / symbols_tool
////       / diagnostics_tool, each built by read_tool
////
//// a call:
////   run_definition / run_references / run_hover / run_symbols /
////   run_diagnostics
////     → decode_query or decode_path → the door closure
////     → render_* → with_warmth → ToolOutcome
////     (a QueryError → render_error → tool.failure)
//// ```
////
//// Every argument is decoded before the door is asked, so a malformed
//// call costs no server request.

import broker/policy.{type SandboxPolicy}
import core/json.{type JsonValue}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lsp/query.{
  type Diagnostics, type QueryError, type Reference, type Site, type SymbolEntry,
  type SymbolQuery, type Warmth,
}
import tools/hashline
import tools/lsp
import tools/tool.{type Tool, type ToolOutcome}

/// The name of `lsp_definition`.
pub const definition_name = "lsp_definition"

/// The name of `lsp_references`.
pub const references_name = "lsp_references"

/// The name of `lsp_hover`.
pub const hover_name = "lsp_hover"

/// The name of `lsp_symbols`, a file's outline.
pub const symbols_name = "lsp_symbols"

/// The name of `lsp_diagnostics`.
pub const diagnostics_name = "lsp_diagnostics"

/// Every tool this module registers, in registration order.
pub const tool_names = [
  definition_name, references_name, hover_name, symbols_name, diagnostics_name,
]

/// The most definition sites `lsp_definition` lists. A name defined in
/// more places than this is a name to qualify, and the answer says so.
pub const max_definition_sites = 20

/// The most reference hits `lsp_references` lists. Past it the answer says
/// how many it left out, because a reference list is unbounded and a model
/// that needs every one is better served by narrowing the query.
pub const max_reference_hits = 50

/// The most outline lines `lsp_symbols` lists, counting nested members.
/// A file with more is cut and the answer says how many entries were left.
pub const max_outline_entries = 100

/// The most bytes of a server's hover text `lsp_hover` shows. The server
/// decides how long a hover is, and some print a whole module's
/// documentation. Four KiB holds a signature and its doc comment.
pub const max_hover_bytes = 4096

/// The five `lsp_*` tools over one door.
///
/// `hints` are the configured servers' profile hints as `#(server name,
/// hint)`, in the order they should be read. They are appended once, as a
/// "Language notes:" block, to `lsp_definition`'s description and nowhere
/// else, since every symbol-taking tool addresses symbols the same way. With
/// no hints every description is what it would be without them.
///
/// ## Examples
///
/// ```gleam
/// // tool.registry(list.append(core_tools, lsp_query.tools(door, [])))
/// ```
///
pub fn tools(door: query.Door, hints: List(#(String, String))) -> List(Tool) {
  [
    definition_tool(door, hints),
    references_tool(door),
    hover_tool(door),
    symbols_tool(door),
    diagnostics_tool(door),
  ]
}

// --- the tool definitions -------------------------------------------------

// The servers' hints as the block `lsp_definition`'s description ends
// with, or nothing when no server wrote one. Each hint is a single
// printable line, so each stays one line of the block.
/// The servers' hints as the block `lsp_definition`'s description ends with, or the empty string.
fn language_notes(hints: List(#(String, String))) -> String {
  case hints {
    [] -> ""
    [_, ..] ->
      "\n\nLanguage notes:\n"
      <> string.join(
        list.map(hints, fn(hint) { hint.0 <> ": " <> hint.1 }),
        "\n",
      )
  }
}

// The sentence every symbol-addressed description ends with, so the facts a
// model needs to call these well are stated once and identically.
const addressing =
  " Address the symbol by name as the code spells it, optionally qualified (`util.Greet`, `probe.greet`); positions are never needed. Add `path`, and `line` as fs_read prints it, only to narrow an ambiguous name. Every site in the answer is printed as `path:line:anchor|text`, so it can be edited with fs_edit without reading the file first. Paths outside the language server's project are refused. If no language server serves the file, the answer says it is unavailable; use grep and fs_read instead."

/// Builds `lsp_definition` over the door's `definition` closure.
fn definition_tool(door: query.Door, hints: List(#(String, String))) -> Tool {
  let ask = door.definition
  read_tool(
    name: definition_name,
    description: "Find where a symbol is defined, using the language "
      <> "server's semantic view rather than a text search. At most "
      <> int.to_string(max_definition_sites)
      <> " sites are listed."
      <> addressing
      <> language_notes(hints),
    snippet: "`lsp_definition` finds where a symbol is defined, by name; "
      <> "results carry fs_edit anchors.",
    schema: symbol_schema(),
    run: fn(args) { run_definition(ask, args) },
  )
}

/// Builds `lsp_references` over the door's `references` closure.
fn references_tool(door: query.Door) -> Tool {
  let ask = door.references
  read_tool(
    name: references_name,
    description: "Find every reference to a symbol, its declaration "
      <> "included. The answer counts first (references and files), then "
      <> "groups the hits by file and by the function or type containing "
      <> "each one, which answers who depends on the symbol. At most "
      <> int.to_string(max_reference_hits)
      <> " hits are listed; to see the rest, narrow the query."
      <> addressing,
    snippet: "`lsp_references` lists who refers to a symbol, grouped by file "
      <> "and containing function, with fs_edit anchors.",
    schema: symbol_schema(),
    run: fn(args) { run_references(ask, args) },
  )
}

/// Builds `lsp_hover` over the door's `hover` closure.
fn hover_tool(door: query.Door) -> Tool {
  let ask = door.hover
  read_tool(
    name: hover_name,
    description: "Show a symbol's type or signature and its documentation, "
      <> "as the language server reports them. Text past "
      <> int.to_string(max_hover_bytes)
      <> " bytes is cut and says so."
      <> addressing,
    snippet: "`lsp_hover` shows a symbol's type, signature and docs, by name.",
    schema: symbol_schema(),
    run: fn(args) { run_hover(ask, args) },
  )
}

/// Builds `lsp_symbols` over the door's `outline` closure.
fn symbols_tool(door: query.Door) -> Tool {
  let ask = door.outline
  read_tool(
    name: symbols_name,
    description: "Outline one file: every function, type, constant and "
      <> "their nested members, each with its kind, the server's detail "
      <> "(usually a signature) and its anchored line as fs_read prints "
      <> "it. At most "
      <> int.to_string(max_outline_entries)
      <> " lines are listed. Paths outside the language server's project "
      <> "are refused.",
    snippet: "`lsp_symbols` outlines a file's definitions with signatures "
      <> "and fs_edit anchors.",
    schema: tool.object_schema(
      [#("path", tool.string_property("the workspace file to outline"))],
      ["path"],
    ),
    run: fn(args) { run_symbols(ask, args) },
  )
}

/// Builds `lsp_diagnostics` over the door's `diagnostics` closure.
fn diagnostics_tool(door: query.Door) -> Tool {
  let ask = door.diagnostics
  read_tool(
    name: diagnostics_name,
    description: "The language server's current errors and warnings for "
      <> "one file, or for every file it has reported on when `path` is "
      <> "omitted. The answer says whether the diagnostics settled: an "
      <> "unsettled block may be stale or incomplete and never means the "
      <> "code is clean. fs_edit and fs_write already append this block "
      <> "after every write, so call this only for a file you have not "
      <> "just written. At most "
      <> int.to_string(lsp.max_rendered_diagnostics)
      <> " entries are listed; the heading counts all of them.",
    snippet: "`lsp_diagnostics` shows the language server's current errors "
      <> "and warnings.",
    schema: tool.object_schema(
      [
        #(
          "path",
          tool.string_property(
            "optional: one workspace file; omitted, every file the server "
            <> "has reported on",
          ),
        ),
      ],
      [],
    ),
    run: fn(args) { run_diagnostics(ask, args) },
  )
}

// Every tool is a read: re-running it after a crash repeats no effect, and
// it may run beside other reads.
/// Builds one read-only tool: replay-safe, concurrent and needing no sandbox grant.
fn read_tool(
  name name: String,
  description description: String,
  snippet snippet: String,
  schema schema: JsonValue,
  run run: fn(JsonValue) -> ToolOutcome,
) -> Tool {
  tool.Tool(
    name:,
    description:,
    prompt_snippet: Some(snippet),
    schema:,
    replay: tool.Safe,
    execution_mode: tool.Concurrent,
    requirements: empty_requirements,
    run: fn(_ctx, args) { run(args) },
  )
}

// The schema of a symbol-addressed tool: `symbol` required, `path` and
// `line` optional.
/// The argument schema of a symbol-addressed tool: `symbol` required, `path` and `line` optional.
fn symbol_schema() -> JsonValue {
  tool.object_schema(
    [
      #(
        "symbol",
        tool.string_property(
          "the name as the code spells it, e.g. `greet`, or qualified, "
          <> "e.g. `util.Greet`",
        ),
      ),
      #(
        "path",
        tool.string_property(
          "optional: a workspace file the symbol appears in, to narrow it",
        ),
      ),
      #(
        "line",
        tool.integer_property(
          "optional, with `path`: the 1-based line it appears on, as "
          <> "fs_read and grep print it",
        ),
      ),
    ],
    ["symbol"],
  )
}

// The door does its own clearance, per server, when it starts one; the
// tool touches no path through the broker and starts no process, so it
// asks for nothing and composes with any session base.
fn empty_requirements(workspace: String) -> SandboxPolicy {
  let base = tool.read_requirements(workspace)
  policy.SandboxPolicy(..base, readable_roots: [])
}

// --- decoding the arguments -----------------------------------------------

// A symbol query from the arguments. `line` narrows a `path` and means
// nothing alone (the door's contract), so a line without a path is refused
// rather than silently ignored.
/// Decodes `symbol`, `path` and `line` into a `SymbolQuery`, or the refusal the model reads.
fn decode_query(args: JsonValue) -> Result(SymbolQuery, String) {
  use symbol <- result.try(tool.required_string(args, "symbol"))
  use path <- result.try(tool.optional_string(args, "path"))
  use line <- result.try(tool.optional_int(args, "line"))
  let symbol = string.trim(symbol)

  // A blank symbol would be searched for as the empty identifier.
  use Nil <- result.try(case symbol {
    "" -> Error("`symbol` must name a symbol")
    _ -> Ok(Nil)
  })

  use Nil <- result.try(check_line(path, line))
  Ok(query.SymbolQuery(symbol:, path:, line:))
}

// `line` is 1-based because `fs_read` and grep print it that way, and a
// zero or negative line is a model counting from the wrong origin.
/// Refuses a `line` that has no `path` to narrow or that is not 1-based.
fn check_line(path: Option(String), line: Option(Int)) -> Result(Nil, String) {
  case path, line {
    _, None -> Ok(Nil)
    None, Some(_) ->
      Error("`line` narrows a `path`; give the file's `path` as well")
    Some(_), Some(number) if number < 1 ->
      Error("`line` is 1-based, as fs_read prints it")
    Some(_), Some(_) -> Ok(Nil)
  }
}

// A named path must be non-empty: the empty string would reach the door as
// a path and be refused there with a message about the server's root.
/// Decodes the required, non-empty `path` of `lsp_symbols`.
fn decode_path(args: JsonValue) -> Result(String, String) {
  use path <- result.try(tool.required_string(args, "path"))

  // The empty string is a path the door would refuse with a message about
  // the server's root; refuse it here in the model's terms.
  case string.trim(path) {
    "" -> Error("`path` must name a file")
    trimmed -> Ok(trimmed)
  }
}

// An optional path, with the same refusal of an empty string.
/// Decodes the optional `path` of `lsp_diagnostics`, refusing an empty one.
fn decode_optional_path(args: JsonValue) -> Result(Option(String), String) {
  use path <- result.try(tool.optional_string(args, "path"))

  // Absent means every file the server has reported on; present must name one.
  case path {
    None -> Ok(None)
    Some(text) ->
      case string.trim(text) {
        "" -> Error("`path`, when given, must name a file")
        trimmed -> Ok(Some(trimmed))
      }
  }
}

// --- running the tools ----------------------------------------------------

// The tools share one shape. Decode the arguments (`tool.with_arg` returns
// the refusal as the outcome), ask the door (`tool.or_outcome` turns a
// `QueryError` into `render_error`'s text), and render the answer behind its
// warmth line.
/// Runs `lsp_definition`: decode, ask the door, render the sites.
fn run_definition(
  ask: fn(SymbolQuery) -> Result(query.Served(List(Site)), QueryError),
  args: JsonValue,
) -> ToolOutcome {
  use asked <- tool.with_arg(decode_query(args))
  use served <- tool.or_outcome(ask(asked), error_outcome)
  tool.success(with_warmth(
    served.warmth,
    render_definitions(asked.symbol, served.value),
  ))
}

/// Runs `lsp_references`: decode, ask the door, render the grouped hits.
fn run_references(
  ask: fn(SymbolQuery) -> Result(query.Served(List(Reference)), QueryError),
  args: JsonValue,
) -> ToolOutcome {
  use asked <- tool.with_arg(decode_query(args))
  use served <- tool.or_outcome(ask(asked), error_outcome)
  tool.success(with_warmth(
    served.warmth,
    render_references(asked.symbol, served.value),
  ))
}

/// Runs `lsp_hover`: decode, ask the door, render the clipped text.
fn run_hover(
  ask: fn(SymbolQuery) -> Result(query.Served(query.Hover), QueryError),
  args: JsonValue,
) -> ToolOutcome {
  use asked <- tool.with_arg(decode_query(args))
  use served <- tool.or_outcome(ask(asked), error_outcome)
  tool.success(with_warmth(served.warmth, render_hover(served.value)))
}

/// Runs `lsp_symbols`: decode the path, ask the door, render the outline.
fn run_symbols(
  ask: fn(String) -> Result(query.Served(List(SymbolEntry)), QueryError),
  args: JsonValue,
) -> ToolOutcome {
  use path <- tool.with_arg(decode_path(args))
  use served <- tool.or_outcome(ask(path), error_outcome)
  tool.success(with_warmth(served.warmth, render_outline(path, served.value)))
}

/// Runs `lsp_diagnostics`: decode the optional path, ask the door, render the block.
fn run_diagnostics(
  ask: fn(Option(String)) -> Result(query.Served(Diagnostics), QueryError),
  args: JsonValue,
) -> ToolOutcome {
  use path <- tool.with_arg(decode_optional_path(args))
  use served <- tool.or_outcome(ask(path), error_outcome)
  tool.success(with_warmth(served.warmth, lsp.render_diagnostics(served.value)))
}

// --- rendering ------------------------------------------------------------

// A started server costs a handshake and a whole-project compile, seconds
// rather than milliseconds; the first line says so, so a slow answer does
// not read as a hang.
/// Prefixes an answer with a line saying a server was started for it, if one was.
fn with_warmth(warmth: Warmth, body: String) -> String {
  case warmth {
    query.Warm -> body
    query.Started(server:) ->
      "(started the "
      <> server
      <> " language server for this query; later queries are fast)\n"
      <> body
  }
}

// "1 file", "2 files". Every count goes through it so no answer says
// "1 files".
fn plural(count: Int, noun: String) -> String {
  case count {
    1 -> "1 " <> noun
    _ -> int.to_string(count) <> " " <> noun <> "s"
  }
}

// The `fs_read` form of a site's line, for answers that already name the
// file above it.
/// Renders a site's line in `fs_read`'s `line:anchor|text` form.
fn render_anchored(site: Site) -> String {
  hashline.render_line(hashline.AnchoredLine(
    line: site.line,
    anchor: hashline.anchor(site.text),
    text: site.text,
  ))
}

/// What `lsp_definition` answers: a count, then at most
/// `max_definition_sites` sites, with a closing line naming any cut.
///
/// ## Examples
///
/// ```gleam
/// assert lsp_query.render_definitions("greet", [])
///   == "no definition found for `greet`"
/// ```
///
pub fn render_definitions(symbol: String, sites: List(Site)) -> String {
  // No sites reads as a plain "none found"; otherwise count, list and cut.
  case sites {
    [] -> "no definition found for `" <> symbol <> "`"
    [_, ..] -> {
      let hidden = list.length(sites) - max_definition_sites
      plural(list.length(sites), "definition")
      <> " of `"
      <> symbol
      <> "`:\n"
      <> string.join(
        list.map(list.take(sites, max_definition_sites), lsp.render_site),
        "\n",
      )
      <> case hidden > 0 {
        True ->
          "\n… "
          <> int.to_string(hidden)
          <> " more; qualify the name or give a `path` to narrow it"
        False -> ""
      }
    }
  }
}

/// What `lsp_hover` answers: the site, then the server's text, clipped to
/// `max_hover_bytes`.
///
/// ## Examples
///
/// ```gleam
/// // lsp_query.render_hover(query.Hover(site:, contents: "func Greet()"))
/// ```
///
pub fn render_hover(hover: query.Hover) -> String {
  // A server with nothing to say is told as such, not shown as a blank.
  let contents = case string.trim(hover.contents) {
    "" -> "(the language server has no type or documentation for it)"
    trimmed -> lsp.clip(trimmed, max_hover_bytes)
  }

  lsp.render_site(hover.site) <> "\n\n" <> contents
}

/// What `lsp_references` answers: the count and file count first, then the
/// hits grouped by file and, inside a file, by containing symbol.
///
/// At most `max_reference_hits` hits are listed, taken in the grouped order
/// so a truncated list is a prefix of the full one. The heading says how
/// many are shown and a closing line how many were left out. Each file's
/// heading counts all of its references, shown or not.
///
/// ## Examples
///
/// ```gleam
/// assert lsp_query.render_references("greet", [])
///   == "no references to `greet` found"
/// ```
///
pub fn render_references(
  symbol: String,
  references: List(Reference),
) -> String {
  // Nothing found is said plainly; otherwise count, group, bound and trail.
  case references {
    [] -> "no references to `" <> symbol <> "` found"
    [_, ..] -> {
      let files = group(references, reference_path)
      let total = list.length(references)

      // Flattening the grouping first is what makes the bound a prefix of
      // the grouped answer rather than of the server's order.
      let ordered =
        list.flat_map(files, fn(file) {
          list.flat_map(group(file.1, reference_container), fn(pair) { pair.1 })
        })
      let shown = list.take(ordered, max_reference_hits)
      let hidden = total - list.length(shown)
      let counts =
        dict.from_list(
          list.map(files, fn(file) { #(file.0, list.length(file.1)) }),
        )
      string.join(
        [
          references_heading(symbol, total, list.length(files), hidden),
          ..list.map(group(shown, reference_path), render_reference_file(
            _,
            counts,
          ))
        ],
        "\n",
      )
      <> references_trailer(hidden)
    }
  }
}

// The count line. When some hits are hidden it also says how many are
// shown, so the heading alone tells a model the list is partial.
/// The count line of a reference answer, saying how many are shown when some are cut.
fn references_heading(
  symbol: String,
  total: Int,
  files: Int,
  hidden: Int,
) -> String {
  let heading =
    plural(total, "reference")
    <> " to `"
    <> symbol
    <> "` in "
    <> plural(files, "file")

  // Nothing hidden means the heading alone is the whole count.
  case hidden {
    0 -> heading
    _ -> heading <> "; showing " <> int.to_string(max_reference_hits)
  }
}

/// The closing line naming how many references were left out, or nothing.
fn references_trailer(hidden: Int) -> String {
  // A trailer exists only when some hits were cut.
  case hidden {
    0 -> ""
    _ ->
      "\n… "
      <> int.to_string(hidden)
      <> " more not shown; narrow with `path` and `line`"
  }
}

// One file's block: its heading counts every reference in the file, shown
// or not, and its hits sit under the containing function or type, so the
// list answers who depends on the symbol.
/// One file's block of references, grouped under their containing symbols.
fn render_reference_file(
  file: #(String, List(Reference)),
  counts: Dict(String, Int),
) -> String {
  let #(path, references) = file
  let count =
    dict.get(counts, path)
    |> result.lazy_unwrap(fn() { list.length(references) })
  let containers =
    group(references, reference_container)
    |> list.map(fn(pair) {
      // A reference outside every symbol, such as an import line, is
      // "at top level".
      let heading = case pair.0 {
        Some(name) -> "  in " <> name <> ":"
        None -> "  at top level:"
      }

      [
        heading,
        ..list.map(pair.1, fn(hit) { "    " <> lsp.render_site(hit.site) })
      ]
      |> string.join("\n")
    })
  string.join(
    [path <> " (" <> plural(count, "reference") <> "):", ..containers],
    "\n",
  )
}

fn reference_path(reference: Reference) -> String {
  reference.site.path
}

fn reference_container(reference: Reference) -> Option(String) {
  reference.container
}

// Groups items by key, keeping the order in which each key first appears
// and each group's items in their original order.
/// Groups items by key, keeping first-appearance order of keys and original order within each.
fn group(items: List(a), key: fn(a) -> k) -> List(#(k, List(a))) {
  let #(order, groups) =
    list.fold(items, #([], dict.new()), fn(state, item) {
      let #(order, groups) = state
      let name = key(item)

      // A key seen before extends its group; a new key opens one and
      // records where it first appeared.
      case dict.get(groups, name) {
        Ok(members) -> #(order, dict.insert(groups, name, [item, ..members]))
        Error(Nil) -> #([name, ..order], dict.insert(groups, name, [item]))
      }
    })
  order
  |> list.reverse
  |> list.map(fn(name) {
    #(name, dict.get(groups, name) |> result.unwrap([]) |> list.reverse)
  })
}

/// What `lsp_symbols` answers: a count, then the outline nested as the
/// server nests it, each entry as its kind, name and detail over its
/// anchored line in `fs_read`'s form. At most `max_outline_entries` lines
/// are listed and a closing line says how many entries were left out.
///
/// ## Examples
///
/// ```gleam
/// assert lsp_query.render_outline("src/a.go", []) == "no symbols in src/a.go"
/// ```
///
pub fn render_outline(path: String, entries: List(SymbolEntry)) -> String {
  // An empty outline is said plainly; otherwise count, list and cut.
  case entries {
    [] -> "no symbols in " <> path
    [_, ..] -> {
      let total = count_entries(entries)
      let #(lines, shown) = outline_lines(entries, "", max_outline_entries)
      let hidden = total - shown
      plural(total, "symbol")
      <> " in "
      <> path
      <> ":\n"
      <> string.join(lines, "\n")
      <> case hidden > 0 {
        True -> "\n… " <> int.to_string(hidden) <> " more symbols not shown"
        False -> ""
      }
    }
  }
}

fn count_entries(entries: List(SymbolEntry)) -> Int {
  list.fold(entries, 0, fn(total, entry) {
    total + 1 + count_entries(entry.children)
  })
}

// The outline's lines in order, stopping once `budget` entries are shown;
// the second value is how many entries made it in. A cut is always at an
// entry boundary, so no entry is half shown.
/// The outline's lines in order, stopping at an entry boundary once the budget is spent.
fn outline_lines(
  entries: List(SymbolEntry),
  indent: String,
  budget: Int,
) -> #(List(String), Int) {
  // An exhausted budget or no entries ends the walk; otherwise one entry,
  // its children, then its siblings share what is left.
  case entries, budget <= 0 {
    [], _ | _, True -> #([], 0)
    [entry, ..rest], False -> {
      let own = outline_entry(entry, indent)
      let #(inner, inner_shown) =
        outline_lines(entry.children, indent <> "  ", budget - 1)
      let #(after, after_shown) =
        outline_lines(rest, indent, budget - 1 - inner_shown)
      #(list.flatten([own, inner, after]), 1 + inner_shown + after_shown)
    }
  }
}

/// The two lines one outline entry prints: its kind, name and detail, then its anchored line.
fn outline_entry(entry: SymbolEntry, indent: String) -> List(String) {
  // The detail is usually a signature and is shown only when there is one.
  let detail = case entry.detail {
    Some(detail) if detail != "" -> " — " <> detail
    Some(_) | None -> ""
  }

  [
    indent <> entry.kind <> " " <> entry.name <> detail,
    indent <> "  " <> render_anchored(entry.site),
  ]
}

/// The words a model reads for a refused or failed query. A query that
/// cannot reach a server (none owns the file, the path is past the
/// server's root, the request timed out or the server died) begins
/// "language server unavailable", so a model can tell it from a question
/// the server answered with nothing.
///
/// ## Examples
///
/// ```gleam
/// assert string.starts_with(
///   lsp_query.render_error(query.NoServer("no server owns a.txt")),
///   "language server unavailable",
/// )
/// ```
///
pub fn render_error(error: QueryError) -> String {
  case error {
    query.NoServer(reason:) ->
      "language server unavailable: "
      <> reason
      <> ". Servers are configured per file extension as [lsp.<name>] "
      <> "tables; for files no server owns, use grep and fs_read."
    query.Unavailable(reason:) ->
      "language server unavailable: "
      <> reason
      <> ". If the server was restarting or busy, asking again may work; "
      <> "grep and fs_read work meanwhile."
    query.Unsupported(server:, request:) ->
      "the "
      <> server
      <> " language server does not support "
      <> request
      <> ", so it was not asked. lsp_references names the function "
      <> "containing each reference, and grep finds text."
    query.NotFound(query: asked, searched:) ->
      "`"
      <> asked.symbol
      <> "` was not found "
      <> where(asked, searched)
      <> ". Check the spelling, qualify it the way the code does "
      <> "(`module.name`), or give the `path` and the 1-based `line` where "
      <> "it appears."
    query.Ambiguous(candidates:) ->
      "the name is ambiguous: "
      <> plural(list.length(candidates), "distinct definition")
      <> " match:\n"
      <> string.join(
        list.map(list.take(candidates, max_definition_sites), lsp.render_site),
        "\n",
      )
      <> "\nAsk again with `path` (and `line`) naming one of them, or "
      <> "qualify the name (`module.name`)."
    query.ServerRefused(message:) -> "the language server refused: " <> message
  }
}

// Where the search looked, in the words the model can act on. A query that
// named no file searched a server's root, which the door words itself.
/// Words where a failed search looked, from the query and the door's own note.
fn where(asked: SymbolQuery, searched: Option(String)) -> String {
  case asked.path, asked.line, searched {
    Some(path), Some(line), _ ->
      "on line " <> int.to_string(line) <> " of " <> path
    Some(path), None, _ -> "in " <> path
    None, _, Some(root) -> "in " <> root
    None, _, None -> "in the workspace"
  }
}

fn error_outcome(error: QueryError) -> ToolOutcome {
  tool.failure(render_error(error))
}
