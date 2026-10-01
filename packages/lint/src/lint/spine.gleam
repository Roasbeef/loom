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
//// Fenced blocks are refused inside the section because a fence is exactly
//// where a stale name would hide from the span check, and a spine is meant
//// to be a short numbered list, not a code listing.

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

/// What reading the section's lines produced: the spans worth resolving, and
/// the findings about fences, which are decided as the lines go by.
type Scan {
  Scan(spans: List(#(Int, String)), fences: List(Raw), inside: Fence)
}

/// Whether the walk is inside a fenced block, whose contents are neither
/// spine nor checked.
type Fence {
  Outside
  Inside
}

fn check_section(module: glance.Module, section: Section) -> List(Raw) {
  let scan = read_lines(section.body, Scan([], [], Outside))
  let spans = list.reverse(scan.spans)
  let defined = defined_functions(module)
  let aliases = import_aliases(module)
  let unresolved = list.filter_map(spans, resolve(_, defined, aliases))
  let named = named_functions(spans, defined)
  list.flatten([
    list.reverse(scan.fences),
    unresolved,
    too_few(section.heading, named),
  ])
}

fn read_lines(lines: List(DocLine), scan: Scan) -> Scan {
  case lines, scan.inside {
    [], _ -> scan
    [line, ..rest], Inside ->
      read_lines(rest, Scan(..scan, inside: closes(line, scan.inside)))
    [line, ..rest], Outside ->
      case string.starts_with(string.trim(line.text), "```") {
        True ->
          read_lines(
            rest,
            Scan(..scan, fences: [fence(line), ..scan.fences], inside: Inside),
          )
        False ->
          read_lines(rest, Scan(..scan, spans: spans_of(line, scan.spans)))
      }
  }
}

/// A fence closes on the next fence line; anything else leaves the walk
/// inside the block.
fn closes(line: DocLine, inside: Fence) -> Fence {
  case string.starts_with(string.trim(line.text), "```") {
    True -> Outside
    False -> inside
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
    detail: "a fenced code block inside the Flow section hides names from the"
      <> " check; write the spine as a numbered list of backticked names",
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
fn named_functions(spans: List(#(Int, String)), defined: Set(String)) -> Int {
  spans
  |> list.filter_map(fn(span) {
    case reference(span.1) {
      Local(name) ->
        case set.contains(defined, name) {
          True -> Ok(name)
          False -> Error(Nil)
        }
      Qualified(_, _) | Prose -> Error(Nil)
    }
  })
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
