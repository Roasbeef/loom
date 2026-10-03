//// Shared rename landing, preview diffs, and post-write diagnostics.
////
//// The landing tests write real files under the package build directory.
//// They check that all preflights precede every write, partial failures
//// retain earlier landings, and server notifications name only landed
//// paths in order. Diagnostic rendering preserves settlement and bounds
//// the displayed entries without disguising incomplete answers as clean.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import lsp/query
import simplifile
import support/internal/ffi_memory
import tools/fs
import tools/hashline
import tools/lsp
import tools/tool

// A door where every closure answers `Unavailable`, so a test overrides
// exactly the closure it is about and any other call shows up as a
// failure it did not expect.
fn door() -> query.Door {
  let unused = query.Unavailable("not part of this test")
  query.Door(
    definition: fn(_) { Error(unused) },
    references: fn(_) { Error(unused) },
    hover: fn(_) { Error(unused) },
    outline: fn(_) { Error(unused) },
    calls: fn(_, _) { Error(unused) },
    diagnostics: fn(_) { Error(unused) },
    prepare_rename: fn(_, _) { Error(unused) },
    after_write: fn(_) { None },
  )
}

fn site(path: String, line: Int, text: String) -> query.Site {
  query.Site(path:, line:, column: 1, text:)
}

// The rendered form of a site, built independently of the module: a grep
// hit with the anchor fs_read prints spliced in.
fn hit(path: String, line: Int, text: String) -> String {
  path
  <> ":"
  <> int.to_string(line)
  <> ":"
  <> hashline.anchor(text)
  <> "|"
  <> text
}

// A real temporary workspace under the package build directory.
fn workspace(name: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runs in a directory"
  let root = here <> "/build/lsp_test/" <> name
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "the scratch root can be made"
  root
}

fn put(root: String, path: String, content: String) -> Nil {
  let assert Ok(Nil) = simplifile.write(root <> "/" <> path, content)
    as "the fixture file can be written"
  Nil
}

fn disk(root: String, path: String) -> String {
  let assert Ok(content) = simplifile.read(root <> "/" <> path)
    as "the file can be read back"
  content
}

// The target maker a code-mode caller would pass: `fs.write_target` over
// the workspace, with nothing protected.
fn targets(root: String) -> fn(String) -> Result(fs.WriteTarget, String) {
  fn(path) {
    fs.write_target(
      filesystem: fs.real_filesystem(),
      workspace: root,
      roots: [],
      protected: [],
      path:,
    )
    |> result.replace_error("unwritable: " <> path)
  }
}

fn rename_edit(path: String, base: String) -> query.FileEdit {
  query.FileEdit(
    path:,
    base:,
    edited: string.replace(base, "greet", "hello"),
    edits: list.length(string.split(base, "greet")) - 1,
  )
}

// The numbers 1 to `last`, in order.
fn one_to(last: Int) -> List(Int) {
  int.range(from: last, to: 0, with: [], run: list.prepend)
}

// Every path `after_write` was told of, in order.
fn told(subject: process.Subject(String)) -> List(String) {
  case process.receive(subject, 0) {
    Ok(path) -> [path, ..told(subject)]
    Error(Nil) -> []
  }
}

fn error_diagnostic(path: String, line: Int, text: String) -> query.Diagnostic {
  query.Diagnostic(
    site: site(path, line, text),
    severity: query.SeverityError,
    message: "Unknown variable `greet`",
  )
}

pub fn clip_cuts_on_a_line_then_a_character_boundary_test() {
  assert lsp.clip("short", 10) == "short"
  assert lsp.clip("one\ntwo\nthree", 9) == "one\ntwo\n[6 more bytes cut]"

  // One line longer than the bound is cut inside it, but never inside a
  // character: `é` is two bytes and does not fit in the third.
  assert lsp.clip("abé", 3) == "ab\n[2 more bytes cut]"
}

pub fn settled_diagnostics_render_an_anchored_block_test() {
  let shown =
    lsp.render_diagnostics(
      query.Settled([
        error_diagnostic("src/a.gleam", 2, "  greet()"),
      ]),
    )
  assert shown
    == "diagnostics (settled): 1 (1 error)\nerror at "
    <> hit("src/a.gleam", 2, "  greet()")
    <> "\n  Unknown variable `greet`"
}

pub fn rename_preview_spans_preserve_each_line_and_anchor_test() {
  let root = workspace("preview")
  let a = "import probe\n\npub fn main() {\n  probe.greet()\n}\n"
  let b = "pub fn greet() {\n  \"hi\"\n}\n"
  put(root, "a.gleam", a)
  put(root, "b.gleam", b)

  let assert [lsp.ChangedSpan(removed: [a_before], added: [a_after])] =
    lsp.changed_spans(a, rename_edit("a.gleam", a).edited)
    as "the caller changes one anchored line"
  let assert [lsp.ChangedSpan(removed: [b_before], added: [b_after])] =
    lsp.changed_spans(b, rename_edit("b.gleam", b).edited)
    as "the definition changes one anchored line"
  assert a_before
    == hashline.AnchoredLine(
      4,
      hashline.anchor("  probe.greet()"),
      "  probe.greet()",
    )
  assert a_after
    == hashline.AnchoredLine(
      4,
      hashline.anchor("  probe.hello()"),
      "  probe.hello()",
    )
  assert b_before
    == hashline.AnchoredLine(
      1,
      hashline.anchor("pub fn greet() {"),
      "pub fn greet() {",
    )
  assert b_after
    == hashline.AnchoredLine(
      1,
      hashline.anchor("pub fn hello() {"),
      "pub fn hello() {",
    )
  assert disk(root, "a.gleam") == a
  assert disk(root, "b.gleam") == b
}

pub fn rename_landing_updates_every_gleam_file_test() {
  let root = workspace("apply")
  let a = "pub fn greet() {\n  1\n}\n"
  let b = "fn main() {\n  greet()\n}\n"
  put(root, "a.gleam", a)
  put(root, "b.gleam", b)
  let report =
    lsp.land(
      edits: [rename_edit("a.gleam", a), rename_edit("b.gleam", b)],
      target: targets(root),
      filesystem: fs.real_filesystem(),
      after_write: fn(_) { Some(query.Settled([])) },
    )

  assert report
    == query.RenameReport(
      files: [query.Landed("a.gleam", 1), query.Landed("b.gleam", 1)],
      diagnostics: query.Settled([]),
    )
  assert disk(root, "a.gleam") == "pub fn hello() {\n  1\n}\n"
  assert disk(root, "b.gleam") == "fn main() {\n  hello()\n}\n"
}

pub fn land_writes_every_file_and_tells_the_server_in_path_order_test() {
  let root = workspace("land_all")
  let a = "greet\n"
  let b = "x\ngreet greet\n"
  put(root, "a.txt", a)
  put(root, "b.txt", b)
  let calls = process.new_subject()
  let settled = query.Settled([error_diagnostic("b.txt", 2, "hello hello")])
  let report =
    lsp.land(
      edits: [rename_edit("b.txt", b), rename_edit("a.txt", a)],
      target: targets(root),
      filesystem: fs.real_filesystem(),
      after_write: fn(path) {
        process.send(calls, path)
        Some(settled)
      },
    )

  assert report
    == query.RenameReport(
      files: [query.Landed("a.txt", 1), query.Landed("b.txt", 2)],
      diagnostics: settled,
    )
  assert told(calls) == ["a.txt", "b.txt"]
  assert disk(root, "a.txt") == "hello\n"
  assert disk(root, "b.txt") == "x\nhello hello\n"
}

// The concurrency check runs over every file before the first write: a
// file changed since the server looked stops the whole rename, and the
// file that sorts before it is left exactly as it was.
pub fn a_stale_file_stops_every_write_test() {
  let root = workspace("land_stale")
  let a = "greet\n"
  let b = "greet\n"
  put(root, "a.txt", a)
  put(root, "b.txt", "greet\nsomeone else's line\n")
  let calls = process.new_subject()
  let report =
    lsp.land(
      edits: [rename_edit("a.txt", a), rename_edit("b.txt", b)],
      target: targets(root),
      filesystem: fs.real_filesystem(),
      after_write: fn(path) {
        process.send(calls, path)
        Some(query.Settled([]))
      },
    )

  let assert [query.NotAttempted("a.txt"), query.Rejected("b.txt", reason)] =
    report.files
    as "the stale file is rejected and the other not attempted"
  assert string.contains(reason, "the file changed after the language server")
  assert report.diagnostics == query.Unsettled([])
  assert told(calls) == []
  assert disk(root, "a.txt") == a
  assert disk(root, "b.txt") == "greet\nsomeone else's line\n"
}

// Landing is not atomic across files: a write that fails after an earlier
// one landed leaves the earlier one written, and the report says exactly
// which. The server is told only about files that were written.
pub fn a_later_write_failure_keeps_the_earlier_landing_test() {
  let root = workspace("land_partial")
  let a = "greet\n"
  let b = "greet\n"
  let c = "greet\n"
  put(root, "a.txt", a)
  put(root, "b.txt", b)
  put(root, "c.txt", c)
  let real = fs.real_filesystem()
  let failing_b =
    tool.FileSystem(..real, write: fn(path, bytes) {
      case string.ends_with(path, "/b.txt") {
        True -> Error(tool.FsPermissionDenied(path))
        False -> real.write(path, bytes)
      }
    })
  let calls = process.new_subject()
  let report =
    lsp.land(
      edits: [
        rename_edit("c.txt", c),
        rename_edit("a.txt", a),
        rename_edit("b.txt", b),
      ],
      target: targets(root),
      filesystem: failing_b,
      after_write: fn(path) {
        process.send(calls, path)
        Some(query.Settled([]))
      },
    )

  let assert [
    query.Landed("a.txt", 1),
    query.Rejected("b.txt", reason),
    query.Landed("c.txt", 1),
  ] = report.files
    as "each file's fate is reported in path order"
  assert reason != ""
  assert told(calls) == ["a.txt", "c.txt"]
  assert disk(root, "a.txt") == "hello\n"
  assert disk(root, "b.txt") == "greet\n"
  assert disk(root, "c.txt") == "hello\n"
}

// One unsettled answer makes the whole block unsettled, and an unsettled
// block never renders as clean — not even an empty one.
pub fn unsettled_diagnostics_never_read_as_clean_test() {
  let root = workspace("land_unsettled")
  let a = "greet\n"
  let b = "greet\n"
  put(root, "a.txt", a)
  put(root, "b.txt", b)
  let report =
    lsp.land(
      edits: [rename_edit("a.txt", a), rename_edit("b.txt", b)],
      target: targets(root),
      filesystem: fs.real_filesystem(),
      after_write: fn(path) {
        case path {
          "a.txt" -> Some(query.Unsettled([]))
          _ -> Some(query.Settled([]))
        }
      },
    )

  assert report.diagnostics == query.Unsettled([])
  let text = lsp.render_diagnostics(report.diagnostics)
  assert string.contains(text, "NOT settled")
  assert !string.contains(text, "clean")
  assert !string.contains(lsp.render_diagnostics(query.Unsettled([])), "clean")
}

// --- the post-write observer ---------------------------------------------

pub fn the_observer_renders_the_door_answer_test() {
  let answers = fn(path) {
    case path {
      "/w/none.txt" -> None
      "/w/clean.gleam" -> Some(query.Settled([]))
      _ ->
        Some(query.Unsettled(
          one_to(25)
          |> list.map(fn(line) { error_diagnostic("a.gleam", line, "x") }),
        ))
    }
  }
  let observe =
    lsp.diagnostics_observer(query.Door(..door(), after_write: answers))

  assert observe("/w/none.txt") == None
  assert observe("/w/clean.gleam") == Some("diagnostics: clean (settled)")

  let assert Some(block) = observe("/w/broken.gleam")
    as "an owned path answers a block"
  let lines = string.split(block, "\n")
  assert list.first(lines)
    == Ok(
      "diagnostics: NOT settled — the language server had not finished when "
      <> "the wait expired, so these may be stale or incomplete: 25 (25 "
      <> "errors)",
    )
  assert list.count(lines, fn(line) { string.starts_with(line, "error at ") })
    == 20
  assert list.last(lines) == Ok("… 5 more not shown")
  assert !string.contains(block, "clean")
}

/// The live diagnostics observer retains only its after-write callback.
pub fn observer_does_not_retain_sibling_slots_test() {
  let payload = list.repeat(#("hover", "payload"), 8192)
  let small =
    query.Door(..door(), after_write: fn(_) { Some(query.Settled([])) })
  let large =
    query.Door(..small, hover: fn(_asked) {
      Error(query.Unavailable(string.inspect(payload)))
    })

  // Growing an unrelated callback must not increase the retained observer.
  // The hover callback still owns its payload and remains callable.
  assert ffi_memory.flat_words(large) > ffi_memory.flat_words(small) + 8192
  let assert Error(query.Unavailable(reason:)) =
    large.hover(query.SymbolQuery("greet", None, None))
    as "the hover payload must remain in its intended callback"
  assert string.contains(reason, "payload")

  let small_observer = lsp.diagnostics_observer(small)
  let large_observer = lsp.diagnostics_observer(large)
  assert ffi_memory.flat_words(large_observer)
    == ffi_memory.flat_words(small_observer)
  assert large_observer("/w/clean.gleam")
    == Some("diagnostics: clean (settled)")
}
