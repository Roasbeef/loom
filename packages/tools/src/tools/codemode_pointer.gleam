//// Which capability reference a failed code-mode program should read next.
////
//// A model that gets a compile error about `lsp_sql.Plan`, or a
//// `lsp.snapshot` call that failed, can read the module's reference with
//// `fs_read` on `cap://lsp_sql`, but it has to think of doing so. Without a
//// pointer it guesses at field names and probes `sqlite_master`. This module
//// decides, from the failure alone, whether to say so and which modules to
//// name, and it is pure: the caller passes the modules the host admits, so a
//// pointer never names a reference `cap://` would refuse.
////
//// Two failures qualify. A compile error whose diagnostics mention a
//// capability module, either by its import path (`cap/lsp_sql`) or by a
//// qualified use (`lsp_sql.Plan`), and a program that ran while its call
//// record shows a failed capability call, named by the module that owns the
//// call. A vetting refusal never reaches this module: its text already says
//// which import is forbidden. At most two modules are named, and no line is
//// produced when none applies.
////
//// A third kind of help is for a name that does not exist. The compiler says
//// ``The module `cap/proc` does not have a `int_to_string` value.``, and the
//// usual cause is a function called on the wrong module. `suggestions` reads
//// those diagnostics and names the right module when it can be checked
//// against the generated prelude surfaces, or flags a guess at a standard
//// library function when it cannot.

import gleam/int
import gleam/list
import gleam/result
import gleam/string
import tools/call_record.{type CallLog}

/// The most modules one pointer names.
pub const max_modules = 2

/// The modules, among `admitted` (import paths such as `cap/lsp_sql`), that a
/// compiler's diagnostics mention, in the order they first appear.
///
/// ## Examples
///
/// ```gleam
/// assert codemode_pointer.compile_modules(
///     "error: Unknown module value\n  lsp_sql.Plann(...)",
///     ["cap/fs", "cap/lsp_sql"],
///   )
///   == ["cap/lsp_sql"]
/// ```
///
pub fn compile_modules(
  diagnostics: String,
  admitted: List(String),
) -> List(String) {
  admitted
  |> list.filter(is_capability)
  |> list.filter_map(fn(module) {
    mention_index(diagnostics, module)
    |> result.map(fn(at) { #(at, module) })
  })
  |> list.sort(fn(left, right) { int.compare(left.0, right.0) })
  |> list.map(fn(pair) { pair.1 })
  |> list.take(max_modules)
}

/// The modules, among `admitted`, that own a capability call the program
/// made and that failed, in the order the failures happened.
///
/// A call is named `<module>.<operation>`, with one exception: the
/// `lsp.snapshot` call belongs to `cap/lsp_sql`.
///
/// ## Examples
///
/// ```gleam
/// // codemode_pointer.failed_call_modules(calls, ["cap/lsp", "cap/lsp_sql"])
/// //   == ["cap/lsp_sql"]
/// ```
///
pub fn failed_call_modules(
  calls: CallLog,
  admitted: List(String),
) -> List(String) {
  calls.items
  |> list.filter(fn(record) { record.status == call_record.CallFailed })
  |> list.map(fn(record) { owner(record.cap) })
  |> list.unique
  |> list.filter(fn(module) { list.contains(admitted, module) })
  |> list.take(max_modules)
}

/// The most suggestion lines one build gets.
pub const max_suggestions = 3

/// One line for each `The module `M` does not have a `X` value.` diagnostic,
/// at most `max_suggestions` in all and in the order they appear.
///
/// `surfaces` is the generated prelude (`tools/prelude.surfaces`) and
/// `allowed` the import paths the program may use. A diagnostic about a
/// module outside `allowed` gets no line. Otherwise:
///
/// - if `X` is a public function of another allowed module in `surfaces`,
///   the line says which one; this is checked against the surface text.
/// - if `X` reads `<p>_<rest>` and `gleam/<p>` is allowed, the line guesses
///   `<p>.<rest>` and says it is unchecked, because the host holds no
///   standard library exports.
///
/// ## Examples
///
/// ```gleam
/// // suggestions(diagnostic_about("cap/proc", "int_to_string"), [], ["cap/proc", "gleam/int"])
/// //   == ["`int_to_string`: maybe `int.to_string` from gleam/int (unchecked)"]
/// ```
///
pub fn suggestions(
  diagnostics: String,
  surfaces: List(#(String, String)),
  allowed: List(String),
) -> List(String) {
  unknown_values(diagnostics)
  |> list.filter(fn(pair) { list.contains(allowed, pair.0) })
  |> list.filter_map(fn(pair) { suggest(pair.0, pair.1, surfaces, allowed) })
  |> list.unique
  |> list.take(max_suggestions)
}

// Every `#(module, value)` the compiler reported as missing, in order.
fn unknown_values(diagnostics: String) -> List(#(String, String)) {
  case string.split(diagnostics, "The module `") {
    [] -> []
    [_before, ..segments] -> list.filter_map(segments, missing_value)
  }
}

// Reads ``cap/proc` does not have a `int_to_string` value.`` from the text
// after "The module `".
fn missing_value(segment: String) -> Result(#(String, String), Nil) {
  use #(module, rest) <- result.try(string.split_once(segment, on: "`"))
  use rest <- result.try(drop_prefix(rest, " does not have a `"))
  use #(value, rest) <- result.try(string.split_once(rest, on: "`"))
  case string.starts_with(rest, " value") {
    True -> Ok(#(module, value))
    False -> Error(Nil)
  }
}

fn drop_prefix(text: String, prefix: String) -> Result(String, Nil) {
  case string.starts_with(text, prefix) {
    True -> Ok(string.drop_start(text, string.length(prefix)))
    False -> Error(Nil)
  }
}

fn suggest(
  module: String,
  value: String,
  surfaces: List(#(String, String)),
  allowed: List(String),
) -> Result(String, Nil) {
  case owner_in_surfaces(module, value, surfaces, allowed) {
    Ok(owner) -> Ok("`" <> value <> "` is in " <> owner <> ", not " <> module)
    Error(Nil) -> stdlib_guess(value, allowed)
  }
}

// The first allowed module other than `module` whose surface declares
// `pub fn value(`.
fn owner_in_surfaces(
  module: String,
  value: String,
  surfaces: List(#(String, String)),
  allowed: List(String),
) -> Result(String, Nil) {
  let declaration = "pub fn " <> value <> "("
  list.find_map(allowed, fn(candidate) {
    case candidate != module, list.key_find(surfaces, candidate) {
      True, Ok(surface) ->
        case string.contains(surface, declaration) {
          True -> Ok(candidate)
          False -> Error(Nil)
        }
      _, _ -> Error(Nil)
    }
  })
}

// `int_to_string` is a guess at `int.to_string`, offered only when
// `gleam/int` is importable and said to be unchecked.
fn stdlib_guess(value: String, allowed: List(String)) -> Result(String, Nil) {
  use #(prefix, rest) <- result.try(string.split_once(value, on: "_"))
  let module = "gleam/" <> prefix
  case prefix != "" && rest != "" && list.contains(allowed, module) {
    True ->
      Ok(
        "`"
        <> value
        <> "`: maybe `"
        <> prefix
        <> "."
        <> rest
        <> "` from "
        <> module
        <> " (unchecked)",
      )
    False -> Error(Nil)
  }
}

/// The one line the model reads, or nothing when no module applies.
///
/// ## Examples
///
/// ```gleam
/// assert codemode_pointer.line(["cap/lsp_sql"])
///   == "see fs_read cap://lsp_sql for its types, functions and error helpers"
/// assert codemode_pointer.line([]) == ""
/// ```
///
pub fn line(modules: List(String)) -> String {
  case list.map(list.take(modules, max_modules), reference) {
    [] -> ""
    [one] ->
      "see fs_read " <> one <> " for its types, functions and error helpers"
    [first, second, ..] ->
      "see fs_read "
      <> first
      <> " and "
      <> second
      <> " for their types, functions and error helpers"
  }
}

// `cap/lsp_sql` is read as `cap://lsp_sql`.
fn reference(module: String) -> String {
  "cap://" <> string.drop_start(module, string.length("cap/"))
}

fn is_capability(module: String) -> Bool {
  string.starts_with(module, "cap/")
}

// The capability `lsp.snapshot` is the one call whose owning module is not
// its prefix: it is `cap/lsp_sql`'s only call, and `cap/lsp` has no
// `snapshot`.
fn owner(capability: String) -> String {
  case capability {
    "lsp.snapshot" -> "cap/lsp_sql"
    other ->
      case string.split_once(other, on: ".") {
        Ok(#(prefix, _operation)) -> "cap/" <> prefix
        Error(Nil) -> "cap/" <> other
      }
  }
}

// The character offset of the first mention of `module`, as its import path
// or, boundary-checked, as a qualified use of its last segment.
fn mention_index(text: String, module: String) -> Result(Int, Nil) {
  let short = case list.last(string.split(module, "/")) {
    Ok(last) -> last
    Error(Nil) -> module
  }
  case first_index(text, module), qualified_index(text, short <> ".", 0) {
    Ok(path), Ok(use_) -> Ok(int.min(path, use_))
    Ok(path), Error(Nil) -> Ok(path)
    Error(Nil), Ok(use_) -> Ok(use_)
    Error(Nil), Error(Nil) -> Error(Nil)
  }
}

// The offset of the first mention of `needle` that is not the front of a
// longer name: `cap/lsp` is found in `cap/lsp.` but not inside `cap/lsp_sql`.
fn first_index(text: String, needle: String) -> Result(Int, Nil) {
  first_bounded(text, needle, 0)
}

fn first_bounded(
  text: String,
  needle: String,
  offset: Int,
) -> Result(Int, Nil) {
  case string.split_once(text, on: needle) {
    Error(Nil) -> Error(Nil)
    Ok(#(before, after)) ->
      case starts_a_name(after) {
        False -> Ok(offset + string.length(before))
        True ->
          first_bounded(
            after,
            needle,
            offset + string.length(before) + string.length(needle),
          )
      }
  }
}

fn starts_a_name(after: String) -> Bool {
  case string.pop_grapheme(after) {
    Error(Nil) -> False
    Ok(#(first, _rest)) -> string.contains(name_characters, first)
  }
}

// A qualified use only counts when the text before it is not part of a
// longer name: `fs.read` is a mention of `fs`, `tools.fs.read` and
// `my_fs.read` are not.
fn qualified_index(
  text: String,
  needle: String,
  offset: Int,
) -> Result(Int, Nil) {
  case string.split_once(text, on: needle) {
    Error(Nil) -> Error(Nil)
    Ok(#(before, after)) ->
      case ends_a_name(before) {
        False -> Ok(offset + string.length(before))
        True ->
          qualified_index(
            after,
            needle,
            offset + string.length(before) + string.length(needle),
          )
      }
  }
}

fn ends_a_name(before: String) -> Bool {
  case string.pop_grapheme(string.reverse(before)) {
    Error(Nil) -> False
    Ok(#(last, _rest)) -> string.contains(name_characters, last)
  }
}

const name_characters =
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_/."
