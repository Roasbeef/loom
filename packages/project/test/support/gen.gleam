//// qcheck generators for the project package's values, used by the codec,
//// policy and engine property tests. Seeds are fixed by the tests that call
//// them; nothing here draws from a clock.

import gleam/int
import gleam/list
import gleam/string
import project/event.{type Event}
import project/host
import project/model.{
  type CommitId, type Head, type Inputs, type Mandate, type Report,
  type RouteKind, type Routing, type RuleMatch, type Trigger, ActorId,
  CommandDigest, CommitId, EntryId, PrincipalId, Routing, RuleId, RuleMatch,
  SessionId, SourceId, ThreadId, TicketId, Trigger, TriggerId,
}
import qcheck.{type Generator}

/// One of the listed values, uniformly.
pub fn one_of(values: List(a)) -> Generator(a) {
  case values {
    [first, ..rest] ->
      qcheck.from_generators(
        qcheck.return(first),
        list.map(rest, qcheck.return),
      )
    [] -> panic as "one_of needs at least one value"
  }
}

fn tricky_codepoint() -> Generator(Int) {
  qcheck.from_generators(qcheck.bounded_int(0x20, 0x7E), [
    qcheck.bounded_int(0x300, 0x36F),
    qcheck.bounded_int(0x1F600, 0x1F64F),
    qcheck.bounded_int(0xA0, 0x2FF),
  ])
}

/// Text that includes quotes, backslashes, combining marks and emoji.
pub fn text() -> Generator(String) {
  qcheck.from_generators(qcheck.string(), [
    qcheck.generic_string(
      qcheck.map(tricky_codepoint(), codepoint),
      qcheck.bounded_int(0, 8),
    ),
    qcheck.return("\"\\\n"),
  ])
}

fn codepoint(code: Int) -> UtfCodepoint {
  case string.utf_codepoint(code) {
    Ok(point) -> point
    Error(Nil) -> panic as "the generator offered a surrogate"
  }
}

/// A short identifier with a prefix, from a small pool so values collide.
pub fn ident(prefix: String) -> Generator(String) {
  qcheck.map(qcheck.bounded_int(0, 5), fn(n) { prefix <> int.to_string(n) })
}

pub fn trigger_id() -> Generator(model.TriggerId) {
  qcheck.map(text(), TriggerId)
}

pub fn ticket_id() -> Generator(model.TicketId) {
  qcheck.map(text(), TicketId)
}

pub fn commit() -> Generator(CommitId) {
  qcheck.map(text(), CommitId)
}

pub fn principal() -> Generator(model.PrincipalId) {
  qcheck.map(text(), PrincipalId)
}

pub fn sender() -> Generator(model.Sender) {
  one_of([
    model.Owner,
    model.Person,
    model.ListedBot,
    model.CiFailure,
    model.Unlisted,
  ])
}

pub fn addressing() -> Generator(model.Addressing) {
  one_of([model.Addressed, model.Unaddressed])
}

pub fn rule_match() -> Generator(RuleMatch) {
  qcheck.map2(
    qcheck.map(text(), RuleId),
    one_of([model.ApprovalsGranted, model.ApprovalsNotGranted]),
    RuleMatch,
  )
}

pub fn inputs() -> Generator(Inputs) {
  qcheck.map3(
    sender(),
    addressing(),
    qcheck.option_from(rule_match()),
    fn(sender, addressing, rule) { model.Inputs(sender:, addressing:, rule:) },
  )
}

pub fn trigger() -> Generator(Trigger) {
  qcheck.map6(
    trigger_id(),
    qcheck.map(text(), SourceId),
    qcheck.map(text(), ThreadId),
    qcheck.map(text(), ActorId),
    inputs(),
    qcheck.tuple2(
      qcheck.bounded_int(0, 6),
      qcheck.bounded_int(0, 2_000_000_000),
    ),
    fn(id, source, thread, actor, inputs, times) {
      Trigger(
        id:,
        source:,
        thread:,
        actor:,
        inputs:,
        generation: times.0,
        at_ms: times.1,
      )
    },
  )
}

pub fn route_kind() -> Generator(RouteKind) {
  qcheck.from_generators(
    qcheck.map(text(), fn(t) { model.Accept(model.title(t)) }),
    [
      qcheck.map(ticket_id(), model.Attach),
      qcheck.map(ticket_id(), model.Resume),
    ],
  )
}

pub fn routing() -> Generator(Routing) {
  qcheck.map5(
    trigger_id(),
    route_kind(),
    qcheck.list_from(trigger_id()),
    qcheck.list_from(qcheck.tuple2(
      ticket_id(),
      one_of([model.Duplicate, model.Blocks, model.Follows]),
    )),
    qcheck.option_from(trigger_id()),
    fn(trigger, kind, holds, related, prior_hand_back) {
      Routing(trigger:, kind:, holds:, related:, prior_hand_back:)
    },
  )
}

pub fn report() -> Generator(Report) {
  qcheck.from_generators(qcheck.return(model.Progress), [
    qcheck.return(model.Waiting(model.NoQuestion)),
    qcheck.map(qcheck.bounded_int(0, 9), fn(n) {
      model.Waiting(model.Asking(n))
    }),
    qcheck.return(model.Blocked),
    qcheck.return(model.Failed),
    qcheck.return(model.Dropped),
  ])
}

pub fn head() -> Generator(Head) {
  qcheck.from_generators(qcheck.return(model.NoHead), [
    qcheck.map2(
      commit(),
      one_of([model.ProtectedPathsTouched, model.ProtectedPathsUntouched]),
      model.Head,
    ),
  ])
}

/// Any review reason. The host's words are capped when a reason is made, so
/// the generator makes them the same way.
pub fn review_reason() -> Generator(model.ReviewReason) {
  qcheck.from_generators(qcheck.return(model.NoCheckConfigured), [
    qcheck.return(model.PublishingOff),
    qcheck.map(text(), model.publish_unavailable),
    qcheck.map(text(), model.check_unfinished),
    qcheck.map(text(), model.intake_refused),
  ])
}

pub fn check_result() -> Generator(event.CheckResult) {
  qcheck.from_generators(
    qcheck.map3(
      commit(),
      qcheck.map(text(), CommandDigest),
      qcheck.map(text(), EntryId),
      fn(c, d, e) { event.CheckOk(host.passed(c, d, e)) },
    ),
    [
      qcheck.map2(
        commit(),
        qcheck.map(text(), CommandDigest),
        event.CheckRejected,
      ),
    ],
  )
}

/// Any event, with arbitrary text in every field.
pub fn event() -> Generator(Event) {
  let seq = qcheck.bounded_int(0, 5)
  let mode = one_of([model.Off, model.Observe, model.Auto])
  qcheck.from_generators(qcheck.return(event.RouterTurnEnded), [
    qcheck.map2(trigger(), qcheck.map(text(), ActorId), event.TriggerArrived),
    qcheck.map(routing(), event.Routed),
    qcheck.map2(trigger_id(), ticket_id(), event.RoutedStop),
    qcheck.map(trigger_id(), event.RoutedIgnore),
    qcheck.map2(trigger_id(), principal(), event.Requeued),
    qcheck.map3(
      qcheck.map(text(), SourceId),
      qcheck.map(text(), RuleId),
      mode,
      event.ModeSet,
    ),
    qcheck.map4(
      qcheck.map(text(), SourceId),
      qcheck.map(text(), RuleId),
      text(),
      one_of([model.VerdictPassed, model.VerdictFailed]),
      event.VerdictRecorded,
    ),
    qcheck.map(text(), event.PolicyVersionSet),
    qcheck.map(
      one_of([model.CeilingClear, model.CeilingReached]),
      event.CeilingChanged,
    ),
    qcheck.map3(
      ticket_id(),
      seq,
      qcheck.map(text(), SessionId),
      event.SessionBound,
    ),
    qcheck.map2(ticket_id(), seq, event.AssignmentLive),
    qcheck.map3(
      ticket_id(),
      seq,
      one_of([model.SessionExited, model.SessionCrashed, model.SessionRested]),
      event.AssignmentEnded,
    ),
    qcheck.map3(ticket_id(), seq, text(), event.WorkerFailed),
    qcheck.map4(ticket_id(), seq, report(), head(), event.Reported),
    qcheck.map3(ticket_id(), seq, head(), event.HeadObserved),
    qcheck.map3(ticket_id(), commit(), review_reason(), event.ReviewRequested),
    qcheck.map3(ticket_id(), seq, principal(), event.Answered),
    qcheck.map2(ticket_id(), trigger_id(), event.InputFailed),
    qcheck.map2(ticket_id(), trigger_id(), event.InputDelivered),
    qcheck.map2(ticket_id(), check_result(), event.CheckFinished),
    qcheck.map3(ticket_id(), principal(), commit(), event.PersonPublished),
    qcheck.map2(ticket_id(), principal(), event.PersonStopped),
    qcheck.map2(ticket_id(), principal(), event.PersonClosed),
    qcheck.map2(ticket_id(), principal(), event.RetryRequested),
    qcheck.map2(
      ticket_id(),
      qcheck.map(text(), model.PullRequestRef),
      event.PullRequestOpened,
    ),
    qcheck.map2(
      ticket_id(),
      one_of([
        model.Merged,
        model.Closed,
        model.Abandoned,
        model.StoppedByPerson,
      ]),
      event.Concluded,
    ),
  ])
}

/// A mandate with arbitrary authority and arbitrary everything else.
pub fn mandate() -> Generator(Mandate) {
  qcheck.map6(
    one_of([model.Explicit, model.Inferred]),
    one_of([
      model.FromComposer,
      model.FromAddressed,
      model.FromFollowUp,
      model.FromOverheard,
      model.FromAutomation,
    ]),
    qcheck.map(text(), ActorId),
    qcheck.map(text(), SourceId),
    qcheck.tuple2(
      text(),
      one_of([model.ApprovalsGranted, model.ApprovalsNotGranted]),
    ),
    text(),
    fn(strength, basis, actor, source, scope, policy_version) {
      model.Mandate(
        strength:,
        basis:,
        actor:,
        source:,
        scope: model.Scope(scope.0, scope.1),
        policy_version:,
      )
    },
  )
}
