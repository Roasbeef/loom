//// Reading the call record back: the golden shape the `tools` encoder
//// writes, the results that carry none, and every way a record can be
//// malformed.
////
//// The decoder is total by contract, so most of what is pinned here is
//// what it declines to do: it never raises, and anything it cannot trust
//// reads as no record rather than as an error a transcript must show.

import core/json.{type JsonValue}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import qcheck
import session_view/call_tree.{CallLog}

// The same literal `tools/call_record_test` asserts the encoder writes, so
// the two packages cannot drift apart without one test failing.
const golden =
  "{\"started_unix_ms\":1790000000000,\"elapsed_ms\":1840,\"total\":2,\"failed\":1,\"cancelled\":0,\"unsettled\":0,\"items\":[{\"cap\":\"fs.read\",\"args\":\"src/app.gleam\",\"status\":\"ok\",\"start_ms\":12,\"duration_ms\":3},{\"cap\":\"proc.run\",\"args\":\"gleam +2 args\",\"status\":\"failed\",\"error\":\"exec_failed\",\"start_ms\":20,\"duration_ms\":1511}]}"

fn details_with(calls: String) -> JsonValue {
  let assert Ok(details) =
    json.parse("{\"status\":\"completed\",\"calls\":" <> calls <> "}")
    as "the fixture is well-formed JSON"
  details
}

pub fn the_golden_record_decodes_test() {
  let assert Some(log) = call_tree.read(details_with(golden))
  assert log.started_unix_ms == 1_790_000_000_000
  assert log.elapsed_ms == 1840
  assert log.total == 2
  assert log.failed == 1
  let assert [first, second] = log.items
  assert first
    == call_tree.Call(
      cap: "fs.read",
      args: Some("src/app.gleam"),
      status: call_tree.Settled,
      error: None,
      start_ms: 12,
      duration_ms: 3,
    )
  assert second.status == call_tree.Failed
  assert second.error == Some("exec_failed")
}

pub fn the_summary_names_the_calls_and_the_failures_test() {
  let assert Some(log) = call_tree.read(details_with(golden))
  assert call_tree.summary(log) == "2 calls · 1 failed"
  assert call_tree.summary(CallLog(..log, total: 1, failed: 0))
    == "1 call · 0 failed"
  assert call_tree.summary(CallLog(..log, cancelled: 2, unsettled: 1))
    == "2 calls · 1 failed · 2 cancelled · 1 unsettled"
}

pub fn an_old_result_has_no_record_test() {
  let assert Ok(old) =
    json.parse("{\"status\":\"completed\",\"value\":1,\"sandbox\":{}}")
  assert call_tree.read(old) == None
  assert call_tree.read(json.Null) == None
  assert call_tree.read(json.Array([])) == None
}

pub fn unknown_keys_are_ignored_test() {
  let widened =
    string.replace(golden, "\"total\":2", "\"total\":2,\"lanes\":[1,2]")
    |> string.replace("\"status\":\"ok\"", "\"status\":\"ok\",\"extra\":null")
  assert option.is_some(call_tree.read(details_with(widened)))
}

pub fn every_malformed_variant_reads_as_no_record_test() {
  let variants = [
    // The wrong type for the whole record.
    "[]",
    "null",
    "\"calls\"",
    // A missing required field.
    string.replace(golden, "\"elapsed_ms\":1840,", ""),
    string.replace(golden, "\"items\":", "\"rows\":"),
    // A wrong type for a counter.
    string.replace(golden, "\"total\":2", "\"total\":\"2\""),
    string.replace(golden, "\"failed\":1", "\"failed\":1.5"),
    // An unknown status.
    string.replace(golden, "\"status\":\"ok\"", "\"status\":\"done\""),
    string.replace(golden, "\"status\":\"ok\"", "\"status\":3"),
    // A negative offset or count.
    string.replace(golden, "\"start_ms\":12", "\"start_ms\":-1"),
    string.replace(golden, "\"duration_ms\":3", "\"duration_ms\":-3"),
    string.replace(golden, "\"cancelled\":0", "\"cancelled\":-1"),
    // More items than calls.
    string.replace(golden, "\"total\":2", "\"total\":1"),
    // A text field of the wrong type.
    string.replace(golden, "\"args\":\"src/app.gleam\"", "\"args\":7"),
    string.replace(golden, "\"cap\":\"fs.read\"", "\"cap\":null"),
    string.replace(golden, "\"error\":\"exec_failed\"", "\"error\":[]"),
  ]
  list.each(variants, fn(variant) {
    assert call_tree.read(details_with(variant)) == None
  })
}

pub fn an_empty_but_honest_record_decodes_test() {
  let empty =
    "{\"started_unix_ms\":0,\"elapsed_ms\":0,\"total\":0,\"failed\":0,\"cancelled\":0,\"unsettled\":0,\"items\":[]}"
  let assert Some(log) = call_tree.read(details_with(empty))
  assert log.items == []
}

/// A thousand arbitrary values, each placed under the `calls` key and also
/// offered as the whole of `details`, from a fixed seed so the gate is
/// deterministic.
const sweep_count = 1000

const sweep_seed = 3

pub fn reading_is_total_over_arbitrary_json_test() {
  // The assertion is that reading returns, not what it returns; whether a
  // value decodes is pinned by the cases above. A failure would be a panic
  // inside the decoder, and qcheck then shrinks the value toward a smaller
  // tree of plainer leaves.
  let config =
    qcheck.default_config()
    |> qcheck.with_test_count(sweep_count)
    |> qcheck.with_seed(qcheck.seed(sweep_seed))

  qcheck.run(config, arbitrary(3), fn(value) {
    let _ = call_tree.read(json.Object([#("calls", value)]))
    let _ = call_tree.read(value)
    Nil
  })
}

// The keys the real record uses, so the sweep reaches the decoder's
// interior and not only its first guard.
const keys = [
  "started_unix_ms", "elapsed_ms", "total", "failed", "cancelled", "unsettled",
  "items", "cap", "args", "status", "error", "start_ms", "duration_ms",
]

const words = ["ok", "failed", "cancelled", "unsettled", "fs.read", "", "x"]

/// A JSON value of at most `depth` levels of nesting. Leaves are drawn as
/// indexes or small ranges so they shrink toward `null`, zero and the first
/// word; containers hold up to three items or seven fields, and shrink by
/// dropping them. Depth zero is leaves only.
fn arbitrary(depth: Int) -> qcheck.Generator(JsonValue) {
  let leaves = [
    qcheck.return(json.Null),
    qcheck.map(qcheck.bool(), json.Bool),
    qcheck.map(qcheck.bounded_int(from: -3, to: 5), json.Int),
    qcheck.return(json.Float(1.5)),
    qcheck.map(pick(words), json.String),
  ]

  case depth <= 0 {
    True -> qcheck.from_generators(qcheck.return(json.Null), leaves)
    False -> {
      let inner = arbitrary(depth - 1)
      let array =
        qcheck.generic_list(
          elements_from: inner,
          length_from: qcheck.bounded_int(from: 0, to: 3),
        )
        |> qcheck.map(json.Array)
      let object =
        qcheck.generic_list(
          elements_from: qcheck.tuple2(key(), inner),
          length_from: qcheck.bounded_int(from: 0, to: 7),
        )
        |> qcheck.map(json.Object)

      qcheck.from_generators(qcheck.return(json.Null), [array, object, ..leaves])
    }
  }
}

/// A key of the real record, or one with a stray underscore that the decoder
/// must treat as unknown.
fn key() -> qcheck.Generator(String) {
  qcheck.map2(pick(keys), qcheck.bounded_int(from: 0, to: 2), fn(name, stray) {
    case stray {
      0 -> name <> "_"
      _ -> name
    }
  })
}

fn pick(choices: List(String)) -> qcheck.Generator(String) {
  qcheck.bounded_int(from: 0, to: list.length(choices) - 1)
  |> qcheck.map(fn(index) {
    case list.drop(choices, index) {
      [chosen, ..] -> chosen
      [] -> ""
    }
  })
}
