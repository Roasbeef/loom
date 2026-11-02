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
import gleam/string
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

  /// The actor queued a recovery note for an assignment that a restart
  /// interrupted. The record is what makes a second restart queue none: the
  /// pair is in the history, and replay puts it in the actor's set.
  Recovered(
    /// The ticket.
    ticket: String,
    /// The assignment.
    seq: Int,
  )

  /// The host ran the project's check at a commit, or could not. The record
  /// is what a passing check's entry id names, so the proof in the engine's
  /// event points at a line that says what ran and what it printed.
  CheckRecorded(
    /// The ticket.
    ticket: String,
    /// The commit the check ran against.
    commit: String,
    /// The command, as the project's policy gave it.
    command: String,
    /// `passed`, `failed` or `unfinished`.
    outcome: String,
    /// The bounded tail of what the check printed, or why it did not finish.
    detail: String,
  )

  /// What a source's last pass left for a person to read: a rate limit's end,
  /// an answer GitHub gave that could not be read, items skipped. The host
  /// writes one only when the words change, so a source that stays broken for
  /// a day adds one line and not one for every poll.
  SourceNote(
    /// The source's name.
    source: String,
    /// The words, capped. Empty when the source recovered.
    text: String,
  )

  /// The marker a compaction writes about itself, so that the event it
  /// compacts to is never the engine's newest and the ledger's numbering
  /// continues past the point. It changes no table.
  Retention(
    /// How many triggers the compaction dropped.
    dropped: Int,
  )

  /// An assignment's worktree was kept when its ticket ended, because it held
  /// commits its base lacks. The board names it from this record.
  TreeKept(
    /// The ticket.
    ticket: String,
    /// The assignment.
    seq: Int,
    /// Where the worktree is.
    path: String,
    /// Why it stayed.
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

  /// Read the head of the idle worker's branch and report it.
  ObserveJob(
    /// The ticket.
    ticket: String,
    /// The assignment whose worktree to read.
    seq: Int,
  )

  /// Run the project's check at a commit.
  CheckJob(
    /// The ticket.
    ticket: String,
    /// The commit to check.
    commit: String,
  )

  /// Push the ticket's branch at a commit and open its pull request.
  PublishJob(
    /// The ticket.
    ticket: String,
    /// The commit to publish.
    commit: String,
  )

  /// End the assignment's session.
  StopJob(
    /// The ticket.
    ticket: String,
    /// The assignment.
    seq: Int,
  )

  /// Tell a worker that a restart interrupted its assignment.
  RecoverJob(
    /// The ticket.
    ticket: String,
    /// The assignment.
    seq: Int,
  )

  /// Post a router's reply to a GitHub issue or pull request as a comment.
  ReplyJob(
    /// The trigger the reply answers.
    subject: String,
    /// The issue or pull request number, from the subject's thread.
    number: Int,
    /// The purpose word, which sets the word cap.
    purpose: String,
    /// The router's words, before they are made safe for GitHub.
    text: String,
    /// The reply's own key, which names its marker comment.
    key: String,
    /// When the reply was queued, so a search for its marker starts there.
    queued_ms: Int,
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

/// The ledger line of a host record. The `host` field names the variant, and
/// is also what `decode_line` uses to tell a host record from an engine event.
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
    Recovered(ticket:, seq:) ->
      json.object([
        #("host", json.string("recovered")),
        #("ticket", json.string(ticket)),
        #("seq", json.int(seq)),
      ])
    CheckRecorded(ticket:, commit:, command:, outcome:, detail:) ->
      json.object([
        #("host", json.string("check")),
        #("ticket", json.string(ticket)),
        #("commit", json.string(commit)),
        #("command", json.string(command)),
        #("outcome", json.string(outcome)),
        #("detail", json.string(detail)),
      ])
    Retention(dropped:) ->
      json.object([
        #("host", json.string("retention")),
        #("dropped", json.int(dropped)),
      ])
    SourceNote(source:, text:) ->
      json.object([
        #("host", json.string("source_note")),
        #("source", json.string(source)),
        #("text", json.string(text)),
      ])
    TreeKept(ticket:, seq:, path:, reason:) ->
      json.object([
        #("host", json.string("tree_kept")),
        #("ticket", json.string(ticket)),
        #("seq", json.int(seq)),
        #("path", json.string(path)),
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

/// Decodes a host record by its `host` word. A word it does not know fails the
/// decoder, which `decode_line` then reads as an engine event.
fn host_decoder() -> decode.Decoder(Record) {
  use kind <- decode.field("host", decode.string)

  // Each arm reads the fields its variant wrote in `record_json`.
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
    "recovered" -> {
      use ticket <- decode.field("ticket", decode.string)
      use seq <- decode.field("seq", decode.int)
      decode.success(Recovered(ticket:, seq:))
    }
    "check" -> {
      use ticket <- decode.field("ticket", decode.string)
      use commit <- decode.field("commit", decode.string)
      use command <- decode.field("command", decode.string)
      use outcome <- decode.field("outcome", decode.string)
      use detail <- decode.field("detail", decode.string)
      decode.success(CheckRecorded(
        ticket:,
        commit:,
        command:,
        outcome:,
        detail:,
      ))
    }
    "retention" -> {
      use dropped <- decode.field("dropped", decode.int)
      decode.success(Retention(dropped:))
    }
    "source_note" -> {
      use source <- decode.field("source", decode.string)
      use text <- decode.field("text", decode.string)
      decode.success(SourceNote(source:, text:))
    }
    "tree_kept" -> {
      use ticket <- decode.field("ticket", decode.string)
      use seq <- decode.field("seq", decode.int)
      use path <- decode.field("path", decode.string)
      use reason <- decode.field("reason", decode.string)
      decode.success(TreeKept(ticket:, seq:, path:, reason:))
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
  // The key of each row is built from the ids that make the effect unique, so
  // a repeat of the same event cannot queue a second copy of the same work.
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
    event.ObserveHead(ticket:, seq: assignment) ->
      row(
        "observe",
        ticket.value
          <> ":"
          <> int.to_string(assignment)
          <> ":"
          <> int.to_string(seq),
        [
          #("ticket", json.string(ticket.value)),
          #("seq", json.int(assignment)),
        ],
        now_ms,
      )
    event.RequestCheck(ticket:, commit:) ->
      row(
        "check",
        ticket.value <> ":" <> commit.value <> ":" <> int.to_string(seq),
        [
          #("ticket", json.string(ticket.value)),
          #("commit", json.string(commit.value)),
        ],
        now_ms,
      )
    event.PublishBranch(ticket:, branch: _, commit:) ->
      row(
        "publish",
        ticket.value <> ":" <> commit.value <> ":" <> int.to_string(seq),
        [
          #("ticket", json.string(ticket.value)),
          #("commit", json.string(commit.value)),
        ],
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
  }
}

/// The row that tells a worker its assignment was interrupted by a restart,
/// due at once. The key is the assignment, so the row is one per assignment.
///
/// ## Examples
///
/// ```gleam
/// assert project_records.recovery_draft("t-a", 1, 0).key == "t-a:1"
/// ```
pub fn recovery_draft(
  ticket: String,
  seq: Int,
  now_ms: Int,
) -> project_ledger.EffectDraft {
  row(
    "recover",
    ticket <> ":" <> int.to_string(seq),
    [#("ticket", json.string(ticket)), #("seq", json.int(seq))],
    now_ms,
  )
}

/// The row that posts a router's reply to GitHub, due at once. Its key leads
/// with the ledger position in twelve digits, so the rows of one thread sort
/// in the order the replies were queued, and the performer posts them in that
/// order.
///
/// ## Examples
///
/// ```gleam
/// assert project_records.github_reply_draft(7, "gh-c-1", 12, "clarify", "which one?", 0).key
///   == "000000000007:gh-c-1"
/// ```
pub fn github_reply_draft(
  seq: Int,
  subject: String,
  number: Int,
  purpose: String,
  text: String,
  now_ms: Int,
) -> project_ledger.EffectDraft {
  let key = string.pad_start(int.to_string(seq), 12, "0") <> ":" <> subject
  row(
    "github_reply",
    key,
    [
      #("subject", json.string(subject)),
      #("number", json.int(number)),
      #("purpose", json.string(purpose)),
      #("text", json.string(text)),
      #("key", json.string(key)),
      #("queued_ms", json.int(now_ms)),
    ],
    now_ms,
  )
}

/// An effect row due at `now_ms`, with its fields as a JSON object payload.
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

/// The policy the Mandate derived, recorded with the start so a reader of the
/// ledger sees what the worker was meant to get. Enforcement by the broker is a
/// later slice; this slice records the result and does not apply it.
fn policy_text(found: policy.WorkerPolicy) -> String {
  // The network posture as a word.
  let network = case found.network {
    policy.RegistriesOnly -> "registries_only"
    policy.OwnerSessionPolicy -> "owner_session_policy"
  }

  // The approvals posture as a word.
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

  // The kind word is the one `draft` wrote. An unknown kind is an error the
  // caller settles, since it can never decode later.
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
    "observe" ->
      parse(payload, {
        use ticket <- decode.field("ticket", decode.string)
        use seq <- decode.field("seq", decode.int)
        decode.success(ObserveJob(ticket:, seq:))
      })
    "check" ->
      parse(payload, {
        use ticket <- decode.field("ticket", decode.string)
        use commit <- decode.field("commit", decode.string)
        decode.success(CheckJob(ticket:, commit:))
      })
    "publish" ->
      parse(payload, {
        use ticket <- decode.field("ticket", decode.string)
        use commit <- decode.field("commit", decode.string)
        decode.success(PublishJob(ticket:, commit:))
      })
    "stop" ->
      parse(payload, {
        use ticket <- decode.field("ticket", decode.string)
        use seq <- decode.field("seq", decode.int)
        decode.success(StopJob(ticket:, seq:))
      })
    "recover" ->
      parse(payload, {
        use ticket <- decode.field("ticket", decode.string)
        use seq <- decode.field("seq", decode.int)
        decode.success(RecoverJob(ticket:, seq:))
      })
    "github_reply" ->
      parse(payload, {
        use subject <- decode.field("subject", decode.string)
        use number <- decode.field("number", decode.int)
        use purpose <- decode.field("purpose", decode.string)
        use text <- decode.field("text", decode.string)
        use key <- decode.field("key", decode.string)
        use queued_ms <- decode.field("queued_ms", decode.int)
        decode.success(ReplyJob(
          subject:,
          number:,
          purpose:,
          text:,
          key:,
          queued_ms:,
        ))
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
