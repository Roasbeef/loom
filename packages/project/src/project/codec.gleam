//// The ledger's wire form of an event: JSON out, total decoders in.
////
//// The ledger stores events and nothing else, so what `encode` writes must
//// read back to the same event, and what `decode` reads must never crash on
//// bytes it did not write. Every decoder here is total: garbage, a missing
//// field, an unknown tag or an unknown enum word returns `Error`, and a title
//// longer than the cap is cut on the way in, so a stored event cannot smuggle
//// a long title past `model.title`.
////
//// Each event is an object with a `t` tag naming its variant. Enumerations
//// are lower-case words from one table per type, which serves both
//// directions, so a word cannot be added to the decoder and forgotten by the
//// encoder. A passing check is rebuilt through `host.passed`, the same door
//// the host used when the ledger entry was first written.
////
//// Only `gleam/json` and `gleam/dynamic/decode` are used, which keeps the
//// package off the Erlang-only dependencies lint R6 forbids.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import project/event.{type CheckResult, type Event}
import project/host
import project/model.{
  type ActorId, type ApprovalGrant, type Head, type Inputs, type Question,
  type Report, type RouteKind, type Routing, type RuleMatch, type Trigger,
  ActorId, Asking, CommandDigest, CommitId, EntryId, Head, Inputs, NoHead,
  NoQuestion, PrincipalId, PullRequestRef, Routing, RuleId, RuleMatch, SessionId,
  SourceId, ThreadId, TicketId, Trigger, TriggerId,
}

/// Why a stored event could not be read.
pub type CodecError {
  /// The text is not JSON, or it does not have the shape of an event.
  Malformed
}

/// Write an event as one line of JSON.
///
/// ## Examples
///
/// ```gleam
/// let text = codec.encode(event.RouterTurnEnded)
/// assert codec.decode(text) == Ok(event.RouterTurnEnded)
/// ```
pub fn encode(incoming: Event) -> String {
  incoming |> to_json |> json.to_string
}

/// Read an event back. Total: any text that is not an event is `Malformed`.
///
/// ## Examples
///
/// ```gleam
/// assert codec.decode("not json") == Error(codec.Malformed)
/// ```
pub fn decode(text: String) -> Result(Event, CodecError) {
  case json.parse(text, event_decoder()) {
    Ok(found) -> Ok(found)
    Error(_) -> Error(Malformed)
  }
}

// --- events ------------------------------------------------------------------

fn tagged(name: String, fields: List(#(String, Json))) -> Json {
  json.object([#("t", json.string(name)), ..fields])
}

fn ticket_field(ticket: model.TicketId) -> #(String, Json) {
  #("ticket", json.string(ticket.value))
}

/// Write any event as a tagged object. The match is exhaustive, so a new
/// event cannot be added without deciding its wire form.
fn to_json(incoming: Event) -> Json {
  case incoming {
    event.TriggerArrived(trigger, bot) ->
      tagged("trigger_arrived", [
        #("trigger", trigger_json(trigger)),
        #("bot", json.string(bot.value)),
      ])
    event.Routed(routing) ->
      tagged("routed", [#("routing", routing_json(routing))])
    event.RoutedStop(trigger, ticket) ->
      tagged("routed_stop", [
        #("trigger", json.string(trigger.value)),
        ticket_field(ticket),
      ])
    event.RoutedIgnore(trigger) ->
      tagged("routed_ignore", [#("trigger", json.string(trigger.value))])
    event.RouterTurnEnded -> tagged("router_turn_ended", [])
    event.Requeued(trigger, by) ->
      tagged("requeued", [
        #("trigger", json.string(trigger.value)),
        #("by", json.string(by.value)),
      ])
    event.ModeSet(source, rule, mode) ->
      tagged("mode_set", [
        #("source", json.string(source.value)),
        #("rule", json.string(rule.value)),
        #("mode", word(modes, mode)),
      ])
    event.VerdictRecorded(source, rule, version, outcome) ->
      tagged("verdict_recorded", [
        #("source", json.string(source.value)),
        #("rule", json.string(rule.value)),
        #("version", json.string(version)),
        #("outcome", word(verdicts, outcome)),
      ])
    event.PolicyVersionSet(version) ->
      tagged("policy_version_set", [#("version", json.string(version))])
    event.CeilingChanged(ceiling) ->
      tagged("ceiling_changed", [#("ceiling", word(ceilings, ceiling))])
    event.SessionBound(ticket, seq, session) ->
      tagged("session_bound", [
        ticket_field(ticket),
        #("seq", json.int(seq)),
        #("session", json.string(session.value)),
      ])
    event.AssignmentLive(ticket, seq) ->
      tagged("assignment_live", [ticket_field(ticket), #("seq", json.int(seq))])
    event.AssignmentEnded(ticket, seq, end) ->
      tagged("assignment_ended", [
        ticket_field(ticket),
        #("seq", json.int(seq)),
        #("end", word(ends, end)),
      ])
    event.Reported(ticket, seq, report, head) ->
      tagged("reported", [
        ticket_field(ticket),
        #("seq", json.int(seq)),
        #("report", report_json(report)),
        #("head", head_json(head)),
      ])
    event.Answered(ticket, question, by) ->
      tagged("answered", [
        ticket_field(ticket),
        #("question", json.int(question)),
        #("by", json.string(by.value)),
      ])
    event.InputFailed(ticket, trigger) ->
      tagged("input_failed", [
        ticket_field(ticket),
        #("trigger", json.string(trigger.value)),
      ])
    event.InputDelivered(ticket, trigger) ->
      tagged("input_delivered", [
        ticket_field(ticket),
        #("trigger", json.string(trigger.value)),
      ])
    event.CheckFinished(ticket, finished) ->
      tagged("check_finished", [
        ticket_field(ticket),
        #("check", check_json(finished)),
      ])
    event.PersonPublished(ticket, by, commit) ->
      tagged("person_published", [
        ticket_field(ticket),
        #("by", json.string(by.value)),
        #("commit", json.string(commit.value)),
      ])
    event.PersonStopped(ticket, by) ->
      tagged("person_stopped", [
        ticket_field(ticket),
        #("by", json.string(by.value)),
      ])
    event.RetryRequested(ticket, by) ->
      tagged("retry_requested", [
        ticket_field(ticket),
        #("by", json.string(by.value)),
      ])
    event.PullRequestOpened(ticket, pull_request) ->
      tagged("pull_request_opened", [
        ticket_field(ticket),
        #("url", json.string(pull_request.url)),
      ])
    event.Concluded(ticket, outcome) ->
      tagged("concluded", [
        ticket_field(ticket),
        #("outcome", word(outcomes, outcome)),
      ])
  }
}

/// Read an event by its tag, starting with the router's own events.
fn event_decoder() -> Decoder(Event) {
  use tag <- decode.field("t", decode.string)

  // The `t` tag picks the event family. Each helper below owns one group and
  // fails the decode on a tag it does not know.
  case tag {
    "trigger_arrived" -> arrived_decoder()
    "routed" -> {
      use routing <- decode.field("routing", routing_decoder())
      decode.success(event.Routed(routing))
    }
    "routed_stop" -> {
      use trigger <- decode.field("trigger", trigger_id())
      use ticket <- decode.field("ticket", ticket_id())
      decode.success(event.RoutedStop(trigger, ticket))
    }
    "routed_ignore" -> {
      use trigger <- decode.field("trigger", trigger_id())
      decode.success(event.RoutedIgnore(trigger))
    }
    "router_turn_ended" -> decode.success(event.RouterTurnEnded)
    "requeued" -> {
      use trigger <- decode.field("trigger", trigger_id())
      use by <- decode.field("by", principal())
      decode.success(event.Requeued(trigger, by))
    }
    _ -> control_decoder(tag)
  }
}

fn arrived_decoder() -> Decoder(Event) {
  use trigger <- decode.field("trigger", trigger_decoder())
  use bot <- decode.field("bot", actor_id())
  decode.success(event.TriggerArrived(trigger, bot))
}

/// Project-level controls.
fn control_decoder(tag: String) -> Decoder(Event) {
  // Project-level controls: modes, verdicts, the policy version and the
  // ceiling.
  case tag {
    "mode_set" -> {
      use source <- decode.field("source", source_id())
      use rule <- decode.field("rule", rule_id())
      use mode <- decode.field("mode", word_decoder(modes, model.Off, "Mode"))
      decode.success(event.ModeSet(source, rule, mode))
    }
    "verdict_recorded" -> {
      use source <- decode.field("source", source_id())
      use rule <- decode.field("rule", rule_id())
      use version <- decode.field("version", decode.string)
      use outcome <- decode.field(
        "outcome",
        word_decoder(verdicts, model.VerdictFailed, "Verdict"),
      )
      decode.success(event.VerdictRecorded(source, rule, version, outcome))
    }
    "policy_version_set" -> {
      use version <- decode.field("version", decode.string)
      decode.success(event.PolicyVersionSet(version))
    }
    "ceiling_changed" -> {
      use ceiling <- decode.field(
        "ceiling",
        word_decoder(ceilings, model.CeilingClear, "Ceiling"),
      )
      decode.success(event.CeilingChanged(ceiling))
    }
    _ -> assignment_decoder(tag)
  }
}

/// Assignment lifecycle and reports.
fn assignment_decoder(tag: String) -> Decoder(Event) {
  // Assignment lifecycle events and worker reports.
  case tag {
    "session_bound" -> {
      use ticket <- decode.field("ticket", ticket_id())
      use seq <- decode.field("seq", decode.int)
      use session <- decode.field("session", text_decoder(SessionId))
      decode.success(event.SessionBound(ticket, seq, session))
    }
    "assignment_live" -> {
      use ticket <- decode.field("ticket", ticket_id())
      use seq <- decode.field("seq", decode.int)
      decode.success(event.AssignmentLive(ticket, seq))
    }
    "assignment_ended" -> {
      use ticket <- decode.field("ticket", ticket_id())
      use seq <- decode.field("seq", decode.int)
      use end <- decode.field(
        "end",
        word_decoder(ends, model.SessionExited, "SessionEnd"),
      )
      decode.success(event.AssignmentEnded(ticket, seq, end))
    }
    "reported" -> {
      use ticket <- decode.field("ticket", ticket_id())
      use seq <- decode.field("seq", decode.int)
      use report <- decode.field("report", report_decoder())
      use head <- decode.field("head", head_decoder())
      decode.success(event.Reported(ticket, seq, report, head))
    }
    _ -> person_decoder(tag)
  }
}

/// Commands and host facts about one ticket.
fn person_decoder(tag: String) -> Decoder(Event) {
  // Answers, input delivery, check results and publication.
  case tag {
    "answered" -> {
      use ticket <- decode.field("ticket", ticket_id())
      use question <- decode.field("question", decode.int)
      use by <- decode.field("by", principal())
      decode.success(event.Answered(ticket, question, by))
    }
    "input_failed" -> {
      use ticket <- decode.field("ticket", ticket_id())
      use trigger <- decode.field("trigger", trigger_id())
      decode.success(event.InputFailed(ticket, trigger))
    }
    "input_delivered" -> {
      use ticket <- decode.field("ticket", ticket_id())
      use trigger <- decode.field("trigger", trigger_id())
      decode.success(event.InputDelivered(ticket, trigger))
    }
    "check_finished" -> {
      use ticket <- decode.field("ticket", ticket_id())
      use finished <- decode.field("check", check_decoder())
      decode.success(event.CheckFinished(ticket, finished))
    }
    "person_published" -> {
      use ticket <- decode.field("ticket", ticket_id())
      use by <- decode.field("by", principal())
      use commit <- decode.field("commit", commit_id())
      decode.success(event.PersonPublished(ticket, by, commit))
    }
    _ -> closing_decoder(tag)
  }
}

/// How a ticket ends.
fn closing_decoder(tag: String) -> Decoder(Event) {
  // How a ticket is stopped, retried, given a pull request or concluded. This
  // is the last family, so an unknown tag fails here.
  case tag {
    "person_stopped" -> {
      use ticket <- decode.field("ticket", ticket_id())
      use by <- decode.field("by", principal())
      decode.success(event.PersonStopped(ticket, by))
    }
    "retry_requested" -> {
      use ticket <- decode.field("ticket", ticket_id())
      use by <- decode.field("by", principal())
      decode.success(event.RetryRequested(ticket, by))
    }
    "pull_request_opened" -> {
      use ticket <- decode.field("ticket", ticket_id())
      use url <- decode.field("url", decode.string)
      decode.success(event.PullRequestOpened(ticket, PullRequestRef(url)))
    }
    "concluded" -> {
      use ticket <- decode.field("ticket", ticket_id())
      use outcome <- decode.field(
        "outcome",
        word_decoder(outcomes, model.Closed, "Outcome"),
      )
      decode.success(event.Concluded(ticket, outcome))
    }
    _ -> decode.failure(event.RouterTurnEnded, "Event")
  }
}

// --- shared shapes -----------------------------------------------------------

/// Write a trigger with its gate inputs spelled out.
fn trigger_json(trigger: Trigger) -> Json {
  json.object([
    #("id", json.string(trigger.id.value)),
    #("source", json.string(trigger.source.value)),
    #("thread", json.string(trigger.thread.value)),
    #("actor", json.string(trigger.actor.value)),
    #("inputs", inputs_json(trigger.inputs)),
    #("generation", json.int(trigger.generation)),
    #("at_ms", json.int(trigger.at_ms)),
  ])
}

/// Read a trigger; every field is required.
fn trigger_decoder() -> Decoder(Trigger) {
  use id <- decode.field("id", trigger_id())
  use source <- decode.field("source", source_id())
  use thread <- decode.field("thread", text_decoder(ThreadId))
  use actor <- decode.field("actor", actor_id())
  use inputs <- decode.field("inputs", inputs_decoder())
  use generation <- decode.field("generation", decode.int)
  use at_ms <- decode.field("at_ms", decode.int)
  decode.success(Trigger(
    id:,
    source:,
    thread:,
    actor:,
    inputs:,
    generation:,
    at_ms:,
  ))
}

/// Write the inputs the gate decides strength from.
fn inputs_json(inputs: Inputs) -> Json {
  json.object([
    #("sender", word(senders, inputs.sender)),
    #("addressing", word(addressings, inputs.addressing)),
    #("rule", json.nullable(inputs.rule, rule_match_json)),
  ])
}

/// Read the gate's inputs; the rule is `null` when none matched.
fn inputs_decoder() -> Decoder(Inputs) {
  use sender <- decode.field(
    "sender",
    word_decoder(senders, model.Owner, "Sender"),
  )
  use addressing <- decode.field(
    "addressing",
    word_decoder(addressings, model.Addressed, "Addressing"),
  )
  use rule <- decode.field("rule", decode.optional(rule_match_decoder()))
  decode.success(Inputs(sender:, addressing:, rule:))
}

fn rule_match_json(matched: RuleMatch) -> Json {
  json.object([
    #("rule", json.string(matched.rule.value)),
    #("approvals", word(grants, matched.approvals)),
  ])
}

/// Read a matching rule and what it grants.
fn rule_match_decoder() -> Decoder(RuleMatch) {
  use rule <- decode.field("rule", rule_id())
  use approvals <- decode.field(
    "approvals",
    word_decoder(grants, model.ApprovalsNotGranted, "Grant"),
  )
  decode.success(RuleMatch(rule:, approvals:))
}

/// Write a routing decision as references only, with no free text for a
/// worker.
fn routing_json(routing: Routing) -> Json {
  json.object([
    #("trigger", json.string(routing.trigger.value)),
    #("kind", route_kind_json(routing.kind)),
    #("holds", json.array(routing.holds, fn(id) { json.string(id.value) })),
    #("related", json.array(routing.related, related_json)),
    #(
      "prior_hand_back",
      json.nullable(routing.prior_hand_back, fn(id) { json.string(id.value) }),
    ),
  ])
}

fn related_json(link: #(model.TicketId, model.Relation)) -> Json {
  json.object([
    #("ticket", json.string({ link.0 }.value)),
    #("relation", word(relations, link.1)),
  ])
}

/// Read a routing decision.
fn routing_decoder() -> Decoder(Routing) {
  use trigger <- decode.field("trigger", trigger_id())
  use kind <- decode.field("kind", route_kind_decoder())
  use holds <- decode.field("holds", decode.list(trigger_id()))
  use related <- decode.field("related", decode.list(related_decoder()))
  use prior_hand_back <- decode.field(
    "prior_hand_back",
    decode.optional(trigger_id()),
  )
  decode.success(Routing(trigger:, kind:, holds:, related:, prior_hand_back:))
}

/// Read one related ticket and its relation.
fn related_decoder() -> Decoder(#(model.TicketId, model.Relation)) {
  use ticket <- decode.field("ticket", ticket_id())
  use relation <- decode.field(
    "relation",
    word_decoder(relations, model.Duplicate, "Relation"),
  )
  decode.success(#(ticket, relation))
}

/// Write a route kind under its `k` tag.
fn route_kind_json(kind: RouteKind) -> Json {
  case kind {
    model.Accept(title) ->
      json.object([
        #("k", json.string("accept")),
        #("title", json.string(model.title_text(title))),
      ])
    model.Attach(ticket) ->
      json.object([
        #("k", json.string("attach")),
        #("ticket", json.string(ticket.value)),
      ])
    model.Resume(ticket) ->
      json.object([
        #("k", json.string("resume")),
        #("ticket", json.string(ticket.value)),
      ])
  }
}

/// Read a route kind, capping the title on the way in.
fn route_kind_decoder() -> Decoder(RouteKind) {
  use tag <- decode.field("k", decode.string)

  // The `k` tag picks the route kind; an unknown tag fails the decode.
  case tag {
    "accept" -> {
      use title <- decode.field("title", decode.string)
      decode.success(model.Accept(model.title(title)))
    }
    "attach" -> {
      use ticket <- decode.field("ticket", ticket_id())
      decode.success(model.Attach(ticket))
    }
    "resume" -> {
      use ticket <- decode.field("ticket", ticket_id())
      decode.success(model.Resume(ticket))
    }
    _ -> decode.failure(model.Attach(TicketId("")), "RouteKind")
  }
}

/// Write a worker report under its `kind` word.
fn report_json(report: Report) -> Json {
  case report {
    model.Progress -> json.object([#("kind", json.string("progress"))])
    model.Waiting(question) ->
      json.object([
        #("kind", json.string("waiting")),
        #("question", json.nullable(question_number(question), json.int)),
      ])
    model.Blocked -> json.object([#("kind", json.string("blocked"))])
    model.Failed -> json.object([#("kind", json.string("failed"))])
    model.Dropped -> json.object([#("kind", json.string("dropped"))])
  }
}

fn question_number(question: Question) -> Option(Int) {
  case question {
    NoQuestion -> None
    Asking(seq) -> Some(seq)
  }
}

/// Read a worker report; any word but the five statuses fails, so there is no
/// `ready` to read.
fn report_decoder() -> Decoder(Report) {
  use kind <- decode.field("kind", decode.string)

  // The `kind` word picks the report, and only `waiting` carries a question.
  case kind {
    "progress" -> decode.success(model.Progress)
    "waiting" -> {
      use number <- decode.field("question", decode.optional(decode.int))
      decode.success(model.Waiting(question_from(number)))
    }
    "blocked" -> decode.success(model.Blocked)
    "failed" -> decode.success(model.Failed)
    "dropped" -> decode.success(model.Dropped)
    _ -> decode.failure(model.Progress, "Report")
  }
}

fn question_from(number: Option(Int)) -> Question {
  case number {
    None -> NoQuestion
    Some(seq) -> Asking(seq)
  }
}

/// Write the host's snapshot of a worker's branch, or `null` for none.
fn head_json(head: Head) -> Json {
  case head {
    NoHead -> json.null()
    Head(commit, paths) ->
      json.object([
        #("commit", json.string(commit.value)),
        #("paths", word(scopes, paths)),
      ])
  }
}

/// Read a head, mapping `null` to no head.
fn head_decoder() -> Decoder(Head) {
  decode.optional(head_fields())
  |> decode.map(fn(found) {
    case found {
      Some(head) -> head
      None -> NoHead
    }
  })
}

/// Read the fields of a present head.
fn head_fields() -> Decoder(Head) {
  use commit <- decode.field("commit", commit_id())
  use paths <- decode.field(
    "paths",
    word_decoder(scopes, model.ProtectedPathsTouched, "PathScope"),
  )
  decode.success(Head(commit:, paths:))
}

/// Write a check result, including the ledger entry of a pass.
fn check_json(finished: CheckResult) -> Json {
  case finished {
    event.CheckOk(proof) ->
      json.object([
        #("result", json.string("passed")),
        #("commit", json.string(host.commit(proof).value)),
        #("digest", json.string(host.command_digest(proof).value)),
        #("entry", json.string(host.entry(proof).value)),
      ])
    event.CheckRejected(commit, digest) ->
      json.object([
        #("result", json.string("rejected")),
        #("commit", json.string(commit.value)),
        #("digest", json.string(digest.value)),
      ])
  }
}

/// Read a check result, rebuilding a pass through the host's door.
fn check_decoder() -> Decoder(CheckResult) {
  use result <- decode.field("result", decode.string)
  use commit <- decode.field("commit", commit_id())
  use digest <- decode.field("digest", text_decoder(CommandDigest))

  // A `passed` result carries the ledger entry that proves it and is rebuilt
  // through `host.passed`; a rejection carries none.
  case result {
    "passed" -> {
      use entry <- decode.field("entry", text_decoder(EntryId))
      decode.success(event.CheckOk(host.passed(commit, digest, entry)))
    }
    "rejected" -> decode.success(event.CheckRejected(commit, digest))
    _ -> decode.failure(event.CheckRejected(commit, digest), "CheckResult")
  }
}

// --- identifiers -------------------------------------------------------------

fn text_decoder(make: fn(String) -> a) -> Decoder(a) {
  decode.map(decode.string, make)
}

fn trigger_id() -> Decoder(model.TriggerId) {
  text_decoder(TriggerId)
}

fn ticket_id() -> Decoder(model.TicketId) {
  text_decoder(TicketId)
}

fn actor_id() -> Decoder(ActorId) {
  text_decoder(ActorId)
}

fn commit_id() -> Decoder(model.CommitId) {
  text_decoder(CommitId)
}

fn principal() -> Decoder(model.PrincipalId) {
  text_decoder(PrincipalId)
}

fn source_id() -> Decoder(model.SourceId) {
  text_decoder(SourceId)
}

fn rule_id() -> Decoder(model.RuleId) {
  text_decoder(RuleId)
}

// --- enumerations ------------------------------------------------------------

// One table per enumeration serves both directions.
fn word(table: List(#(String, a)), value: a) -> Json {
  case list.find(table, fn(row) { row.1 == value }) {
    Ok(row) -> json.string(row.0)
    Error(Nil) -> json.string("")
  }
}

/// Decode one of the words in `table`, failing with `fallback` for any other
/// so that an unknown word is an error and not a crash.
fn word_decoder(
  table: List(#(String, a)),
  fallback: a,
  name: String,
) -> Decoder(a) {
  use text <- decode.then(decode.string)

  // A word outside the table fails the decode with the fallback value, which
  // is what makes the decoder total.
  case list.find(table, fn(row) { row.0 == text }) {
    Ok(row) -> decode.success(row.1)
    Error(Nil) -> decode.failure(fallback, name)
  }
}

const senders: List(#(String, model.Sender)) = [
  #("owner", model.Owner),
  #("person", model.Person),
  #("listed_bot", model.ListedBot),
  #("ci_failure", model.CiFailure),
  #("unlisted", model.Unlisted),
]

const addressings: List(#(String, model.Addressing)) = [
  #("addressed", model.Addressed),
  #("unaddressed", model.Unaddressed),
]

const grants: List(#(String, ApprovalGrant)) = [
  #("granted", model.ApprovalsGranted),
  #("not_granted", model.ApprovalsNotGranted),
]

const relations: List(#(String, model.Relation)) = [
  #("duplicate", model.Duplicate),
  #("blocks", model.Blocks),
  #("follows", model.Follows),
]

const modes: List(#(String, model.Mode)) = [
  #("off", model.Off),
  #("observe", model.Observe),
  #("auto", model.Auto),
]

const verdicts: List(#(String, model.VerdictOutcome)) = [
  #("passed", model.VerdictPassed),
  #("failed", model.VerdictFailed),
]

const ceilings: List(#(String, model.Ceiling)) = [
  #("clear", model.CeilingClear),
  #("reached", model.CeilingReached),
]

const ends: List(#(String, model.SessionEnd)) = [
  #("exited", model.SessionExited),
  #("crashed", model.SessionCrashed),
]

const outcomes: List(#(String, model.Outcome)) = [
  #("merged", model.Merged),
  #("closed", model.Closed),
  #("abandoned", model.Abandoned),
  #("stopped", model.StoppedByPerson),
]

const scopes: List(#(String, model.PathScope)) = [
  #("touched", model.ProtectedPathsTouched),
  #("untouched", model.ProtectedPathsUntouched),
]
