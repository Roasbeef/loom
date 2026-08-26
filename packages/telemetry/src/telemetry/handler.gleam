//// Boot-time installation of the JSON handler, and the only impure
//// entry point in the package.
////
//// §3.4 asks for "Erlang `logger`, JSON handler". OTP ships no JSON
//// handler, so this installs the stock `default` handler — its
//// supervision, its overload protection, its back-pressure — with
//// `telemetry_ffi` as its formatter. Every line that reaches `logger`
//// then comes out as one JSON object on one line, ours and OTP's
//// alike.
////
//// Installing is an entry point's job and nobody else's. A library
//// that installed a handler would silently reconfigure the VM of
//// whatever embedded it, which is why this lives in its own module
//// with one function rather than inside `log`.

import telemetry/internal/ffi_logger
import telemetry/level.{type Level}
import telemetry/log.{type Logger}

/// Installs the JSON formatter on the default handler, opens the
/// primary level to `threshold`, and returns the logger a host should
/// inject everywhere. Idempotent: calling it twice in one VM replaces
/// the same configuration.
///
/// ## Examples
///
/// ```gleam
/// // let logger = handler.install(threshold: level.Info)
/// ```
///
pub fn install(threshold threshold: Level) -> Logger {
  ffi_logger.install(threshold)
  log.erlang(threshold:)
}

/// The threshold an operator asked for, falling back to `Info` when
/// they asked for nothing or for something unrecognised. Total, and
/// deliberately silent about a bad value: refusing to boot over a
/// misspelled log level would be worse than the level being wrong.
///
/// ## Examples
///
/// ```gleam
/// assert handler.threshold_named(Ok("debug")) == level.Debug
/// assert handler.threshold_named(Error(Nil)) == level.Info
/// ```
///
pub fn threshold_named(named: Result(String, e)) -> Level {
  case named {
    Ok(text) ->
      case level.parse(text) {
        Ok(parsed) -> parsed
        Error(Nil) -> level.Info
      }
    Error(_) -> level.Info
  }
}

/// The environment variable an operator sets to change the level.
pub const level_variable = "LOOM_LOG_LEVEL"
