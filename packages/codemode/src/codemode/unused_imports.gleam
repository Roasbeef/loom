//// Removing the imports a build reported as unused, and nothing else.
////
//// The production build runs with `--warnings-as-errors`, which is what
//// turns Gleam's "transitive dependency imported" warning into a compile
//// error (`codemode/build`). The same flag makes an unused `import
//// gleam/int` fail the build, and a failure costs the model a round trip
//// to delete a line the compiler already named. This module reads the
//// compiler's own diagnostics and, only when *every* diagnostic is an
//// unused-import warning, returns the program with exactly those imports
//// removed. The caller vets and builds that program once more.
////
//// # Why the rule is all-or-nothing
////
//// A build that fails for any other reason, or that carries any other
//// warning alongside the unused imports, is not rewritten at all. A
//// transitive-dependency warning in particular must keep failing the
//// build, so one such diagnostic anywhere makes the whole rewrite refuse,
//// as does an error, a diagnostic that does not parse, and a summary that
//// does not account for every warning (the build output is cut at a fixed
//// size, and a cut output cannot prove it listed everything).
////
//// The compiler offers no machine-readable diagnostics in the pinned
//// toolchain, so the text is parsed, and every step that could be wrong
//// refuses instead of guessing. The location line and the echoed source
//// line must agree with the program text exactly before a character is
//// removed.
////
//// # What is removed
////
//// Gleam names four titles: `Unused imported module` for a whole import,
//// and `Unused imported value`, `type` or `item` for one name inside an
//// unqualified list `{...}`. A whole import is removed with its line. A
//// named item is removed from its list together with its `as` alias, and
//// the braces and the `.` go with the last item, leaving an `as` alias on
//// the module itself in place. Imports written across several lines are
//// refused, because their spans do not sit on one line.

import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// The program after the removals, and one note per removal for the model
/// to read, in source order.
pub type Rewrite {
  Rewrite(
    /// The submitted source with the unused imports removed.
    source: String,
    /// Lines such as `removed unused import gleam/int (line 3)`.
    notes: List(String),
  )
}

// What an unused-import warning removes.
type Scope {
  // The whole `import` statement.
  Statement

  // One name inside the `{...}` list.
  Member
}

// One parsed unused-import warning: where the compiler underlined, how wide,
// and the source line it echoed beside the underline.
type Unused {
  Unused(scope: Scope, line: Int, column: Int, width: Int, echoed: String)
}

/// Removes the imports `diagnostics` reports as unused from `source`, or
/// `Error(Nil)` when anything else is in the output or anything fails to
/// agree. `file` is the path suffix the warnings must be about, such as
/// `src/loom_program.gleam`: a warning about another module is not this
/// program's to fix.
///
/// ## Examples
///
/// ```gleam
/// let diagnostics =
///   "warning: Unused imported module\n  ┌─ /b/src/p.gleam:1:1\n  │\n"
///   <> "1 │ import gleam/int\n  │ ^^^^^^^^^^^^^^^^ This imported module "
///   <> "is never used\n\nHint: You can safely remove it.\n\n"
///   <> "error: 1 warning generated.\n"
/// assert unused_imports.rewrite("import gleam/int\npub fn main() { 1 }", diagnostics, "src/p.gleam")
///   == Ok(unused_imports.Rewrite(
///     source: "pub fn main() { 1 }",
///     notes: ["removed unused import gleam/int (line 1)"],
///   ))
/// ```
///
pub fn rewrite(
  source: String,
  diagnostics: String,
  file: String,
) -> Result(Rewrite, Nil) {
  use warnings <- result.try(parse(diagnostics, file))
  let lines = string.split(source, "\n")
  use edited <- result.try(edit_lines(lines, warnings, 1, [], []))
  let #(kept, notes) = edited
  Ok(Rewrite(source: string.join(kept, "\n"), notes: list.reverse(notes)))
}

// --- reading the compiler's output ---------------------------------------

// Every diagnostic block must be an unused-import warning, apart from the
// closing `error: N warning(s) generated.` summary, whose count must match.
fn parse(diagnostics: String, file: String) -> Result(List(Unused), Nil) {
  let blocks = blocks(string.split(diagnostics, "\n"))
  use classified <- result.try(list.try_map(blocks, classify(_, file)))
  let warnings = list.filter_map(classified, warning_of)
  let summaries =
    list.filter_map(classified, fn(entry) {
      case entry {
        Summary(count:) -> Ok(count)
        Warning(_) -> Error(Nil)
      }
    })
  let listed = list.length(warnings)
  case summaries, warnings {
    [count], [_, ..] if count == listed -> Ok(warnings)
    _, _ -> Error(Nil)
  }
}

type Classified {
  Warning(Unused)
  Summary(count: Int)
}

fn warning_of(entry: Classified) -> Result(Unused, Nil) {
  case entry {
    Warning(unused) -> Ok(unused)
    Summary(count: _) -> Error(Nil)
  }
}

// Splits the output into blocks, each a title line at the left margin and
// the lines up to the next title. Progress lines before the first title
// (`Compiling ...`) belong to no block and are dropped.
fn blocks(lines: List(String)) -> List(#(String, List(String))) {
  case lines {
    [] -> []
    [line, ..rest] ->
      case is_title(line) {
        False -> blocks(rest)
        True -> {
          let #(body, after) =
            list.split_while(rest, fn(next) { !is_title(next) })
          [#(line, body), ..blocks(after)]
        }
      }
  }
}

fn is_title(line: String) -> Bool {
  string.starts_with(line, "warning: ") || string.starts_with(line, "error: ")
}

fn classify(
  block: #(String, List(String)),
  file: String,
) -> Result(Classified, Nil) {
  let #(title, body) = block
  case title {
    "warning: Unused imported module" ->
      unused(Statement, body, file) |> result.map(Warning)
    "warning: Unused imported value"
    | "warning: Unused imported type"
    | "warning: Unused imported item" ->
      unused(Member, body, file) |> result.map(Warning)
    _ -> summary(title)
  }
}

// `error: 7 warnings generated.`, and only that, is the closing line.
fn summary(title: String) -> Result(Classified, Nil) {
  use rest <- result.try(after_prefix(title, "error: "))
  case string.split(rest, " ") {
    [count, "warning", "generated."] | [count, "warnings", "generated."] ->
      int.parse(count) |> result.map(fn(count) { Summary(count:) })
    _ -> Error(Nil)
  }
}

// The location line, then the echoed source line and the underline under it.
fn unused(
  scope: Scope,
  body: List(String),
  file: String,
) -> Result(Unused, Nil) {
  use location <- result.try(
    list.find_map(body, fn(line) {
      after_prefix(string.trim_start(line), "┌─ ")
    }),
  )
  use #(path, line, column) <- result.try(split_location(location))
  use _ <- result.try(case string.ends_with(path, file) {
    True -> Ok(Nil)
    False -> Error(Nil)
  })
  use #(echoed, width, offset) <- result.try(echoed_span(body, line))

  // The underline must start under the column the location names, or the
  // two descriptions of one span disagree and nothing is removed.
  case offset == column - 1 {
    True -> Ok(Unused(scope:, line:, column:, width:, echoed:))
    False -> Error(Nil)
  }
}

// `path:line:column`, split from the right because a path may hold colons.
fn split_location(location: String) -> Result(#(String, Int, Int), Nil) {
  case list.reverse(string.split(string.trim(location), ":")) {
    [column, line, ..path] if path != [] -> {
      use column <- result.try(int.parse(column))
      use line <- result.try(int.parse(line))
      Ok(#(string.join(list.reverse(path), ":"), line, column))
    }
    _ -> Error(Nil)
  }
}

// Finds `<line> │ <source>` followed by `  │ <spaces>^^^ <message>` and
// returns the echoed source, the underline's width and its offset in
// characters from the start of the source line.
fn echoed_span(
  body: List(String),
  line: Int,
) -> Result(#(String, Int, Int), Nil) {
  list.window_by_2(body)
  |> list.find_map(fn(pair) {
    use #(number, source) <- result.try(gutter(pair.0))
    use #(blank, marks) <- result.try(gutter(pair.1))
    use _ <- result.try(case int.parse(number) == Ok(line) && blank == "" {
      True -> Ok(Nil)
      False -> Error(Nil)
    })
    let spaces = string.length(marks) - string.length(string.trim_start(marks))
    let carets = string.trim_start(marks) |> string.to_graphemes
    let width = list.length(list.take_while(carets, fn(c) { c == "^" }))
    case width > 0 {
      True -> Ok(#(source, width, spaces))
      False -> Error(Nil)
    }
  })
}

// A diagnostic gutter line: what stands left of `│`, trimmed, and what
// stands right of it after the single separating space.
fn gutter(line: String) -> Result(#(String, String), Nil) {
  use #(left, right) <- result.try(string.split_once(line, "│"))
  Ok(#(string.trim(left), string.remove_prefix(right, " ")))
}

// --- editing the source --------------------------------------------------

// Walks the source line by line. `kept` is the output newest first, and
// `notes` the removal notes, newest first. A warning about a line that is
// not in the source, or that the line does not match, refuses the whole
// rewrite.
fn edit_lines(
  lines: List(String),
  warnings: List(Unused),
  number: Int,
  kept: List(String),
  notes: List(String),
) -> Result(#(List(String), List(String)), Nil) {
  case lines {
    [] ->
      case list.any(warnings, fn(warning) { warning.line >= number }) {
        True -> Error(Nil)
        False -> Ok(#(list.reverse(kept), notes))
      }
    [line, ..rest] -> {
      let here = list.filter(warnings, fn(warning) { warning.line == number })
      use edited <- result.try(edit_line(line, here, number))
      let #(replacement, added) = edited
      edit_lines(
        rest,
        warnings,
        number + 1,
        list.append(replacement, kept),
        list.append(list.reverse(added), notes),
      )
    }
  }
}

// One source line and the warnings about it: the line unchanged, deleted,
// or with some list members removed, and the notes for what changed.
fn edit_line(
  line: String,
  warnings: List(Unused),
  number: Int,
) -> Result(#(List(String), List(String)), Nil) {
  case warnings {
    [] -> Ok(#([line], []))
    _ -> {
      // The echoed line must be the line itself, byte for byte.
      use _ <- result.try(
        case list.all(warnings, fn(warning) { warning.echoed == line }) {
          True -> Ok(Nil)
          False -> Error(Nil)
        },
      )
      case list.any(warnings, fn(warning) { warning.scope == Statement }) {
        True -> remove_statement(line, warnings, number)
        False -> remove_members(line, warnings, number)
      }
    }
  }
}

// A whole-import warning removes the line. It must start the line and span
// the entire statement. A list member flagged on a line that is being
// deleted anyway is the same fact twice and is not counted separately.
fn remove_statement(
  line: String,
  warnings: List(Unused),
  number: Int,
) -> Result(#(List(String), List(String)), Nil) {
  use statement <- result.try(after_prefix(line, "import "))
  let statements =
    list.filter(warnings, fn(warning) { warning.scope == Statement })
  let whole =
    list.all(statements, fn(warning) {
      warning.column == 1
      && warning.width == string.length(string.trim_end(line))
    })
  case whole {
    True ->
      Ok(
        #([], [
          "removed unused import "
          <> string.trim(statement)
          <> " (line "
          <> int.to_string(number)
          <> ")",
        ]),
      )
    False -> Error(Nil)
  }
}

// Removes the named members from `import module.{a, b as c, type D}`.
fn remove_members(
  line: String,
  warnings: List(Unused),
  number: Int,
) -> Result(#(List(String), List(String)), Nil) {
  use #(head, rest) <- result.try(string.split_once(line, ".{"))
  use #(inside, tail) <- result.try(string.split_once(rest, "}"))
  use module <- result.try(after_prefix(head, "import "))
  let members = members(inside, string.length(head) + 2)
  let removed =
    list.filter(members, fn(member) {
      list.any(warnings, fn(warning) {
        warning.column == member.0 && warning.width == string.length(member.1)
      })
    })

  // Every warning must have found its member, so a span that names no
  // member of this list refuses instead of being skipped.
  use _ <- result.try(case list.length(removed) == list.length(warnings) {
    True -> Ok(Nil)
    False -> Error(Nil)
  })
  let remaining =
    list.filter(members, fn(member) { !list.contains(removed, member) })
  let rebuilt = case remaining {
    [] -> head <> tail
    _ ->
      head
      <> ".{"
      <> string.join(list.map(remaining, fn(member) { member.1 }), ", ")
      <> "}"
      <> tail
  }
  let notes =
    list.map(removed, fn(member) {
      "removed unused import "
      <> string.trim(module)
      <> ".{"
      <> member.1
      <> "} (line "
      <> int.to_string(number)
      <> ")"
    })
  Ok(#([rebuilt], notes))
}

// The members of a list's inside as `#(column, text)`, columns counted from
// one in characters over the whole line. `start` is how many characters
// precede the inside.
fn members(inside: String, start: Int) -> List(#(Int, String)) {
  let #(found, _next) =
    list.fold(string.split(inside, ","), #([], start), fn(state, piece) {
      let #(found, offset) = state
      let text = string.trim(piece)
      let lead = string.length(piece) - string.length(string.trim_start(piece))
      let found = case text {
        "" -> found
        _ -> [#(offset + lead + 1, text), ..found]
      }
      #(found, offset + string.length(piece) + 1)
    })
  list.reverse(found)
}

// The rest of `text` after `prefix`, or `Error(Nil)` when it does not start
// with it.
fn after_prefix(text: String, prefix: String) -> Result(String, Nil) {
  case string.starts_with(text, prefix) {
    True -> Ok(string.drop_start(text, string.length(prefix)))
    False -> Error(Nil)
  }
}
