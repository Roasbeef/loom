//// A retained report produces a bounded transcript preview after durable custody.
////
//// The original MessagePack value stays in its checked complete bundle. Preview
//// rendering visits at most 32 nodes, copies only bounded string prefixes and
//// never base64-encodes binary values. A preview is deliberately lossy; the
//// reference retrieves the exact value and independent host observations.

import core/json
import core/msgpack as mp
import core/report_value
import gleam/bit_array
import gleam/float
import gleam/int
import gleam/list
import tools/tool

/// The owner commits the report under the original admitted invocation.
/// A returned reference asserts custody, not permission to replay effects.
pub type Retain =
  fn(tool.Ctx, report_value.CompleteReport) ->
    Result(report_value.ReportRef, String)

/// The trusted pipeline stage that refused before producing a terminal outcome.
pub type RefusalStage {
  /// Pure vetting rejected the source before compilation.
  Vet

  /// Compilation failed before satellite execution.
  Compile
}

/// Builds a small transcript result from an already retained complete report.
///
/// ## Examples
///
/// ```gleam
/// // code_report.render(complete_report, durable_reference)
/// ```
pub fn render(
  report: report_value.CompleteReport,
  reference: report_value.ReportRef,
) -> tool.ToolOutcome {
  let uri = report_value.ref_to_string(reference)
  let #(outcome, text) = case report_value.outcome(report) {
    report_value.Completed(value) -> #(tool.success, preview(value, 32).0)
    report_value.Errored(message, details) -> #(
      tool.failure,
      "Program failure: "
        <> prefix(message, 1024)
        <> "\n"
        <> preview(details, 32).0,
    )
  }
  let text =
    prefix(text, 3000)
    <> "\nComplete result: "
    <> uri
    <> "\nRead with cap/report.load_result; this preview is abbreviated."
  outcome(text)
  |> tool.with_details(
    json.Object([
      #("kind", json.String("code_mode_report_v1")),
      #("reference", json.String(uri)),
    ]),
  )
}

/// Records only an actual vet or compile refusal supplied by the trusted shell.
/// This does not assert that physical build resources have retired.
///
/// ## Examples
///
/// ```gleam
/// // code_report.not_run(code_report.Compile, "unknown variable")
/// ```
pub fn not_run(stage: RefusalStage, diagnostic: String) -> tool.ToolOutcome {
  let name = case stage {
    Vet -> "vet"
    Compile -> "compile"
  }
  tool.failure(prefix(diagnostic, 4096))
  |> tool.with_details(
    json.Object([
      #("kind", json.String("code_mode_not_run_v1")),
      #("stage", json.String(name)),
    ]),
  )
}

// Slice bytes before validating UTF-8, so a long combining sequence cannot make
// a grapheme-based limit copy an unbounded prefix. At most three bytes retreat.
fn prefix(text: String, maximum: Int) -> String {
  let bytes = <<text:utf8>>
  case bytes {
    <<start:size(maximum)-bytes, _rest:bytes>> -> utf8_prefix(start)
    _ -> text
  }
}

fn utf8_prefix(bytes: BitArray) -> String {
  case bit_array.to_string(bytes) {
    Ok(text) -> text
    Error(_) -> {
      let size = bit_array.byte_size(bytes) - 1
      case bytes {
        <<start:size(size)-bytes, _last:8>> -> utf8_prefix(start)
        _ -> ""
      }
    }
  }
}

// The shared node budget covers keys and values together. Containers are never
// counted or rendered in full merely to produce an abbreviated description.
fn preview(value: mp.MsgPackValue, remaining: Int) -> #(String, Int) {
  case remaining <= 0 {
    True -> #("…", 0)
    False -> preview_node(value, remaining - 1)
  }
}

fn preview_node(value: mp.MsgPackValue, remaining: Int) -> #(String, Int) {
  case value {
    mp.NilValue -> #("null", remaining)
    mp.BoolValue(True) -> #("true", remaining)
    mp.BoolValue(False) -> #("false", remaining)
    mp.IntValue(value) -> #(int.to_string(value), remaining)
    mp.FloatValue(value) -> #(float.to_string(value), remaining)
    mp.StringValue(value) -> #(
      json.to_string(json.String(prefix(value, 256))),
      remaining,
    )
    mp.BinaryValue(bytes) -> #(
      "<binary: " <> int.to_string(bit_array.byte_size(bytes)) <> " bytes>",
      remaining,
    )
    mp.ArrayValue(values) -> {
      let #(items, rest) = preview_array(values, remaining, [])
      #("[" <> items <> "]", rest)
    }
    mp.MapValue(pairs) -> {
      let #(items, rest) = preview_pairs(pairs, remaining, [])
      #("{" <> items <> "}", rest)
    }
  }
}

fn preview_array(
  values: List(mp.MsgPackValue),
  remaining: Int,
  parts: List(String),
) -> #(String, Int) {
  case values, remaining <= 0 {
    [], _ -> #(join(parts), remaining)
    [_item, ..], True -> #(join(["…", ..parts]), 0)
    [item, ..rest], False -> {
      let #(text, remaining) = preview(item, remaining)
      preview_array(rest, remaining, [text, ..parts])
    }
  }
}

fn preview_pairs(
  pairs: List(#(mp.MsgPackValue, mp.MsgPackValue)),
  remaining: Int,
  parts: List(String),
) -> #(String, Int) {
  case pairs, remaining < 2 {
    [], _ -> #(join(parts), remaining)
    [_pair, ..], True -> #(join(["…", ..parts]), 0)
    [#(key, value), ..rest], False -> {
      let #(key, remaining) = preview(key, remaining)
      let #(value, remaining) = preview(value, remaining)
      preview_pairs(rest, remaining, [key <> ": " <> value, ..parts])
    }
  }
}

fn join(parts: List(String)) -> String {
  parts
  |> list.reverse
  |> list.fold("", fn(acc, part) {
    case acc {
      "" -> part
      _ -> acc <> ", " <> part
    }
  })
}
