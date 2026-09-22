import cap/fs
import cap/notes
import cap/report
import cap/task
import gleam/list
import gleam/result

pub fn main() -> report.Outcome {
  case analyze() {
    Ok(value) -> report.value(value)
    Error(reason) -> report.failure(reason)
  }
}

fn analyze() -> Result(report.Value, String) {
  use counts <- result.try(
    task.parallel_map(
      ["input-a.json", "input-b.json"],
      max_concurrency: 2,
      with: read_count,
    )
    |> result.map_error(fn(_) { "an input could not be read or decoded" }),
  )
  let value =
    report.object([
      #("count", report.int(list.fold(counts, 0, fn(a, b) { a + b }))),
    ])
  use Nil <- result.try(
    notes.put("analysis", value)
    |> result.map_error(fn(_) { "note write failed" }),
  )
  use text <- result.try(report.encode_json(value))
  use Nil <- result.try(
    fs.write("analysis.json", text)
    |> result.map_error(fn(_) { "JSON export failed" }),
  )
  Ok(value)
}

fn read_count(path: String) -> Result(Int, String) {
  use text <- result.try(
    fs.read(path) |> result.map_error(fn(_) { "read failed" }),
  )
  use value <- result.try(report.decode_json(text))
  report.field(value, "count")
  |> result.try(report.as_int)
  |> result.map_error(fn(_) { "expected an integer count" })
}
