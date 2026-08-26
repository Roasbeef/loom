//// The boot-time handler: what the operator's stream actually holds.
////
//// Our own lines are rendered by `record.render`, which is pure and
//// tested next door. What this covers is the other half — lines the
//// harness did not author (OTP crash reports, third-party libraries)
//// still land as JSON on one line, still carry the process's stamped
//// context, and are still scrubbed. Foreign text arrives with no field
//// types to reason about, so the formatter scrubs it whole.

import gleam/string
import support/internal/ffi_format
import telemetry/context
import telemetry/field
import telemetry/handler
import telemetry/level
import telemetry/log

const clearance_hex = "3f5a9c1d7b2e4086af13c5d9e07b6482913ac5de7f024b8619cd3a5e7f01b2c4"

pub fn a_loom_line_passes_through_the_formatter_verbatim_test() {
  let line =
    ffi_format.format_report(level.Error, "{\"event\":\"boot.failed\"}")
  assert string.trim(line) == "{\"event\":\"boot.failed\"}"
}

pub fn a_foreign_line_is_wrapped_as_json_test() {
  let line = ffi_format.format_string(level.Warning, "gen_server terminating")
  assert string.contains(line, "\"level\":\"warning\"")
  assert string.contains(line, "\"event\":\"erlang\"")
  assert string.contains(line, "gen_server terminating")
  assert string.ends_with(line, "\n")
  assert string.split(string.trim(line), "\n") == [string.trim(line)]
}

pub fn a_foreign_line_is_scrubbed_test() {
  let line =
    ffi_format.format_string(
      level.Error,
      "connection failed with token " <> clearance_hex,
    )
  assert !string.contains(line, clearance_hex)
  assert string.contains(line, field.redacted_marker)
}

pub fn a_foreign_line_carries_the_stamped_context_test() {
  log.adopt(log.scoped(
    log.discard(),
    context.for_session("sess-5") |> context.with_strand("main"),
  ))
  let line = ffi_format.format_string(level.Error, "boom")
  assert string.contains(line, "\"session\":\"sess-5\"")
  assert string.contains(line, "\"strand\":\"main\"")
}

pub fn the_operator_threshold_falls_back_rather_than_refusing_test() {
  // A misspelled level must not stop a server booting; it must not
  // silently open the stream to `debug` either.
  assert handler.threshold_named(Ok("debug")) == level.Debug
  assert handler.threshold_named(Ok("WARN")) == level.Warning
  assert handler.threshold_named(Ok("shout")) == level.Info
  assert handler.threshold_named(Error(Nil)) == level.Info
}
