//// Test-only bindings that drive `telemetry_ffi:format/2` directly, so
//// the handler's rendering of *foreign* log events can be asserted
//// without installing a handler and racing the VM's own output.

import gleam/option.{type Option}
import telemetry/level

/// Formats a loom-authored event whose message is already-rendered JSON.
///
/// Binds `telemetry_ffi:format/2` through
/// `telemetry_test_ffi:format_report/2`, which builds the logger event.
@external(erlang, "telemetry_test_ffi", "format_report")
pub fn format_report(level: level.Level, json: String) -> String

/// Formats a foreign `{string, _}` log event — what OTP's own reports
/// and third-party libraries produce.
@external(erlang, "telemetry_test_ffi", "format_string")
pub fn format_string(level: level.Level, text: String) -> String

/// The calling process's ownership label as `#(path, role)`, or `None`
/// when it has none of the frozen `{pickglass_owner, 1, Path, Role}`
/// shape. Reads `process_info(self(), label)` through
/// `telemetry_test_ffi:owner_label/0`, exactly what an inspector reads.
@external(erlang, "telemetry_test_ffi", "owner_label")
pub fn owner_label() -> Option(#(List(#(String, String)), String))
