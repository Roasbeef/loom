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
