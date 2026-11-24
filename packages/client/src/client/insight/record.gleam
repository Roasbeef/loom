//// What one triage request and its answer leave behind, so the run can be
//// replayed with no spend (`docs/design-notes/insight-triage.md`, section
//// 8.3, the last sentence).
////
//// A record holds the prompt that was sent, the text the model answered with
//// and the rows the prompt numbered, which is everything `verdict` needs to
//// score a session and everything a replay needs to check that the harness
//// would send the same request again. It names the role and the model the
//// owner's catalogue routed it to, and never a key: the secret store is read
//// at dispatch and a record is written from what dispatch returned.

import gleam/dynamic/decode
import gleam/json
import gleam/result

/// One session's request and the answer it got.
pub type Record {
  Record(
    /// The session the request was built from.
    session: String,
    /// The role the request was routed by.
    role: String,
    /// The catalogue entry and model identifier the role resolved to.
    model: String,
    /// The prompt that was sent.
    prompt: String,
    /// The text the model answered with.
    answer: String,
    /// The classifier's keys for the rows the prompt numbered, in its order.
    rows: List(String),
  )
}

/// A record as the file written to disk.
///
/// ## Examples
///
/// ```gleam
/// let record = record.Record("s", "summarize", "m", "p", "a", ["k"])
/// assert record.decode(record.encode(record)) == Ok(record)
/// ```
pub fn encode(record: Record) -> String {
  json.object([
    #("session", json.string(record.session)),
    #("role", json.string(record.role)),
    #("model", json.string(record.model)),
    #("prompt", json.string(record.prompt)),
    #("answer", json.string(record.answer)),
    #("rows", json.array(record.rows, json.string)),
  ])
  |> json.to_string
}

/// The record in a file, or why it could not be read.
///
/// ## Examples
///
/// ```gleam
/// assert record.decode("{}") == Error("the record file is not a triage record")
/// ```
pub fn decode(text: String) -> Result(Record, String) {
  let reader = {
    use session <- decode.field("session", decode.string)
    use role <- decode.field("role", decode.string)
    use model <- decode.field("model", decode.string)
    use prompt <- decode.field("prompt", decode.string)
    use answer <- decode.field("answer", decode.string)
    use rows <- decode.field("rows", decode.list(decode.string))
    decode.success(Record(session:, role:, model:, prompt:, answer:, rows:))
  }

  json.parse(text, reader)
  |> result.replace_error("the record file is not a triage record")
}
