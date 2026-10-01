//// R18, the census of short one-caller helpers the module doc never names (issue #593, 4).
////
//// Extracting a helper buys a name, and the name is the whole return: a
//// reader skims `run`, sees `reconcile_orphans(state)`, and does not open it
//// because the name told them what it does. A helper that names no domain
//// operation — `do_thing`, `step_2`, `inner` — buys nothing and costs a
//// jump, and the lone caller's body is now scattered over two places. This
//// rule counts the candidates; deciding which are real is a reader's job.
////
//// A candidate is a private function with exactly one in-module caller
//// (`lint/calls`: recursion is not a caller, a reference from a constant is
//// invisible), whose definition spans at most `unnamed_helper_lines` lines
//// from the `fn` line to the closing brace inclusive, and whose name appears
//// nowhere in the module doc as a whole word. The last clause is the escape
//// hatch the style asks for: a helper the module doc names is part of the
//// module's story, so it has been promoted to a domain operation by the one
//// reader who is entitled to say so.
////
//// The module doc is read from `glexer` comment tokens rather than from
//// lines of text, for the reason `lint/source` lexes its comments: a `////`
//// at the start of a line inside a multi-line string is a string, and a
//// name "documented" there would silence the rule for nothing.
////
//// Both readings over-report, as every census here does, so the rule warns
//// forever. A short helper with one caller is often right — it is the
//// second caller next week that the rule cannot see.

import glance
import gleam/int
import gleam/list
import gleam/set.{type Set}
import gleam/string
import glexer
import glexer/token
import lint/calls.{type Helper}
import lint/finding
import lint/policy.{type Policy}
import lint/scan.{type Raw, Raw}
import lint/source.{type Lines}

/// Every finding this rule makes about one parsed module.
///
/// ## Examples
///
/// ```gleam
/// unnamed_helper.findings(module, code, lines, policy.default(), "tools/fs")
/// // -> []
/// ```
pub fn findings(
  module: glance.Module,
  code: String,
  lines: Lines,
  policy: Policy,
  own_path: String,
) -> List(Raw) {
  let _ = own_path
  let named = doc_words(code)

  calls.private_helpers(module)
  |> list.filter_map(fn(helper) {
    candidate(helper, lines, policy.unnamed_helper_lines, named)
  })
}

/// The finding for one helper, or `Error(Nil)` when any clause of the rule
/// rejects it: a second caller, a body too long to be a trivial extraction,
/// or a name the module doc has already promoted.
fn candidate(
  helper: Helper,
  lines: Lines,
  limit: Int,
  named: Set(String),
) -> Result(Raw, Nil) {
  let function = helper.function
  let span = span_lines(function, lines)
  case helper.callers {
    [only] if span <= limit ->
      case set.contains(named, function.name) {
        True -> Error(Nil)
        False -> Ok(finding_for(function, only.name, span))
      }
    _ -> Error(Nil)
  }
}

/// Lines from the `fn` line to the closing brace, inclusive. A function's
/// location starts at its `fn` (or `pub fn`) keyword, so the doc comment
/// above it is never part of the span.
fn span_lines(function: glance.Function, lines: Lines) -> Int {
  let first = source.line_of(lines.starts, function.location.start)
  let last = source.line_of(lines.starts, function.location.end)
  last - first + 1
}

fn finding_for(function: glance.Function, caller: String, span: Int) -> Raw {
  Raw(
    rule: finding.UnnamedHelper,
    offset: function.location.start,
    function: function.name,
    detail: "`"
      <> function.name
      <> "` has one caller (`"
      <> caller
      <> "`), spans "
      <> int.to_string(span)
      <> " lines, and the module doc never names it; if it does not name a "
      <> "domain operation, inline it into `"
      <> caller
      <> "`",
  )
}

/// Every whole word the module doc contains, where a word is a maximal run
/// of ASCII letters, digits and underscores — exactly the characters of a
/// Gleam function name, so `run` is a word of "calls `run` first" and not of
/// "runner". The tokens are rendered back to source and only those that
/// begin `////` are read, which a string token never does: it renders with
/// its quotes, so a `////` inside a string is not module doc, and naming
/// the token variant would need a catch-all over glexer's sixty-odd kinds.
fn doc_words(code: String) -> Set(String) {
  glexer.new(code)
  |> glexer.discard_whitespace
  |> glexer.lex
  |> list.map(fn(lexed) { token.to_source(lexed.0) })
  |> list.filter(string.starts_with(_, "////"))
  |> list.flat_map(words)
  |> set.from_list
}

/// Split one comment's text into words, dropping everything between them.
fn words(text: String) -> List(String) {
  text
  |> string.to_graphemes
  |> list.chunk(is_word_grapheme)
  |> list.filter(fn(chunk) {
    case chunk {
      [first, ..] -> is_word_grapheme(first)
      [] -> False
    }
  })
  |> list.map(string.concat)
}

fn is_word_grapheme(grapheme: String) -> Bool {
  case string.to_utf_codepoints(grapheme) {
    [point] -> {
      let code = string.utf_codepoint_to_int(point)
      code == 95
      || { code >= 48 && code <= 57 }
      || { code >= 65 && code <= 90 }
      || { code >= 97 && code <= 122 }
    }
    _ -> False
  }
}
