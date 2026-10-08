//// Repairing what a build reported as unused, and nothing else.
////
//// The production build runs with `--warnings-as-errors`, which is what
//// turns Gleam's "transitive dependency imported" warning into a compile
//// error (`codemode/build`). The same flag makes an unused `import
//// gleam/int`, an unused lambda argument or an unused `let` fail the
//// build, and a failure costs the model a round trip to fix something the
//// compiler already named. This module reads the compiler's own
//// diagnostics and, only when *every* diagnostic is one of those unused
//// warnings, returns the program with exactly those spots repaired. The
//// caller vets and builds that program once more.
////
//// # Why the rule is all-or-nothing
////
//// A build that fails for any other reason, or that carries any other
//// warning alongside the unused ones, is not rewritten at all. A
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
//// changed.
////
//// # What is repaired
////
//// Imports: Gleam names four titles: `Unused imported module` for a whole
//// import, and `Unused imported value`, `type` or `item` for one name
//// inside an unqualified list `{...}`. A whole import is removed with its
//// line. A named item is removed from its list together with its `as`
//// alias, and the braces and the `.` go with the last item, leaving an
//// `as` alias on the module itself in place. Imports written across
//// several lines are refused, because their spans do not sit on one line.
////
//// Names: `Unused function argument` covers lambda parameters, named
//// function parameters and `use` bindings (`use` desugars to a callback,
//// so the compiler files an unused one under this title), and `Unused
//// variable` covers `let` bindings. The underline covers the name and the
//// `Hint:` line gives the replacement, `_name`. The underlined text must
//// equal the hinted name, and then one `_` is inserted before it. A
//// labelled parameter `label name` has its underline on `name`, so the
//// label is never touched. Edits on one line apply right to left so the
//// columns of the earlier ones stay valid.
////
//// A `let` or `use` binding that nothing reads often means the program
//// forgot to use a value it computed, so those notes say so. Underscoring
//// it makes the build pass and leaves the missing value missing.
////
//// A variable bound in alternative patterns (`Ok(x) | Error(x) ->`) gets one
//// warning and so one underscore, and the second build then fails because
//// the alternatives no longer bind the same name. That build's diagnostics
//// are final and its note names the rename, so this case is left as it is.

import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// The program after the removals, and one note per removal for the model
/// to read, in source order.
pub type Rewrite {
  Rewrite(
    /// The submitted source with the unused spots repaired.
    source: String,
    /// One line per repair, such as `removed unused import gleam/int (line
    /// 3)` or `renamed unused argument e to _e (line 18)`.
    notes: List(String),
  )
}

// What an unused warning repairs.
type Scope {
  // The whole `import` statement.
  Statement

  // One name inside the `{...}` list.
  Member

  // A function or lambda parameter, or a `use` binding, which the compiler
  // reports under the same title. Carries the name without its underscore.
  Argument(name: String)

  // A `let` binding, or a pattern variable the compiler calls a variable.
  Binding(name: String)
}

// One parsed unused warning: where the compiler underlined, how wide, and
// the source line it echoed beside the underline.
type Unused {
  Unused(scope: Scope, line: Int, column: Int, width: Int, echoed: String)
}

/// Repairs what `diagnostics` reports as unused in `source`: unused imports
/// are removed, unused arguments and bindings get a leading underscore. It
/// returns `Error(Nil)` when anything else is in the output or anything
/// fails to agree. `file` is the path suffix the warnings must be about, such as
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
/// assert unused_repair.rewrite("import gleam/int\npub fn main() { 1 }", diagnostics, "src/p.gleam")
///   == Ok(unused_repair.Rewrite(
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

// Every diagnostic block must be an unused warning, apart from the
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
      unused(fn(_) { Ok(Statement) }, body, file) |> result.map(Warning)
    "warning: Unused imported value"
    | "warning: Unused imported type"
    | "warning: Unused imported item" ->
      unused(fn(_) { Ok(Member) }, body, file) |> result.map(Warning)
    "warning: Unused function argument" ->
      unused(named(_, Argument), body, file) |> result.map(Warning)
    "warning: Unused variable" ->
      unused(named(_, Binding), body, file) |> result.map(Warning)
    _ -> summary(title)
  }
}

// The scope of a rename warning. The `Hint:` line names the replacement,
// `` `_e` ``, and the text under the underline must be that name without the
// underscore: a hint that disagrees with the underline, such as the `name:`
// shorthand in a pattern, is not a name this module knows how to rename.
fn named(
  found: #(List(String), String),
  scope: fn(String) -> Scope,
) -> Result(Scope, Nil) {
  let #(body, underlined) = found
  use hint <- result.try(
    list.find_map(body, fn(line) {
      after_prefix(line, "Hint: You can ignore it with an underscore: `")
    }),
  )
  use hinted <- result.try(string.split_once(hint, "`"))
  use name <- result.try(after_prefix(hinted.0, "_"))
  case name != "" && name == underlined {
    True -> Ok(scope(name))
    False -> Error(Nil)
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
// `scope_of` is given the block body and the underlined text and answers
// the scope, or refuses.
fn unused(
  scope_of: fn(#(List(String), String)) -> Result(Scope, Nil),
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
  let underlined = slice(echoed, offset, width)
  use scope <- result.try(scope_of(#(body, underlined)))

  // The underline must start under the column the location names, or the
  // two descriptions of one span disagree and nothing is changed.
  case offset == column - 1 {
    True -> Ok(Unused(scope:, line:, column:, width:, echoed:))
    False -> Error(Nil)
  }
}

// `width` graphemes of `text` from the zero-based grapheme `offset`.
//
// Three units meet here. Gleam's location column counts characters, the
// underline's offset in the echoed line is a display width, and `slice`
// counts graphemes. They agree for ordinary text. When they do not, as after
// an emoji or a combining mark earlier on the line, the underlined text
// differs from the hinted name or the offset differs from the column, and
// the caller refuses instead of editing the wrong span.
fn slice(text: String, offset: Int, width: Int) -> String {
  text |> string.drop_start(offset) |> string.slice(0, width)
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
      case list.all(warnings, is_rename), list.any(warnings, is_rename) {
        True, _ -> rename_names(line, warnings, number)
        False, True -> Error(Nil)
        False, False ->
          case list.any(warnings, fn(warning) { warning.scope == Statement }) {
            True -> remove_statement(line, warnings, number)
            False -> remove_members(line, warnings, number)
          }
      }
    }
  }
}

// Whether the warning is about a name to underscore rather than an import.
// A line holding both kinds is refused: an `import` statement cannot hold a
// parameter, so the two descriptions of the line disagree.
fn is_rename(warning: Unused) -> Bool {
  case warning.scope {
    Argument(name: _) | Binding(name: _) -> True
    Statement | Member -> False
  }
}

// Inserts `_` before each flagged name, right to left so the columns of the
// names still to be edited stay valid. Two warnings at one column would
// double the underscore, so they refuse. The underlined text was checked
// against the hinted name while parsing, and the echoed line against this
// one, so the column is known to hold the name.
fn rename_names(
  line: String,
  warnings: List(Unused),
  number: Int,
) -> Result(#(List(String), List(String)), Nil) {
  let ordered =
    list.sort(warnings, fn(a, b) { int.compare(a.column, b.column) })
  let columns = list.map(ordered, fn(warning) { warning.column })
  use _ <- result.try(case list.unique(columns) == columns {
    True -> Ok(Nil)
    False -> Error(Nil)
  })
  let rebuilt =
    list.fold(list.reverse(ordered), line, fn(text, warning) {
      string.slice(text, 0, warning.column - 1)
      <> "_"
      <> string.drop_start(text, warning.column - 1)
    })
  Ok(#([rebuilt], list.map(ordered, rename_note(_, line, number))))
}

// The note for one rename. A `use` or `let` binding gets the warning that
// nothing reads it, because that usually means the program forgot to use a
// value it computed; underscoring only silences the compiler.
fn rename_note(warning: Unused, line: String, number: Int) -> String {
  let at = " (line " <> int.to_string(number) <> ")"
  case warning.scope {
    Argument(name:) ->
      case is_use_binding(line, warning.column) {
        True -> binding_note(name, at)
        False -> "renamed unused argument " <> name <> " to _" <> name <> at
      }
    Binding(name:) -> binding_note(name, at)
    Statement | Member -> ""
  }
}

fn binding_note(name: String, at: String) -> String {
  "renamed unused binding "
  <> name
  <> " to _"
  <> name
  <> at
  <> "; nothing reads it, so a value the program meant to return may be missing"
}

// A `use` binding's name sits in the pattern list between `use ` and `<-`.
// The compiler reports it as an argument; the source line is what tells the
// two apart. Only identifier characters, commas and spaces may stand between
// `use ` and the name, so a lambda argument later on a `use` line, as in
// `use _ <- result.try(f(fn(y) { 1 }))`, is not mistaken for a binding.
fn is_use_binding(line: String, column: Int) -> Bool {
  let before = string.trim_start(string.slice(line, 0, column - 1))
  case string.starts_with(before, "use ") {
    True ->
      string.drop_start(before, 4)
      |> string.to_graphemes
      |> list.all(is_pattern_character)
    False -> False
  }
}

fn is_pattern_character(grapheme: String) -> Bool {
  grapheme == "_"
  || grapheme == ","
  || grapheme == " "
  || string.lowercase(grapheme) != string.uppercase(grapheme)
  || list.contains(["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"], grapheme)
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
