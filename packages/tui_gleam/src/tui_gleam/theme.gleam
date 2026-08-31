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

/// Added source in a structured edit preview.
pub const added = style.Rgb(116, 201, 138)

/// The subdued background behind added source.
pub const added_bg = style.Rgb(24, 52, 35)

/// The subdued background behind removed source.
pub const removed_bg = style.Rgb(57, 27, 31)

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

/// A quiet modal label whose background keeps its full terminal intensity.
///
/// Dim is useful on the ordinary transcript, but several terminals apply it
/// to the complete cell and visibly darken modal backgrounds.
pub fn overlay_quiet() -> style.Style {
  style.new(quiet, graphite, style.none())
}

/// A bold operator action on the shared modal background.
pub fn overlay_signal() -> style.Style {
  style.new(signal, graphite, style.bold())
}

/// A bold live value on the shared modal background.
pub fn overlay_current() -> style.Style {
  style.new(current, graphite, style.bold())
}

/// Ordinary modal text on the shared modal background.
pub fn overlay_plain() -> style.Style {
  style.new(paper, graphite, style.none())
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

/// A green success mark for completed tool activity.
pub fn success_text() -> style.Style {
  style.new(added, style.Default, style.bold())
}

/// A readable added-line style for unified diffs.
pub fn diff_added() -> style.Style {
  style.new(added, added_bg, style.none())
}

/// A readable removed-line style for unified diffs.
pub fn diff_removed() -> style.Style {
  style.new(danger, removed_bg, style.none())
}
