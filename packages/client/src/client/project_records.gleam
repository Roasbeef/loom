//// What the project actor writes beside the engine's events: the host
//// records, and the jobs that an event's effects become.
////
//// The engine's events carry references and no text. A trigger's body, a
//// worker's question and a router's reply have to live somewhere, and the
//// ledger is the one durable place the actor owns, so they are written into
//// the same ordered history as host records, each a JSON object with a `host`
//// field that no engine event has. Replaying the ledger folds the engine
//// events through `engine.apply` and rebuilds the text tables from the host
//// records, so the two agree because they come from one sequence.
////
//// A `Job` is the other half: the engine's `Effect` reduced to what the
//// actor needs to perform it again after a restart. Each job has a kind and a
//// key derived from the event that caused it (`project_ledger.EffectDraft`),
//// so writing the same intent twice leaves one row.

import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import project/codec
import project/event.{type Effect, type Event}
import project/policy
import storage/project_ledger

/// A line of the ledger: an engine event, or something the host recorded.
pub type Line {
  /// An event the engine applied.
  Engine(event: Event)

  /// A host record.
  Host(record: Record)
}

/// What the host records beside the engine's events.
pub type Record {
  /// The body of a trigger and the attribution its source gave. The engine
  /// stores the trigger's identity and the host stores what it said.
  TriggerText(
    /// The trigger.
    trigger: String,
    /// The source's name.
    source: String,
    /// The actor the source names.
    actor: String,
    /// The text.
    body: String,
  )

  /// The question a worker asked beside a `waiting` report.
  QuestionText(
    /// The ticket.
    ticket: String,
    /// The question's sequence number, as the engine recorded it.
    question: Int,
    /// The text.
    body: String,
  )

  /// A reply the router queued.
  ReplyQueued(
    /// The trigger answered.
    subject: String,
    /// The purpose word.
    purpose: String,
    /// The text.
    body: String,
  )

  /// A worker handed an input back.
  HandedBack(
    /// The ticket.
    ticket: String,
    /// The input.
    trigger: String,
    /// The worker's reason.
    reason: String,
  )
}

/// What the actor does for one effect.
pub type Job {
  /// Create or recover the worker session under `key` and bind it.
  StartJob(
    /// The ticket.
    ticket: String,
    /// The assignment.
    seq: Int,
    /// The idempotency key.
    key: String,
  )

  /// Hand a stored trigger to the assignment's worker.
  DeliverJob(
    /// The ticket.
    ticket: String,
    /// The assignment.
    seq: Int,
    /// The trigger.
    trigger: String,
  )

  /// Show the router these candidates.
  OfferJob(
    /// The candidates in order.
    triggers: List(String),
  )

  /// A check the host does not run yet; the row is logged and settled.
  CheckJob(
    /// The ticket.
    ticket: String,
  )

  /// A pull request the host does not open yet; logged and settled.
  PullRequestJob(
    /// The ticket.
    ticket: String,
  )

  /// End the assignment's session.
  StopJob(
    /// The ticket.
    ticket: String,
    /// The assignment.
    seq: Int,
  )

  /// Tell the worker a person answered; logged and settled in this slice.
  AnswerJob(
    /// The ticket.
    ticket: String,
    /// The assignment.
    seq: Int,
  )
}

/// A time no due scan reaches, for rows the host keeps for reading and never
/// performs.
pub const never_ms = 9_000_000_000_000_000

/// Writes an engine event as a ledger line.
///
/// ## Examples
///
/// ```gleam
/// assert project_records.decode_line(project_records.encode_event(event.RouterTurnEnded))
///   == Ok(project_records.Engine(event.RouterTurnEnded))
/// ```
pub fn encode_event(incoming: Event) -> String {
  codec.encode(incoming)
}

/// Writes a host record as a ledger line.
///
/// ## Examples
///
/// ```gleam
/// let line = project_records.encode_record(project_records.HandedBack("t", "c", "r"))
/// assert project_records.decode_line(line)
///   == Ok(project_records.Host(project_records.HandedBack("t", "c", "r")))
/// ```
pub fn encode_record(record: Record) -> String {
  record_json(record) |> json.to_string
}

fn record_json(record: Record) -> Json {
  case record {
    TriggerText(trigger:, source:, actor:, body:) ->
      json.object([
        #("host", json.string("text")),
        #("trigger", json.string(trigger)),
        #("source", json.string(source)),
        #("actor", json.string(actor)),
        #("body", json.string(body)),
      ])
    QuestionText(ticket:, question:, body:) ->
      json.object([
        #("host", json.string("question")),
        #("ticket", json.string(ticket)),
        #("question", json.int(question)),
        #("body", json.string(body)),
      ])
    ReplyQueued(subject:, purpose:, body:) ->
      json.object([
        #("host", json.string("reply")),
        #("subject", json.string(subject)),
        #("purpose", json.string(purpose)),
        #("body", json.string(body)),
      ])
    HandedBack(ticket:, trigger:, reason:) ->
      json.object([
        #("host", json.string("handback")),
        #("ticket", json.string(ticket)),
        #("trigger", json.string(trigger)),
        #("reason", json.string(reason)),
      ])
  }
}

/// Reads a ledger line. A line with a `host` field is a host record and any
/// other line must be an engine event; text that is neither is an error, and
/// the caller refuses to start on it.
///
/// ## Examples
///
/// ```gleam
/// assert project_records.decode_line("nonsense") == Error("not a ledger line")
/// ```
pub fn decode_line(text: String) -> Result(Line, String) {
  case json.parse(text, host_decoder()) {
    Ok(record) -> Ok(Host(record))
    Error(_) ->
      case codec.decode(text) {
        Ok(found) -> Ok(Engine(found))
        Error(codec.Malformed) -> Error("not a ledger line")
      }
  }
}

fn host_decoder() -> decode.Decoder(Record) {
  use kind <- decode.field("host", decode.string)
  case kind {
    "text" -> {
      use trigger <- decode.field("trigger", decode.string)
      use source <- decode.field("source", decode.string)
      use actor <- decode.field("actor", decode.string)
      use body <- decode.field("body", decode.string)
      decode.success(TriggerText(trigger:, source:, actor:, body:))
    }
    "question" -> {
      use ticket <- decode.field("ticket", decode.string)
      use question <- decode.field("question", decode.int)
      use body <- decode.field("body", decode.string)
      decode.success(QuestionText(ticket:, question:, body:))
    }
    "reply" -> {
      use subject <- decode.field("subject", decode.string)
      use purpose <- decode.field("purpose", decode.string)
      use body <- decode.field("body", decode.string)
      decode.success(ReplyQueued(subject:, purpose:, body:))
    }
    "handback" -> {
      use ticket <- decode.field("ticket", decode.string)
      use trigger <- decode.field("trigger", decode.string)
      use reason <- decode.field("reason", decode.string)
      decode.success(HandedBack(ticket:, trigger:, reason:))
    }
    _ -> decode.failure(HandedBack("", "", ""), "a known host record")
  }
}

// --- effects as jobs ---------------------------------------------------------

/// The ledger row an effect becomes, keyed by the event that caused it. The
/// event's sequence number joins the key of effects that no other fact names,
/// so a repeat of the same event writes the same row.
///
/// ## Examples
///
/// ```gleam
/// // project_records.draft(7, 1_700_000_000_000, event.OfferCandidates([]))
/// ```
pub fn draft(
  seq: Int,
  now_ms: Int,
  effect: Effect,
) -> project_ledger.EffectDraft {
  case effect {
    event.StartSession(ticket:, seq: assignment, key:, mandate:) -> {
      let recorded = policy.for_mandate(mandate)
      row(
        "start",
        key,
        [
          #("ticket", json.string(ticket.value)),
          #("seq", json.int(assignment)),
          #("key", json.string(key)),
          #("policy", json.string(policy_text(recorded))),
        ],
        now_ms,
      )
    }
    event.Deliver(ticket:, seq: assignment, trigger:) ->
      row(
        "deliver",
        ticket.value <> ":" <> int.to_string(assignment) <> ":" <> trigger.value,
        [
          #("ticket", json.string(ticket.value)),
          #("seq", json.int(assignment)),
          #("trigger", json.string(trigger.value)),
        ],
        now_ms,
      )
    event.OfferCandidates(triggers:) ->
      row(
        "offer",
        int.to_string(seq),
        [
          #(
            "triggers",
            json.array(triggers, fn(each) { json.string(each.value) }),
          ),
        ],
        now_ms,
      )
    event.RequestCheck(ticket:, commit:) ->
      row(
        "check",
        ticket.value <> ":" <> commit.value,
        [#("ticket", json.string(ticket.value))],
        now_ms,
      )
    event.OpenPullRequest(ticket:, branch: _, commit:) ->
      row(
        "pull_request",
        ticket.value <> ":" <> commit.value,
        [#("ticket", json.string(ticket.value))],
        now_ms,
      )
    event.StopSession(ticket:, seq: assignment) ->
      row(
        "stop",
        ticket.value <> ":" <> int.to_string(assignment),
        [
          #("ticket", json.string(ticket.value)),
          #("seq", json.int(assignment)),
        ],
        now_ms,
      )
    event.RelayAnswer(ticket:, seq: assignment, question:) ->
      row(
        "answer",
        ticket.value
          <> ":"
          <> int.to_string(assignment)
          <> ":"
          <> int.to_string(question),
        [
          #("ticket", json.string(ticket.value)),
          #("seq", json.int(assignment)),
        ],
        now_ms,
      )
  }
}

fn row(
  kind: String,
  key: String,
  fields: List(#(String, Json)),
  now_ms: Int,
) -> project_ledger.EffectDraft {
  project_ledger.EffectDraft(
    kind:,
    key:,
    payload_json: json.to_string(json.object(fields)),
    due_ms: now_ms,
  )
}

// The policy the Mandate derived, recorded with the start so a reader of the
// ledger sees what the worker was meant to get. Enforcement by the broker is a
// later slice; this slice records the result and does not apply it.
fn policy_text(found: policy.WorkerPolicy) -> String {
  let network = case found.network {
    policy.RegistriesOnly -> "registries_only"
    policy.OwnerSessionPolicy -> "owner_session_policy"
  }
  let approvals = case found.approvals {
    policy.ApprovalsRefused -> "refused"
    policy.ApprovalsToPerson -> "to_person"
  }
  "network=" <> network <> " credentials=none approvals=" <> approvals
}

/// Reads a queued row back into the job it stands for.
///
/// ## Examples
///
/// ```gleam
/// assert project_records.job(project_ledger.Effect("nonsense", "k", "{}", 0, 0))
///   == Error("unknown job kind nonsense")
/// ```
pub fn job(found: project_ledger.Effect) -> Result(Job, String) {
  let payload = found.payload_json
  case found.kind {
    "start" ->
      parse(payload, {
        use ticket <- decode.field("ticket", decode.string)
        use seq <- decode.field("seq", decode.int)
        use key <- decode.field("key", decode.string)
        decode.success(StartJob(ticket:, seq:, key:))
      })
    "deliver" ->
      parse(payload, {
        use ticket <- decode.field("ticket", decode.string)
        use seq <- decode.field("seq", decode.int)
        use trigger <- decode.field("trigger", decode.string)
        decode.success(DeliverJob(ticket:, seq:, trigger:))
      })
    "offer" ->
      parse(payload, {
        use triggers <- decode.field("triggers", decode.list(decode.string))
        decode.success(OfferJob(triggers:))
      })
    "check" ->
      parse(payload, {
        use ticket <- decode.field("ticket", decode.string)
        decode.success(CheckJob(ticket:))
      })
    "pull_request" ->
      parse(payload, {
        use ticket <- decode.field("ticket", decode.string)
        decode.success(PullRequestJob(ticket:))
      })
    "stop" ->
      parse(payload, {
        use ticket <- decode.field("ticket", decode.string)
        use seq <- decode.field("seq", decode.int)
        decode.success(StopJob(ticket:, seq:))
      })
    "answer" ->
      parse(payload, {
        use ticket <- decode.field("ticket", decode.string)
        use seq <- decode.field("seq", decode.int)
        decode.success(AnswerJob(ticket:, seq:))
      })
    other -> Error("unknown job kind " <> other)
  }
}

fn parse(payload: String, decoder: decode.Decoder(Job)) -> Result(Job, String) {
  case json.parse(payload, decoder) {
    Ok(found) -> Ok(found)
    Error(_) -> Error("malformed job payload")
  }
}

/// Every job a list of effects stands for, as ledger rows.
///
/// ## Examples
///
/// ```gleam
/// assert project_records.drafts(1, 0, []) == []
/// ```
pub fn drafts(
  seq: Int,
  now_ms: Int,
  effects: List(Effect),
) -> List(project_ledger.EffectDraft) {
  list.map(effects, fn(each) { draft(seq, now_ms, each) })
}
