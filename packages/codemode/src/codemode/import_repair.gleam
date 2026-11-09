//// Adding the imports a build reported missing, and nothing else.
////
//// A model that writes `int.to_string(n)` without `import gleam/int` gets
//// a build that fails with `Unknown module`, and the compiler's own hint
//// names the fix: ``Hint: Did you mean to import `gleam/int`?``. Programs
//// on a real deployment fail this way often enough that the round trip to
//// add one line is a large share of every failed build. This module reads
//// those diagnostics and returns the program with the hinted imports
//// added. The caller vets the result again under the same policy and
//// builds it once more, so a hint for a module the program may not import
//// is refused by vetting and the original failure stands: only modules the
//// vetting policy admits are ever added.
////
//// # What it reads
////
//// Every `error: Unknown module` block about the program's own file must
//// carry the two lines the compiler writes for a module it can suggest:
//// ``No module has been found with the name `int`.`` and
//// ``Hint: Did you mean to import `gleam/int`?``, where the hinted path's
//// last segment is the unknown name. A block without a hint (the name
//// matches no module the build knows) or with a hint that disagrees makes
//// the whole rewrite refuse, because adding the other imports would cost a
//// rebuild that still fails. So does a hinted module the program already
//// imports: under an alias (`import gleam/int as i`) the compiler still
//// hints `gleam/int` for a bare `int.`, and a second import of it is not a
//// fix.
////
//// Every other diagnostic is left alone. Errors that follow from the
//// missing module, such as `Unknown type for record access` on a value a
//// call into it returned, go away with the import, and anything else is
//// still in the second build's output, which is final.
////
//// # Where the imports go
////
//// At the end of the file. Gleam accepts an import anywhere at the top
//// level, and appending moves no existing line, so every other diagnostic
//// of the first build still names the line it named, and the model's own
//// reading of its program stays true.

import codemode/unused_repair.{type Rewrite, Rewrite}
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// Adds the imports `diagnostics` reports missing from `source`, as the
/// compiler hinted them. It returns `Error(Nil)` when no missing import is
/// reported, or when any `Unknown module` diagnostic about `file` lacks a
/// hint, disagrees with itself, or names a module the program already
/// imports. `file` is the path suffix the diagnostics must be about, such as
/// `src/loom_program.gleam`.
///
/// ## Examples
///
/// ```gleam
/// let diagnostics =
///   "error: Unknown module\n  ┌─ /b/src/p.gleam:2:3\n  │\n2 │   int.to_string(1)\n"
///   <> "  │   ^^^\n\nNo module has been found with the name `int`.\n\n"
///   <> "Hint: Did you mean to import `gleam/int`?\n"
/// assert import_repair.rewrite("pub fn main() {\n  int.to_string(1)\n}\n", diagnostics, "src/p.gleam")
///   == Ok(Rewrite(
///     source: "pub fn main() {\n  int.to_string(1)\n}\nimport gleam/int\n",
///     notes: ["added missing import gleam/int (line 4)"],
///   ))
/// ```
///
pub fn rewrite(
  source: String,
  diagnostics: String,
  file: String,
) -> Result(Rewrite, Nil) {
  use missing <- result.try(missing_modules(diagnostics, file))
  use Nil <- result.try(none_imported(source, missing))

  let lines = string.split(source, "\n")

  // The imports go after the last line of the program. A source that ends
  // in a newline keeps ending in one.
  let #(body, ending) = case list.reverse(lines) {
    ["", ..rest] -> #(list.reverse(rest), [""])
    _ -> #(lines, [])
  }

  let first = list.length(body) + 1
  let added = list.map(missing, fn(module) { "import " <> module })
  let notes =
    list.index_map(missing, fn(module, index) {
      "added missing import "
      <> module
      <> " (line "
      <> int.to_string(first + index)
      <> ")"
    })

  Ok(Rewrite(
    source: string.join(list.flatten([body, added, ending]), "\n"),
    notes:,
  ))
}

// --- reading the compiler's output ---------------------------------------

/// The hinted modules, once each, in the order the compiler first named
/// them, or `Error(Nil)` when there are none or any block does not read as
/// a missing import with a hint.
fn missing_modules(
  diagnostics: String,
  file: String,
) -> Result(List(String), Nil) {
  let unknown =
    blocks(string.split(diagnostics, "\n"))
    |> list.filter(fn(block) { block.0 == "error: Unknown module" })
  use hinted <- result.try(list.try_map(unknown, hinted_module(_, file)))

  // Nothing to add is not a rewrite: the caller builds nothing again.
  case list.unique(hinted) {
    [] -> Error(Nil)
    modules -> Ok(modules)
  }
}

/// The module one `Unknown module` block hints, when the block is about
/// `file`, names the unknown module and hints a path whose last segment is
/// that name.
fn hinted_module(
  block: #(String, List(String)),
  file: String,
) -> Result(String, Nil) {
  let #(_title, body) = block
  use location <- result.try(
    list.find_map(body, fn(line) {
      after_prefix(string.trim_start(line), "┌─ ")
    }),
  )
  use path <- result.try(path_of(location))

  // A diagnostic about another module is not this program's to fix.
  use _ <- result.try(case string.ends_with(path, file) {
    True -> Ok(Nil)
    False -> Error(Nil)
  })

  use name <- result.try(
    list.find_map(body, fn(line) {
      quoted(line, "No module has been found with the name `", "`.")
    }),
  )
  use module <- result.try(
    list.find_map(body, fn(line) {
      quoted(line, "Hint: Did you mean to import `", "`?")
    }),
  )

  // The hint must be a module path and must end with the name the program
  // used, or the two lines describe different modules.
  case
    is_module_path(module) && list.last(string.split(module, "/")) == Ok(name)
  {
    True -> Ok(module)
    False -> Error(Nil)
  }
}

/// The path of a `path:line:column` location, split from the right because
/// a path may hold colons.
fn path_of(location: String) -> Result(String, Nil) {
  // The last two fields must be numbers; everything before them is the path.
  case list.reverse(string.split(string.trim(location), ":")) {
    [column, line, ..path] if path != [] -> {
      use _ <- result.try(int.parse(column))
      use _ <- result.try(int.parse(line))
      Ok(string.join(list.reverse(path), ":"))
    }
    _ -> Error(Nil)
  }
}

/// The text between `prefix` and `suffix` when `line` is exactly the two
/// around it.
fn quoted(line: String, prefix: String, suffix: String) -> Result(String, Nil) {
  use rest <- result.try(after_prefix(string.trim(line), prefix))

  // The quoted text runs up to the suffix, which must end the line.
  case string.ends_with(rest, suffix) {
    True -> Ok(string.drop_end(rest, string.length(suffix)))
    False -> Error(Nil)
  }
}

/// Whether `text` is a Gleam module path: lowercase segments of letters,
/// digits and underscores, each starting with a letter, joined by `/`.
fn is_module_path(text: String) -> Bool {
  let lower = string.to_graphemes("abcdefghijklmnopqrstuvwxyz")
  let rest_of_name = list.append(lower, string.to_graphemes("0123456789_"))

  string.split(text, "/")
  |> list.all(fn(segment) {
    // A segment starts with a letter and holds no other kind of character.
    case string.to_graphemes(segment) {
      [first, ..rest] ->
        list.contains(lower, first)
        && list.all(rest, list.contains(rest_of_name, _))
      [] -> False
    }
  })
}

/// Splits the output into blocks, each a title line at the left margin and
/// the lines up to the next title. Progress lines before the first title
/// (`Compiling ...`) belong to no block and are dropped.
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

// --- reading the source --------------------------------------------------

/// `Ok(Nil)` when the program imports none of `modules` in any form: a
/// plain import, an aliased one or one with an unqualified list.
fn none_imported(source: String, modules: List(String)) -> Result(Nil, Nil) {
  let imported =
    string.split(source, "\n")
    |> list.filter_map(fn(line) {
      use rest <- result.try(after_prefix(string.trim_start(line), "import "))
      Ok(module_of(string.trim(rest)))
    })

  // One hinted module already imported is a hint no import can satisfy.
  case list.any(modules, list.contains(imported, _)) {
    True -> Error(Nil)
    False -> Ok(Nil)
  }
}

/// The module an import statement's text names: everything before an
/// unqualified list, an alias or the end.
fn module_of(statement: String) -> String {
  // An unqualified list starts at `.{`.
  let before_list = case string.split_once(statement, ".{") {
    Ok(#(module, _)) -> module
    Error(Nil) -> statement
  }

  // An alias follows the module after a space.
  case string.split_once(before_list, " ") {
    Ok(#(module, _)) -> module
    Error(Nil) -> before_list
  }
}

// The rest of `text` after `prefix`, or `Error(Nil)` when it does not start
// with it.
fn after_prefix(text: String, prefix: String) -> Result(String, Nil) {
  case string.starts_with(text, prefix) {
    True -> Ok(string.drop_start(text, string.length(prefix)))
    False -> Error(Nil)
  }
}
