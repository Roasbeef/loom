//// Decode review records and return only the approved IDs as JSON.
//// File contents from cap/fs.read or command output can replace the sample
//// input. The pinned gleam_json API uses json.parse with a typed decoder.

import cap/report
import gleam/dynamic/decode
import gleam/json
import gleam/list

/// Parses the input with a record decoder before filtering or encoding it.
///
/// ## Examples
///
/// ```gleam
/// main()
/// // -> A text report containing {"approved":[7]}.
/// ```
pub fn main() -> report.Outcome {
  let review = {
    use id <- decode.field("id", decode.int)
    use state <- decode.field("state", decode.string)
    decode.success(#(id, state))
  }
  let raw =
    "[{\"id\":7,\"state\":\"APPROVED\"},{\"id\":9,\"state\":\"COMMENTED\"}]"

  // Malformed input becomes a report failure rather than a partial value.
  case json.parse(raw, decode.list(review)) {
    Error(_error) -> report.failure("Expected review objects with id and state")
    Ok(reviews) -> {
      let approved = list.filter(reviews, fn(review) { review.1 == "APPROVED" })
      json.object([
        #("approved", json.array(approved, fn(review) { json.int(review.0) })),
      ])
      |> json.to_string
      |> report.text
    }
  }
}
