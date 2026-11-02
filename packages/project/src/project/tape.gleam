//// A tape: the triggers of one source and rule, each with the thread as it
//// stood when the trigger arrived and what the project did with it.
////
//// A verdict is a measurement over recorded triggers, so the recording has to
//// be faithful in the one way that matters here. A later comment on a thread
//// is evidence the router did not have when it judged an earlier one, and a
//// tape that carried it would let the measurement read the future. Each frame
//// therefore holds only the thread entries that existed at its trigger, and
//// the relation the gate saw is fixed in the frame rather than asked of a
//// later state.
////
//// A tape is built from the engine's state and not from the event log. The
//// state keeps a thread's entries newest first and never rewrites one, so the
//// entries from a trigger's own position onward are exactly the thread as it
//// stood. That keeps the tape available after retention has deleted the
//// events below a snapshot, and it is why a labelled trigger is never
//// retired (`project/snapshot.retire`).
////
//// The tape is a pure value with a total decoder, so a tape can be written
//// next to a verdict and read back by something that never saw the project.
//// It holds the text of each trigger, supplied by the caller because the
//// engine keeps ids and not text, for the live lane to put to the router.
//// The text is external and hostile by assumption: it is data in the tape and
//// never an instruction to anything that reads the tape.
////
//// ## Flow
////
//// `record` → `encode` → `decode`
////
//// 1. `record` selects the triggers of one source and rule, orders them by
////    arrival, and fixes each frame's thread, relation and recorded answer.
//// 2. `encode` writes the tape as one JSON document.
//// 3. `decode` reads it back. Total: anything else is `Malformed`.

import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option
import gleam/order
import gleam/result
import gleam/string
import project/codec
import project/gate
import project/model.{
  type RuleId, type SourceId, type Thread, type ThreadEntry, type Trigger,
  type TriggerId, ThreadEntry, TriggerId,
}
import project/state.{type State, type Ticket, type TriggerRecord}

/// What the router answered about a trigger, as the tape serves it back.
pub type Recorded {
  /// The project took the trigger on: the router accepted, attached or
  /// resumed it, or a subscribed ticket took it, and an `observe` pair
  /// recorded that it would have.
  Took

  /// The router was asked and ignored it.
  Declined

  /// The router never answered: the trigger was not admitted, was shed or
  /// held, or was offered and left unrouted.
  NotAsked
}

/// One recorded trigger.
pub type Frame {
  Frame(
    /// The trigger, with the inputs the gate decides strength from.
    trigger: Trigger,
    /// The trigger's text, cut by the caller.
    text: String,
    /// Whether the sender already owned a ticket on the thread when the
    /// trigger arrived.
    relation: gate.ThreadRelation,
    /// The thread as it stood, newest first, ending at the thread's first
    /// entry and starting at this trigger.
    thread: List(ThreadEntry),
    /// What the router answered.
    recorded: Recorded,
  )
}

/// The recorded triggers of one source and rule, oldest first.
pub type Tape {
  Tape(
    /// The source.
    source: SourceId,
    /// The rule.
    rule: RuleId,
    /// The frames, ordered by arrival time and then by id.
    frames: List(Frame),
  )
}

/// Why a document is not a tape.
pub type TapeError {
  /// The text is not JSON, or it does not have the shape `encode` writes.
  Malformed
}

/// Record the tape of one source and rule from the engine's state. `text_of`
/// supplies each trigger's text, or an empty string when the host has none.
///
/// ## Examples
///
/// ```gleam
/// let tape = tape.record(state.start(config), model.SourceId("s"), model.RuleId("r"), fn(_) { "" })
/// assert tape.frames == []
/// ```
pub fn record(
  current: State,
  source: SourceId,
  rule: RuleId,
  text_of: fn(TriggerId) -> String,
) -> Tape {
  let frames =
    current.triggers
    |> dict.values
    |> list.filter(fn(stored) { matches(stored, source, rule) })
    |> list.sort(fn(a, b) {
      case int.compare(a.trigger.at_ms, b.trigger.at_ms) {
        order.Eq -> string.compare(a.trigger.id.value, b.trigger.id.value)
        other -> other
      }
    })
    |> list.map(fn(stored) { frame_of(current, stored, text_of) })
  Tape(source:, rule:, frames:)
}

/// Whether a stored trigger belongs to the source and rule.
fn matches(stored: TriggerRecord, source: SourceId, rule: RuleId) -> Bool {
  stored.trigger.source == source
  && option.map(stored.trigger.inputs.rule, fn(matched) { matched.rule })
  == option.Some(rule)
}

/// Fix one frame from the state. The thread is cut at the trigger, which is
/// the step that keeps later entries out.
fn frame_of(
  current: State,
  stored: TriggerRecord,
  text_of: fn(TriggerId) -> String,
) -> Frame {
  let trigger = stored.trigger
  let thread = as_it_stood(current, trigger)
  Frame(
    trigger:,
    text: text_of(trigger.id),
    relation: relation_at(current, trigger, thread),
    thread:,
    recorded: recorded_of(stored.fate),
  )
}

/// The entries of the trigger's thread from the trigger itself back to the
/// first. Entries are kept newest first and never rewritten, so dropping what
/// precedes the trigger's own entry removes exactly what arrived later.
fn as_it_stood(current: State, trigger: Trigger) -> List(ThreadEntry) {
  case dict.get(current.threads, trigger.thread) {
    Error(Nil) -> []
    Ok(found) -> held_from(found, trigger.id)
  }
}

fn held_from(found: Thread, id: TriggerId) -> List(ThreadEntry) {
  list.drop_while(found.entries, fn(entry) { entry.trigger != id })
}

/// Whether the sender owned a ticket on the thread when the trigger arrived.
/// A ticket existed then when the trigger that opened it, or one it was
/// handed, is among the entries older than this one. Subscriptions are not
/// timestamped, so this is the state's own record of the same fact the gate
/// read at arrival.
fn relation_at(
  current: State,
  trigger: Trigger,
  thread: List(ThreadEntry),
) -> gate.ThreadRelation {
  let older =
    list.filter_map(thread, fn(entry) {
      case entry.trigger == trigger.id {
        True -> Error(Nil)
        False -> Ok(entry.trigger)
      }
    })
  let owns =
    current.subscriptions
    |> list.filter(fn(link) { link.thread == trigger.thread })
    |> list.filter_map(fn(link) { dict.get(current.tickets, link.ticket) })
    |> list.any(fn(ticket) {
      ticket.mandate.actor == trigger.actor && names_any(ticket, older)
    })

  // Owning a ticket on the thread is what turns a follow-up explicit.
  case owns {
    True -> gate.OwnTicketThread
    False -> gate.UnrelatedThread
  }
}

fn names_any(ticket: Ticket, older: List(TriggerId)) -> Bool {
  list.contains(older, ticket.origin)
  || list.any(ticket.routings, fn(routing) {
    list.contains(older, routing.trigger)
  })
}

/// What the trigger's fate says the router answered.
fn recorded_of(fate: state.Fate) -> Recorded {
  case fate {
    state.Decided(state.Accepted(_)) -> Took
    state.Decided(state.Attached(_)) -> Took
    state.Decided(state.Resumed(_)) -> Took
    state.Decided(state.StoppedTicket(_)) -> Took
    state.Decided(state.Delivered(_)) -> Took
    state.Decided(state.WouldAccept) -> Took
    state.Decided(state.Ignored) -> Declined
    state.Decided(state.OwnMessage) -> NotAsked
    state.Decided(state.RecordedOnly) -> NotAsked
    state.Decided(state.Shed) -> NotAsked
    state.Decided(state.Held(_)) -> NotAsked
    state.Decided(state.Unrouted(_)) -> NotAsked
    state.Awaiting | state.Offered -> NotAsked
  }
}

// --- the document -------------------------------------------------------------

/// Write a tape as one JSON document.
///
/// ## Examples
///
/// ```gleam
/// let empty = tape.Tape(model.SourceId("s"), model.RuleId("r"), [])
/// assert tape.decode(tape.encode(empty)) == Ok(empty)
/// ```
pub fn encode(found: Tape) -> String {
  json.object([
    #("source", json.string(found.source.value)),
    #("rule", json.string(found.rule.value)),
    #("frames", json.array(found.frames, frame_json)),
  ])
  |> json.to_string
}

/// Read a tape back. Total: any text that is not a tape is `Malformed`.
///
/// ## Examples
///
/// ```gleam
/// assert tape.decode("nonsense") == Error(tape.Malformed)
/// ```
pub fn decode(text: String) -> Result(Tape, TapeError) {
  json.parse(text, tape_decoder())
  |> result.replace_error(Malformed)
}

/// One frame as a JSON object. The thread keeps its order, newest first, and
/// records for each entry only whether the gate let it through.
fn frame_json(frame: Frame) -> Json {
  json.object([
    #("trigger", codec.trigger_json(frame.trigger)),
    #("text", json.string(frame.text)),
    #("relation", json.string(relation_word(frame.relation))),
    #(
      "thread",
      json.array(frame.thread, fn(entry) {
        json.object([
          #("trigger", json.string(entry.trigger.value)),
          #("received", json.bool(entry.reception == model.Received)),
        ])
      }),
    ),
    #("recorded", json.string(recorded_word(frame.recorded))),
  ])
}

/// Reads a whole tape. A missing field fails the document.
fn tape_decoder() -> Decoder(Tape) {
  use source <- decode.field(
    "source",
    decode.map(decode.string, model.SourceId),
  )
  use rule <- decode.field("rule", decode.map(decode.string, model.RuleId))
  use frames <- decode.field("frames", decode.list(frame_decoder()))
  decode.success(Tape(source:, rule:, frames:))
}

/// Reads one frame. The trigger goes through the codec's own decoder, so a
/// trigger in a tape is read exactly as one in the ledger is.
fn frame_decoder() -> Decoder(Frame) {
  use trigger <- decode.field("trigger", codec.trigger_decoder())
  use text <- decode.field("text", decode.string)
  use relation <- decode.field("relation", relation_decoder())
  use thread <- decode.field("thread", decode.list(entry_decoder()))
  use recorded <- decode.field("recorded", recorded_decoder())
  decode.success(Frame(trigger:, text:, relation:, thread:, recorded:))
}

/// Reads one entry of a frame's thread, in the order it was written.
fn entry_decoder() -> Decoder(ThreadEntry) {
  use trigger <- decode.field("trigger", decode.map(decode.string, TriggerId))
  use received <- decode.field("received", decode.bool)
  decode.success(
    ThreadEntry(trigger:, reception: case received {
      True -> model.Received
      False -> model.Recorded
    }),
  )
}

/// The word a frame's thread relation is written as.
fn relation_word(relation: gate.ThreadRelation) -> String {
  case relation {
    gate.OwnTicketThread -> "own"
    gate.UnrelatedThread -> "unrelated"
  }
}

/// Reads a thread relation from its word. Any other word fails the decode.
fn relation_decoder() -> Decoder(gate.ThreadRelation) {
  use word <- decode.then(decode.string)

  // The fallback value only types the failure; the decode still fails.
  case word {
    "own" -> decode.success(gate.OwnTicketThread)
    "unrelated" -> decode.success(gate.UnrelatedThread)
    _ -> decode.failure(gate.UnrelatedThread, "ThreadRelation")
  }
}

/// The word a recorded answer is written as.
fn recorded_word(recorded: Recorded) -> String {
  case recorded {
    Took -> "took"
    Declined -> "declined"
    NotAsked -> "not_asked"
  }
}

/// Reads a recorded answer from its word. Any other word fails the decode.
fn recorded_decoder() -> Decoder(Recorded) {
  use word <- decode.then(decode.string)

  // The fallback value only types the failure; the decode still fails.
  case word {
    "took" -> decode.success(Took)
    "declined" -> decode.success(Declined)
    "not_asked" -> decode.success(NotAsked)
    _ -> decode.failure(NotAsked, "Recorded")
  }
}
