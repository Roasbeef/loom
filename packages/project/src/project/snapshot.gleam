//// The engine's state as one JSON document, and the retention rule that
//// decides which of it to forget.
////
//// The ledger stores events, and replaying them rebuilds the state. That is
//// the whole crash story, and it makes the ledger grow for as long as the
//// project lives. Retention cuts the history: the ledger deletes every event
//// below a sequence number and keeps, in the same transaction, a snapshot of
//// the state those events built (`storage/project_ledger.compact_before`). A
//// restart then reads the snapshot and replays only the events after it. For
//// that to be sound, `decode` must read back exactly what `encode` wrote, so
//// `decode(config, encode(state)) == Ok(state)` is a property of this module
//// and the model-based test checks it on every state it reaches.
////
//// ## What retention forgets
////
//// `retire` drops what no later event can name. A ticket that ended and whose
//// opening message is older than the horizon is dropped with its
//// subscriptions. A trigger that was settled, is older than the horizon, is
//// named by no ticket that stays, and is neither queued nor offered is dropped
//// with its place on its thread. Each dropped trigger leaves a `Retired`
//// record, which keeps the decision, so a person can still ask what became of
//// it. Anything waiting for a person, such as an unrouted candidate, a would
//// accept record from the last horizon, or a ticket still open, stays.
////
//// ## What the document is not
////
//// The state's `Config` is not in it. The caller builds the config from the
//// project's row and the daemon's settings at every start, and `decode` takes
//// it, so changing `max_workers` needs no migration. Every decoder is total:
//// a field missing, a word not in a table or a tag not known is an error and
//// never a crash, and a snapshot that fails to decode stops the start, because
//// replaying from a state that never formed would be worse than not running.
////
//// ## Flow
////
//// `encode` → `decode` → `retire`
////
//// 1. `encode` writes the state as one document.
//// 2. `decode` reads it back with the caller's config, through a decoder per
////    shape, in the order the document nests them: triggers, threads, tickets,
////    then the project's controls.
//// 3. `retire` returns the state without what no later event can name, and
////    the decisions kept for each trigger it dropped.

import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import project/codec
import project/gate.{type Admission, Admitted, NotAdmitted}
import project/host
import project/model.{
  type Mandate, type Scope, type TicketId, type TriggerId, ActorId,
  CommandDigest, CommitId, EntryId, Mandate, PrincipalId, PullRequestRef, RuleId,
  Scope, SessionId, SourceId, ThreadId, TicketId, TriggerId,
}
import project/readiness
import project/state.{
  type Assignment, type Decision, type Fate, type State, type Ticket,
  type TriggerRecord, Assignment, Ticket, TriggerRecord,
}

/// Why a document could not be read.
pub type SnapshotError {
  /// The text is not JSON, or it does not have the shape `encode` writes.
  Malformed
}

/// What retention kept of a trigger it dropped.
pub type Retired {
  Retired(
    /// The dropped trigger.
    trigger: TriggerId,
    /// How its life ended, in the engine's words.
    decision: String,
    /// The ticket the decision names, when it names one.
    ticket: Option(TicketId),
    /// The system time the trigger arrived.
    at_ms: Int,
  )
}

// --- the document -------------------------------------------------------------

/// Write a state as one JSON document.
///
/// ## Examples
///
/// ```gleam
/// let current = state.start(config)
/// assert snapshot.decode(config, snapshot.encode(current)) == Ok(current)
/// ```
pub fn encode(current: State) -> String {
  json.object([
    #("policy_version", json.string(current.policy_version)),
    #(
      "triggers",
      json.array(sorted(dict.to_list(current.triggers)), fn(entry) {
        stored_json(entry.1)
      }),
    ),
    #(
      "threads",
      json.array(sorted(dict.to_list(current.threads)), fn(entry) {
        thread_json(entry.1)
      }),
    ),
    #("subscriptions", json.array(current.subscriptions, subscription_json)),
    #("order", json.array(current.order, fn(id) { json.string(id.value) })),
    #(
      "tickets",
      json.array(sorted(dict.to_list(current.tickets)), fn(entry) {
        ticket_json(entry.1)
      }),
    ),
    #("queue", json.array(current.queue, trigger_name)),
    #("offered", json.array(current.offered, trigger_name)),
    #(
      "offers",
      json.array(sorted(dict.to_list(current.offers)), fn(entry) {
        json.object([
          #("trigger", json.string({ entry.0 }.value)),
          #("count", json.int(entry.1)),
        ])
      }),
    ),
    #("router", word(routers, current.router)),
    #(
      "modes",
      json.array(sorted(dict.to_list(current.modes)), fn(entry) {
        json.object([
          #("source", json.string(entry.0.0.value)),
          #("rule", json.string(entry.0.1.value)),
          #("mode", word(modes, entry.1)),
        ])
      }),
    ),
    #(
      "verdicts",
      json.array(sorted(dict.to_list(current.verdicts)), fn(entry) {
        json.object([
          #("source", json.string(entry.0.0.value)),
          #("rule", json.string(entry.0.1.value)),
          #("pin", codec.pin_json({ entry.1 }.pin)),
          #("outcome", word(verdict_outcomes, { entry.1 }.outcome)),
          #("covers", codec.covers_json({ entry.1 }.covers)),
        ])
      }),
    ),
    #("prompt_revision", json.string(current.prompt_revision)),
    #("router_model", json.string(current.router_model)),
    #(
      "labels",
      json.array(sorted(dict.to_list(current.labels)), fn(entry) {
        json.object([
          #("trigger", json.string({ entry.0 }.value)),
          #("label", codec.label_json(entry.1)),
        ])
      }),
    ),
    #("ceiling", word(ceilings, current.ceiling)),
  ])
  |> json.to_string
}

/// Read a document back into a state with the given config. Total.
///
/// ## Examples
///
/// ```gleam
/// assert snapshot.decode(config, "nonsense") == Error(snapshot.Malformed)
/// ```
pub fn decode(
  config: state.Config,
  text: String,
) -> Result(State, SnapshotError) {
  json.parse(text, state_decoder(config))
  |> result.replace_error(Malformed)
}

/// Entries in a stable order, so the same state always writes the same text.
fn sorted(entries: List(#(key, value))) -> List(#(key, value)) {
  list.sort(entries, fn(a, b) {
    string.compare(string.inspect(a.0), string.inspect(b.0))
  })
}

/// The decoder of the whole document. It reads every list first and builds the
/// dictionaries last, so a duplicate id in a document collapses to one entry the
/// way a repeated insert would, and a field that is missing fails the document.
fn state_decoder(config: state.Config) -> Decoder(State) {
  use policy_version <- decode.field("policy_version", decode.string)
  use triggers <- decode.field("triggers", decode.list(stored_decoder()))
  use threads <- decode.field("threads", decode.list(thread_decoder()))
  use subscriptions <- decode.field(
    "subscriptions",
    decode.list(subscription_decoder()),
  )
  use order <- decode.field("order", decode.list(ticket_name()))
  use tickets <- decode.field("tickets", decode.list(ticket_decoder()))
  use queue <- decode.field("queue", decode.list(trigger_name_decoder()))
  use offered <- decode.field("offered", decode.list(trigger_name_decoder()))
  use offers <- decode.field("offers", decode.list(offer_decoder()))
  use router <- decode.field(
    "router",
    word_decoder(routers, state.RouterIdle, "RouterPhase"),
  )
  use modes_list <- decode.field("modes", decode.list(mode_entry_decoder()))
  use verdicts_list <- decode.field(
    "verdicts",
    decode.list(verdict_entry_decoder()),
  )

  // A document written before verdicts carried a pin and before labels
  // existed has none of these fields. The router's pin then reads as unset and
  // the labels as empty, which is the state such a ledger was in.
  use prompt_revision <- decode.optional_field(
    "prompt_revision",
    "",
    decode.string,
  )
  use router_model <- decode.optional_field("router_model", "", decode.string)
  use labels_list <- decode.optional_field(
    "labels",
    [],
    decode.list(label_entry_decoder()),
  )
  use ceiling <- decode.field(
    "ceiling",
    word_decoder(ceilings, model.CeilingClear, "Ceiling"),
  )
  decode.success(state.State(
    config:,
    policy_version:,
    triggers: dict.from_list(
      list.map(triggers, fn(stored) { #(stored.trigger.id, stored) }),
    ),
    threads: dict.from_list(
      list.map(threads, fn(thread) { #(thread.id, thread) }),
    ),
    subscriptions:,
    tickets: dict.from_list(
      list.map(tickets, fn(ticket) { #(ticket.id, ticket) }),
    ),
    order:,
    queue:,
    offered:,
    offers: dict.from_list(offers),
    router:,
    modes: dict.from_list(modes_list),
    verdicts: dict.from_list(verdicts_list),
    prompt_revision:,
    router_model:,
    labels: dict.from_list(labels_list),
    ceiling:,
  ))
}

// --- triggers -----------------------------------------------------------------

/// A stored trigger: the trigger as events write it, the gate's verdict that
/// was fixed when it arrived, and where it is in its life.
fn stored_json(stored: TriggerRecord) -> Json {
  json.object([
    #("trigger", codec.trigger_json(stored.trigger)),
    #("admission", admission_json(stored.admission)),
    #("fate", fate_json(stored.fate)),
  ])
}

fn stored_decoder() -> Decoder(TriggerRecord) {
  use trigger <- decode.field("trigger", codec.trigger_decoder())
  use admission <- decode.field("admission", admission_decoder())
  use fate <- decode.field("fate", fate_decoder())
  decode.success(TriggerRecord(trigger:, admission:, fate:))
}

/// The gate's verdict under a `t` tag. The verdict is stored and not asked
/// again, because a later state would answer it differently.
fn admission_json(admission: Admission) -> Json {
  case admission {
    Admitted(strength, basis, approvals) ->
      json.object([
        #("t", json.string("admitted")),
        #("strength", word(strengths, strength)),
        #("basis", basis_json(basis)),
        #("approvals", word(grants, approvals)),
      ])
    NotAdmitted(reason) ->
      json.object([
        #("t", json.string("withheld")),
        #("reason", word(withheld, reason)),
      ])
  }
}

/// Reads the gate's verdict back, with each enumeration word checked against
/// its table, so a word the table does not hold fails the document.
fn admission_decoder() -> Decoder(Admission) {
  use tag <- decode.field("t", decode.string)

  // The `t` tag picks the variant; an unknown tag fails the decode.
  case tag {
    "admitted" -> {
      use strength <- decode.field(
        "strength",
        word_decoder(strengths, model.Explicit, "Strength"),
      )
      use basis <- decode.field("basis", basis_decoder())
      use approvals <- decode.field(
        "approvals",
        word_decoder(grants, model.ApprovalsNotGranted, "Grant"),
      )
      decode.success(Admitted(strength, basis, approvals))
    }
    "withheld" -> {
      use reason <- decode.field(
        "reason",
        word_decoder(withheld, gate.SenderUnlisted, "Withheld"),
      )
      decode.success(NotAdmitted(reason))
    }
    _ -> decode.failure(NotAdmitted(gate.SenderUnlisted), "Admission")
  }
}

/// Why a trigger was admitted, under a `k` tag, with the admitting rule's name
/// when a rule admitted it.
fn basis_json(basis: model.Basis) -> Json {
  case basis {
    model.FromRule(rule) ->
      json.object([
        #("k", json.string("rule")),
        #("rule", json.string(rule.value)),
      ])
    model.FromComposer -> json.object([#("k", json.string("composer"))])
    model.FromAddressed -> json.object([#("k", json.string("addressed"))])
    model.FromFollowUp -> json.object([#("k", json.string("follow_up"))])
    model.FromOverheard -> json.object([#("k", json.string("overheard"))])
    model.FromAutomation -> json.object([#("k", json.string("automation"))])
  }
}

/// Reads why a trigger was admitted. An unknown tag fails the document.
fn basis_decoder() -> Decoder(model.Basis) {
  use kind <- decode.field("k", decode.string)

  // The `k` tag picks the basis, and only a rule carries a name.
  case kind {
    "rule" -> {
      use rule <- decode.field("rule", rule_name())
      decode.success(model.FromRule(rule))
    }
    "composer" -> decode.success(model.FromComposer)
    "addressed" -> decode.success(model.FromAddressed)
    "follow_up" -> decode.success(model.FromFollowUp)
    "overheard" -> decode.success(model.FromOverheard)
    "automation" -> decode.success(model.FromAutomation)
    _ -> decode.failure(model.FromComposer, "Basis")
  }
}

/// Where a trigger is in its life: waiting, offered to the router, or decided.
fn fate_json(fate: Fate) -> Json {
  case fate {
    state.Awaiting -> json.object([#("t", json.string("awaiting"))])
    state.Offered -> json.object([#("t", json.string("offered"))])
    state.Decided(decision) ->
      json.object([
        #("t", json.string("decided")),
        #("decision", decision_json(decision)),
      ])
  }
}

/// Reads where a trigger is in its life. An unknown tag fails the document.
fn fate_decoder() -> Decoder(Fate) {
  use tag <- decode.field("t", decode.string)

  // The `t` tag picks the fate, and only a decided one carries a decision.
  case tag {
    "awaiting" -> decode.success(state.Awaiting)
    "offered" -> decode.success(state.Offered)
    "decided" -> {
      use decision <- decode.field("decision", decision_decoder())
      decode.success(state.Decided(decision))
    }
    _ -> decode.failure(state.Awaiting, "Fate")
  }
}

/// A decision under its `k` tag, with the ticket it names when it names one.
fn decision_json(decision: Decision) -> Json {
  case decision {
    state.OwnMessage -> json.object([#("k", json.string("own_message"))])
    state.RecordedOnly -> json.object([#("k", json.string("recorded_only"))])
    state.Delivered(ticket) -> with_ticket("delivered", ticket)
    state.Accepted(ticket) -> with_ticket("accepted", ticket)
    state.Attached(ticket) -> with_ticket("attached", ticket)
    state.Resumed(ticket) -> with_ticket("resumed", ticket)
    state.StoppedTicket(ticket) -> with_ticket("stopped_ticket", ticket)
    state.Ignored -> json.object([#("k", json.string("ignored"))])
    state.Shed -> json.object([#("k", json.string("shed"))])
    state.WouldAccept -> json.object([#("k", json.string("would_accept"))])
    state.Held(hold) ->
      json.object([#("k", json.string("held")), #("hold", hold_json(hold))])
    state.Unrouted(state.NoDecision(offers)) ->
      json.object([
        #("k", json.string("unrouted")),
        #("offers", json.int(offers)),
      ])
  }
}

fn with_ticket(kind: String, ticket: TicketId) -> Json {
  json.object([
    #("k", json.string(kind)),
    #("ticket", json.string(ticket.value)),
  ])
}

/// Reads what became of a trigger. An unknown tag fails the document.
fn decision_decoder() -> Decoder(Decision) {
  use kind <- decode.field("k", decode.string)

  // The `k` tag picks the decision; five of them name a ticket.
  case kind {
    "own_message" -> decode.success(state.OwnMessage)
    "recorded_only" -> decode.success(state.RecordedOnly)
    "delivered" -> ticketed(state.Delivered)
    "accepted" -> ticketed(state.Accepted)
    "attached" -> ticketed(state.Attached)
    "resumed" -> ticketed(state.Resumed)
    "stopped_ticket" -> ticketed(state.StoppedTicket)
    "ignored" -> decode.success(state.Ignored)
    "shed" -> decode.success(state.Shed)
    "would_accept" -> decode.success(state.WouldAccept)
    "held" -> {
      use hold <- decode.field("hold", hold_decoder())
      decode.success(state.Held(hold))
    }
    "unrouted" -> {
      use offers <- decode.field("offers", decode.int)
      decode.success(state.Unrouted(state.NoDecision(offers)))
    }
    _ -> decode.failure(state.Ignored, "Decision")
  }
}

fn ticketed(make: fn(TicketId) -> Decision) -> Decoder(Decision) {
  use ticket <- decode.field("ticket", ticket_name())
  decode.success(make(ticket))
}

/// Why an admitted inferred trigger never reached the router, under a `k` tag.
fn hold_json(hold: state.Hold) -> Json {
  case hold {
    state.HeldByGate(reason) ->
      json.object([
        #("k", json.string("gate")),
        #("reason", word(refusals, reason)),
      ])
    state.HeldByAttention -> json.object([#("k", json.string("attention"))])
    state.HeldByCeiling -> json.object([#("k", json.string("ceiling"))])
  }
}

/// Reads why a trigger was held. An unknown tag fails the document.
fn hold_decoder() -> Decoder(state.Hold) {
  use kind <- decode.field("k", decode.string)

  // The `k` tag picks the hold, and only the gate's carries its reason.
  case kind {
    "gate" -> {
      use reason <- decode.field(
        "reason",
        word_decoder(refusals, gate.NoMatchingRule, "AcceptRefusal"),
      )
      decode.success(state.HeldByGate(reason))
    }
    "attention" -> decode.success(state.HeldByAttention)
    "ceiling" -> decode.success(state.HeldByCeiling)
    _ -> decode.failure(state.HeldByAttention, "Hold")
  }
}

// --- threads and links --------------------------------------------------------

/// A thread's entries in the order the engine keeps them, newest first, each
/// with whether the gate let the trigger through.
fn thread_json(thread: model.Thread) -> Json {
  json.object([
    #("id", json.string(thread.id.value)),
    #(
      "entries",
      json.array(thread.entries, fn(entry) {
        json.object([
          #("trigger", json.string(entry.trigger.value)),
          #("reception", word(receptions, entry.reception)),
        ])
      }),
    ),
  ])
}

fn thread_decoder() -> Decoder(model.Thread) {
  use id <- decode.field("id", decode.map(decode.string, ThreadId))
  use entries <- decode.field("entries", decode.list(entry_decoder()))
  decode.success(model.Thread(id:, entries:))
}

/// Reads one entry of a thread. The order of the list is kept as written.
fn entry_decoder() -> Decoder(model.ThreadEntry) {
  use trigger <- decode.field("trigger", trigger_name_decoder())
  use reception <- decode.field(
    "reception",
    word_decoder(receptions, model.Recorded, "Reception"),
  )
  decode.success(model.ThreadEntry(trigger:, reception:))
}

fn subscription_json(link: model.Subscription) -> Json {
  json.object([
    #("ticket", json.string(link.ticket.value)),
    #("thread", json.string(link.thread.value)),
  ])
}

fn subscription_decoder() -> Decoder(model.Subscription) {
  use ticket <- decode.field("ticket", ticket_name())
  use thread <- decode.field("thread", decode.map(decode.string, ThreadId))
  decode.success(model.Subscription(ticket:, thread:))
}

fn trigger_name(id: TriggerId) -> Json {
  json.string(id.value)
}

fn trigger_name_decoder() -> Decoder(TriggerId) {
  decode.map(decode.string, TriggerId)
}

fn ticket_name() -> Decoder(TicketId) {
  decode.map(decode.string, TicketId)
}

fn rule_name() -> Decoder(model.RuleId) {
  decode.map(decode.string, RuleId)
}

fn offer_decoder() -> Decoder(#(TriggerId, Int)) {
  use trigger <- decode.field("trigger", trigger_name_decoder())
  use count <- decode.field("count", decode.int)
  decode.success(#(trigger, count))
}

/// Reads the mode of one source and rule pair.
fn mode_entry_decoder() -> Decoder(
  #(#(model.SourceId, model.RuleId), model.Mode),
) {
  use source <- decode.field("source", decode.map(decode.string, SourceId))
  use rule <- decode.field("rule", rule_name())
  use mode <- decode.field("mode", word_decoder(modes, model.Off, "Mode"))
  decode.success(#(#(source, rule), mode))
}

/// Reads the latest verdict of one source and rule pair with the policy version
/// it was measured under, which decides whether it is still current.
fn verdict_entry_decoder() -> Decoder(
  #(#(model.SourceId, model.RuleId), state.Verdict),
) {
  use source <- decode.field("source", decode.map(decode.string, SourceId))
  use rule <- decode.field("rule", rule_name())
  use pin <- decode.field("pin", codec.pin_decoder())
  use outcome <- decode.field(
    "outcome",
    word_decoder(verdict_outcomes, model.VerdictFailed, "VerdictOutcome"),
  )
  use covers <- decode.field("covers", codec.covers_decoder())
  decode.success(#(#(source, rule), state.Verdict(pin:, outcome:, covers:)))
}

/// Reads one label of a trigger.
fn label_entry_decoder() -> Decoder(#(TriggerId, model.Label)) {
  use trigger <- decode.field("trigger", decode.map(decode.string, TriggerId))
  use label <- decode.field("label", codec.label_decoder())
  decode.success(#(trigger, label))
}

// --- tickets ------------------------------------------------------------------

/// A ticket with everything the engine reads of it: its mandate, assignments,
/// readiness, routings and how it ended. Its title is the capped one.
fn ticket_json(ticket: Ticket) -> Json {
  json.object([
    #("id", json.string(ticket.id.value)),
    #("title", json.string(model.title_text(ticket.title))),
    #("origin", json.string(ticket.origin.value)),
    #("mandate", mandate_json(ticket.mandate)),
    #("authority", authority_json(ticket.authority)),
    #("assignments", json.array(ticket.assignments, assignment_json)),
    #("demand", demand_json(ticket.demand)),
    #("inbox", json.array(ticket.inbox, trigger_name)),
    #("failed_inputs", json.array(ticket.failed_inputs, trigger_name)),
    #("question", json.nullable(question_number(ticket.question), json.int)),
    #("latest", json.nullable(ticket.latest, codec.report_json)),
    #("failure", json.nullable(ticket.failure, json.string)),
    #("heard", word(heards, ticket.heard)),
    #("head", json.nullable(ticket.head, commit_name)),
    #("last_checked", json.nullable(ticket.last_checked, commit_name)),
    #("rejected", json.nullable(ticket.rejected, rejected_json)),
    #("readiness", readiness_json(ticket.readiness)),
    #("review", json.nullable(ticket.review, codec.reason_json)),
    #(
      "pull_request",
      json.nullable(ticket.pull_request, fn(found) { json.string(found.url) }),
    ),
    #(
      "outcome",
      json.nullable(ticket.outcome, fn(found) { word(outcomes, found) }),
    ),
    #("routings", json.array(ticket.routings, codec.routing_json)),
  ])
}

/// Reads a ticket. The title is rebuilt through `model.title`, which caps it, so
/// a document cannot carry a title longer than an event could.
fn ticket_decoder() -> Decoder(Ticket) {
  use id <- decode.field("id", ticket_name())
  use title <- decode.field("title", decode.string)
  use origin <- decode.field("origin", trigger_name_decoder())
  use mandate <- decode.field("mandate", mandate_decoder())
  use authority <- decode.field("authority", authority_decoder())
  use assignments <- decode.field(
    "assignments",
    decode.list(assignment_decoder()),
  )
  use demand <- decode.field("demand", demand_decoder())
  use inbox <- decode.field("inbox", decode.list(trigger_name_decoder()))
  use failed_inputs <- decode.field(
    "failed_inputs",
    decode.list(trigger_name_decoder()),
  )
  use question <- decode.field("question", decode.optional(decode.int))
  use latest <- decode.field("latest", decode.optional(codec.report_decoder()))
  use failure <- decode.field("failure", decode.optional(decode.string))
  use heard <- decode.field(
    "heard",
    word_decoder(heards, model.Silent, "Heard"),
  )
  use head <- decode.field("head", decode.optional(commit_decoder()))
  use last_checked <- decode.field(
    "last_checked",
    decode.optional(commit_decoder()),
  )
  use rejected <- decode.field("rejected", decode.optional(rejected_decoder()))
  use readiness <- decode.field("readiness", readiness_decoder())
  use review <- decode.field("review", decode.optional(codec.reason_decoder()))
  use pull_request <- decode.field(
    "pull_request",
    decode.optional(decode.map(decode.string, PullRequestRef)),
  )
  use outcome <- decode.field(
    "outcome",
    decode.optional(word_decoder(outcomes, model.Abandoned, "Outcome")),
  )
  use routings <- decode.field("routings", decode.list(codec.routing_decoder()))
  decode.success(Ticket(
    id:,
    title: model.title(title),
    origin:,
    mandate:,
    authority:,
    assignments:,
    demand:,
    inbox:,
    failed_inputs:,
    question: case question {
      Some(seq) -> model.Asking(seq)
      None -> model.NoQuestion
    },
    latest:,
    failure:,
    heard:,
    head:,
    last_checked:,
    rejected:,
    readiness:,
    review:,
    pull_request:,
    outcome:,
    routings:,
  ))
}

fn question_number(question: model.Question) -> Option(Int) {
  case question {
    model.NoQuestion -> None
    model.Asking(seq) -> Some(seq)
  }
}

fn commit_name(commit: model.CommitId) -> Json {
  json.string(commit.value)
}

fn commit_decoder() -> Decoder(model.CommitId) {
  decode.map(decode.string, CommitId)
}

fn rejected_json(rejected: #(model.CommitId, model.CommandDigest)) -> Json {
  json.object([
    #("commit", json.string({ rejected.0 }.value)),
    #("digest", json.string({ rejected.1 }.value)),
  ])
}

fn rejected_decoder() -> Decoder(#(model.CommitId, model.CommandDigest)) {
  use commit <- decode.field("commit", commit_decoder())
  use digest <- decode.field("digest", decode.map(decode.string, CommandDigest))
  decode.success(#(commit, digest))
}

/// What a ticket was authorized to do. It holds no model output, and neither
/// does its document.
fn mandate_json(mandate: Mandate) -> Json {
  json.object([
    #("strength", word(strengths, mandate.strength)),
    #("basis", basis_json(mandate.basis)),
    #("actor", json.string(mandate.actor.value)),
    #("source", json.string(mandate.source.value)),
    #("workspace", json.string(mandate.scope.workspace)),
    #("approvals", word(grants, mandate.scope.approvals)),
    #("policy_version", json.string(mandate.policy_version)),
  ])
}

/// Reads a mandate field by field. The scope's two fields are flat in the
/// document and are put back into a `Scope` once both are known.
fn mandate_decoder() -> Decoder(Mandate) {
  use strength <- decode.field(
    "strength",
    word_decoder(strengths, model.Explicit, "Strength"),
  )
  use basis <- decode.field("basis", basis_decoder())
  use actor <- decode.field("actor", decode.map(decode.string, ActorId))
  use source <- decode.field("source", decode.map(decode.string, SourceId))
  use workspace <- decode.field("workspace", decode.string)
  use approvals <- decode.field(
    "approvals",
    word_decoder(grants, model.ApprovalsNotGranted, "Grant"),
  )
  use policy_version <- decode.field("policy_version", decode.string)
  decode.success(Mandate(
    strength:,
    basis:,
    actor:,
    source:,
    scope: scope_of(workspace, approvals),
    policy_version:,
  ))
}

fn scope_of(workspace: String, approvals: model.ApprovalGrant) -> Scope {
  Scope(workspace:, approvals:)
}

/// Whether a ticket's mandate stands, and when it was withdrawn, by whom or by
/// which message.
fn authority_json(authority: state.Authority) -> Json {
  case authority {
    state.Granted -> json.object([#("k", json.string("granted"))])
    state.Withdrawn(state.ByCommand(by)) ->
      json.object([
        #("k", json.string("command")),
        #("by", json.string(by.value)),
      ])
    state.Withdrawn(state.ByMessage(trigger)) ->
      json.object([
        #("k", json.string("message")),
        #("trigger", json.string(trigger.value)),
      ])
  }
}

/// Reads whether a mandate stands. An unknown tag fails the document.
fn authority_decoder() -> Decoder(state.Authority) {
  use kind <- decode.field("k", decode.string)

  // The `k` tag picks the authority, and a withdrawal says how it happened.
  case kind {
    "granted" -> decode.success(state.Granted)
    "command" -> {
      use by <- decode.field("by", decode.map(decode.string, PrincipalId))
      decode.success(state.Withdrawn(state.ByCommand(by)))
    }
    "message" -> {
      use trigger <- decode.field("trigger", trigger_name_decoder())
      decode.success(state.Withdrawn(state.ByMessage(trigger)))
    }
    _ -> decode.failure(state.Granted, "Authority")
  }
}

/// One binding of a ticket to a worker session, with the session id once the
/// host has bound one.
fn assignment_json(assignment: Assignment) -> Json {
  json.object([
    #("seq", json.int(assignment.seq)),
    #(
      "session",
      json.nullable(assignment.session, fn(id) { json.string(id.value) }),
    ),
    #("slot", word(slots, assignment.slot)),
    #("wanted", word(wanteds, assignment.wanted)),
    #("status", status_json(assignment.status)),
  ])
}

/// Reads an assignment, with its slot, its demand and its status checked
/// against their tables.
fn assignment_decoder() -> Decoder(Assignment) {
  use seq <- decode.field("seq", decode.int)
  use session <- decode.field(
    "session",
    decode.optional(decode.map(decode.string, SessionId)),
  )
  use slot <- decode.field("slot", word_decoder(slots, state.General, "Slot"))
  use wanted <- decode.field(
    "wanted",
    word_decoder(wanteds, model.ByRouting, "Wanted"),
  )
  use status <- decode.field("status", status_decoder())
  decode.success(Assignment(seq:, session:, slot:, wanted:, status:))
}

/// An assignment's status as one word: pending, running, or how it ended.
fn status_json(status: state.AssignmentStatus) -> Json {
  case status {
    state.AssignmentPending -> json.string("pending")
    state.AssignmentRunning -> json.string("running")
    state.AssignmentDone(model.SessionExited) -> json.string("exited")
    state.AssignmentDone(model.SessionCrashed) -> json.string("crashed")
    state.AssignmentDone(model.SessionRested) -> json.string("rested")
  }
}

/// Reads an assignment's status word. An unknown word fails the document.
fn status_decoder() -> Decoder(state.AssignmentStatus) {
  use text <- decode.then(decode.string)

  // The word is one of five, and three of them say how the session ended.
  case text {
    "pending" -> decode.success(state.AssignmentPending)
    "running" -> decode.success(state.AssignmentRunning)
    "exited" -> decode.success(state.AssignmentDone(model.SessionExited))
    "crashed" -> decode.success(state.AssignmentDone(model.SessionCrashed))
    "rested" -> decode.success(state.AssignmentDone(model.SessionRested))
    _ -> decode.failure(state.AssignmentPending, "AssignmentStatus")
  }
}

/// Whether a ticket is waiting for a session, and what wants one.
fn demand_json(demand: model.Demand) -> Json {
  case demand {
    model.Satisfied -> json.string("satisfied")
    model.Wanting(model.ByPerson) -> json.string("by_person")
    model.Wanting(model.ByRouting) -> json.string("by_routing")
  }
}

/// Reads whether a ticket is waiting for a session. An unknown word fails the
/// document.
fn demand_decoder() -> Decoder(model.Demand) {
  use text <- decode.then(decode.string)

  // Nothing waits, or a person's message wants a session, or the router does.
  case text {
    "satisfied" -> decode.success(model.Satisfied)
    "by_person" -> decode.success(model.Wanting(model.ByPerson))
    "by_routing" -> decode.success(model.Wanting(model.ByRouting))
    _ -> decode.failure(model.Satisfied, "Demand")
  }
}

/// A readiness under its `k` tag. A pass is rebuilt through `host.passed`,
/// the same door the ledger's event decoder uses, so the document cannot give
/// a ticket a proof the host did not write.
fn readiness_json(state_of: readiness.Readiness) -> Json {
  case state_of {
    readiness.InProgress -> json.object([#("k", json.string("in_progress"))])
    readiness.AwaitingReview ->
      json.object([#("k", json.string("awaiting_review"))])
    readiness.Ready(proof) ->
      json.object([
        #("k", json.string("ready")),
        #("commit", json.string(host.commit(proof).value)),
        #("digest", json.string(host.command_digest(proof).value)),
        #("entry", json.string(host.entry(proof).value)),
      ])
    readiness.Published(by, commit) ->
      json.object([
        #("k", json.string("published")),
        #("by", json.string(by.value)),
        #("commit", json.string(commit.value)),
      ])
  }
}

/// Reads a readiness. A pass is rebuilt through `host.passed`. An unknown tag
/// fails the document.
fn readiness_decoder() -> Decoder(readiness.Readiness) {
  use kind <- decode.field("k", decode.string)

  // The `k` tag picks the readiness, and two of them carry what vouches for it.
  case kind {
    "in_progress" -> decode.success(readiness.InProgress)
    "awaiting_review" -> decode.success(readiness.AwaitingReview)
    "ready" -> {
      use commit <- decode.field("commit", commit_decoder())
      use digest <- decode.field(
        "digest",
        decode.map(decode.string, CommandDigest),
      )
      use entry <- decode.field("entry", decode.map(decode.string, EntryId))
      decode.success(readiness.Ready(host.passed(commit, digest, entry)))
    }
    "published" -> {
      use by <- decode.field("by", decode.map(decode.string, PrincipalId))
      use commit <- decode.field("commit", commit_decoder())
      decode.success(readiness.Published(by, commit))
    }
    _ -> decode.failure(readiness.InProgress, "Readiness")
  }
}

// --- retention ----------------------------------------------------------------

/// Drop what no later event can name, and say what became of each trigger
/// dropped. `horizon_ms` is a system time: a trigger that arrived before it is
/// old. An ended ticket whose opening trigger is old is dropped with its
/// subscriptions and the thread entries of its triggers.
///
/// A trigger stays when it is not settled (queued, offered or awaiting), when
/// it is an unrouted candidate that waits for a person, when an open or recent
/// ticket names it, or when it is not old. The check that makes the dropped
/// set safe is that nothing the engine can still read names it: a later event
/// refers to a trigger only through the queue, the offered list, a ticket's
/// inbox, failed inputs or routings, or a thread entry that is itself dropped.
///
/// ## Examples
///
/// ```gleam
/// let #(kept, retired) = snapshot.retire(state.start(config), 0)
/// assert retired == []
/// ```
pub fn retire(current: State, horizon_ms: Int) -> #(State, List(Retired)) {
  let dead_tickets =
    dict.values(current.tickets)
    |> list.filter(fn(ticket) { ended_before(current, ticket, horizon_ms) })
  let dead_ticket_ids = list.map(dead_tickets, fn(ticket) { ticket.id })
  let kept_tickets =
    dict.values(current.tickets)
    |> list.filter(fn(ticket) { !list.contains(dead_ticket_ids, ticket.id) })
  let named = names_of(kept_tickets)
  let dead_triggers =
    dict.values(current.triggers)
    |> list.filter(fn(stored) { droppable(current, stored, named, horizon_ms) })
  let dead_trigger_ids =
    list.map(dead_triggers, fn(stored) { stored.trigger.id })
  let retired = list.map(dead_triggers, retired_of)
  #(prune(current, kept_tickets, dead_ticket_ids, dead_trigger_ids), retired)
}

/// Whether a ticket ended and its opening message is older than the horizon.
fn ended_before(current: State, ticket: Ticket, horizon_ms: Int) -> Bool {
  case ticket.outcome, dict.get(current.triggers, ticket.origin) {
    Some(_), Ok(stored) -> stored.trigger.at_ms < horizon_ms
    Some(_), Error(Nil) -> True
    None, _ -> False
  }
}

/// Every trigger a ticket that stays can still name.
fn names_of(tickets: List(Ticket)) -> List(TriggerId) {
  list.flat_map(tickets, fn(ticket) {
    list.flatten([
      [ticket.origin],
      ticket.inbox,
      ticket.failed_inputs,
      list.flat_map(ticket.routings, fn(routing) {
        list.flatten([
          [routing.trigger],
          routing.holds,
          option.to_result(routing.prior_hand_back, Nil)
            |> result.map(fn(id) { [id] })
            |> result.unwrap([]),
        ])
      }),
    ])
  })
}

/// Whether a stored trigger may be dropped.
fn droppable(
  current: State,
  stored: TriggerRecord,
  named: List(TriggerId),
  horizon_ms: Int,
) -> Bool {
  let id = stored.trigger.id

  // A trigger is settled when it was decided, except an unrouted candidate,
  // which waits on the board for a person to queue it again.
  let settled = case stored.fate {
    state.Decided(state.Unrouted(_)) -> False
    state.Decided(_) -> True
    state.Awaiting | state.Offered -> False
  }

  // A labelled trigger stays whatever its age. The label is a person's effort
  // and the tape that a verdict is measured on is built from the trigger, so
  // dropping it would silently shrink the labelled count.
  settled
  && stored.trigger.at_ms < horizon_ms
  && !dict.has_key(current.labels, id)
  && !list.contains(named, id)
  && !list.contains(current.queue, id)
  && !list.contains(current.offered, id)
}

/// What is kept of a dropped trigger.
fn retired_of(stored: TriggerRecord) -> Retired {
  // A dropped trigger is nearly always decided; the two other words are for a
  // caller that retires one regardless.
  let #(decision, ticket) = case stored.fate {
    state.Decided(found) -> decision_word(found)
    state.Awaiting -> #("awaiting", None)
    state.Offered -> #("offered", None)
  }

  Retired(
    trigger: stored.trigger.id,
    decision:,
    ticket:,
    at_ms: stored.trigger.at_ms,
  )
}

/// A decision as a word, and the ticket it names.
fn decision_word(decision: Decision) -> #(String, Option(TicketId)) {
  case decision {
    state.OwnMessage -> #("own_message", None)
    state.RecordedOnly -> #("recorded_only", None)
    state.Delivered(ticket) -> #("delivered", Some(ticket))
    state.Accepted(ticket) -> #("accepted", Some(ticket))
    state.Attached(ticket) -> #("attached", Some(ticket))
    state.Resumed(ticket) -> #("resumed", Some(ticket))
    state.StoppedTicket(ticket) -> #("stopped_ticket", Some(ticket))
    state.Ignored -> #("ignored", None)
    state.Shed -> #("shed", None)
    state.WouldAccept -> #("would_accept", None)
    state.Held(_) -> #("held", None)
    state.Unrouted(_) -> #("unrouted", None)
  }
}

/// The state without the dropped tickets and triggers, and without the
/// subscriptions, thread entries and offer counts that named them.
fn prune(
  current: State,
  kept_tickets: List(Ticket),
  dead_tickets: List(TicketId),
  dead_triggers: List(TriggerId),
) -> State {
  let threads =
    dict.values(current.threads)
    |> list.filter_map(fn(thread) {
      let entries =
        list.filter(thread.entries, fn(entry) {
          !list.contains(dead_triggers, entry.trigger)
        })

      // A thread left with no entry is dropped with its last trigger.
      case entries {
        [] -> Error(Nil)
        [_, ..] -> Ok(#(thread.id, model.Thread(..thread, entries:)))
      }
    })
  let subscriptions =
    list.filter(current.subscriptions, fn(link) {
      !list.contains(dead_tickets, link.ticket)
    })

  state.State(
    ..current,
    triggers: dict.filter(current.triggers, fn(id, _) {
      !list.contains(dead_triggers, id)
    }),
    threads: dict.from_list(threads),
    subscriptions:,
    tickets: dict.from_list(
      list.map(kept_tickets, fn(ticket) { #(ticket.id, ticket) }),
    ),
    order: list.filter(current.order, fn(id) {
      !list.contains(dead_tickets, id)
    }),
    offers: dict.filter(current.offers, fn(id, _) {
      !list.contains(dead_triggers, id)
    }),
  )
}

// --- words --------------------------------------------------------------------

fn word(table: List(#(String, a)), value: a) -> Json {
  case list.find(table, fn(row) { row.1 == value }) {
    Ok(row) -> json.string(row.0)
    Error(Nil) -> json.string("")
  }
}

/// Decodes one of the words in `table`, failing with `fallback` and `name` for
/// any other, so an unknown word is an error and never a crash.
fn word_decoder(
  table: List(#(String, a)),
  fallback: a,
  name: String,
) -> Decoder(a) {
  use text <- decode.then(decode.string)

  // A word outside the table fails the decode.
  case list.find(table, fn(row) { row.0 == text }) {
    Ok(row) -> decode.success(row.1)
    Error(Nil) -> decode.failure(fallback, name)
  }
}

const strengths: List(#(String, model.Strength)) = [
  #("explicit", model.Explicit),
  #("inferred", model.Inferred),
]

const grants: List(#(String, model.ApprovalGrant)) = [
  #("granted", model.ApprovalsGranted),
  #("not_granted", model.ApprovalsNotGranted),
]

const withheld: List(#(String, gate.Withheld)) = [
  #("sender_unlisted", gate.SenderUnlisted),
  #("past_generation_limit", gate.PastGenerationLimit),
  #("own_output", gate.OwnOutput),
]

const refusals: List(#(String, gate.AcceptRefusal)) = [
  #("no_matching_rule", gate.NoMatchingRule),
  #("mode_is_off", gate.ModeIsOff),
  #("no_current_verdict", gate.NoCurrentVerdict),
]

const receptions: List(#(String, model.Reception)) = [
  #("received", model.Received),
  #("recorded", model.Recorded),
]

const routers: List(#(String, state.RouterPhase)) = [
  #("idle", state.RouterIdle),
  #("busy", state.RouterBusy),
]

const modes: List(#(String, model.Mode)) = [
  #("off", model.Off),
  #("observe", model.Observe),
  #("auto", model.Auto),
]

const verdict_outcomes: List(#(String, model.VerdictOutcome)) = [
  #("passed", model.VerdictPassed),
  #("failed", model.VerdictFailed),
]

const ceilings: List(#(String, model.Ceiling)) = [
  #("clear", model.CeilingClear),
  #("reached", model.CeilingReached),
]

const heards: List(#(String, model.Heard)) = [
  #("silent", model.Silent),
  #("person_heard", model.PersonHeard),
]

const slots: List(#(String, state.SlotKind)) = [
  #("general", state.General),
  #("reserved", state.Reserved),
]

const wanteds: List(#(String, model.Wanted)) = [
  #("by_person", model.ByPerson),
  #("by_routing", model.ByRouting),
]

const outcomes: List(#(String, model.Outcome)) = [
  #("merged", model.Merged),
  #("closed", model.Closed),
  #("abandoned", model.Abandoned),
  #("stopped", model.StoppedByPerson),
]
