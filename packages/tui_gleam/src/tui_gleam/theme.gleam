//// The Loom terminal palette.
////
//// The client uses an industrial control-room vocabulary: graphite fields,
//// warm signal amber for operator actions, and cold cyan for live agent
//// output. The terminal remains legible when true colour is unavailable
//// because structure never depends on colour alone.

import etui/style

/// The background shared by the header and command rail.
pub const graphite = style.Rgb(24, 27, 31)

/// The foreground shared by the header and command rail.
pub const paper = style.Rgb(226, 224, 216)

/// Operator-controlled actions and prompts.
pub const signal = style.Rgb(240, 164, 70)

/// Agent output and live activity.
pub const current = style.Rgb(91, 203, 217)

/// Secondary annotations and inactive controls.
pub const quiet = style.Rgb(118, 124, 130)

/// Failures and refused actions.
pub const danger = style.Rgb(235, 102, 112)

/// A bold signal style for the Loom mark and command names.
///
/// ## Examples
///
/// ```gleam
/// span.span_styled("/model", theme.signal_bold())
/// ```
pub fn signal_bold() -> style.Style {
  style.new(signal, style.Default, style.bold())
}

/// A bold current style for assistant labels.
///
/// ## Examples
///
/// ```gleam
/// span.span_styled("◆", theme.current_bold())
/// ```
pub fn current_bold() -> style.Style {
  style.new(current, style.Default, style.bold())
}

/// A dim annotation style for metadata.
///
/// ## Examples
///
/// ```gleam
/// span.span_styled("thinking", theme.quiet_text())
/// ```
pub fn quiet_text() -> style.Style {
  style.new(quiet, style.Default, style.dim())
}

/// A red failure style for refused commands and transport faults.
///
/// ## Examples
///
/// ```gleam
/// span.span_styled("refused", theme.danger_text())
/// ```
pub fn danger_text() -> style.Style {
  style.new(danger, style.Default, style.bold())
}
