import cap/fs
import cap/notes
import cap/report
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result

pub fn main() -> report.Outcome {
  case analyze() {
    Ok(Nil) ->
      report.text("Saved analysis; later calls can read main/analysis.")
    Error(reason) -> report.failure(reason)
  }
}

fn analyze() -> Result(Nil, String) {
  use raw <- result.try(
    fs.read("input.json") |> result.map_error(fn(_) { "read failed" }),
  )
  use rows <- result.try(
    json.parse(raw, decode.list(decode.int))
    |> result.map_error(fn(_) { "invalid input" }),
  )
  let value =
    report.object([
      #("sum", report.int(list.fold(rows, 0, fn(total, n) { total + n }))),
      #("rows", report.list(list.map(rows, report.int))),
    ])
  notes.put("analysis", value)
  |> result.map_error(fn(_) { "note write failed" })
}
