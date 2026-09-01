//// Log levels, and the level *policy* the rest of the tree is expected
//// to follow. Spec §3.4 names structured logs but not a severity
//// ladder, so this module is where the ladder is decided once instead
//// of improvised per call site.
////
//// Four levels, not OTP's eight. `logger` offers `emergency`,
//// `alert`, `critical`, `notice` as well; a harness whose failure
//// domain is one session on one host has no use for the distinctions
//// they draw (there is no pager, no fleet, no severity routing), and an
//// unused rung is a rung people guess at. Four is what the policy can
//// state crisply:
////
//// - **`error`** — the harness could not do what it was asked and no
////   automatic recovery remains. A commit faulted or the lease was
////   lost; a supervised child died and took the session with it; boot
////   refused. Every `error` line names something an operator must act
////   on. Settling an effect as an *in-band* error is not this: a tool
////   that failed and reported so is the system working.
//// - **`warning`** — degraded but still progressing. A retry armed, a
////   provider fell back, an optional facility is absent on this host, a
////   projection catch-up failed and the next pull will retry it. A
////   `warning` is a thing to read after the fact, not during.
//// - **`info`** — the lifecycle skeleton, at most one line per durable
////   state change: session opened and closed, strand started and
////   stopped, operation opened and settled. Sized so that a full run at
////   `info` is readable by a human, which is what makes it the default.
////   Never per planning pass — the drive loop replans many times per
////   step.
//// - **`debug`** — per-step effect dispatch and settlement, and the
////   drive loop's decisions. Off by default; this is the level that
////   costs money on a busy session.
////
//// Two rules cut across all four. A log line is never load-bearing:
//// the conversation store and the usage ledger are the record, and
//// §3.4 makes telemetry observability only, so nothing may read a log
//// line back or give one authority over a ledger row. And no line at
//// any level may carry a token, a key, or a capability token — see
//// `telemetry/field`, which enforces it rather than asking.

import gleam/option.{None, Some}
import gleam/string

/// A log level. Ordered by severity; see the module doc for what
/// belongs at each.
///
/// Constructor invariants: the four constructors are exactly Erlang
/// `logger`'s `debug`, `info`, `warning` and `error` atoms, so a value
/// of this type can be handed to `logger:log/3` unchanged.
pub type Level {
  /// Per-step effect dispatch and settlement; off by default.
  Debug

  /// One line per durable state change; the default threshold.
  Info

  /// Degraded but progressing.
  Warning

  /// No automatic recovery remains; an operator must act.
  Error
}

/// The level's name, as it appears in the rendered line and as Erlang
/// `logger` spells it.
///
/// ## Examples
///
/// ```gleam
/// assert level.name(level.Warning) == "warning"
/// ```
///
pub fn name(level: Level) -> String {
  case level {
    Debug -> "debug"
    Info -> "info"
    Warning -> "warning"
    Error -> "error"
  }
}

/// Parses an operator-supplied level name, case-insensitively, taking
/// `warn` and `err` as the abbreviations people actually type. Total:
/// anything else is `Error(Nil)` and the caller keeps its default.
///
/// ## Examples
///
/// ```gleam
/// assert level.parse("WARN") == Ok(level.Warning)
/// assert level.parse("shout") == Error(Nil)
/// ```
///
pub fn parse(text: String) -> Result(Level, Nil) {
  // `Error` is a constructor of this type, so it shadows the prelude's
  // inside this module: the failure is built through `Option` rather
  // than named directly.
  case string.lowercase(string.trim(text)) {
    "debug" -> Some(Debug)
    "info" -> Some(Info)
    "warn" | "warning" -> Some(Warning)
    "err" | "error" -> Some(Error)
    _ -> None
  }
  |> option.to_result(Nil)
}

/// Whether a logger set to `threshold` emits a record at `level` — true
/// when `level` is at least as severe.
///
/// ## Examples
///
/// ```gleam
/// assert level.permits(threshold: level.Info, level: level.Error)
/// assert !level.permits(threshold: level.Info, level: level.Debug)
/// ```
///
pub fn permits(threshold threshold: Level, level level: Level) -> Bool {
  severity(level) >= severity(threshold)
}

/// The level's rank, low to high. Exposed because a sink that forwards
/// elsewhere (an OpenTelemetry exporter, a file handler) usually needs
/// to map severity onto its own scale.
///
/// ## Examples
///
/// ```gleam
/// assert level.severity(level.Debug) < level.severity(level.Error)
/// ```
///
pub fn severity(level: Level) -> Int {
  case level {
    Debug -> 0
    Info -> 1
    Warning -> 2
    Error -> 3
  }
}
