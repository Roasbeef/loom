//// The words a status bar and the context panel use for the spend of children
//// on other orchestrators (protocol-change/084, phase 2).
////
//// This is apart from `session_view/remote_usage` because the snapshot decoder
//// imports that module, and the count labels this one needs
//// (`agent_roster.count_label`) sit above the decoder in the import graph.

import gleam/list
import gleam/string
import session_view/agent_roster
import session_view/remote_usage.{type RemoteUsage}
import session_view/text_hygiene

/// One entry as words: the orchestrator, then the tokens its settled children
/// used, input and output.
///
/// ## Examples
///
/// ```gleam
/// assert remote_usage_words.entry(RemoteUsage("box", 12_300, 678, 0, 0, 0.0))
///   == "box in 12.3k out 678"
/// ```
pub fn entry(usage: RemoteUsage) -> String {
  text_hygiene.single_line(usage.orchestrator)
  <> " in "
  <> agent_roster.count_label(usage.input)
  <> " out "
  <> agent_roster.count_label(usage.output)
}

/// Every entry as one line for the status bar, empty when there are none: the
/// entries joined by a middle dot, in the order the snapshot gave them.
///
/// ## Examples
///
/// ```gleam
/// assert remote_usage_words.line([]) == ""
/// ```
pub fn line(entries: List(RemoteUsage)) -> String {
  entries |> list.map(entry) |> string.join(" · ")
}
