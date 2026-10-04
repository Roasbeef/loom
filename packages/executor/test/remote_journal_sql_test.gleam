import executor/custody_schema
import executor/sql
import gleam/list
import gleam/string
import simplifile

pub fn embedded_schema_matches_the_sqlc_schema_test() {
  let assert Ok(source) = simplifile.read("sql/schema.sql")
    as "executor schema source is checked in"
  assert custody_schema.schema == source
}

pub fn generated_queries_match_named_sql_sources_test() {
  let assert Ok(source) = simplifile.read("src/executor/sql/custody.sql")
    as "executor named queries are checked in"
  let generated = [
    sql.initialize_custody(<<>>, 1).0,
    sql.custody_metadata().0,
    sql.custody_events(8).0,
    sql.append_custody_event(1, <<>>).0,
    sql.advance_custody_head(1, 1, 0, 0).0,
  ]
  assert normalize(source) == normalize(string.join(generated, "\n"))
}

// sqlc numbers named parameters and removes comments and terminators. Compare
// the remaining SQL so changing a source without regeneration fails the gate.
fn normalize(source: String) -> String {
  source
  |> string.replace("@next_version", "?1")
  |> string.replace("@next_bytes", "?2")
  |> string.replace("@previous_version", "?3")
  |> string.replace("@previous_bytes", "?4")
  |> string.split("\n")
  |> list.filter(fn(line) { !string.starts_with(string.trim(line), "--") })
  |> string.join(" ")
  |> string.replace(";", "")
  |> string.split(" ")
  |> list.filter(fn(part) { part != "" })
  |> string.join(" ")
}
