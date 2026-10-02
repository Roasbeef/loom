//// R14, transition tables in a module doc checked against the type they describe (issue #593, 6).
////
//// A state machine's behaviour is a table: for each state, what each event
//// does. Prose tables rot, because adding a constructor to the type costs
//// nothing at the table. This rule makes the table's *row set* a checked
//// fact. A module doc may carry a marker line naming the type it describes,
//// followed by a markdown table whose first column lists the type's
//// constructors; the rule fails when the rows and the constructors differ.
//// The other cells stay prose, since only the author can say whether a
//// transition is right. What the rule can say is that every state has a row.
////
//// The doc is read through `lint/module_doc`, as the module doc is invisible
//// to `glance`. The type is looked up in the parsed module, so a marker for
//// a type that was renamed, removed or never defined here fails too, as does
//// a marker naming another module, which would otherwise be checked against
//// the wrong file's constructors.
////
//// A marker with a problem the rest of the check depends on (wrong module,
//// unknown type, no table) reports that one finding and stops, because every
//// later complaint would be a consequence of it.

import glance
import gleam/int
import gleam/list
import gleam/set.{type Set}
import gleam/string
import lint/finding
import lint/module_doc.{type DocLine}
import lint/policy.{type Policy}
import lint/scan.{type Raw, Raw}
import lint/source.{type Lines}

/// The opening and closing of a marker line.
const marker_open: String = "<!-- transitions:"

const marker_close: String = "-->"

/// A marker line and everything the module doc says after it.
type Marker {
  Marker(line: DocLine, target: String, after: List(DocLine))
}

/// One body row of a table: where it is, and its cells with the outer pipes
/// and surrounding space removed.
type Row {
  Row(line: DocLine, cells: List(String))
}

/// Every finding this rule makes about one parsed module.
///
/// ## Examples
///
/// ```gleam
/// transitions.findings(module, code, lines, policy.default(), "tools/fs")
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
  let _ = #(lines, policy)
  code
  |> module_doc.lines
  |> markers
  |> list.flat_map(check_marker(module, own_path, _))
}

/// Find each marker and keep the lines after it. A marker is a line that is
/// the whole marker comment and nothing else, so a doc that merely mentions
/// the syntax in prose is not one.
fn markers(doc: List(DocLine)) -> List(Marker) {
  case doc {
    [] -> []
    [line, ..rest] ->
      case marker_target(line.text) {
        Ok(target) -> [Marker(line, target, rest), ..markers(rest)]
        Error(Nil) -> markers(rest)
      }
  }
}

fn marker_target(text: String) -> Result(String, Nil) {
  case
    string.starts_with(text, marker_open)
    && string.ends_with(text, marker_close)
  {
    False -> Error(Nil)
    True ->
      text
      |> string.drop_start(string.length(marker_open))
      |> string.drop_end(string.length(marker_close))
      |> string.trim
      |> Ok
  }
}

fn check_marker(
  module: glance.Module,
  own_path: String,
  marker: Marker,
) -> List(Raw) {
  case split_target(marker.target) {
    Error(Nil) -> [
      at_marker(
        marker,
        "the marker names `" <> marker.target <> "`; it must name `module.Type`",
      ),
    ]
    Ok(#(named_module, type_name)) ->
      case names_this_module(named_module, own_path) {
        False -> [
          at_marker(
            marker,
            "the marker names module `"
              <> named_module
              <> "`, but this module is `"
              <> own_path
              <> "`; a table is checked against the type in its own module",
          ),
        ]
        True -> check_type(module, marker, type_name)
      }
  }
}

/// `module.Type`, split at the last dot so a full module path such as
/// `session_view/session_channel` keeps its slash and has no dot to confuse.
fn split_target(target: String) -> Result(#(String, String), Nil) {
  case list.reverse(string.split(target, ".")) {
    [type_name, ..reversed] if reversed != [] && type_name != "" ->
      Ok(#(string.join(list.reverse(reversed), "."), type_name))
    _ -> Error(Nil)
  }
}

/// The marker may spell the module as its full path or as its last segment.
fn names_this_module(named: String, own_path: String) -> Bool {
  named == own_path || named == last_segment(own_path)
}

fn last_segment(path: String) -> String {
  case list.last(string.split(path, "/")) {
    Ok(name) -> name
    Error(Nil) -> path
  }
}

fn check_type(
  module: glance.Module,
  marker: Marker,
  type_name: String,
) -> List(Raw) {
  let matching =
    list.find(module.custom_types, fn(definition) {
      { definition.definition }.name == type_name
    })
  case matching {
    Error(Nil) -> [
      at_marker(
        marker,
        "`" <> type_name <> "` is not a custom type defined in this module",
      ),
    ]
    Ok(definition) -> {
      let variants =
        list.map(definition.definition.variants, fn(variant) { variant.name })
      case table(marker.after) {
        Error(Nil) -> [
          at_marker(
            marker,
            "no markdown table follows the marker; expected a header row, a"
              <> " separator row and one row per constructor of `"
              <> type_name
              <> "`",
          ),
        ]
        Ok(#(header, rows)) -> check_rows(marker, variants, header, rows)
      }
    }
  }
}

/// The table after a marker: its header cells and its body rows.
///
/// The table is the first run of lines that start with a pipe once blank doc
/// lines are skipped. Its second line must be a separator (`| --- | --- |`),
/// which is what tells a table from a stray line that begins with a pipe.
fn table(after: List(DocLine)) -> Result(#(List(String), List(Row)), Nil) {
  let run =
    after
    |> list.drop_while(fn(line) { line.text == "" })
    |> list.take_while(fn(line) { string.starts_with(line.text, "|") })
  case run {
    [header, separator, ..body] ->
      case is_separator(cells(separator)) {
        True ->
          Ok(#(
            cells(header),
            list.map(body, fn(line) { Row(line, cells(line)) }),
          ))
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// A line's cells, trimmed, without the outer pipes. A line that omits its
/// closing pipe still has the cells it shows.
fn cells(line: DocLine) -> List(String) {
  let inner = string.drop_start(line.text, 1)
  let inner = case string.ends_with(inner, "|") {
    True -> string.drop_end(inner, 1)
    False -> inner
  }
  inner |> string.split("|") |> list.map(string.trim)
}

/// A separator row: every cell is dashes with optional alignment colons.
fn is_separator(cells: List(String)) -> Bool {
  cells != []
  && list.all(cells, fn(cell) {
    string.contains(cell, "-")
    && list.all(string.to_graphemes(cell), fn(grapheme) {
      grapheme == "-" || grapheme == ":"
    })
  })
}

fn check_rows(
  marker: Marker,
  variants: List(String),
  header: List(String),
  rows: List(Row),
) -> List(Raw) {
  let shape = list.filter_map(rows, malformed(_, header))
  let #(names, found) = by_name(rows, set.from_list(variants))
  let missing =
    variants
    |> list.filter(fn(variant) { !set.contains(names, variant) })
    |> list.map(fn(variant) {
      at_marker(
        marker,
        "the table has no row for `"
          <> variant
          <> "`; every constructor needs a state row",
      )
    })
  list.flatten([shape, found, missing])
}

/// A row with the wrong number of cells or an empty one. An empty cell is
/// refused because a blank is how a transition gets forgotten; `n/a` or
/// `refused` says it was considered.
fn malformed(row: Row, header: List(String)) -> Result(Raw, Nil) {
  case
    list.length(row.cells) == list.length(header),
    list.contains(row.cells, "")
  {
    True, False -> Error(Nil)
    False, _ ->
      Ok(at_row(
        row,
        "the row has "
          <> int.to_string(list.length(row.cells))
          <> " cells but the header has "
          <> int.to_string(list.length(header)),
      ))
    True, True ->
      Ok(at_row(
        row,
        "the row has an empty cell; write what happens, even if it is"
          <> " `refused`",
      ))
  }
}

/// Walk the rows once, naming the ones that repeat a state or name no
/// constructor, and return every row name seen so the caller can say which
/// constructors never appeared.
fn by_name(
  rows: List(Row),
  variants: Set(String),
) -> #(Set(String), List(Raw)) {
  let #(seen, reversed) =
    list.fold(rows, #(set.new(), []), fn(state, row) {
      let name = row_name(row)
      case set.contains(state.0, name), set.contains(variants, name) {
        True, _ -> #(state.0, [duplicate(row, name), ..state.1])
        False, False -> #(set.insert(state.0, name), [
          extra(row, name),
          ..state.1
        ])
        False, True -> #(set.insert(state.0, name), state.1)
      }
    })
  #(seen, list.reverse(reversed))
}

/// The state a row is about: its first cell without backticks or space.
fn row_name(row: Row) -> String {
  case row.cells {
    [first, ..] -> first |> string.replace("`", "") |> string.trim
    [] -> ""
  }
}

fn duplicate(row: Row, name: String) -> Raw {
  at_row(row, "`" <> name <> "` has more than one row; a state is listed once")
}

fn extra(row: Row, name: String) -> Raw {
  at_row(
    row,
    "`" <> name <> "` is not a constructor of the type the marker names",
  )
}

fn at_marker(marker: Marker, detail: String) -> Raw {
  Raw(
    rule: finding.TransitionTable,
    offset: marker.line.offset,
    function: "",
    detail:,
  )
}

fn at_row(row: Row, detail: String) -> Raw {
  Raw(
    rule: finding.TransitionTable,
    offset: row.line.offset,
    function: "",
    detail:,
  )
}
