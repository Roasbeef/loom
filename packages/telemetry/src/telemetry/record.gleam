//// One log event, and how it becomes one line.
////
//// Rendering is pure: a `Record` is data, `render` is a total function
//// from it to a single-line JSON document, and nothing here touches
//// `logger`, the clock, or the process. That is what makes the
//// redaction rule testable — the secret test plants a secret in a
//// record, renders it, and greps the bytes — and it is why the JSON is
//// built in Gleam rather than in the Erlang formatter.
////
//// ## Why the record carries no timestamp
////
//// Spec §0.2 makes time an injected `Clock` capability, and `core`'s
//// clock is *threaded*: reading it returns a new clock. A log call that
//// read the session's clock would consume steps from it and shift the
//// ids minted after it, so a line written for observation would change
//// what the system durably records. A log timestamp is not domain time
//// anyway. So the record carries none, and the handler stamps
//// `logger`'s own `time` metadata onto the line as it writes it — the
//// one place where a wall clock is both correct and harmless.
////
//// ## Line shape
////
//// `{"level":…,"event":…,"session":…,"strand":…,"op":…,"step":…,…}` —
//// level and event first, then whichever of the four context slots are
//// known, then the call site's own fields in the order given. Unknown
//// context slots are omitted rather than null, so a grep for a slot
//// cannot match a line that never had one. `core/json` treats a
//// duplicated object key as corruption, so the first occurrence of a
//// key wins and later ones are dropped; a caller cannot shadow
//// `session` with a field of its own.

import core/json.{type JsonValue}
import gleam/list
import telemetry/context.{type Context}
import telemetry/field.{type Field}
import telemetry/level.{type Level}

/// One log event, before rendering.
///
/// Constructor invariants: `event` is a stable dotted name
/// (`operation.opened`, `tool.settled`) and never interpolated text —
/// the variable part belongs in `fields`, where the redaction rules
/// reach it and where a consumer can index on it. `fields` may name a
/// key more than once; render keeps the first.
pub type Record {
  Record(level: Level, event: String, context: Context, fields: List(Field))
}

/// The record as a JSON object, with both redaction rules applied and
/// duplicate keys resolved.
///
/// ## Examples
///
/// ```gleam
/// // record.to_json(Record(level.Info, "strand.started", ctx, []))
/// ```
///
pub fn to_json(record: Record) -> JsonValue {
  let head = [
    #("level", json.String(level.name(record.level))),
    #("event", json.String(field.scrub_text(record.event))),
  ]
  let body =
    context.fields(record.context)
    |> list.append(record.fields)
    |> list.map(field.scrub)
    |> list.map(fn(one) { #(one.key, encode(one.value)) })
  json.Object(dedupe(list.append(head, body), [], []))
}

/// The record as one line of JSON, with no trailing newline. Total: any
/// record renders, and a rendered record always parses back.
///
/// ## Examples
///
/// ```gleam
/// // record.render(Record(level.Info, "strand.started", ctx, []))
/// // -> "{\"level\":\"info\",\"event\":\"strand.started\"}"
/// ```
///
pub fn render(record: Record) -> String {
  json.to_string(to_json(record))
}

fn encode(value: field.Value) -> JsonValue {
  case value {
    field.Text(text) -> json.String(text)
    field.Ident(text) -> json.String(text)
    field.Count(number) -> json.Int(number)
    field.Flag(flag) -> json.Bool(flag)
    field.Redacted -> json.String(field.redacted_marker)
  }
}

// First occurrence of each key wins. A duplicated key is corruption to
// `core/json`'s parser, so a line carrying one would not read back —
// and the reserved context keys are emitted first, which is what stops
// a caller's field from shadowing `session`.
fn dedupe(
  fields: List(#(String, JsonValue)),
  seen: List(String),
  acc: List(#(String, JsonValue)),
) -> List(#(String, JsonValue)) {
  case fields {
    [] -> list.reverse(acc)
    [#(key, value), ..rest] ->
      case list.contains(seen, key) {
        True -> dedupe(rest, seen, acc)
        False -> dedupe(rest, [key, ..seen], [#(key, value), ..acc])
      }
  }
}
