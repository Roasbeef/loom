//// Confined FFI over OTP's `logger` (spec §0.2: every `@external`
//// lives in an `internal/ffi_*` module, names the OTP function it
//// binds, and says why no pure alternative exists). The Erlang side is
//// `telemetry_ffi.erl`.
////
//// Why FFI at all: `logger` is the OTP-native logging facility — the
//// one thing every OTP library, the SASL crash reporter, and the
//// emulator itself already write to — and neither `gleam_erlang` nor
//// the standard library binds it. Writing our own sink instead would
//// leave every foreign line (a `gen_server` termination report, a
//// supervisor's `child_terminated`) on a separate, unformatted,
//// uncorrelated stream, which is precisely the diagnosability gap spec
//// §3.4 exists to close.
////
//// The confinement is narrow on purpose. Nothing here decides *what*
//// a line says: the record is built and rendered by pure code in
//// `telemetry/record`, and this module only carries the finished line
//// across the boundary. That includes the redaction rules — the Erlang
//// formatter calls back into `telemetry@field:scrub_text/1` rather
//// than reimplementing them, so there is one implementation and the
//// tests reach it.

import gleam/option.{type Option}
import telemetry/level.{type Level}

/// Installs the JSON formatter on the default handler and opens the
/// primary level to `threshold`. Idempotent — a second call in one VM
/// (which is what a second test does) replaces the same configuration.
///
/// Binds `logger:update_handler_config/3` and
/// `logger:set_primary_config/2` via `telemetry_ffi:install/1`. OTP
/// ships no JSON handler, so the handler is the stock `default` one —
/// its supervision and overload protection — with our formatter.
@external(erlang, "telemetry_ffi", "install")
pub fn install(threshold: Level) -> Nil

/// Raises or lowers the primary level without touching the handler.
///
/// Binds `logger:set_primary_config/2` via
/// `telemetry_ffi:set_primary_level/1`.
@external(erlang, "telemetry_ffi", "set_primary_level")
pub fn set_primary_level(threshold: Level) -> Nil

/// Writes one already-rendered JSON line at `level`.
///
/// Binds `logger:log/3` via `telemetry_ffi:emit/2`. The line is passed
/// as a report under a single key rather than as a format string, so
/// nothing between here and the formatter can reinterpret it.
@external(erlang, "telemetry_ffi", "emit")
pub fn emit(level: Level, line: String) -> Nil

/// Stamps the correlation slots onto the *calling* process's `logger`
/// metadata, so lines the harness did not author land correlated. Our
/// own lines never read this — they carry the context as a value.
///
/// Binds `logger:set_process_metadata/1` (merging, not replacing) via
/// `telemetry_ffi:stamp/4`.
@external(erlang, "telemetry_ffi", "stamp")
pub fn stamp(
  session: Option(String),
  strand: Option(String),
  op: Option(String),
  step: Option(String),
) -> Nil

/// Reads back what `stamp` wrote on the calling process. A process that
/// never stamped answers with four `None`s.
///
/// Binds `logger:get_process_metadata/0` via `telemetry_ffi:stamped/0`.
@external(erlang, "telemetry_ffi", "stamped")
pub fn stamped() -> #(
  Option(String),
  Option(String),
  Option(String),
  Option(String),
)
