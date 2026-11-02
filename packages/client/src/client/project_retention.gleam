//// What the project actor keeps when it compacts its ledger, and the document
//// it keeps it in (protocol-change/106, "Durable state").
////
//// The ledger is append-only, so a project that lives for months grows without
//// bound unless it forgets. The actor forgets once a day. It asks
//// `project/snapshot.retire` which tickets and triggers no later event can
//// name, writes the engine's state without them as a snapshot, and has the
//// ledger delete every event below the snapshot's point in the same
//// transaction (`storage/project_ledger.compact_before`). A restart reads the
//// snapshot and replays only the events after it.
////
//// The engine's state is only half of what the actor knows. A trigger's text,
//// a worker's question, the router's queued replies and the record that a
//// passing check names are host records in the ledger, and deleting the events
//// below the snapshot would delete them too. So the snapshot document carries
//// the host records that still matter, as the lines they were written as, and
//// a restart folds them back through the same function that replays them. This
//// module decides which lines still matter and reads and writes the document.
////
//// ## Flow
////
//// `select_records` → `encode` → `decode` → `gone`
////
//// 1. `select_records` keeps the records of tickets and triggers that stayed,
////    the newest queued replies and the latest note.
//// 2. `encode` writes them with the state, the arrival entries and the
////    decisions kept for what was dropped; `decode` reads the document at the
////    next start.
//// 3. `gone` turns the retention rule's dropped triggers into decisions, each
////    with the ledger entry its trigger arrived at.
////
//// ## What a decision keeps
////
//// A dropped trigger's text is gone, and what is kept of it is what a person
//// asks later: how it ended, which ticket it named, when it arrived and the
//// ledger entry it arrived at. The list is bounded at `max_gone`, oldest
//// first to go, so even a project that never stops receiving comments does
//// not grow without bound.

import client/project_records.{type Record}
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import project/model
import project/snapshot.{type Retired}
import project/state.{type State}

/// How old a trigger or an ended ticket must be before retention drops it, in
/// milliseconds: thirty days. A merged ticket's pull request can still draw a
/// comment that resumes it, and a month is the window the owner has to say so.
pub const retain_ms = 2_592_000_000

/// How often the actor compacts, in milliseconds: daily.
pub const day_ms = 86_400_000

/// The fewest events since the last compaction that make another worth its
/// pause. A project that did nothing all day does not rewrite its ledger.
pub const min_events = 200

/// The most queued replies a snapshot keeps. The board shows the newest.
const max_replies = 100

/// The most dropped triggers whose decisions are kept.
pub const max_gone = 20_000

/// What became of a trigger that retention dropped.
pub type Gone {
  Gone(
    /// The trigger's id.
    trigger: String,
    /// How it ended, in the engine's words.
    decision: String,
    /// The ticket the decision names, when it names one.
    ticket: Option(String),
    /// When it arrived, in system milliseconds.
    at_ms: Int,
    /// The ledger entry it arrived at. The entry itself is gone with the
    /// events below the snapshot; the number says where in the history the
    /// decision's trigger began.
    entry: Int,
  )
}

/// What a snapshot holds besides the engine's state.
pub type Document {
  Document(
    /// The engine's state as `project/snapshot.encode` wrote it.
    state: String,
    /// The host records that still matter, as the ledger lines they were
    /// written as, oldest first.
    records: List(String),
    /// The ledger entry each remaining trigger arrived at.
    arrivals: List(#(String, Int)),
    /// What became of the triggers dropped so far.
    gone: List(Gone),
  )
}

// --- choosing records ---------------------------------------------------------

/// The ledger lines of the host records that still matter once `kept` is the
/// state, oldest first. Engine events are not records and are left out.
///
/// A record stays when the ticket or trigger it is about stays. The router's
/// queued replies are kept to the newest `max_replies`, and of the notes about
/// a source only the latest stays. Of the template's records the latest build
/// and the latest failure stay, in their order, which is all a replay needs to
/// know whether the template is ready and whether a rebuild has failed since. The marker a compaction writes about itself
/// does not.
///
/// ## Examples
///
/// ```gleam
/// assert project_retention.select_records([], state.start(config)) == []
/// ```
pub fn select_records(lines: List(String), kept: State) -> List(String) {
  let parsed =
    list.filter_map(lines, fn(text) {
      case project_records.decode_line(text) {
        Ok(project_records.Host(record)) -> Ok(#(text, record))
        Ok(project_records.Engine(_)) | Error(_) -> Error(Nil)
      }
    })
  let stays = list.filter(parsed, fn(entry) { stays(entry.1, kept) })
  let replies = latest(stays, is_reply, max_replies)
  let notes = latest(stays, is_note, 1)
  let builds = latest(stays, is_template_build, 1)
  let failures = latest(stays, is_template_failure, 1)
  list.filter(stays, fn(entry) {
    case is_reply(entry.1), is_note(entry.1) {
      True, _ -> list.contains(replies, entry.0)
      _, True -> list.contains(notes, entry.0)
      False, False ->
        case is_template_build(entry.1), is_template_failure(entry.1) {
          True, _ -> list.contains(builds, entry.0)
          _, True -> list.contains(failures, entry.0)
          False, False -> True
        }
    }
  })
  |> list.map(fn(entry) { entry.0 })
}

/// Whether a record's subject is still in the state.
fn stays(record: Record, kept: State) -> Bool {
  case record {
    project_records.TriggerText(trigger:, ..) -> text_stays(trigger, kept)
    project_records.QuestionText(ticket:, ..) -> ticket_stays(ticket, kept)
    project_records.HandedBack(ticket:, ..) -> ticket_stays(ticket, kept)
    project_records.Recovered(ticket:, ..) -> ticket_stays(ticket, kept)
    project_records.CheckRecorded(ticket:, ..) -> ticket_stays(ticket, kept)
    project_records.TreeKept(ticket:, ..) -> ticket_stays(ticket, kept)
    project_records.ReplyQueued(..) -> True
    project_records.SourceNote(..) -> True
    project_records.TemplateBuilt(..) -> True
    project_records.TemplateFailed(..) -> True
    project_records.Retention(..) -> False
  }
}

fn ticket_stays(ticket: String, kept: State) -> Bool {
  dict.has_key(kept.tickets, ticket_id(ticket))
}

/// A trigger's text stays with the trigger. A person's answer is a text with a
/// key that is not a trigger (`a~<ticket>~<question>`), so it stays with its
/// ticket.
fn text_stays(trigger: String, kept: State) -> Bool {
  case string.split(trigger, "~") {
    ["a", ticket, _] -> ticket_stays(ticket, kept)
    _ -> dict.has_key(kept.triggers, trigger_id(trigger))
  }
}

fn ticket_id(text: String) -> model.TicketId {
  model.TicketId(text)
}

fn trigger_id(text: String) -> model.TriggerId {
  model.TriggerId(text)
}

/// Whether a record is a reply the router queued.
fn is_reply(record: Record) -> Bool {
  case record {
    project_records.ReplyQueued(..) -> True
    project_records.TriggerText(..)
    | project_records.QuestionText(..)
    | project_records.HandedBack(..)
    | project_records.Recovered(..)
    | project_records.CheckRecorded(..)
    | project_records.SourceNote(..)
    | project_records.TreeKept(..)
    | project_records.TemplateBuilt(..)
    | project_records.TemplateFailed(..)
    | project_records.Retention(..) -> False
  }
}

/// Whether a record is a note about a source's last pass.
fn is_note(record: Record) -> Bool {
  case record {
    project_records.SourceNote(..) -> True
    project_records.TriggerText(..)
    | project_records.QuestionText(..)
    | project_records.HandedBack(..)
    | project_records.Recovered(..)
    | project_records.CheckRecorded(..)
    | project_records.ReplyQueued(..)
    | project_records.TreeKept(..)
    | project_records.TemplateBuilt(..)
    | project_records.TemplateFailed(..)
    | project_records.Retention(..) -> False
  }
}

/// Whether a record says the template was built.
fn is_template_build(record: Record) -> Bool {
  case record {
    project_records.TemplateBuilt(..) -> True
    _ -> False
  }
}

/// Whether a record says a template build failed.
fn is_template_failure(record: Record) -> Bool {
  case record {
    project_records.TemplateFailed(..) -> True
    _ -> False
  }
}

/// The lines of the last `count` entries that satisfy `wanted`.
fn latest(
  entries: List(#(String, Record)),
  wanted: fn(Record) -> Bool,
  count: Int,
) -> List(String) {
  entries
  |> list.filter(fn(entry) { wanted(entry.1) })
  |> list.reverse
  |> list.take(count)
  |> list.map(fn(entry) { entry.0 })
}

// --- decisions ----------------------------------------------------------------

/// The decisions to keep for the triggers retention just dropped, each with
/// the ledger entry it arrived at, or `boundary` when the host no longer knows
/// that entry. `earlier` is what was kept before; the result is bounded at
/// `max_gone`, the oldest going first.
///
/// ## Examples
///
/// ```gleam
/// assert project_retention.gone([], dict.new(), 9, []) == []
/// ```
pub fn gone(
  dropped: List(Retired),
  arrivals: Dict(String, Int),
  boundary: Int,
  earlier: List(Gone),
) -> List(Gone) {
  let fresh =
    list.map(dropped, fn(each) {
      Gone(
        trigger: each.trigger.value,
        decision: each.decision,
        ticket: option.map(each.ticket, fn(found) { found.value }),
        at_ms: each.at_ms,
        entry: result.unwrap(dict.get(arrivals, each.trigger.value), boundary),
      )
    })
  list.append(earlier, fresh)
  |> list.sort(fn(a, b) {
    case int.compare(a.at_ms, b.at_ms) {
      order.Eq -> string.compare(a.trigger, b.trigger)
      other -> other
    }
  })
  |> keep_newest(max_gone)
}

/// The last `count` of a list that is in time order: the oldest go first.
fn keep_newest(entries: List(Gone), count: Int) -> List(Gone) {
  let extra = list.length(entries) - count

  // Only a list over the bound loses its head.
  case extra > 0 {
    True -> list.drop(entries, extra)
    False -> entries
  }
}

// --- the document -------------------------------------------------------------

/// Writes the document as the text the ledger stores in its snapshot row.
///
/// ## Examples
///
/// ```gleam
/// let document = project_retention.Document("{}", [], [], [])
/// assert project_retention.decode(project_retention.encode(document)) == Ok(document)
/// ```
pub fn encode(document: Document) -> String {
  json.object([
    #("v", json.int(1)),
    #("state", json.string(document.state)),
    #("records", json.array(document.records, json.string)),
    #(
      "arrivals",
      json.array(document.arrivals, fn(entry) {
        json.object([
          #("trigger", json.string(entry.0)),
          #("entry", json.int(entry.1)),
        ])
      }),
    ),
    #("gone", json.array(document.gone, gone_json)),
  ])
  |> json.to_string
}

/// One kept decision, with the ticket it names or `null`.
fn gone_json(found: Gone) -> json.Json {
  json.object([
    #("trigger", json.string(found.trigger)),
    #("decision", json.string(found.decision)),
    #("ticket", json.nullable(found.ticket, json.string)),
    #("at_ms", json.int(found.at_ms)),
    #("entry", json.int(found.entry)),
  ])
}

/// Reads a document back. Total: text that is not one is an error that names
/// no more than that, and the actor refuses to start on it.
///
/// ## Examples
///
/// ```gleam
/// assert project_retention.decode("nonsense") == Error("the snapshot is not a project snapshot")
/// ```
pub fn decode(text: String) -> Result(Document, String) {
  json.parse(text, document_decoder())
  |> result.replace_error("the snapshot is not a project snapshot")
}

/// The document's decoder. Every field is required, and only version 1 is
/// read.
fn document_decoder() -> decode.Decoder(Document) {
  use version <- decode.field("v", decode.int)
  use state <- decode.field("state", decode.string)
  use records <- decode.field("records", decode.list(decode.string))
  use arrivals <- decode.field("arrivals", decode.list(arrival_decoder()))
  use gone <- decode.field("gone", decode.list(gone_decoder()))

  // A document of a version this build does not know fails the decode, so a
  // downgrade cannot misread a newer layout.
  case version {
    1 -> decode.success(Document(state:, records:, arrivals:, gone:))
    _ -> decode.failure(Document("", [], [], []), "a version 1 snapshot")
  }
}

fn arrival_decoder() -> decode.Decoder(#(String, Int)) {
  use trigger <- decode.field("trigger", decode.string)
  use entry <- decode.field("entry", decode.int)
  decode.success(#(trigger, entry))
}

/// Reads one kept decision.
fn gone_decoder() -> decode.Decoder(Gone) {
  use trigger <- decode.field("trigger", decode.string)
  use decision <- decode.field("decision", decode.string)
  use ticket <- decode.field("ticket", decode.optional(decode.string))
  use at_ms <- decode.field("at_ms", decode.int)
  use entry <- decode.field("entry", decode.int)
  decode.success(Gone(trigger:, decision:, ticket:, at_ms:, entry:))
}

/// The decision kept for a trigger, if retention dropped it.
///
/// ## Examples
///
/// ```gleam
/// assert project_retention.find([], "gh-c-1") == None
/// ```
pub fn find(kept: List(Gone), trigger: String) -> Option(Gone) {
  case list.find(kept, fn(each) { each.trigger == trigger }) {
    Ok(found) -> Some(found)
    Error(Nil) -> None
  }
}
