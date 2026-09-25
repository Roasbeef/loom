//// The `lsp_*` tools: a language server's semantic view of the code, asked
//// by symbol name and answered in the shape the next edit needs.
////
//// # Why this module exists
////
//// The agent edits by hashline anchor and finds code by grep, which knows
//// text and nothing else. A language server knows where a name is
//// defined, who refers to it, what type it has, and whether the code
//// still compiles after a change (ADR-013). This module is the model's
//// half of that view: seven tool definitions, the argument decoding, and
//// the rendering. Everything with teeth — the jailed server, document
//// sync, symbol resolution, settlement — is on the far side of
//// `lsp/query.Door`, a record of closures `client` fills from the
//// session's one language-server manager, exactly as it fills `Agency`
//// or `CodeMode`.
////
//// # Names in, anchors out
////
//// A model never supplies a position. Every tool that addresses a symbol
//// takes the name as code spells it (`greet`, or qualified as
//// `util.Greet`), optionally narrowed by a `path` and the 1-based `line`
//// `fs_read` prints (ADR-013 §5). And every site an answer names is
//// rendered as `path:line:anchor|text` — a `grep` hit with the hashline
//// anchor `fs_read` would have printed for that line spliced in — so a
//// result feeds `fs_edit` directly, with no read round trip in between.
//// Lists count before they list and stop at a bound, so a model knows
//// when to narrow a query or move it into code mode.
////
//// # Rename lands through the one landing path
////
//// A rename is answered in two halves. The door's `prepare_rename` asks
//// the server and hands back each file's text before and after, writing
//// nothing. `land` then turns each pair into a hashline plan bound to the
//// text the server saw, checks every file against the disk before the
//// first byte is written, and writes through `fs.land_plan` — the same
//// path `fs_edit` takes — so a file changed since the server looked is
//// refused as stale rather than overwritten (ADR-013 §4). `land` needs no
//// `Ctx`, because code mode lands a rename through it too; the write
//// boundary arrives as a closure that makes `fs.WriteTarget`s.

import broker/policy.{type SandboxPolicy}
import core/json.{type JsonValue}
import core/message
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import lsp/query.{
  type Call, type CallDirection, type Diagnostic, type Diagnostics,
  type FileEdit, type Landing, type QueryError, type Reference,
  type RenameReport, type Site, type SymbolEntry, type SymbolQuery, type Warmth,
}
import tools/fs
import tools/hashline
import tools/tool.{type Ctx, type FileSystem, type Tool, type ToolOutcome}

/// The most reference hits `lsp_references` lists. Past it the answer says
/// how many it left out, because a reference list is unbounded and a
/// model that needs every one of them is better served by a program.
pub const max_reference_hits = 50

/// The most diagnostics a rendered block lists, in `lsp_diagnostics`, a
/// rename's report and the post-write block alike. The count heading
/// still names every one.
pub const max_rendered_diagnostics = 20

/// The most bytes of a server's hover text `lsp_hover` shows.
///
/// The server decides how long a hover is, and some render a whole
/// module's documentation or an expanded type hundreds of lines long;
/// without a bound here the only limit would be the 16 MiB frame cap.
/// Four KiB holds a signature and its doc comment. Past it the text is cut
/// by `clip` and says how much was left out, so a model that needs the
/// rest reads the definition instead.
pub const max_hover_bytes = 4096

/// Whether `lsp_rename` shows the change or makes it.
///
/// Preview is the default. A rename touches every file that names the
/// symbol and is not atomic across them, so the first call shows every
/// changed line and writes nothing, and the model applies what it has
/// seen (ADR-013 §5, "Preview first").
pub type RenameMode {
  /// Ask the server and render every changed line; write nothing.
  Preview

  /// Ask the server and land every file through the hashline path.
  Apply
}

/// The seven `lsp_*` tools over one door.
///
/// The host registers them only when a language server is configured,
/// because the tool array is the cached prefix and an unconfigured
/// workspace should pay nothing for them (ADR-013 §6).
///
/// `hints` are the configured servers' profile hints, as `#(server name,
/// hint)` in the order they should be read (ADR-014 §2). Each tells the
/// model how its language spells a qualified name, and they are appended
/// once, as one "Language notes:" block, to `lsp_definition`'s description
/// and nowhere else: every other symbol-taking tool addresses symbols the
/// same way, so one statement reaches them all without paying for the
/// text seven times in the cached prefix. With no hints every description
/// is exactly what it was before hints existed.
///
/// ## Examples
///
/// ```gleam
/// // tool.registry(list.append(core_tools, lsp.tools(door, [])))
/// ```
///
/// ```gleam
/// // lsp.tools(door, [#("rust", "Qualify as module::name, without crate::")])
/// ```
///
pub fn tools(door: query.Door, hints: List(#(String, String))) -> List(Tool) {
  [
    definition_tool(door, hints),
    references_tool(door),
    hover_tool(door),
    symbols_tool(door),
    calls_tool(door),
    diagnostics_tool(door),
    rename_tool(door),
  ]
}

// --- the tool definitions -------------------------------------------------

// The servers' hints as the block `lsp_definition`'s description ends
// with, one `name: hint` line each, or nothing at all when no server
// wrote one, so a session without hints carries the description
// byte-for-byte as it was. The hints themselves are single printable
// lines (`client/lsp/profile` refuses anything else), so each stays one
// line of the block.
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

// The sentence every symbol-addressed description ends with, so the three
// facts a model needs to call these well are stated once and identically.
const addressing = " Address the symbol by name as the code spells it, "
  <> "optionally qualified (`util.Greet`, `probe.greet`); positions are "
  <> "never needed. Add `path`, and `line` as fs_read prints it, only to "
  <> "narrow an ambiguous name. Every site in the answer is printed as "
  <> "`path:line:anchor|text`, so it can be edited with fs_edit without "
  <> "reading the file first."

fn definition_tool(door: query.Door, hints: List(#(String, String))) -> Tool {
  read_tool(
    name: "lsp_definition",
    description: "Find where a symbol is defined, using the language "
      <> "server's semantic view rather than a text search."
      <> addressing
      <> language_notes(hints),
    snippet: "`lsp_definition` finds where a symbol is defined, by name; "
      <> "results carry fs_edit anchors.",
    schema: symbol_schema([], []),
    run: fn(args) { run_definition(door, args) },
  )
}

fn references_tool(door: query.Door) -> Tool {
  read_tool(
    name: "lsp_references",
    description: "Find every reference to a symbol, its declaration "
      <> "included. The answer counts first (references and files), then "
      <> "groups the hits by file and by the function or type containing "
      <> "each one, which answers who depends on the symbol. At most "
      <> int.to_string(max_reference_hits)
      <> " hits are listed; for the full list narrow the query or use code "
      <> "mode (cap/lsp)."
      <> addressing,
    snippet: "`lsp_references` lists who refers to a symbol, grouped by file "
      <> "and containing function, with fs_edit anchors.",
    schema: symbol_schema([], []),
    run: fn(args) { run_references(door, args) },
  )
}

fn hover_tool(door: query.Door) -> Tool {
  read_tool(
    name: "lsp_hover",
    description: "Show a symbol's type or signature and its documentation, "
      <> "as the language server reports them."
      <> addressing,
    snippet: "`lsp_hover` shows a symbol's type, signature and docs, by name.",
    schema: symbol_schema([], []),
    run: fn(args) { run_hover(door, args) },
  )
}

fn symbols_tool(door: query.Door) -> Tool {
  read_tool(
    name: "lsp_symbols",
    description: "Outline one file: every function, type, constant and "
      <> "their nested members, each with its kind, the server's detail "
      <> "(usually a signature) and its anchored line as fs_read prints "
      <> "it, so any entry can be edited with fs_edit directly.",
    snippet: "`lsp_symbols` outlines a file's definitions with signatures "
      <> "and fs_edit anchors.",
    schema: tool.object_schema(
      [#("path", tool.string_property("the workspace file to outline"))],
      ["path"],
    ),
    run: fn(args) { run_symbols(door, args) },
  )
}

fn calls_tool(door: query.Door) -> Tool {
  read_tool(
    name: "lsp_calls",
    description: "One level of the call hierarchy around a function: "
      <> "`incoming` lists its callers, `outgoing` what it calls, each with "
      <> "where it is defined and where the call is. Not every language "
      <> "server offers this; where one does not, lsp_references names the "
      <> "function containing each reference, which is the same caller "
      <> "view."
      <> addressing,
    snippet: "`lsp_calls` lists a function's callers or callees, by name.",
    schema: symbol_schema(
      [
        #(
          "direction",
          tool.enum_property(
            ["incoming", "outgoing"],
            "`incoming` for who calls the symbol, `outgoing` for what it calls",
          ),
        ),
      ],
      ["direction"],
    ),
    run: fn(args) { run_calls(door, args) },
  )
}

fn diagnostics_tool(door: query.Door) -> Tool {
  read_tool(
    name: "lsp_diagnostics",
    description: "The language server's current errors and warnings, for "
      <> "one file or for every file it has reported on. The answer says "
      <> "whether the diagnostics settled: an unsettled block may be stale "
      <> "or incomplete and never means the code is clean. fs_edit and "
      <> "fs_write already append this block after every write, so call "
      <> "this only for a file you have not just written.",
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
    run: fn(args) { run_diagnostics(door, args) },
  )
}

fn rename_tool(door: query.Door) -> Tool {
  tool.Tool(
    name: "lsp_rename",
    description: "Rename a symbol everywhere the language server knows it "
      <> "is used. `mode` defaults to \"preview\", which writes nothing and "
      <> "shows every changed line before and after, with anchors; call "
      <> "again with \"apply\" to write it. Preview is the default because a "
      <> "rename touches many files and is not atomic across them: apply "
      <> "checks every file against what the server saw before writing any, "
      <> "refuses the whole rename if one changed since, and reports file "
      <> "by file what was written, followed by the diagnostics after it."
      <> addressing,
    prompt_snippet: Some(
      "`lsp_rename` renames a symbol across files by name: preview first, "
      <> "then apply.",
    ),
    schema: symbol_schema(
      [
        #("new_name", tool.string_property("the new identifier")),
        #(
          "mode",
          tool.enum_property(
            ["preview", "apply"],
            "\"preview\" (default) shows the change and writes nothing; "
              <> "\"apply\" writes it",
          ),
        ),
      ],
      ["new_name"],
    ),
    replay: tool.Never,
    execution_mode: tool.Exclusive,
    requirements: empty_requirements,
    run: fn(ctx, args) { run_rename(door, ctx, args) },
  )
}

// Every tool but rename is a read: re-running it after a crash repeats no
// effect, and it may run beside other reads.
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
// `line` optional, then the tool's own properties and requirements.
fn symbol_schema(
  extra: List(#(String, JsonValue)),
  required: List(String),
) -> JsonValue {
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
      ..extra
    ],
    ["symbol", ..required],
  )
}

// The door does its own clearance, per server, when it starts one; the
// tool itself touches no path through the broker and starts no process,
// so it asks for nothing and composes with any session base. A rename's
// writes go through `fs.edit_target`, which carries `fs_edit`'s own
// resolution and approval.
fn empty_requirements(workspace: String) -> SandboxPolicy {
  let base = tool.read_requirements(workspace)
  policy.SandboxPolicy(..base, readable_roots: [])
}

// --- decoding the arguments -----------------------------------------------

// A symbol query from the arguments. `line` narrows a `path` and means
// nothing alone (the door's contract), so a line without a path is refused
// here rather than silently ignored.
fn decode_query(args: JsonValue) -> Result(SymbolQuery, String) {
  use symbol <- result.try(tool.required_string(args, "symbol"))
  use path <- result.try(tool.optional_string(args, "path"))
  use line <- result.try(tool.optional_int(args, "line"))
  let symbol = string.trim(symbol)
  use Nil <- result.try(case symbol {
    "" -> Error("`symbol` must name a symbol")
    _ -> Ok(Nil)
  })
  use Nil <- result.try(check_line(path, line))
  Ok(query.SymbolQuery(symbol:, path:, line:))
}

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

// The closed vocabulary of `direction`. Anything else is refused in band
// rather than defaulted: a model that asked for callers and got callees
// would read the answer backwards.
fn decode_direction(args: JsonValue) -> Result(CallDirection, String) {
  use direction <- result.try(tool.required_string(args, "direction"))
  case direction {
    "incoming" -> Ok(query.Incoming)
    "outgoing" -> Ok(query.Outgoing)
    other ->
      Error(
        "`direction` must be \"incoming\" or \"outgoing\", not \""
        <> other
        <> "\"",
      )
  }
}

// `mode` defaults to preview; an unknown value is refused rather than
// read as either, because guessing "apply" writes files.
fn decode_mode(args: JsonValue) -> Result(RenameMode, String) {
  use mode <- result.try(tool.optional_string(args, "mode"))
  case mode {
    None | Some("preview") -> Ok(Preview)
    Some("apply") -> Ok(Apply)
    Some(other) ->
      Error("`mode` must be \"preview\" or \"apply\", not \"" <> other <> "\"")
  }
}

fn decode_new_name(args: JsonValue) -> Result(String, String) {
  use new_name <- result.try(tool.required_string(args, "new_name"))
  case string.trim(new_name) {
    "" -> Error("`new_name` must name the new identifier")
    trimmed -> Ok(trimmed)
  }
}

// --- running the read tools -----------------------------------------------

fn run_definition(door: query.Door, args: JsonValue) -> ToolOutcome {
  use asked <- tool.with_arg(decode_query(args))
  use served <- tool.or_outcome(door.definition(asked), error_outcome)
  tool.success(with_warmth(
    served.warmth,
    render_definitions(asked.symbol, served.value),
  ))
}

fn run_references(door: query.Door, args: JsonValue) -> ToolOutcome {
  use asked <- tool.with_arg(decode_query(args))
  use served <- tool.or_outcome(door.references(asked), error_outcome)
  let references = served.value
  let text =
    with_warmth(served.warmth, render_references(asked.symbol, references))

  // The counts travel in the details too, so a client can show them
  // without parsing the heading.
  tool.success(text)
  |> tool.with_details(
    json.Object([
      #("references", json.Int(list.length(references))),
      #("files", json.Int(list.length(group(references, reference_path)))),
      #("shown", json.Int(int.min(list.length(references), max_reference_hits))),
    ]),
  )
}

fn run_hover(door: query.Door, args: JsonValue) -> ToolOutcome {
  use asked <- tool.with_arg(decode_query(args))
  use served <- tool.or_outcome(door.hover(asked), error_outcome)
  tool.success(with_warmth(served.warmth, render_hover(served.value)))
}

fn run_symbols(door: query.Door, args: JsonValue) -> ToolOutcome {
  use path <- tool.with_arg(tool.required_string(args, "path"))
  use served <- tool.or_outcome(door.outline(path), error_outcome)
  tool.success(with_warmth(served.warmth, render_outline(path, served.value)))
}

fn run_calls(door: query.Door, args: JsonValue) -> ToolOutcome {
  use asked <- tool.with_arg(decode_query(args))
  use direction <- tool.with_arg(decode_direction(args))
  use served <- tool.or_outcome(door.calls(asked, direction), error_outcome)
  tool.success(with_warmth(
    served.warmth,
    render_calls(asked.symbol, direction, served.value),
  ))
}

fn run_diagnostics(door: query.Door, args: JsonValue) -> ToolOutcome {
  use path <- tool.with_arg(tool.optional_string(args, "path"))
  use served <- tool.or_outcome(door.diagnostics(path), error_outcome)
  tool.success(with_warmth(served.warmth, render_diagnostics(served.value)))
}

// --- rename ---------------------------------------------------------------

// Every argument is decoded before the server is asked, so an invalid
// `mode` costs no request. Preview and apply ask the same question; they
// differ only in what happens to the answer.
fn run_rename(door: query.Door, ctx: Ctx, args: JsonValue) -> ToolOutcome {
  use asked <- tool.with_arg(decode_query(args))
  use new_name <- tool.with_arg(decode_new_name(args))
  use mode <- tool.with_arg(decode_mode(args))
  use served <- tool.or_outcome(
    door.prepare_rename(asked, new_name),
    error_outcome,
  )
  let edits = served.value
  use <- or_no_edits(edits, asked.symbol, new_name)
  case mode {
    Preview ->
      tool.success(with_warmth(
        served.warmth,
        render_preview(asked.symbol, new_name, edits),
      ))
    Apply -> apply_rename(door, ctx, asked.symbol, new_name, served)
  }
}

// A server that proposes nothing has nothing to preview or land; saying
// so plainly beats a report of zero files that reads like success.
fn or_no_edits(
  edits: List(FileEdit),
  symbol: String,
  new_name: String,
  then: fn() -> ToolOutcome,
) -> ToolOutcome {
  case edits {
    [] ->
      tool.failure(
        "the language server proposed no edits for renaming `"
        <> symbol
        <> "` to `"
        <> new_name
        <> "`; nothing was written",
      )
    [_, ..] -> then()
  }
}

// The tool's apply path: `fs.edit_target` is the target maker, so each
// file goes through exactly the resolution, protected-path refusal and
// approval `fs_edit` gives it.
fn apply_rename(
  door: query.Door,
  ctx: Ctx,
  symbol: String,
  new_name: String,
  served: query.Served(List(FileEdit)),
) -> ToolOutcome {
  let target = fn(path) {
    fs.edit_target(ctx, path) |> result.map_error(outcome_text)
  }
  let report =
    land(
      edits: served.value,
      target:,
      filesystem: ctx.filesystem,
      after_write: door.after_write,
    )
  let text = with_warmth(served.warmth, render_report(symbol, new_name, report))
  let outcome = case list.all(report.files, is_landed) {
    True -> tool.success(text)
    False -> tool.failure(text)
  }
  tool.with_details(outcome, report_details(report))
}

fn report_details(report: RenameReport) -> JsonValue {
  json.Object([
    #(
      "files",
      json.Array(
        list.map(report.files, fn(landing) {
          case landing {
            query.Landed(path:, edits:) ->
              json.Object([
                #("path", json.String(path)),
                #("status", json.String("landed")),
                #("edits", json.Int(edits)),
              ])
            query.Rejected(path:, reason:) ->
              json.Object([
                #("path", json.String(path)),
                #("status", json.String("rejected")),
                #("reason", json.String(reason)),
              ])
            query.NotAttempted(path:) ->
              json.Object([
                #("path", json.String(path)),
                #("status", json.String("not_attempted")),
              ])
          }
        }),
      ),
    ),
  ])
}

/// A rename file, ready to write: its plan, bound to the text the server
/// saw, and its resolved write target.
type Prepared {
  Prepared(edit: FileEdit, plan: hashline.Plan, target: fs.WriteTarget)
}

/// Lands a rename's edits through the hashline path and reports, file by
/// file, exactly what was written.
///
/// Four phases, in ADR-013 §4's order, and every one of the first three
/// runs over every file before the next begins:
///
/// 1. each file's plan is built with `hashline.plan_between`, bound to the
///    digest of the text the server computed against;
/// 2. each file's write target is resolved through `target` — for the
///    tool, `fs.edit_target`, so approval is asked only once every plan
///    exists;
/// 3. each file is read from disk and its digest compared with the
///    base's.
///
/// If any of those fails for any file, **nothing is written**: the
/// failing files are `Rejected` with the reason and every other file is
/// `NotAttempted`. Only then, in path order, is each file written by
/// `fs.land_plan` — which checks the digest again against what it reads,
/// so a change landing between the check and the write still rejects as
/// stale. A write that fails is `Rejected` and the rest are still
/// written: landing across files is not atomic, and an earlier landing is
/// never undone, which is why the report names every file.
///
/// Then `after_write` is told of each landed path, in the same order, and
/// the report carries the last answer's diagnostics — `Unsettled` if any
/// answer did not settle, since a half-current view is not a current one.
/// When nothing landed, or no server owns any landed path, the
/// diagnostics are `Unsettled([])`: nothing was asked, and an empty
/// settled list would read as clean code.
///
/// `target` is a closure so that code mode, which holds write authority
/// but no `Ctx`, lands through this same function with
/// `fs.write_target`.
///
/// ## Examples
///
/// ```gleam
/// // lsp.land(
/// //   edits:,
/// //   target: fn(path) { fs.write_target(..) |> result.map_error(describe) },
/// //   filesystem:,
/// //   after_write: door.after_write,
/// // )
/// // -> RenameReport(files: [Landed("src/a.gleam", 2)], diagnostics: ..)
/// ```
///
pub fn land(
  edits edits: List(FileEdit),
  target target: fn(String) -> Result(fs.WriteTarget, String),
  filesystem filesystem: FileSystem,
  after_write after_write: fn(String) -> Option(Diagnostics),
) -> RenameReport {
  let ordered =
    list.sort(edits, fn(left, right) { string.compare(left.path, right.path) })

  // The three pre-checks. Each is a phase over every file, and the first
  // phase with a failure ends the landing before any byte is written.
  let checked = {
    use planned <- result.try(phase(ordered, edit_path, plan_file))
    use prepared <- result.try(
      phase(
        planned,
        fn(pair: #(FileEdit, hashline.Plan)) { pair.0.path },
        target_file(target, _),
      ),
    )
    phase(prepared, prepared_path, check_disk(filesystem, _))
  }

  case checked {
    Error(files) -> query.RenameReport(files:, diagnostics: query.Unsettled([]))
    Ok(prepared) -> write_all(prepared, filesystem, after_write)
  }
}

fn edit_path(edit: FileEdit) -> String {
  edit.path
}

fn prepared_path(prepared: Prepared) -> String {
  prepared.edit.path
}

// One pre-check over every file. All passing hands the next phase its
// inputs; any failing ends the landing with the report it owes: the
// failures `Rejected` with their reasons, everything else `NotAttempted`.
fn phase(
  items: List(a),
  path: fn(a) -> String,
  step: fn(a) -> Result(b, String),
) -> Result(List(b), List(Landing)) {
  let results = list.map(items, fn(item) { #(item, step(item)) })
  case list.all(results, fn(pair) { result.is_ok(pair.1) }) {
    True -> Ok(list.filter_map(results, fn(pair) { pair.1 }))
    False ->
      Error(
        list.map(results, fn(pair) {
          case pair.1 {
            Ok(_) -> query.NotAttempted(path: path(pair.0))
            Error(reason) -> query.Rejected(path: path(pair.0), reason:)
          }
        }),
      )
  }
}

fn plan_file(edit: FileEdit) -> Result(#(FileEdit, hashline.Plan), String) {
  hashline.plan_between(base: edit.base, edited: edit.edited)
  |> result.map(fn(plan) { #(edit, plan) })
  |> result.map_error(fn(_unreachable) {
    "the server's edited text ends differently from the file (a final "
    <> "newline added or removed), which no line edit can produce; nothing "
    <> "was written"
  })
}

fn target_file(
  target: fn(String) -> Result(fs.WriteTarget, String),
  pair: #(FileEdit, hashline.Plan),
) -> Result(Prepared, String) {
  let #(edit, plan) = pair
  use resolved <- result.try(target(edit.path))
  Ok(Prepared(edit:, plan:, target: resolved))
}

// The concurrency check, made before any write: the disk must still hold
// exactly the text the server computed its answer against. `land_plan`
// checks the same digest again when it writes, but only file by file —
// this pass is what makes a stale file stop the whole rename rather than
// half of it.
fn check_disk(
  filesystem: FileSystem,
  prepared: Prepared,
) -> Result(Prepared, String) {
  let resolved = fs.target_path(prepared.target)
  use current <- result.try(
    fs.read_text_file(filesystem:, resolved:)
    |> result.map_error(fn(error) {
      outcome_text(fs.land_error_outcome(fs.LandUnreadable(error)))
    }),
  )
  let on_disk = hashline.digest(current)
  case on_disk == prepared.plan.digest {
    True -> Ok(prepared)
    False ->
      Error(
        "the file changed after the language server computed the rename "
        <> "(disk digest "
        <> on_disk
        <> ", the server saw "
        <> prepared.plan.digest
        <> "); nothing was written. Ask lsp_rename again to recompute it.",
      )
  }
}

// Every pre-check passed: write each file in path order, then tell the
// server about each landed one. The writes all happen before the first
// notification so the server's last settlement is over the finished
// rename, not a half-written one.
fn write_all(
  prepared: List(Prepared),
  filesystem: FileSystem,
  after_write: fn(String) -> Option(Diagnostics),
) -> RenameReport {
  let files = list.map(prepared, land_file(filesystem, _))
  let answers =
    files
    |> list.filter_map(landed_path)
    |> list.filter_map(fn(path) { after_write(path) |> option.to_result(Nil) })
  query.RenameReport(files:, diagnostics: combine(answers))
}

fn land_file(filesystem: FileSystem, prepared: Prepared) -> Landing {
  let path = prepared.edit.path
  case fs.land_plan(filesystem:, target: prepared.target, plan: prepared.plan) {
    Ok(_) -> query.Landed(path:, edits: prepared.edit.edits)
    Error(error) ->
      query.Rejected(path:, reason: outcome_text(fs.land_error_outcome(error)))
  }
}

fn landed_path(landing: Landing) -> Result(String, Nil) {
  case landing {
    query.Landed(path:, ..) -> Ok(path)
    query.Rejected(..) | query.NotAttempted(..) -> Error(Nil)
  }
}

fn is_landed(landing: Landing) -> Bool {
  result.is_ok(landed_path(landing))
}

// The last answer is the newest view of the whole rename. One unsettled
// answer anywhere makes the whole block unsettled: the server did not
// finish with some file, so the last view may be missing what it found.
fn combine(answers: List(Diagnostics)) -> Diagnostics {
  case list.last(answers) {
    Error(Nil) -> query.Unsettled([])
    Ok(last) ->
      case list.any(answers, is_unsettled) {
        True -> query.Unsettled(diagnostic_entries(last))
        False -> last
      }
  }
}

fn is_unsettled(diagnostics: Diagnostics) -> Bool {
  case diagnostics {
    query.Settled(..) -> False
    query.Unsettled(..) -> True
  }
}

fn diagnostic_entries(diagnostics: Diagnostics) -> List(Diagnostic) {
  case diagnostics {
    query.Settled(diagnostics:) -> diagnostics
    query.Unsettled(seen:) -> seen
  }
}

// --- post-write diagnostics -----------------------------------------------

/// The `fs.WriteObserver` a host hands `fs.write_tool_with` and
/// `fs.edit_tool_with`: after a write lands, the door is told of it and
/// its diagnostics are rendered as the block the result gains (ADR-013
/// §6). A path no server owns answers `None` and leaves the result as it
/// was.
///
/// ## Examples
///
/// ```gleam
/// // fs.edit_tool_with(lsp.diagnostics_observer(door))
/// ```
///
pub fn diagnostics_observer(door: query.Door) -> fs.WriteObserver {
  // The observer lives as long as the tools it is handed to; it keeps the
  // one closure it calls, not the whole door.
  let after_write = door.after_write
  fn(path) { after_write(path) |> option.map(render_diagnostics) }
}

// --- rendering ------------------------------------------------------------

/// One site as every `lsp_*` answer prints it: `path:line:anchor|text`.
///
/// That is a `grep` hit with the hashline anchor spliced in, and its
/// `line:anchor|text` tail is exactly the line `fs_read` prints, so the
/// line and anchor feed an `fs_edit` reference unchanged.
///
/// ## Examples
///
/// ```gleam
/// let site = query.Site(path: "a.gleam", line: 3, column: 1, text: "x")
/// assert lsp.render_site(site)
///   == "a.gleam:3:" <> hashline.anchor("x") <> "|x"
/// ```
///
pub fn render_site(site: Site) -> String {
  site.path <> ":" <> render_anchored(site)
}

// The `fs_read` form of a site's line, for answers that already name the
// file above it.
fn render_anchored(site: Site) -> String {
  hashline.render_line(hashline.AnchoredLine(
    line: site.line,
    anchor: hashline.anchor(site.text),
    text: site.text,
  ))
}

// A started server costs a handshake and a whole-project compile, seconds
// rather than milliseconds; the first line says so, so a slow answer does
// not read as a hang, and the next one is not feared.
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

fn plural(count: Int, noun: String) -> String {
  case count {
    1 -> "1 " <> noun
    _ -> int.to_string(count) <> " " <> noun <> "s"
  }
}

/// What `lsp_definition` answers.
///
/// ## Examples
///
/// ```gleam
/// assert lsp.render_definitions("greet", [])
///   == "no definition found for `greet`"
/// ```
///
pub fn render_definitions(symbol: String, sites: List(Site)) -> String {
  case sites {
    [] -> "no definition found for `" <> symbol <> "`"
    _ ->
      plural(list.length(sites), "definition")
      <> " of `"
      <> symbol
      <> "`:\n"
      <> string.join(list.map(sites, render_site), "\n")
  }
}

/// What `lsp_hover` answers: the site, then the server's text.
///
/// ## Examples
///
/// ```gleam
/// // lsp.render_hover(query.Hover(site:, contents: "fn(String) -> String"))
/// ```
///
pub fn render_hover(hover: query.Hover) -> String {
  let contents = case string.trim(hover.contents) {
    "" -> "(the language server has no type or documentation for it)"
    trimmed -> clip(trimmed, max_hover_bytes)
  }
  render_site(hover.site) <> "\n\n" <> contents
}

/// A server's text cut to at most `limit` bytes, with a closing line
/// saying how many bytes were cut.
///
/// The cut falls at the last line break inside the bound, so no line is
/// shown half, unless the first line alone is longer than the bound; then
/// it falls on the last character boundary inside it, so the result is
/// always valid UTF-8. Text within the bound comes back unchanged. The
/// marker line is added past the bound, since it is the harness's words
/// rather than the server's. `lsp_hover` clips at `max_hover_bytes`, and
/// code mode's `lsp.hover` at its own, larger bound.
///
/// ## Examples
///
/// ```gleam
/// assert lsp.clip("short", 10) == "short"
/// assert lsp.clip("one\ntwo\nthree", 9) == "one\ntwo\n[6 more bytes cut]"
/// ```
///
pub fn clip(text: String, limit: Int) -> String {
  let size = string.byte_size(text)
  case size <= limit {
    True -> text
    False -> {
      let kept = at_line_break(utf8_prefix(<<text:utf8>>, int.max(limit, 0)))
      kept
      <> "\n["
      <> int.to_string(size - string.byte_size(kept))
      <> " more bytes cut]"
    }
  }
}

// The longest prefix of `bytes` of at most `length` bytes that is valid
// UTF-8. A cut inside a multi-byte character fails to decode, and backing
// off one byte at a time reaches a boundary within three steps.
fn utf8_prefix(bytes: BitArray, length: Int) -> String {
  let decoded =
    bit_array.slice(bytes, 0, length)
    |> result.try(bit_array.to_string)
  case decoded, length > 0 {
    Ok(text), _ -> text
    Error(Nil), True -> utf8_prefix(bytes, length - 1)
    Error(Nil), False -> ""
  }
}

// The text before its last line break, or the text whole
// when it has none: a hover whose first line overruns the bound is still
// shown up to the bound rather than not at all.
fn at_line_break(text: String) -> String {
  case list.reverse(string.split(text, "\n")) {
    [_partial, _, ..] as reversed ->
      list.drop(reversed, 1) |> list.reverse |> string.join("\n")
    [_] | [] -> text
  }
}

/// What `lsp_references` answers: the count and file count first, then
/// the hits grouped by file and, inside a file, by containing symbol.
///
/// At most `max_reference_hits` hits are listed, taken in the grouped
/// order so a truncated list is a prefix of the full one; the heading says
/// how many are shown and a closing line how many were left out. Each
/// file's heading counts all of its references, shown or not.
///
/// ## Examples
///
/// ```gleam
/// assert lsp.render_references("greet", [])
///   == "no references to `greet` found"
/// ```
///
pub fn render_references(
  symbol: String,
  references: List(Reference),
) -> String {
  let files = group(references, reference_path)
  let total = list.length(references)

  // Flattening the grouping first is what makes the bound a prefix of the
  // grouped answer rather than of the server's order.
  let ordered =
    list.flat_map(files, fn(file) {
      list.flat_map(group(file.1, reference_container), fn(pair) { pair.1 })
    })
  let shown = list.take(ordered, max_reference_hits)
  let hidden = total - list.length(shown)
  let counts =
    dict.from_list(list.map(files, fn(file) { #(file.0, list.length(file.1)) }))

  case references {
    [] -> "no references to `" <> symbol <> "` found"
    [_, ..] ->
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
  case hidden {
    0 -> heading
    _ -> heading <> "; showing " <> int.to_string(max_reference_hits)
  }
}

fn references_trailer(hidden: Int) -> String {
  case hidden {
    0 -> ""
    _ ->
      "\n… "
      <> int.to_string(hidden)
      <> " more; narrow with path/line or use code mode (cap/lsp) for the "
      <> "full list"
  }
}

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
      let heading = case pair.0 {
        Some(name) -> "  in " <> name <> ":"
        None -> "  at top level:"
      }
      [heading, ..list.map(pair.1, fn(hit) { "    " <> render_site(hit.site) })]
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
fn group(items: List(a), key: fn(a) -> k) -> List(#(k, List(a))) {
  let #(order, groups) =
    list.fold(items, #([], dict.new()), fn(state, item) {
      let #(order, groups) = state
      let name = key(item)
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
/// anchored line in `fs_read`'s form.
///
/// ## Examples
///
/// ```gleam
/// assert lsp.render_outline("src/a.gleam", []) == "no symbols in src/a.gleam"
/// ```
///
pub fn render_outline(path: String, entries: List(SymbolEntry)) -> String {
  case entries {
    [] -> "no symbols in " <> path
    [_, ..] ->
      plural(count_entries(entries), "symbol")
      <> " in "
      <> path
      <> ":\n"
      <> string.join(list.flat_map(entries, render_entry(_, "")), "\n")
  }
}

fn count_entries(entries: List(SymbolEntry)) -> Int {
  list.fold(entries, 0, fn(total, entry) {
    total + 1 + count_entries(entry.children)
  })
}

fn render_entry(entry: SymbolEntry, indent: String) -> List(String) {
  let detail = case entry.detail {
    Some(detail) if detail != "" -> " — " <> detail
    Some(_) | None -> ""
  }
  [
    indent <> entry.kind <> " " <> entry.name <> detail,
    indent <> "  " <> render_anchored(entry.site),
    ..list.flat_map(entry.children, render_entry(_, indent <> "  "))
  ]
}

/// What `lsp_calls` answers: a count, then each caller or callee with
/// where it is defined and where each call is.
///
/// ## Examples
///
/// ```gleam
/// assert lsp.render_calls("greet", query.Incoming, [])
///   == "no callers of `greet` found"
/// ```
///
pub fn render_calls(
  symbol: String,
  direction: CallDirection,
  calls: List(Call),
) -> String {
  let count = list.length(calls)
  let heading = case direction, calls {
    query.Incoming, [] -> "no callers of `" <> symbol <> "` found"
    query.Outgoing, [] ->
      "`" <> symbol <> "` calls nothing the language server can resolve"
    query.Incoming, [_, ..] ->
      plural(count, "caller") <> " of `" <> symbol <> "`:"
    query.Outgoing, [_, ..] ->
      "`" <> symbol <> "` calls " <> plural(count, "function") <> ":"
  }
  string.join([heading, ..list.map(calls, render_call)], "\n")
}

fn render_call(call: Call) -> String {
  [
    call.name,
    "  defined at " <> render_site(call.site),
    ..list.map(call.at, fn(site) { "  called at " <> render_site(site) })
  ]
  |> string.join("\n")
}

/// A diagnostics block, as `lsp_diagnostics`, a rename's report and the
/// post-write observer all print it.
///
/// Settled and empty is the one clean answer. A settled list counts by
/// severity first. An unsettled block says, before anything else, that
/// the server had not finished and the list may be stale or incomplete —
/// an empty unsettled block is "nothing known yet", never clean. At most
/// `max_rendered_diagnostics` entries are listed.
///
/// ## Examples
///
/// ```gleam
/// assert lsp.render_diagnostics(query.Settled([]))
///   == "diagnostics: clean (settled)"
/// ```
///
pub fn render_diagnostics(diagnostics: Diagnostics) -> String {
  case diagnostics {
    query.Settled(diagnostics: []) -> "diagnostics: clean (settled)"
    query.Settled(diagnostics: entries) ->
      "diagnostics (settled): "
      <> severity_summary(entries)
      <> "\n"
      <> render_entries(entries)
    query.Unsettled(seen: []) ->
      "diagnostics: NOT settled — the language server had not finished when "
      <> "the wait expired, so nothing is known yet; this is not a passing "
      <> "result"
    query.Unsettled(seen: entries) ->
      "diagnostics: NOT settled — the language server had not finished when "
      <> "the wait expired, so these may be stale or incomplete: "
      <> severity_summary(entries)
      <> "\n"
      <> render_entries(entries)
  }
}

// "3 (2 errors, 1 warning)": the total, then each severity that occurs,
// most severe first.
fn severity_summary(entries: List(Diagnostic)) -> String {
  let parts =
    [
      #(query.SeverityError, "error"),
      #(query.SeverityWarning, "warning"),
      #(query.SeverityInformation, "info"),
      #(query.SeverityHint, "hint"),
    ]
    |> list.filter_map(fn(pair) {
      case list.count(entries, fn(entry) { entry.severity == pair.0 }) {
        0 -> Error(Nil)
        count -> Ok(plural(count, pair.1))
      }
    })
  int.to_string(list.length(entries)) <> " (" <> string.join(parts, ", ") <> ")"
}

fn render_entries(entries: List(Diagnostic)) -> String {
  let shown =
    list.take(entries, max_rendered_diagnostics)
    |> list.map(render_diagnostic)
  let hidden = list.length(entries) - max_rendered_diagnostics
  let trailer = case int.compare(hidden, 0) {
    order.Gt -> ["… " <> int.to_string(hidden) <> " more not shown"]
    order.Eq | order.Lt -> []
  }
  string.join(list.append(shown, trailer), "\n")
}

// The site line first, so it reads like every other answer here; the
// message under it, each of its lines indented, because compiler messages
// are often several lines long.
fn render_diagnostic(entry: Diagnostic) -> String {
  let severity = case entry.severity {
    query.SeverityError -> "error"
    query.SeverityWarning -> "warning"
    query.SeverityInformation -> "info"
    query.SeverityHint -> "hint"
  }
  let message =
    string.trim_end(entry.message)
    |> string.split("\n")
    |> list.map(fn(line) { "  " <> line })
    |> string.join("\n")
  severity <> " at " <> render_site(entry.site) <> "\n" <> message
}

/// What a rename preview shows: counts first, then per file every changed
/// line before (`-`) and after (`+`), each in `fs_read`'s anchored form —
/// the `-` anchors are the file's current ones, the `+` anchors those it
/// will have. Nothing is written.
///
/// ## Examples
///
/// ```gleam
/// // lsp.render_preview("greet", "hello", edits)
/// // |> string.starts_with("Preview: renaming `greet` to `hello`")
/// ```
///
pub fn render_preview(
  symbol: String,
  new_name: String,
  edits: List(FileEdit),
) -> String {
  let ordered =
    list.sort(edits, fn(left, right) { string.compare(left.path, right.path) })
  let files = list.map(ordered, fn(edit) { #(edit, changed_lines(edit)) })
  let lines = list.fold(files, 0, fn(total, file) { total + file.1.0 })
  let occurrences = list.fold(edits, 0, fn(total, edit) { total + edit.edits })
  let heading =
    "Preview: renaming `"
    <> symbol
    <> "` to `"
    <> new_name
    <> "` changes "
    <> plural(lines, "line")
    <> " in "
    <> plural(list.length(edits), "file")
    <> " ("
    <> plural(occurrences, "edit")
    <> "). Nothing was written; to write it, call lsp_rename again with "
    <> "mode \"apply\"."
  let blocks =
    list.map(files, fn(file) {
      let #(edit, #(_, rendered)) = file
      string.join(
        [edit.path <> " (" <> plural(edit.edits, "edit") <> "):", ..rendered],
        "\n",
      )
    })
  string.join([heading, ..blocks], "\n")
}

// The changed lines of one file, as a count and the rendered `-`/`+`
// lines. A span with lines on both sides counts once per line of its
// longer side, since each is one line that changed.
fn changed_lines(edit: FileEdit) -> #(Int, List(String)) {
  let spans = changed_spans(edit.base, edit.edited)
  #(
    list.fold(spans, 0, fn(total, span) {
      total + int.max(list.length(span.removed), list.length(span.added))
    }),
    list.flat_map(spans, fn(span) {
      list.append(
        list.map(span.removed, removed_line),
        list.map(span.added, added_line),
      )
    }),
  )
}

/// One place a file changes: the lines taken out, as the file has them
/// now, and the lines put in, as it will have them. Either side may be
/// empty, not both.
pub type ChangedSpan {
  ChangedSpan(
    /// The base's lines, numbered and anchored as the file is now.
    removed: List(hashline.AnchoredLine),
    /// The edited text's lines, numbered and anchored as it will be.
    added: List(hashline.AnchoredLine),
  )
}

/// The lines that differ between a file's base and edited text, in line
/// order: the one diff behind both `lsp_rename`'s preview and code mode's
/// `lsp.rename` preview, so a model and a program are shown the same
/// change.
///
/// A rename normally keeps every line where it was, so when the line
/// counts agree each changed line is its own one-line span. Otherwise the
/// run between the common prefix and the common suffix is one span, which
/// is still every line that changed, and a server that added or removed a
/// line shows up rather than being lost.
///
/// Lines are split and anchored by `hashline.annotate`, so a CRLF line
/// keeps its `\r` in `text` and its anchor is the one `fs_read` prints;
/// lines are compared with it too, so a changed line ending is a change.
/// A surface that shows the text without the `\r` trims it for display
/// and never for the anchor.
///
/// ## Examples
///
/// ```gleam
/// let assert [lsp.ChangedSpan(removed: [before], added: [after])] =
///   lsp.changed_spans("x\ngreet\n", "x\nhi\n")
/// assert before.line == 2 && before.text == "greet" && after.text == "hi"
/// ```
///
pub fn changed_spans(base: String, edited: String) -> List(ChangedSpan) {
  let before = hashline.annotate(base)
  let after = hashline.annotate(edited)
  case list.length(before) == list.length(after) {
    True ->
      list.zip(before, after)
      |> list.filter(fn(pair) { pair.0.text != pair.1.text })
      |> list.map(fn(pair) { ChangedSpan(removed: [pair.0], added: [pair.1]) })

    False -> {
      let #(before, after) = drop_common(before, after)
      let #(before, after) =
        drop_common(list.reverse(before), list.reverse(after))
      case before, after {
        [], [] -> []
        _, _ -> [
          ChangedSpan(removed: list.reverse(before), added: list.reverse(after)),
        ]
      }
    }
  }
}

// Drops the leading lines two texts share, by text.
fn drop_common(
  before: List(hashline.AnchoredLine),
  after: List(hashline.AnchoredLine),
) -> #(List(hashline.AnchoredLine), List(hashline.AnchoredLine)) {
  case before, after {
    [left, ..before_rest], [right, ..after_rest] if left.text == right.text ->
      drop_common(before_rest, after_rest)
    _, _ -> #(before, after)
  }
}

fn removed_line(line: hashline.AnchoredLine) -> String {
  "  - " <> hashline.render_line(line)
}

fn added_line(line: hashline.AnchoredLine) -> String {
  "  + " <> hashline.render_line(line)
}

/// What an applied rename reports: how many files were written, then each
/// file's fate, then the diagnostics after the rename — omitted only when
/// nothing was written, since there is then no change to diagnose.
///
/// ## Examples
///
/// ```gleam
/// // lsp.render_report("greet", "hello", report)
/// // |> string.starts_with("Renamed `greet` to `hello`")
/// ```
///
pub fn render_report(
  symbol: String,
  new_name: String,
  report: RenameReport,
) -> String {
  let total = list.length(report.files)
  let landed = list.count(report.files, is_landed)
  let heading = case landed == total, landed {
    True, _ ->
      "Renamed `"
      <> symbol
      <> "` to `"
      <> new_name
      <> "`: wrote "
      <> plural(total, "file")
      <> "."
    False, 0 ->
      "Renaming `"
      <> symbol
      <> "` to `"
      <> new_name
      <> "` wrote nothing: every file was checked first and one was "
      <> "refused, so no file changed."
    False, _ ->
      "Renaming `"
      <> symbol
      <> "` to `"
      <> new_name
      <> "` was only partly written: "
      <> int.to_string(landed)
      <> " of "
      <> plural(total, "file")
      <> ". The written files stay written; finish the rejected ones "
      <> "with fs_edit, starting from the diagnostics below."
  }
  let files = list.map(report.files, render_landing)
  let diagnostics = case landed {
    0 -> []
    _ -> ["", render_diagnostics(report.diagnostics)]
  }
  string.join([heading, ..list.append(files, diagnostics)], "\n")
}

fn render_landing(landing: Landing) -> String {
  case landing {
    query.Landed(path:, edits:) ->
      path <> ": written (" <> plural(edits, "edit") <> ")"
    query.Rejected(path:, reason:) ->
      path <> ": rejected — " <> string.replace(reason, "\n", "\n    ")
    query.NotAttempted(path:) ->
      path <> ": not attempted (another file failed its check first)"
  }
}

/// Every `QueryError` as something the model can act on: which server,
/// which request, which candidates, and what to do next.
///
/// ## Examples
///
/// ```gleam
/// assert lsp.render_error(query.ServerRefused("would make it unexported"))
///   == "the language server refused: would make it unexported"
/// ```
///
pub fn render_error(error: QueryError) -> String {
  case error {
    query.NoServer(reason:) ->
      "no language server answers this: "
      <> reason
      <> ". Servers are configured per file extension as [lsp.<name>] "
      <> "tables in loom.toml; for files no server owns, use grep and "
      <> "fs_read."
    query.Unsupported(server:, request:) ->
      "the "
      <> server
      <> " language server does not support "
      <> request
      <> ", so it was not asked. lsp_references names the function "
      <> "containing each reference, and grep finds text."
    query.NotFound(query: asked) ->
      "`"
      <> asked.symbol
      <> "` was not found "
      <> where(asked)
      <> ". Check the spelling, qualify it the way the code does "
      <> "(`module.name`), or give the `path` and the 1-based `line` where "
      <> "it appears."
    query.Ambiguous(candidates:) ->
      "the name is ambiguous: "
      <> plural(list.length(candidates), "distinct definition")
      <> " match:\n"
      <> string.join(list.map(candidates, render_site), "\n")
      <> "\nAsk again with `path` (and `line`) naming one of them, or "
      <> "qualify the name (`module.name`)."
    query.ServerRefused(message:) -> "the language server refused: " <> message
    query.Unavailable(reason:) ->
      "the question could not be answered: "
      <> reason
      <> ". If the language server was restarting or busy, asking again "
      <> "may work; grep and fs_read work meanwhile."
  }
}

fn where(asked: SymbolQuery) -> String {
  case asked.path, asked.line {
    Some(path), Some(line) ->
      "on line " <> int.to_string(line) <> " of " <> path
    Some(path), None -> "in " <> path
    None, _ -> "in the workspace"
  }
}

fn error_outcome(error: QueryError) -> ToolOutcome {
  tool.failure(render_error(error))
}

// The text of an outcome, for a reason carried inside a `Landing`: the
// landing path renders its refusals as outcomes, and the report owes the
// model the same words.
fn outcome_text(outcome: ToolOutcome) -> String {
  outcome.content
  |> list.filter_map(fn(block) {
    case block {
      message.ToolResultText(text:, ..) -> Ok(text)
      message.ToolResultImage(..) -> Error(Nil)
    }
  })
  |> string.join("\n")
}
