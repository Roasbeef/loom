//// The rendered line's shape: one JSON object per line, carrying the
//// level, the event name, and whatever of `{session, strand, op, step}`
//// the context knows.

import core/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import telemetry/context
import telemetry/field
import telemetry/level
import telemetry/record

fn parsed(entry: record.Record) -> List(#(String, json.JsonValue)) {
  let assert Ok(json.Object(fields)) = json.parse(record.render(entry))
    as "a rendered record must be a JSON object"
  fields
}

fn lookup(
  fields: List(#(String, json.JsonValue)),
  key: String,
) -> option.Option(json.JsonValue) {
  case list.key_find(fields, key) {
    Ok(value) -> Some(value)
    Error(Nil) -> None
  }
}

pub fn a_record_renders_as_one_json_object_test() {
  let fields =
    parsed(
      record.Record(
        level: level.Info,
        event: "operation.opened",
        context: context.for_session("sess-1")
          |> context.with_strand("main")
          |> context.with_op("op-9")
          |> context.with_step("step-0"),
        fields: [field.count(key: "attempt", value: 2)],
      ),
    )
  assert lookup(fields, "level") == Some(json.String("info"))
  assert lookup(fields, "event") == Some(json.String("operation.opened"))
  assert lookup(fields, "session") == Some(json.String("sess-1"))
  assert lookup(fields, "strand") == Some(json.String("main"))
  assert lookup(fields, "op") == Some(json.String("op-9"))
  assert lookup(fields, "step") == Some(json.String("step-0"))
  assert lookup(fields, "attempt") == Some(json.Int(2))
}

pub fn an_unknown_context_slot_is_omitted_not_null_test() {
  let fields =
    parsed(
      record.Record(
        level: level.Debug,
        event: "strand.idle",
        context: context.for_session("sess-1") |> context.with_strand("main"),
        fields: [],
      ),
    )
  assert lookup(fields, "op") == None
  assert lookup(fields, "step") == None
}

pub fn a_rendered_line_holds_no_newline_test() {
  // One event per line is what makes the stream greppable; an embedded
  // newline in a field value would split one event into two.
  let line =
    record.render(
      record.Record(
        level: level.Error,
        event: "boot.failed",
        context: context.anonymous,
        fields: [field.text(key: "reason", value: "line one\nline two")],
      ),
    )
  assert !string.contains(line, "\n")
  let assert Ok(json.Object(_)) = json.parse(line)
    as "the escaped line must still parse as one object"
}

pub fn a_duplicate_key_does_not_corrupt_the_object_test() {
  // core/json calls a duplicated object key corruption, so a rendered
  // line that carried one would not parse back.
  let line =
    record.render(
      record.Record(
        level: level.Info,
        event: "tool.settled",
        context: context.for_session("sess-1"),
        fields: [
          field.text(key: "session", value: "impostor"),
          field.count(key: "size", value: 1),
          field.count(key: "size", value: 2),
        ],
      ),
    )
  let assert Ok(json.Object(fields)) = json.parse(line)
    as "a line with duplicated keys must still parse"
  assert lookup(fields, "session") == Some(json.String("sess-1"))
  assert lookup(fields, "size") == Some(json.Int(1))
}

pub fn every_level_names_itself_test() {
  assert level.name(level.Debug) == "debug"
  assert level.name(level.Info) == "info"
  assert level.name(level.Warning) == "warning"
  assert level.name(level.Error) == "error"
  assert level.parse("warning") == Ok(level.Warning)
  assert level.parse("WARN") == Ok(level.Warning)
  assert level.parse("shout") == Error(Nil)
}

pub fn a_threshold_permits_itself_and_above_test() {
  assert level.permits(threshold: level.Info, level: level.Info)
  assert level.permits(threshold: level.Info, level: level.Error)
  assert !level.permits(threshold: level.Info, level: level.Debug)
  assert level.permits(threshold: level.Debug, level: level.Debug)
}
