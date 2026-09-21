import cap/fs
import cap/notes
import cap/report
import gleam/dynamic/decode
import gleam/json
import gleam/option.{Some}
import gleam/result

pub fn main() -> report.Outcome {
  case reuse() {
    Ok(value) -> report.value(value)
    Error(reason) -> report.failure(reason)
  }
}

fn reuse() -> Result(report.Value, String) {
  use found <- result.try(
    notes.get("main/analysis") |> result.map_error(fn(_) { "note read failed" }),
  )
  use value <- result.try(case found {
    Some(value) -> Ok(value)
    _ -> Error("analysis missing")
  })
  use sum <- result.try(
    report.field(value, "sum")
    |> result.try(report.as_int)
    |> result.map_error(fn(_) { "invalid sum" }),
  )

  // The JSON view is usable by ordinary decoding code in a fresh execution.
  use raw <- result.try(
    fs.read("note://main/analysis")
    |> result.map_error(fn(_) { "virtual read failed" }),
  )
  use projected <- result.try(
    json.parse(raw, decode.at(["sum"], decode.int))
    |> result.map_error(fn(_) { "invalid JSON view" }),
  )
  case projected == sum {
    True ->
      Ok(
        report.object([
          #("saved_sum", report.int(sum)),
          #("next_sum", report.int(sum + 1)),
        ]),
      )
    False -> Error("note views disagree")
  }
}
