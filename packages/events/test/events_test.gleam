import gleam/bool
import gleam/int
import gleam/list
import gleam/string
import gleeunit
import simplifile

import events/search
import events/sql

pub fn main() -> Nil {
  gleeunit.main()
}

/// The DDL embedded in `events/search` must stay byte-identical to
/// `sql/schema.sql`, which is what `scripts/gen-sql.sh` loads into the
/// throwaway codegen database. Compared with comments and blank lines
/// stripped, so prose can evolve without touching the contract.
pub fn schema_matches_source_test() {
  let assert Ok(file) = simplifile.read("sql/schema.sql")
    as "sql/schema.sql must exist next to the package"
  let from_file = normalize(file)
  let from_code = normalize(string.join(search.schema(), "\n"))
  assert from_file == from_code
}

/// The named queries in `src/events/sql/search.sql` must stay in step with
/// the SQL `events/sql` actually issues. The generated module is committed
/// and `scripts/gen-sql.sh` needs `sqlite3` (and a network fetch for
/// `sqlc`), so on a host without them the module can be hand-mirrored —
/// and drift silently — with nothing to catch it. This is the catcher:
/// every `-- name:` block in the source file, and every query the module
/// exposes, compared statement for statement under the same normalization
/// the schema pin uses. `make gen-sql` on a sqlite3-equipped host remains
/// the byte-identity check; this is the property that survives without one.
pub fn queries_match_source_test() {
  let assert Ok(file) = simplifile.read("src/events/sql/search.sql")
    as "src/events/sql/search.sql must exist next to the package"
  assert named_blocks(file) == generated_queries()
}

// The SQL text of every query `events/sql` exposes, under the query names
// the source file gives them. Adding a query without regenerating — or
// regenerating without adding it here — fails the comparison.
fn generated_queries() -> List(#(String, String)) {
  let #(insert_entry_text, _) =
    sql.insert_entry_text(
      session_id: "",
      entry_id: "",
      kind: "",
      ts: 0,
      text: "",
    )
  let #(delete_session_index, _) = sql.delete_session_index(session_id: "")
  let #(search_entries, _, _) =
    sql.search_entries(query: "", kind: "", before: "", max_hits: 0)
  let #(search_entries_in_session, _, _) =
    sql.search_entries_in_session(
      query: "",
      session: "",
      kind: "",
      before: "",
      max_hits: 0,
    )
  let #(recent_entries_in_session, _, _) =
    sql.recent_entries_in_session(session_id: "", limit: 0)
  let #(get_cursor, _, _) = sql.get_cursor(session_id: "")
  let #(search_authorized_entries, _, _) =
    sql.search_authorized_entries(
      query: "",
      sessions: "",
      kind: "",
      before: "",
      max_hits: 0,
    )
  let #(set_cursor, _) =
    sql.set_cursor(session_id: "", generation: 0, high_water: 0)
  let #(delete_cursor, _) = sql.delete_cursor(session_id: "")
  let #(register_source, _) = sql.register_source(session_id: "", path: "")
  let #(get_source, _, _) = sql.get_source(session_id: "")
  let #(delete_source, _) = sql.delete_source(session_id: "")
  [
    #("InsertEntryText", insert_entry_text),
    #("DeleteSessionIndex", delete_session_index),
    #("SearchEntries", search_entries),
    #("SearchEntriesInSession", search_entries_in_session),
    #("RecentEntriesInSession", recent_entries_in_session),
    #("GetCursor", get_cursor),
    #("SearchAuthorizedEntries", search_authorized_entries),
    #("SetCursor", set_cursor),
    #("DeleteCursor", delete_cursor),
    #("RegisterSource", register_source),
    #("GetSource", get_source),
    #("DeleteSource", delete_source),
  ]
  |> list.map(fn(query) { #(query.0, normalize_query(query.1)) })
}

const query_header = "-- name: "

// The query file split at its `-- name:` headers, in file order. The
// banner above the first header belongs to no query and is dropped.
fn named_blocks(source: String) -> List(#(String, String)) {
  source
  |> string.split("\n")
  |> list.fold(from: [], with: collect_line)
  |> list.map(fn(block) {
    #(block.0, normalize_query(string.join(list.reverse(block.1), "\n")))
  })
  |> list.reverse
}

fn collect_line(
  blocks: List(#(String, List(String))),
  line: String,
) -> List(#(String, List(String))) {
  case query_name(line) {
    Ok(name) -> [#(name, []), ..blocks]
    Error(Nil) -> extend_open_block(blocks, line)
  }
}

fn extend_open_block(
  blocks: List(#(String, List(String))),
  line: String,
) -> List(#(String, List(String))) {
  case blocks {
    [] -> []
    [#(name, lines), ..rest] -> [#(name, [line, ..lines]), ..rest]
  }
}

// `-- name: SearchEntries :many` names `SearchEntries`; any other line
// names nothing.
fn query_name(line: String) -> Result(String, Nil) {
  let trimmed = string.trim(line)
  use <- bool.guard(
    when: !string.starts_with(trimmed, query_header),
    return: Error(Nil),
  )
  trimmed
  |> string.drop_start(string.length(query_header))
  |> string.split(on: " ")
  |> list.first
}

// The generated strings carry no statement terminator; the source file's
// statements do. SQLC assigns each named parameter a positional binding in
// first-use order, reusing it for a repeated name. Preserve the positions so
// swapping bindings still fails.
fn normalize_query(sql: String) -> String {
  let normalized = sql |> normalize |> number_named_parameters
  case string.ends_with(normalized, ";") {
    True -> string.drop_end(normalized, 1)
    False -> normalized
  }
}

fn number_named_parameters(sql: String) -> String {
  case string.split(sql, "@") {
    [] -> sql
    [first, ..segments] -> {
      let #(_names, pieces) =
        list.fold(segments, #([], [first]), fn(state, segment) {
          let #(names, pieces) = state
          let name = leading_name(segment)
          let names = case list.contains(names, name) {
            True -> names
            False -> list.append(names, [name])
          }
          let rest = string.drop_start(segment, string.length(name))
          let position = int.to_string(position_of(names, name))
          #(names, [rest, "?" <> position, ..pieces])
        })
      pieces |> list.reverse |> string.concat
    }
  }
}

fn leading_name(segment: String) -> String {
  segment
  |> string.to_graphemes
  |> list.take_while(fn(char) { char == "_" || is_name_char(char) })
  |> string.concat
}

fn is_name_char(char: String) -> Bool {
  string.contains("abcdefghijklmnopqrstuvwxyz0123456789", char)
}

// One-based position of `name` in the first-use list.
fn position_of(names: List(String), name: String) -> Int {
  list.index_fold(names, 0, fn(found, candidate, index) {
    case candidate == name {
      True -> index + 1
      False -> found
    }
  })
}

fn normalize(sql: String) -> String {
  sql
  |> string.split("\n")
  |> list.map(string.trim)
  |> list.filter(fn(line) { line != "" && !string.starts_with(line, "--") })
  |> string.join("\n")
}
