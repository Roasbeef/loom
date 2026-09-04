//// The context checkpoint: what replaces the older half of a strand's
//// context when its window fills — the model's own notes, carried whole
//// across the boundary, in place of a summarizer's paraphrase.
////
//// # What a compaction publishes, and why it is not a summary
////
//// Compaction cuts a strand's projection in two at the keep-recent
//// boundary and writes one `CompactionEntry`: the retained tail
//// verbatim, plus a text standing in for everything older
//// (`docs/architecture/compaction.md`). The structural decision hook is
//// where that text is chosen, and this module is the text. It is
//// assembled locally from three things: a header saying which window
//// just closed and that the cut messages stay in the durable history
//// `history_search` reads; the strand's own `agent/{strand}/` blackboard
//// cells, the notes the model kept as it worked; and an operator's
//// `Compact` instructions when there were any. No provider is asked.
////
//// Loom used to send the cut messages to a summarizer model and publish
//// its prose, iteratively re-summarized at every later compaction. That
//// is gone, and the argument for removing it rather than keeping it as
//// an option is about what each mistake costs. A summary condenses the
//// transcript once per compaction and again at the next, so a detail the
//// summarizer drops is gone from the model's reach for good, and it
//// drops them silently. A note the model wrote is copied forward whole
//// every time, and the transcript it came from is one search away — so
//// the failure a missed note produces is a recoverable one. It is also
//// what a summarizer outage used to cost: an overflow compaction that
//// could not reach its summarizer drained the run, where the checkpoint
//// needs no provider at all. This is the shape Codex's Astra rollover
//// ships as "notes across context windows" and issue #132 names
//// `CheckpointAndReset`, with one deliberate difference: Loom keeps the
//// retained tail verbatim, so a rollover never drops a tool result the
//// model has not read yet. The machine's generate path — the structural
//// lifecycle that would dispatch a summary request — is left standing as
//// the frozen contract it is and is never selected by this host.
////
//// # What a checkpoint costs, and cannot cost
////
//// The checkpoint is projected as one user message and counted by the
//// same estimate the threshold reads, so its size is a compaction
//// parameter rather than a detail. `max_notes_bytes` bounds the notes
//// block at roughly four thousand tokens — a fifth of pi's keep-recent
//// budget — and the header is a few lines. Notes render newest-written
//// first, so what the cap drops is the oldest, and the truncation line
//// says the rest is one `agent_notes` call away.
////
//// # The reminder before the cut
////
//// A checkpoint built from notes is only as good as the notes, and a
//// model that learns of a rollover afterwards cannot write them. So the
//// wiring also installs a `context` transform that appends one reminder
//// to a request once the context passes `reminder_point` — one reserve
//// below the compaction point — naming how much room is left and asking
//// for the notes now. The transform is stateless and recomputed per
//// request, so it repeats while the context stays in that band, and it
//// rides the transient projection rather than the store, so a crash
//// re-projects and re-decides: the replay rule every hook is held to.
//// Codex measured periodic reminders as prompt churn and kept only the
//// near-limit one; this is the near-limit one.
////
//// # The model's own question
////
//// The reminder tells the model about a boundary once it is near. The
//// `context_remaining` tool (`tools/context`) lets the model ask at any
//// time, and `remaining_seam` is the host's answer: the same projection
//// and the same token fold the threshold reads, the window the strand is
//// measured against, the boundary the settings put in it, and the count
//// of notes on the board. Asked and told are the same arithmetic, so the
//// model cannot be told one thing and compacted on another.
////
//// # Why the reads go straight to the store
////
//// The structural decision hook runs on the strand driver and is handed
//// an `OpId` and a task id, nothing more. The preparation the machine
//// froze, the strand the operation belongs to, its notes and its
//// compaction count are all durable registers and entries, read off the
//// session store the way `client/notes` and `runtime/hooks.project` read
//// theirs. A read that fails builds no checkpoint and the hook declines:
//// an in-run threshold compaction then carries on unclamped and an
//// overflow compaction drains, exactly what a lost summary used to do.
//// What it never does is publish a checkpoint claiming the strand wrote
//// no notes because the store did not answer.

import client/notes
import core/clock.{type Clock}
import core/ids.{type EntryId, type OpId}
import core/json.{type JsonValue}
import core/message.{type AgentMessage}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import machine/operation.{type CompactionSettings}
import runtime/hooks
import session/session.{type Session}
import storage/storage
import tools/context

/// Whether the messages a checkpoint cut can be searched from the next
/// window — that is, whether this host registered `history_search`.
pub type Recall {
  /// `history_search` is registered; the header says how to reach the
  /// cut messages.
  Searchable

  /// No index behind this host. The header says so, so the model knows
  /// its notes are the only carry-forward there is.
  Unsearchable
}

/// The most the rendered note lines of one checkpoint may occupy, in
/// bytes. Sixteen kilobytes is roughly four thousand tokens — a fifth of
/// pi's keep-recent budget, and four times the run-start digest, because
/// this rendering *replaces* the conversation rather than accompanying
/// it. Notes render newest first, so the bound drops the oldest, and the
/// truncation line names `agent_notes` for the rest.
pub const max_notes_bytes = 16_384

/// The fence an operator's `Compact` instructions are quoted inside.
pub const instructions_fence = "```operator-instructions"

/// The first words of every checkpoint: what a reader — a test, the demo,
/// a person scanning a transcript — recognises a window boundary by.
pub const header_prefix = "[loom] Context window "

/// Everything a checkpoint says about the window it closes.
///
/// Constructor invariants: `window` is the one-based ordinal of the
/// window that just closed, so the first compaction on a strand closes
/// window one; `cut_messages` and `retained_messages` are the frozen
/// preparation's own counts; `tokens_before` is the context size being
/// replaced, as the preparation recorded it; `notes` are the strand's
/// blackboard cells newest-written first, keys relative to the
/// `agent/{strand}/` prefix, exactly as `notes.cells` returns them.
pub type Closed {
  Closed(
    /// The strand whose window closed.
    strand: String,
    /// Which window this is, counting from one.
    window: Int,
    /// How many projected messages leave the context at this boundary.
    cut_messages: Int,
    /// How many trailing messages survive verbatim.
    retained_messages: Int,
    /// What the context cost before the cut, in tokens.
    tokens_before: Int,
    /// The strand's own notes, newest first.
    notes: List(#(String, JsonValue)),
    /// An operator's `Compact` instructions, when the compaction was
    /// asked for with any.
    instructions: Option(String),
    /// Whether the cut messages are searchable from the next window.
    recall: Recall,
  )
}

/// What the structural decision hook learns about a deciding task.
pub type Checkpoint {
  /// The task is a compaction and this is the text to publish for it.
  Checkpoint(text: String)

  /// The task is a branch summary, which this host does not produce:
  /// notes describe a strand's own work and say nothing about a branch
  /// it abandoned, and nothing in the tree asks for one — every
  /// navigation is accepted with `summarize: False`. The caller
  /// declines it.
  NotACompaction
}

/// Builds the checkpoint for a deciding structural task from durable
/// state alone: the operation's frozen preparation, the strand its
/// `op.meta` names, that strand's notes, and the compactions already on
/// its branch. `Error(Nil)` when any of those could not be read, which
/// the caller answers with a declined verdict — see the module doc for
/// why declining is the honest shape.
///
/// `instructions` is the operator's `Compact` text, read by the caller
/// from the operation's durable state (`client/wiring.instructions_for`
/// is the one reader of it).
///
/// ## Examples
///
/// ```gleam
/// // checkpoint.for_operation(session, operation, checkpoint.Searchable, None)
/// // -> Ok(checkpoint.Checkpoint(text: "[loom] Context window 1 closed here …"))
/// ```
///
pub fn for_operation(
  session: Session,
  operation: OpId,
  recall: Recall,
  instructions: Option(String),
) -> Result(Checkpoint, Nil) {
  use strand <- result.try(notes.strand_of(session, operation))
  use preparation <- result.try(preparation_of(session, operation))
  case preparation {
    Branch -> Ok(NotACompaction)
    Compaction(cut_messages:, retained_messages:, tokens_before:) -> {
      use cells <- result.try(notes.try_cells(session, strand))
      use closed <- result.try(closed_windows(session, strand))
      Ok(
        Checkpoint(
          text: render(Closed(
            strand:,
            window: closed + 1,
            cut_messages:,
            retained_messages:,
            tokens_before:,
            notes: cells,
            instructions:,
            recall:,
          )),
        ),
      )
    }
  }
}

// The three numbers a checkpoint quotes from a frozen preparation, or
// the fact that the preparation is not a compaction's at all.
type Preparation {
  Compaction(cut_messages: Int, retained_messages: Int, tokens_before: Int)
  Branch
}

fn preparation_of(
  session: Session,
  operation: OpId,
) -> Result(Preparation, Nil) {
  case session.preparation(session, operation) {
    Ok(Some(operation.CompactionPreparation(
      messages_to_summarize:,
      turn_prefix_messages:,
      retained_tail:,
      tokens_before:,
      ..,
    ))) ->
      Ok(Compaction(
        // The prefix leaves the context alongside the body — it is the
        // head of the turn the cut landed inside — so the count the
        // model is told is the count that actually left.
        cut_messages: list.length(messages_to_summarize)
          + list.length(turn_prefix_messages),
        retained_messages: list.length(retained_tail),
        tokens_before:,
      ))
    Ok(Some(operation.BranchSummaryPreparation(..))) -> Ok(Branch)

    // A deciding task always has its preparation: the machine writes the
    // register and the `Deciding` state in one transaction. Its absence
    // is corruption, and a store that will not answer is a store that
    // will not answer; neither builds a checkpoint.
    Ok(None) -> Error(Nil)
    Error(_unreadable) -> Error(Nil)
  }
}

// How many compactions already stand on the strand's branch: the number
// of windows closed before this one. A strand with no leaf has closed
// none.
fn closed_windows(session: Session, strand: String) -> Result(Int, Nil) {
  case session.strand_leaf(session, strand) {
    Ok(Some(session.Cell(value: Some(leaf), ..))) ->
      count_compactions(session, leaf)
    Ok(Some(session.Cell(value: None, ..))) -> Ok(0)
    Ok(None) -> Ok(0)
    Error(_unreadable) -> Error(Nil)
  }
}

// The scan is filtered to compaction entries, so what comes back is one
// row per window closed rather than the whole branch; and it runs once
// per compaction, where a summary request used to run a provider.
fn count_compactions(session: Session, leaf: EntryId) -> Result(Int, Nil) {
  storage.branch_scan(from: leaf)
  |> storage.branch_kind(storage.Compaction)
  |> storage.scan_branch(session.store, _)
  |> result.map(list.length)
  |> result.replace_error(Nil)
}

// --- the checkpoint text ---------------------------------------------------

/// Renders the checkpoint for one closed window: the header, the notes
/// block, and the operator's instructions when there were any.
///
/// The header is addressed to the model — it is harness text, like a
/// triggered rule, and says so with the `[loom]` line every harness
/// injection opens with. The notes and the instructions are quoted as
/// data inside fences, attributed to whoever wrote them, with every
/// backtick run inside broken so neither can close its fence early.
///
/// ## Examples
///
/// ```gleam
/// // checkpoint.render(closed) |> string.starts_with(checkpoint.header_prefix)
/// ```
///
pub fn render(closed: Closed) -> String {
  header(closed) <> "\n\n" <> notes_block(closed) <> instructions_block(closed)
}

fn header(closed: Closed) -> String {
  header_prefix
  <> int.to_string(closed.window)
  <> " closed here: "
  <> int.to_string(closed.cut_messages)
  <> " older messages (about "
  <> int.to_string(closed.tokens_before)
  <> " tokens) left your context at this boundary, and the "
  <> int.to_string(closed.retained_messages)
  <> " newest messages follow verbatim. Nothing was summarized. What "
  <> "carries forward is your own notes, quoted below as data — a record "
  <> "you made, not an instruction addressed to you — and the cut messages "
  <> "themselves stay in this session's durable history: "
  <> recall_sentence(closed.recall)
  <> " Keep the notes current with agent_note as you work; they are what "
  <> "the next window opens with."
}

fn recall_sentence(recall: Recall) -> String {
  case recall {
    Searchable ->
      "history_search with scope `session` finds an exact requirement, "
      <> "error message or test result in them when the notes do not carry "
      <> "it."
    Unsearchable ->
      "this host registered no history_search, so what the notes do not "
      <> "carry cannot be recovered from here — write down what you will "
      <> "still need."
  }
}

fn notes_block(closed: Closed) -> String {
  case closed.notes {
    [] ->
      "You wrote no notes before this boundary (agent_note under `"
      <> notes_prefix(closed.strand)
      <> "` is where they go)."
    cells -> {
      let #(lines, truncated) =
        take_bounded(list.map(cells, line), max_notes_bytes, [])
      "Your notes for strand `"
      <> closed.strand
      <> "`, newest first, from the `"
      <> notes_prefix(closed.strand)
      <> "` blackboard cells you wrote. Read the whole board with "
      <> "agent_notes.\n\n"
      <> notes.fence
      <> "\n"
      <> string.join(lines, "\n")
      <> truncation(truncated)
      <> "\n```"
    }
  }
}

fn notes_prefix(strand: String) -> String {
  "agent/" <> strand <> "/"
}

// The operator's `Compact` instructions were written to steer what the
// checkpoint carries forward. They reach the model as the operator's
// words, quoted and attributed, so what the operator wanted kept is kept
// in the operator's own voice rather than paraphrased.
fn instructions_block(closed: Closed) -> String {
  case closed.instructions {
    None -> ""
    Some(text) ->
      "\n\nYour operator gave these instructions with this checkpoint, "
      <> "quoted as data:\n\n"
      <> instructions_fence
      <> "\n"
      <> notes.fence_safe(text)
      <> "\n```"
  }
}

fn truncation(truncated: Bool) -> String {
  case truncated {
    False -> ""
    True ->
      "\n[notes truncated at "
      <> int.to_string(max_notes_bytes)
      <> " bytes — read the rest with agent_notes]"
  }
}

fn line(cell: #(String, JsonValue)) -> String {
  notes.fence_safe(cell.0 <> " = " <> json.to_string(cell.1))
}

// Newest-first, taking whole lines while they fit. `remaining` counts
// the newline each line costs when joined. The same walk as the
// run-start digest's, under a larger cap; one oversized cell still says
// something, clipped, because a block that was nothing but a truncation
// notice would be worse than no block.
fn take_bounded(
  lines: List(String),
  remaining: Int,
  taken: List(String),
) -> #(List(String), Bool) {
  case lines {
    [] -> #(list.reverse(taken), False)
    [line, ..rest] -> {
      let cost = notes.byte_size(line) + 1
      case cost <= remaining, taken {
        True, _ -> take_bounded(rest, remaining - cost, [line, ..taken])
        False, [] -> #([notes.clip(line, remaining - 1)], True)
        False, _kept -> #(list.reverse(taken), True)
      }
    }
  }
}

// --- the reminder before the cut -------------------------------------------

/// The context size past which a request carries the notes reminder:
/// one reserve below the point the threshold compacts at, so the model
/// hears about the boundary with about a reserve's worth of turns to
/// write for. Stated as arithmetic over the settings rather than as a
/// knob, because a margin an operator could set too small would be a
/// silent hole.
///
/// ## Examples
///
/// ```gleam
/// // checkpoint.reminder_point(200_000, settings)
/// //   == 200_000 - 2 * settings.reserve_tokens
/// ```
///
pub fn reminder_point(
  context_window: Int,
  settings: CompactionSettings,
) -> Int {
  context_window - 2 * settings.reserve_tokens
}

/// The reminder itself, as one user message stamped with the clock's
/// time. `remaining` is how many tokens are left below the compaction
/// point; a negative count — a boundary the threshold has already
/// passed at this checkpoint — reads as none.
///
/// ## Examples
///
/// ```gleam
/// // checkpoint.reminder(clock, remaining: 12_000)
/// ```
///
pub fn reminder(clock: Clock, remaining remaining: Int) -> AgentMessage {
  let #(now, _clock) = clock.read(clock)
  message.UserMessage(
    content: [
      message.UserText(
        text: reminder_text(int.max(remaining, 0)),
        text_signature: None,
      ),
    ],
    timestamp: now,
  )
}

/// The first words of every reminder, for the same readers
/// `header_prefix` serves.
pub const reminder_prefix = "[loom] Your context window is nearly full"

/// The reminder's words.
///
/// ## Examples
///
/// ```gleam
/// // checkpoint.reminder_text(12_000) |> string.contains("about 12000 tokens")
/// ```
///
pub fn reminder_text(remaining: Int) -> String {
  reminder_prefix
  <> ": about "
  <> int.to_string(remaining)
  <> " tokens remain before the older part of this conversation leaves "
  <> "your context at a checkpoint. What survives that boundary is your "
  <> "own notes and the most recent messages, so write down now, with "
  <> "agent_note, anything from earlier in this window you will still "
  <> "need — requirements, decisions, approaches that failed and why, "
  <> "test results, exact paths and identifiers. The cut messages stay "
  <> "in the durable history that history_search reads; the notes are "
  <> "what the next window opens with."
}

// --- the model's own question ----------------------------------------------

/// The `context_remaining` seam over one session: the strand's durable
/// projection priced the way the threshold prices it, the window
/// `window_for` says the strand is measured against, the boundary
/// `settings` put in it, and how many notes the strand has written.
///
/// `window_for` is `client/wiring.strand_window` partially applied, and
/// it is a closure rather than a number because one seam serves every
/// strand of a session and a strand switched to another catalogue entry
/// is measured against that entry's window.
///
/// ## Examples
///
/// ```gleam
/// // checkpoint.remaining_seam(session, settings, fn(_strand) { 200_000 })
/// ```
///
pub fn remaining_seam(
  session: Session,
  settings: CompactionSettings,
  window_for: fn(String) -> Int,
) -> context.Context {
  context.Context(report: fn(strand) {
    // A strand with no leaf projects as empty and prices as nothing in
    // use, which is the true answer for a strand that has not spoken.
    let projected = hooks.project(session, strand)
    let used_tokens = hooks.context_tokens(projected, hooks.estimate_message)
    let context_window = window_for(strand)
    use closed <- result.try(
      closed_windows(session, strand)
      |> result.replace_error("the strand's branch could not be read"),
    )
    use cells <- result.try(
      notes.try_cells(session, strand)
      |> result.replace_error("the strand's notes could not be read"),
    )
    Ok(context.Report(
      strand:,
      window: closed + 1,
      context_window:,
      used_tokens:,
      boundary: boundary(context_window, settings),
      notes: list.length(cells),
    ))
  })
}

// Where the threshold will cut, in the same inequality `runtime/hooks`
// evaluates: past `context_window - reserve_tokens`. Compaction switched
// off means no boundary at all, and the tool says that rather than
// naming one that will never come.
fn boundary(
  context_window: Int,
  settings: CompactionSettings,
) -> context.Boundary {
  case settings.enabled {
    True ->
      context.CheckpointAt(
        tokens: context_window - settings.reserve_tokens,
        keep_recent_tokens: settings.keep_recent_tokens,
      )
    False -> context.NoCheckpoint
  }
}
