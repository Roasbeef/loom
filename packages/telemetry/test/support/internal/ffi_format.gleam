//// Test-only bindings that drive `telemetry_ffi:format/2` directly, so
//// the handler's rendering of *foreign* log events can be asserted
//// without installing a handler and racing the VM's own output.

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
