//// The transcript's rows before Markdown and wrapping, and the undurable
//// observations that become rows.
////
//// A `Line` is a speaker and a text. The line builders
//// (`tui/transcript_lines`) decide which lines a durable record, a live
//// stream or a tool call becomes; a renderer decides how each speaker is
//// drawn. The types live apart from the terminal's `Model`, which stores
//// them, because the line builders need nothing else from the model, and a
//// host that draws the same transcript some other way needs the lines
//// without the terminal.

import core/ids

/// Who a transcript line belongs to, which is the whole of its styling.
pub type Speaker {
  System
  User
  Assistant
  Reasoning

  /// One reasoning block stood in for by a single literal row.
  ///
  /// The digest bypasses the Markdown renderer, so a fence or a list
  /// marker inside the model's own prose cannot turn the indicator into
  /// several rows. That is what lets a reasoning block hold one height
  /// from its first live fragment through to its settle.
  ReasoningDigest

  /// A collapsed reasoning block that has a summarizer label (protocol
  /// 050). The text is a header, a newline, and the label: the header row
  /// names the block as summarized, and the label is drawn beneath it as
  /// dim secondary text of at most three rows, so the summary is readable
  /// rather than clipped to what is left of one row.
  SummarizedReasoning

  /// A collapsed long advice or nudges message: the heading row, a
  /// newline, then the summarizer's label or the body's opening line, drawn
  /// the way `SummarizedReasoning` draws its label.
  SummarizedAdvice

  ToolCall
  ToolResult
  ToolDetail

  /// Literal patch content, rendered without interpreting Markdown fences.
  ToolPatch

  ToolFailure
  Failure

  /// One blank row, placed by the projection that knows it is needed.
  ///
  /// Every other block closes itself with a blank, but the tool family is
  /// excluded from that so a call's summary can never be split from the
  /// patch, result or note rows beneath it. The gap between one call and the
  /// next is therefore nobody's trailing blank, and only a fold that can see
  /// where one group ends and another begins is in a position to emit it.
  /// This is the row it emits.
  Spacer
}

/// One rendered transcript line before markdown and wrapping.
pub type Line {
  Line(speaker: Speaker, text: String)
}

/// The undurable fragments of one strand-and-kind generation.
///
/// A request owns its text, thinking and tool-call fragments. Operation IDs
/// alone cannot separate requests around tool batches or retries. An `end`
/// observation keeps an identity marker so an older captured preview cannot
/// resurrect a completed answer. When the request names its reserved response
/// entry, its bounded fragments remain visible until that entry arrives.
///
/// `bytes` is what the fragments weigh, carried rather than recomputed: the
/// budget is checked once per delta and a delta arrives per provider token,
/// so counting the list each time would make a bounded question cost the
/// length of the answer.
pub type Stream {
  Stream(
    strand: String,
    operation: String,
    generation: String,
    kind: String,
    fragments: List(String),
    bytes: Int,
  )
}

/// The rolling tail of one output stream of a tool call that is still
/// running, as the daemon last pushed it (`protocol-change/031`).
///
/// It is kept apart from `Stream` because the two grow differently: a
/// stream is appended to fragment by fragment, while a tail is *replaced*
/// whole on every frame, keyed by `{strand, operation, step, source_index,
/// call_id, stream}`. The daemon bounds `text` at a few kilobytes and this terminal keeps one
/// tail per key, so however long a command runs the region stays the size
/// of the last frame. It is cleared with the strand's streams — on an
/// entry landing and on the operation reaching `done` — and a capture
/// drops it once that call's durable result is visible. A fixed global cap
/// also bounds tails whose matching capture was missed or evicted.
pub type ToolTail {
  ToolTail(
    strand: String,
    operation: String,
    step: String,
    source_index: Int,
    call_id: String,
    stream: String,
    text: String,
    total_bytes: Int,
  )
}

/// One submission this terminal made that the daemon answers with a user
/// entry of its own.
///
/// The list of these is what tells a drained prompt's entry apart from the
/// entry a steer commits. Both arrive as an ordinary `UserMessage` on the
/// active strand and neither reply carries an entry id — the gateway rewrites
/// a steer's entry reply to a bare `mutation_outcome` before it reaches the
/// wire — so the only discriminator left is the order this terminal issued
/// them in, which is the order the daemon commits them in: a steer joins the
/// run that is already open, and a held prompt is drained only once that run
/// has settled.
pub type Submission {
  /// A prompt aimed at a busy strand. The daemon holds it and runs it on
  /// that strand's next turn, so it is drawn under the live tail until the
  /// entry it stands for commits.
  HeldPrompt(text: String)

  /// A steer or a follow-up. It is folded into the answer already on screen
  /// and so draws nothing of its own, but its entry still commits, and that
  /// entry is not the one a held prompt is waiting for.
  Interjection
}

/// A prompt-cache miss already rendered as its transcript row.
///
/// The row belongs inside the transcript rather than at the end of it, so
/// the notice names the entry it follows. A usage event arrives after the
/// entry whose request it bills, which is what puts the row under the turn
/// that missed; naming the entry rather than a position is what survives the
/// compact projection, which joins a call to a result several entries later
/// and must not be cut between them.
pub type CacheNotice {
  CacheNotice(
    /// The strand whose transcript shows the row.
    strand: String,
    /// The last entry that strand held when the row was raised.
    after_entry: ids.EntryId,
    /// The operator-facing line, already formatted.
    text: String,
  )
}
