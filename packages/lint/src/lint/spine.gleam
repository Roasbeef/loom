//// R13, the control-flow spine a large module opens with (issue #593, 1).
////
//// A reader dropped into a thousand-line module by "go to definition" has
//// the function in front of them and no map. The spine is the map: a
//// `//// ## Flow` section in the module doc that names, in order, the
//// functions on the module's main path. This rule has two jobs. It asks for
//// a spine where a module is large enough to need one, and it keeps every
//// spine honest. A spine that names a function the module no longer defines
//// is worse than none, so every backticked name in the section is resolved
//// against the module's own definitions and imports, and a rename that
//// forgets the doc fails the gate.
////
//// The module doc is invisible to `glance`, so the section is read from
//// `lint/module_doc`'s token-based lines. A span is checked only if it looks
//// like a function reference: a bare snake_case name, optionally followed
//// by `(...)` or `/N`, or `alias.name` with the same shape. Anything else,
//// such as an UpperCamel type or a snippet with spaces, is prose. For a
//// qualified span only the alias is checked, against the module's imports;
//// the function behind it lives in another file and is that file's concern.
////
//// A spine may also be drawn as a diagram in a ```` ```text ```` fence, the
//// form the language-server modules use for a path with branches. A fence
//// has no backticks to say which words are names, so it is checked by
//// shape instead: a word with an interior underscore (`begin_server`) or
//// written as a call (`ask(Acquire)`) must be a function or a constant the
//// module defines, because prose has no such words. A plain word such as
//// `handle` or `door` is not checked, since prose is made of those, but it
//// still counts towards the three functions a spine must name when it is
//// one. A qualified word (`lsp.settle`, `backend.connect`) is not checked
//// in a fence, where it is as often a field call as an import, and a
//// pattern such as `decode_<name>` or `render_*` is a family rather than a
//// name. Any other fenced block, one that is not `text`, is refused: a
//// code listing is not a spine.

import glance
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/set.{type Set}
import gleam/string
import lint/finding
import lint/module_doc.{type DocLine, type Section}
import lint/policy.{type Policy}
import lint/scan.{type Raw, Raw}
import lint/source.{type Lines}

/// The heading that opens a spine, as `module_doc` reads it.
const heading: String = "## Flow"

/// A spine has to be a spine: fewer local functions than this and the
/// section is a paragraph about something else.
const minimum_functions: Int = 3

/// Every finding this rule makes about one parsed module.
///
/// A module with no Flow section is a finding only at or over the policy's
/// `spine_lines`; a module with one is checked whatever its size, because a
/// small module's optional spine is just as capable of going stale.
///
/// ## Examples
///
/// ```gleam
/// spine.findings(module, code, lines, policy.default(), "tools/fs")
/// // -> []
/// ```
///
pub fn findings(
  module: glance.Module,
  code: String,
  lines: Lines,
  policy: Policy,
  own_path: String,
) -> List(Raw) {
  let _ = own_path
  case module_doc.section(module_doc.lines(code), heading) {
    Ok(section) -> check_section(module, section)
    Error(Nil) -> missing(code, lines, policy)
  }
}

/// The one finding for a large module with no spine, at the top of the file
/// where the missing section would have been.
fn missing(code: String, lines: Lines, policy: Policy) -> List(Raw) {
  let count = line_count(code, lines)
  case count >= policy.spine_lines {
    False -> []
    True -> [
      Raw(
        rule: finding.FlowSpine,
        offset: 0,
        function: "",
        detail: "module has "
          <> int_string(count)
          <> " lines and no `//// "
          <> heading
          <> "` section in its module doc; a spine names the functions on the"
          <> " module's main path in order, so a reader landing on one function"
          <> " can find the rest",
      ),
    ]
  }
}

/// Lines as `wc -l` would count a file that ends in a newline, and as an
/// editor shows a file that does not: the table holds one entry per line
/// start, so a final newline contributes no phantom line.
fn line_count(code: String, lines: Lines) -> Int {
  let starts = list.length(lines.starts)
  case string.ends_with(code, "\n") {
    True -> starts
    False -> starts + 1
  }
}

/// What a backtick span in the section refers to, as far as this rule can
/// tell without types.
type Reference {
  /// A bare function name, which must be defined in this module.
  Local(name: String)

  /// `alias.name`, whose alias must be an import of this module.
  Qualified(alias: String, name: String)

  /// Anything else: a type, a constructor, a snippet, a path.
  Prose
}

/// What reading the section's lines produced: the spans worth resolving, the
/// words of a diagram, and the findings about fences, which are decided as
/// the lines go by.
type Scan {
  Scan(
    spans: List(#(Int, String)),
    words: List(Word),
    fences: List(Raw),
    inside: Fence,
  )
}

/// Whether the walk is inside a fenced block. A `text` fence is a diagram
/// whose words are read by shape; any other fence is refused and skipped.
type Fence {
  Outside
  Diagram
  Listing
}

/// One word of a diagram, located by the offset of its doc line.
type Word {
  Word(offset: Int, name: String, shape: Shape)
}

/// Whether a diagram word looks like a name or might be prose.
type Shape {
  /// An interior underscore or a call: prose has no such words, so it must
  /// resolve.
  NameShaped

  /// A plain word: counted when it resolves, never reported when it does not.
  Plain
}

fn check_section(module: glance.Module, section: Section) -> List(Raw) {
  let scan = read_lines(section.body, Scan([], [], [], Outside))
  let spans = list.reverse(scan.spans)
  let words = list.reverse(scan.words)
  let defined = defined_functions(module)
  let aliases = import_aliases(module)

  // A diagram may name a constant (a table of served names, say) as well as
  // a function; a backticked span may not, because the numbered list is
  // where a spine names the steps themselves.
  let nameable = set.union(defined, defined_constants(module))
  let unresolved = list.filter_map(spans, resolve(_, defined, aliases))
  let unnamed = list.filter_map(words, resolve_word(_, nameable))
  let named = named_functions(spans, words, defined)
  list.flatten([
    list.reverse(scan.fences),
    unresolved,
    unnamed,
    too_few(section.heading, named),
  ])
}

fn read_lines(lines: List(DocLine), scan: Scan) -> Scan {
  case lines, scan.inside {
    [], _ -> scan

    // A diagram line contributes its words until the closing fence.
    [line, ..rest], Diagram ->
      case is_fence(line) {
        True -> read_lines(rest, Scan(..scan, inside: Outside))
        False ->
          read_lines(rest, Scan(..scan, words: words_of(line, scan.words)))
      }

    [line, ..rest], Listing ->
      case is_fence(line) {
        True -> read_lines(rest, Scan(..scan, inside: Outside))
        False -> read_lines(rest, scan)
      }

    // An opening fence decides what the block is: a `text` diagram is read,
    // anything else is refused once, at its opening line.
    [line, ..rest], Outside ->
      case is_fence(line), opens_diagram(line) {
        True, True -> read_lines(rest, Scan(..scan, inside: Diagram))
        True, False ->
          read_lines(
            rest,
            Scan(..scan, fences: [fence(line), ..scan.fences], inside: Listing),
          )
        False, _ ->
          read_lines(rest, Scan(..scan, spans: spans_of(line, scan.spans)))
      }
  }
}

fn is_fence(line: DocLine) -> Bool {
  string.starts_with(string.trim(line.text), "```")
}

fn opens_diagram(line: DocLine) -> Bool {
  string.trim(line.text) == "```text"
}

/// The words of one diagram line, by the shape rules in the module doc.
///
/// A word is a maximal run of letters, digits and underscores. It is
/// dropped when it starts with a capital or a digit (a type, a constructor,
/// a number), when a `.` joins it to a neighbour (a qualified call), and
/// when it begins or ends with `_` or touches `<`, `>` or `*` (a pattern).
fn words_of(line: DocLine, found: List(Word)) -> List(Word) {
  let graphemes = string.to_graphemes(line.text)
  runs(graphemes, "", [], "", found, line.offset)
}

/// Walk the line keeping the grapheme before the current run, so a run can
/// be judged by both of its neighbours when it ends.
fn runs(
  rest: List(String),
  before: String,
  run: List(String),
  previous: String,
  found: List(Word),
  offset: Int,
) -> List(Word) {
  case rest {
    [] -> keep(run, before, "", "", found, offset)
    [grapheme, ..tail] ->
      case is_word_grapheme(grapheme) {
        True ->
          case run {
            [] -> runs(tail, previous, [grapheme], grapheme, found, offset)
            _ -> runs(tail, before, [grapheme, ..run], grapheme, found, offset)
          }
        False -> {
          let after = case tail {
            [next, ..] -> next
            [] -> ""
          }
          let found = keep(run, before, grapheme, after, found, offset)
          runs(tail, "", [], grapheme, found, offset)
        }
      }
  }
}

/// Decide one finished run. `next` is the grapheme that ended it and
/// `after` the one beyond, which is what tells `handle.` at the end of a
/// clause from `lsp.settle`.
fn keep(
  run: List(String),
  before: String,
  next: String,
  after: String,
  found: List(Word),
  offset: Int,
) -> List(Word) {
  let name = string.concat(list.reverse(run))
  let qualified =
    before == "." || { next == "." && is_word_grapheme(after) && after != "" }
  let pattern =
    string.starts_with(name, "_")
    || string.ends_with(name, "_")
    || list.contains(["<", ">", "*"], before)
    || list.contains(["<", ">", "*"], next)
  case name == "" || qualified || pattern || !starts_lowercase(name) {
    True -> found
    False -> {
      let shape = case string.contains(name, "_") || next == "(" {
        True -> NameShaped
        False -> Plain
      }
      [Word(offset:, name:, shape:), ..found]
    }
  }
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

fn starts_lowercase(name: String) -> Bool {
  case string.first(name) {
    Ok(first) ->
      first == "_" || string.lowercase(first) == first && !is_digit(first)
    Error(Nil) -> False
  }
}

fn is_digit(grapheme: String) -> Bool {
  string.contains("0123456789", grapheme)
}

/// One finding if a name-shaped diagram word names nothing the module
/// defines. A plain word that resolves to nothing is prose.
fn resolve_word(word: Word, nameable: Set(String)) -> Result(Raw, Nil) {
  case word.shape, set.contains(nameable, word.name) {
    NameShaped, False ->
      Ok(unresolved(
        word.offset,
        word.name,
        "is not a function or constant this module defines",
      ))
    NameShaped, True | Plain, _ -> Error(Nil)
  }
}

fn spans_of(
  line: DocLine,
  found: List(#(Int, String)),
) -> List(#(Int, String)) {
  line.text
  |> module_doc.code_spans
  |> list.fold(found, fn(found, span) { [#(line.offset, span), ..found] })
}

fn fence(line: DocLine) -> Raw {
  Raw(
    rule: finding.FlowSpine,
    offset: line.offset,
    function: "",
    detail: "a code listing inside the Flow section hides names from the"
      <> " check; draw the spine as a ```text diagram or a numbered list of"
      <> " backticked names",
  )
}

/// Every function this module defines, public or private. The spine's
/// readers navigate to a private helper as often as to an export, so both
/// resolve.
fn defined_functions(module: glance.Module) -> Set(String) {
  module.functions
  |> list.map(fn(definition) { { definition.definition }.name })
  |> set.from_list
}

/// Every constant this module defines, which a diagram may name.
fn defined_constants(module: glance.Module) -> Set(String) {
  module.constants
  |> list.map(fn(definition) { { definition.definition }.name })
  |> set.from_list
}

/// The qualifiers this module's imports bring into scope: the alias if
/// there is one, otherwise the last segment of the module path.
fn import_aliases(module: glance.Module) -> Set(String) {
  module.imports
  |> list.filter_map(fn(definition) {
    let import_ = definition.definition
    case import_.alias {
      Some(glance.Named(alias)) -> Ok(alias)
      Some(glance.Discarded(_)) -> Error(Nil)
      None -> Ok(last_segment(import_.module))
    }
  })
  |> set.from_list
}

fn last_segment(path: String) -> String {
  case list.last(string.split(path, "/")) {
    Ok(name) -> name
    Error(Nil) -> path
  }
}

/// One finding if the span is a reference that does not resolve.
fn resolve(
  span: #(Int, String),
  defined: Set(String),
  aliases: Set(String),
) -> Result(Raw, Nil) {
  case reference(span.1) {
    Prose -> Error(Nil)
    Local(name) ->
      case set.contains(defined, name) {
        True -> Error(Nil)
        False ->
          Ok(unresolved(span.0, name, "is not a function this module defines"))
      }
    Qualified(alias, name) ->
      case set.contains(aliases, alias) {
        True -> Error(Nil)
        False ->
          Ok(unresolved(
            span.0,
            alias <> "." <> name,
            "uses `" <> alias <> "`, which this module does not import",
          ))
      }
  }
}

fn unresolved(offset: Int, name: String, reason: String) -> Raw {
  Raw(
    rule: finding.FlowSpine,
    offset:,
    function: "",
    detail: "the Flow section names `" <> name <> "`, which " <> reason,
  )
}

/// The distinct local functions the section names. Counting distinct names
/// is what stops one function repeated three times from passing for a
/// spine.
fn named_functions(
  spans: List(#(Int, String)),
  words: List(Word),
  defined: Set(String),
) -> Int {
  let from_spans =
    list.filter_map(spans, fn(span) {
      case reference(span.1) {
        Local(name) -> Ok(name)
        Qualified(_, _) | Prose -> Error(Nil)
      }
    })
  let from_words = list.map(words, fn(word) { word.name })
  list.append(from_spans, from_words)
  |> list.filter(set.contains(defined, _))
  |> list.unique
  |> list.length
}

fn too_few(at: DocLine, named: Int) -> List(Raw) {
  case named >= minimum_functions {
    True -> []
    False -> [
      Raw(
        rule: finding.FlowSpine,
        offset: at.offset,
        function: "",
        detail: "the Flow section names "
          <> int_string(named)
          <> " of this module's functions; a spine lists at least "
          <> int_string(minimum_functions)
          <> " so it is a path through the module and not a remark",
      ),
    ]
  }
}

/// Classify one backtick span.
///
/// A call suffix is stripped first: `(...)` with anything inside, or `/N`
/// with digits, which is how Gleam and Erlang write an arity. What is left
/// must be an identifier, or two joined by one dot.
fn reference(span: String) -> Reference {
  case without_suffix(string.trim(span)) {
    Error(Nil) -> Prose
    Ok(core) ->
      case string.split(core, ".") {
        [name] ->
          case is_identifier(name) {
            True -> Local(name)
            False -> Prose
          }
        [alias, name] ->
          case is_identifier(alias) && is_identifier(name) {
            True -> Qualified(alias, name)
            False -> Prose
          }
        _ -> Prose
      }
  }
}

fn without_suffix(span: String) -> Result(String, Nil) {
  case string.split_once(span, "(") {
    Ok(#(before, rest)) ->
      case string.ends_with(rest, ")") {
        True -> Ok(before)
        False -> Error(Nil)
      }
    Error(Nil) ->
      case string.split_once(span, "/") {
        Ok(#(before, arity)) ->
          case is_digits(arity) {
            True -> Ok(before)
            False -> Error(Nil)
          }
        Error(Nil) -> Ok(span)
      }
  }
}

fn is_digits(text: String) -> Bool {
  text != ""
  && list.all(string.to_graphemes(text), fn(grapheme) {
    string.contains("0123456789", grapheme)
  })
}

/// `[a-z_][a-z0-9_]*`, the shape of a Gleam function name.
fn is_identifier(text: String) -> Bool {
  case string.to_graphemes(text) {
    [] -> False
    [first, ..rest] ->
      string.contains("abcdefghijklmnopqrstuvwxyz_", first)
      && list.all(rest, fn(grapheme) {
        string.contains("abcdefghijklmnopqrstuvwxyz0123456789_", grapheme)
      })
  }
}

fn int_string(value: Int) -> String {
  int.to_string(value)
}
