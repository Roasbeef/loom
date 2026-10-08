import cap/proc
import cap/report
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string

pub fn main() -> report.Outcome {
  let log = proc.stdout(proc.command(["git", "log", "-3", "--format=%h %s"]))
  report.text("log:\n" <> show(log) <> "\n\nfix PRs:\n" <> show(fix_prs()))
}

fn fix_prs() -> Result(String, String) {
  let pull = {
    use number <- decode.field("number", decode.int)
    use title <- decode.field("title", decode.string)
    decode.success(#(number, title))
  }
  use body <- result.try(
    proc.stdout(proc.command(["gh", "pr", "list", "--json", "number,title"])),
  )
  use pulls <- result.try(
    json.parse(body, decode.list(pull))
    |> result.map_error(fn(_) { "unexpected gh JSON" }),
  )
  pulls
  |> list.filter(fn(pull) { string.contains(pull.1, "fix") })
  |> list.map(fn(pull) { "#" <> int.to_string(pull.0) <> " " <> pull.1 })
  |> string.join("\n")
  |> Ok
}

fn show(probe: Result(String, String)) -> String {
  case probe {
    Ok(output) -> output
    Error(reason) -> "ERROR " <> reason
  }
}
