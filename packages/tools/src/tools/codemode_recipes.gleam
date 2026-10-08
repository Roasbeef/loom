//// Executable recipes included in the model-facing code-mode description.
//// Client live tests execute these exact strings and compare them with the
//// documented source files, so advertised examples cannot silently drift.

/// A complete workspace program, exercised through the real jailed pipeline.
///
/// ## Examples
///
/// ```gleam
/// // Submit workspace() as code_mode's program with seam: "workspace".
/// ```
pub fn workspace() -> String {
  "import cap/fs\nimport cap/notes\nimport cap/report\nimport cap/task\nimport gleam/list\nimport gleam/result\n\npub fn main() -> report.Outcome {\n  case analyze() {\n    Ok(value) -> report.value(value)\n    Error(reason) -> report.failure(reason)\n  }\n}\n\nfn analyze() -> Result(report.Value, String) {\n  use counts <- result.try(\n    task.parallel_map(\n      [\"input-a.json\", \"input-b.json\"],\n      max_concurrency: 2,\n      with: read_count,\n    )\n    |> result.map_error(fn(_) { \"an input could not be read or decoded\" }),\n  )\n  let value =\n    report.object([\n      #(\"count\", report.int(list.fold(counts, 0, fn(a, b) { a + b }))),\n    ])\n  use Nil <- result.try(\n    notes.put(\"analysis\", value)\n    |> result.map_error(fn(_) { \"note write failed\" }),\n  )\n  use text <- result.try(report.encode_json(value))\n  use Nil <- result.try(\n    fs.write(\"analysis.json\", text)\n    |> result.map_error(fn(_) { \"JSON export failed\" }),\n  )\n  Ok(value)\n}\n\nfn read_count(path: String) -> Result(Int, String) {\n  use text <- result.try(\n    fs.read(path) |> result.map_error(fn(_) { \"read failed\" }),\n  )\n  use value <- result.try(report.decode_json(text))\n  report.field(value, \"count\")\n  |> result.try(report.as_int)\n  |> result.map_error(fn(_) { \"expected an integer count\" })\n}\n"
}

/// A complete orchestration program, exercised through the real jailed pipeline.
///
/// ## Examples
///
/// ```gleam
/// // Submit orchestration() as code_mode's program with seam: "orchestration".
/// ```
pub fn orchestration() -> String {
  "import cap/notes\nimport cap/report\nimport cap/strand\nimport gleam/list\nimport gleam/result\n\npub fn main() -> report.Outcome {\n  case review() {\n    Ok(value) -> report.value(value)\n    Error(reason) -> report.failure(reason)\n  }\n}\n\nfn review() -> Result(report.Value, String) {\n  let assignments =\n    list.map([\"core\", \"client\"], fn(name) {\n      strand.assignment(\n        purpose: \"review \" <> name,\n        brief: \"Inspect packages/\"\n          <> name\n          <> \"; report a structured integer count of findings.\",\n      )\n      |> strand.expecting([strand.required(\"count\", strand.IntegerField)])\n    })\n  use mapped <- result.try(\n    strand.map(assignments, max_concurrency: 2, within_ms: 20_000)\n    |> result.map_error(strand.error_text),\n  )\n  let value = report.list(list.map(mapped, entry))\n  use Nil <- result.try(\n    notes.put(\"reviews\", value)\n    |> result.map_error(fn(_) { \"note write failed\" }),\n  )\n  Ok(value)\n}\n\nfn entry(item: strand.Mapped) -> report.Value {\n  case item {\n    strand.Joined(strand.Ready(\n      handle:,\n      outcome: strand.Completed,\n      result: strand.ResultGiven(value),\n      ..,\n    )) ->\n      report.object([\n        #(\"status\", report.string(\"completed\")),\n        #(\"handle\", report.string(strand.handle_text(handle))),\n        #(\"value\", value),\n      ])\n    strand.Joined(waited) ->\n      report.object([\n        #(\"status\", report.string(\"needs_attention\")),\n        #(\"handle\", report.string(strand.handle_text(waited.handle))),\n        #(\"detail\", report.string(strand.waited_text(waited))),\n      ])\n    strand.SpawnFailed(error) ->\n      report.object([\n        #(\"status\", report.string(\"spawn_failed\")),\n        #(\"detail\", report.string(strand.error_text(error))),\n      ])\n    strand.JoinFailed(handle, error) ->\n      report.object([\n        #(\"status\", report.string(\"join_failed\")),\n        #(\"handle\", report.string(strand.handle_text(handle))),\n        #(\"detail\", report.string(strand.error_text(error))),\n      ])\n    strand.NotStarted(_) ->\n      report.object([#(\"status\", report.string(\"not_started\"))])\n  }\n}\n"
}

/// A complete `cap/lsp_sql` program that shows the shapes models get wrong:
/// every branch of the top-level `case` returns a `report.Outcome`
/// (`report.failure`, or `report.value` around a `report.string`), `None` and
/// `Some` are imported only because both are used, rows are joined with
/// `string.join`, and errors are rendered with the modules' own `error_text`
/// functions. The codemode end-to-end test compiles this exact string.
///
/// ## Examples
///
/// ```gleam
/// // Submit lsp_sql_skeleton() as code_mode's program with seam: "workspace".
/// ```
pub fn lsp_sql_skeleton() -> String {
  "import cap/lsp_sql\nimport cap/report\nimport gleam/option.{None, Some}\nimport gleam/string\n\npub fn main() -> report.Outcome {\n  let file = \"auth/multi_authenticator.go\"\n  let plan =\n    lsp_sql.Plan(\"gopls\", \".\", [file], [\n      lsp_sql.Target(\"MultiAuthenticator.AcceptForScheme\", file, None),\n      lsp_sql.Target(\"AcceptForScheme\", file, Some(69)),\n    ])\n  case lsp_sql.collect(plan) {\n    Error(error) -> report.failure(lsp_sql.error_text(error))\n    Ok(observation) ->\n      case\n        lsp_sql.query(\n          observation,\n          \"SELECT t.symbol, count(r.target_id) FROM targets t \"\n            <> \"LEFT JOIN \\\"references\\\" r ON r.target_id = t.id GROUP BY t.id\",\n          [],\n          fn(row) {\n            case row {\n              [symbol, count] ->\n                Ok(lsp_sql.cell_text(symbol) <> \": \" <> lsp_sql.cell_text(count))\n              _ -> Error(\"expected two columns\")\n            }\n          },\n        )\n      {\n        Error(error) -> report.failure(lsp_sql.query_error_text(error))\n        Ok(answer) ->\n          report.value(report.string(string.join(answer.rows, \"\\n\")))\n      }\n  }\n}\n"
}

/// A complete shell-probe program: independent `proc.stdout` probes whose
/// failures stay local to their own section, and one `gh --json` call decoded
/// into typed rows with `json.parse` and filtered in the program. The same
/// source is `docs/examples/shell_probes.gleam`, and the client live test
/// compiles and runs this exact string.
///
/// ## Examples
///
/// ```gleam
/// // Submit shell_probes() as code_mode's program with seam: "workspace".
/// ```
pub fn shell_probes() -> String {
  "import cap/proc\nimport cap/report\nimport gleam/dynamic/decode\nimport gleam/int\nimport gleam/json\nimport gleam/list\nimport gleam/result\nimport gleam/string\n\npub fn main() -> report.Outcome {\n  let log = proc.stdout(proc.command([\"git\", \"log\", \"-3\", \"--format=%h %s\"]))\n  report.text(\"log:\\n\" <> show(log) <> \"\\n\\nfix PRs:\\n\" <> show(fix_prs()))\n}\n\nfn fix_prs() -> Result(String, String) {\n  let pull = {\n    use number <- decode.field(\"number\", decode.int)\n    use title <- decode.field(\"title\", decode.string)\n    decode.success(#(number, title))\n  }\n  use body <- result.try(\n    proc.stdout(proc.command([\"gh\", \"pr\", \"list\", \"--json\", \"number,title\"])),\n  )\n  use pulls <- result.try(\n    json.parse(body, decode.list(pull))\n    |> result.map_error(fn(_) { \"unexpected gh JSON\" }),\n  )\n  pulls\n  |> list.filter(fn(pull) { string.contains(pull.1, \"fix\") })\n  |> list.map(fn(pull) { \"#\" <> int.to_string(pull.0) <> \" \" <> pull.1 })\n  |> string.join(\"\\n\")\n  |> Ok\n}\n\nfn show(probe: Result(String, String)) -> String {\n  case probe {\n    Ok(output) -> output\n    Error(reason) -> \"ERROR \" <> reason\n  }\n}\n"
}
