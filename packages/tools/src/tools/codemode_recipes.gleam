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
