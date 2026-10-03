//// Shared language-server support for rename landing and observed writes.
////
//// Code mode obtains typed semantic answers through `cap/lsp`. The host
//// still owns the filesystem boundary: `land` checks every rename file
//// before writing through the same hashline path as `fs_edit`, and the
//// diagnostics observer tells the server about successful native writes.
//// Keeping these paths together preserves stale-file refusal and reports
//// partial write failures without undoing earlier landings (ADR-015 §4).
////
//// Diagnostics retain the server's settlement state. An empty answer from
//// an unfinished server means nothing is known yet; only a settled empty
//// answer can read as clean. The observer bounds the displayed entries
//// while retaining their total count.
////
//// Code mode also uses `changed_spans` for anchored rename previews and
//// `clip` to bound hover text without cutting a UTF-8 character. Neither
//// helper obtains write authority or queries a server.
////
//// ## Flow
////
//// ```text
//// land → phase(plan_file) → phase(target_file) → phase(check_disk)
////   → write_all → land_file → combine
//// diagnostics_observer → render_diagnostics → render_entries → render_site
//// changed_spans → hashline.annotate → drop_common
//// clip → utf8_prefix → at_line_break
//// ```

import core/message
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/order
import gleam/result
import gleam/string
import lsp/query.{
  type Diagnostic, type Diagnostics, type FileEdit, type Landing,
  type RenameReport, type Site,
}
import tools/fs
import tools/hashline
import tools/tool.{type FileSystem, type ToolOutcome}

/// The most diagnostics a post-write block lists. The count heading
/// still names every entry, including those left out of the display.
pub const max_rendered_diagnostics = 20

/// A rename file, ready to write: its plan, bound to the text the server
/// saw, and its resolved write target.
type Prepared {
  Prepared(edit: FileEdit, plan: hashline.Plan, target: fs.WriteTarget)
}

/// One place a file changes: the lines taken out, as the file has them
/// now, and the lines put in, as it will have them. Either side may be
/// empty, not both.
pub type ChangedSpan {
  /// The removed and added lines for one changed run.
  ChangedSpan(
    /// The base's lines, numbered and anchored as the file is now.
    removed: List(hashline.AnchoredLine),
    /// The edited text's lines, numbered and anchored as it will be.
    added: List(hashline.AnchoredLine),
  )
}

/// Lands a rename's edits through the hashline path and reports, file by
/// file, exactly what was written.
///
/// Four phases, in ADR-015 §4's order, and every one of the first three
/// runs over every file before the next begins:
///
/// 1. each file's plan is built with `hashline.plan_between`, bound to the
///    digest of the text the server computed against;
/// 2. each file's write target is resolved through `target`, the caller
///    closure that admits the path under its write authority;
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
/// The caller constructs write targets from its admitted authority with
/// `fs.write_target`; this function receives no session context.
///
/// ## Examples
///
/// ```gleam
/// // lsp.land(
/// //   edits:,
/// //   target: fn(path) { fs.write_target(..) |> result.map_error(describe) },
/// //   filesystem:,
/// //   after_write:,
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

// The two path accessors name a file for `phase`, which reports by path
// at whichever stage a value has reached.
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

// Phase one. `plan_between` fails only when the two texts differ in their
// final newline, which no line edit expresses, so the error arm is a
// refusal of a server answer and never a model mistake.
fn plan_file(edit: FileEdit) -> Result(#(FileEdit, hashline.Plan), String) {
  hashline.plan_between(base: edit.base, edited: edit.edited)
  |> result.map(fn(plan) { #(edit, plan) })
  |> result.map_error(fn(_unreachable) {
    "the server's edited text ends differently from the file (a final "
    <> "newline added or removed), which no line edit can produce; nothing "
    <> "was written"
  })
}

// Phase two. Resolving the target admits each path under the caller's
// write authority. It follows planning so an unrepresentable rename
// cannot reach that authority boundary.
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
        <> "); nothing was written. Preview the rename again with cap/lsp in code mode to recompute it.",
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

// One write. `land_plan` re-checks the digest as it writes, so a change
// between `check_disk` and here still rejects the file instead of
// overwriting it.
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
/// its diagnostics are rendered as the block the result gains (ADR-015
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

/// One diagnostic site in the editable form: `path:line:anchor|text`.
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

// "1 file", "2 files". Every count in an answer goes through it so no
// answer says "1 files".
fn plural(count: Int, noun: String) -> String {
  case count {
    1 -> "1 " <> noun
    _ -> int.to_string(count) <> " " <> noun <> "s"
  }
}

/// A server's text cut to at most `limit` bytes, with a closing line
/// saying how many bytes were cut.
///
/// The cut falls at the last line break inside the bound, so no line is
/// shown half, unless the first line alone is longer than the bound; then
/// it falls on the last character boundary inside it, so the result is
/// always valid UTF-8. Text within the bound comes back unchanged. The
/// marker line is added past the bound, since it is the harness's words
/// rather than the server's. Code mode supplies the bound when projecting
/// the server's hover response into its typed result.
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

/// A diagnostics block for the post-write observer.
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

/// The lines that differ between a file's base and edited text, in line
/// order, for code mode's typed `cap/lsp` rename preview.
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
