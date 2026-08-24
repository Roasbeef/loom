import gleam/list
import gleam/string
import gleeunit
import simplifile

import events/search

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

fn normalize(sql: String) -> String {
  sql
  |> string.split("\n")
  |> list.map(string.trim)
  |> list.filter(fn(line) { line != "" && !string.starts_with(line, "--") })
  |> string.join("\n")
}
