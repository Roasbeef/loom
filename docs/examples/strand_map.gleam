import cap/notes
import cap/report
import cap/strand
import gleam/list
import gleam/result

pub fn main() -> report.Outcome {
  case review() {
    Ok(value) -> report.value(value)
    Error(reason) -> report.failure(reason)
  }
}

fn review() -> Result(report.Value, String) {
  let assignments =
    list.map(["core", "client"], fn(name) {
      strand.assignment(
        purpose: "review " <> name,
        brief: "Inspect packages/"
          <> name
          <> "; report a structured integer count of findings.",
      )
      |> strand.expecting([strand.required("count", strand.IntegerField)])
    })
  use mapped <- result.try(
    strand.map(assignments, max_concurrency: 2, within_ms: 20_000)
    |> result.map_error(strand.error_text),
  )
  let value = report.list(list.map(mapped, entry))
  use Nil <- result.try(
    notes.put("reviews", value)
    |> result.map_error(fn(_) { "note write failed" }),
  )
  Ok(value)
}

fn entry(item: strand.Mapped) -> report.Value {
  case item {
    strand.Joined(strand.Ready(
      handle:,
      outcome: strand.Completed,
      result: strand.ResultGiven(value),
      ..,
    )) ->
      report.object([
        #("status", report.string("completed")),
        #("handle", report.string(strand.handle_text(handle))),
        #("value", value),
      ])
    strand.Joined(waited) ->
      report.object([
        #("status", report.string("needs_attention")),
        #("handle", report.string(strand.handle_text(waited.handle))),
        #("detail", report.string(strand.waited_text(waited))),
      ])
    strand.SpawnFailed(error) ->
      report.object([
        #("status", report.string("spawn_failed")),
        #("detail", report.string(strand.error_text(error))),
      ])
    strand.JoinFailed(handle, error) ->
      report.object([
        #("status", report.string("join_failed")),
        #("handle", report.string(strand.handle_text(handle))),
        #("detail", report.string(strand.error_text(error))),
      ])
    strand.NotStarted(_) ->
      report.object([#("status", report.string("not_started"))])
  }
}
