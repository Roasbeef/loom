//// What the router may do with a candidate: accept, attach, resume, stop or
//// ignore.
////
//// The router reads hostile text by design, so this module assumes it can be
//// turned and bounds what that buys. A router can only route a trigger it was
//// offered. It cannot set strength, because its events carry none: the gate
//// fixed that when the trigger arrived, and `work.open` builds the mandate
//// from the stored verdict. Accepting, attaching or resuming with an inferred
//// trigger needs the gate's `Proceed`, and in `Observe` mode records
//// `WouldAccept` and changes nothing else. Stopping needs a trigger the gate
//// admitted as a person's explicit message, because a bot's comment must not
//// be able to stop a person's ticket. A trigger accepted twice makes one
//// ticket, because the ticket id derives from the trigger id.
////
//// A routing decision refers to other records only by id, and an id the state
//// does not hold refuses the whole decision before anything changes.

import gleam/list
import gleam/option
import gleam/result
import project/event.{type Refusal}
import project/gate.{Admitted, NotAdmitted, Proceed, RecordOnly, Refuse}
import project/model.{
  type Routing, type TicketId, type TriggerId, Accept, Attach, Explicit,
  Inferred, Resume,
}
import project/schedule
import project/state.{
  type State, type Step, type TriggerRecord, Decided, Granted, Offered,
  Withdrawn,
}
import project/work

/// Apply one routing decision.
///
/// ## Examples
///
/// ```gleam
/// // -> Error(NotOffered(id)) for a trigger the router was not shown
/// ```
pub fn route(current: State, routing: Routing) -> Step {
  use stored <- result.try(state.record(current, routing.trigger))

  // Only a candidate the router was offered can be routed, and routing an
  // accepted trigger again is a no-op.
  case stored.fate {
    Offered -> routed(current, stored, routing)
    Decided(state.Accepted(_)) ->
      case routing.kind {
        Accept(_) -> Ok(#(current, []))
        Attach(_) -> Error(event.NotOffered(routing.trigger))
        Resume(_) -> Error(event.NotOffered(routing.trigger))
      }
    Decided(_) -> Error(event.NotOffered(routing.trigger))
    state.Awaiting -> Error(event.NotOffered(routing.trigger))
  }
}

/// Check a routing's references and the gate's acceptance, then act on it.
fn routed(current: State, stored: TriggerRecord, routing: Routing) -> Step {
  use _ <- result.try(check_references(current, routing))
  use acceptance <- result.try(authorize(current, stored))

  // The gate's acceptance decides whether the routing acts, is only recorded,
  // or is refused.
  case acceptance {
    RecordOnly -> Ok(#(settle(current, routing.trigger, state.WouldAccept), []))
    Proceed -> proceed(current, stored, routing)
    Refuse(reason) -> Error(event.AcceptRefused(reason))
  }
}

/// Every id a routing names must be one the state holds.
fn check_references(current: State, routing: Routing) -> Result(Nil, Refusal) {
  use _ <- result.try(
    result.all(list.map(routing.holds, fn(id) { state.record(current, id) })),
  )
  use _ <- result.try(
    result.all(
      list.map(routing.related, fn(link) { state.ticket(current, link.0) }),
    ),
  )

  // A hand-back reference, when present, must name a stored trigger.
  case routing.prior_hand_back {
    option.Some(id) -> result.map(state.record(current, id), fn(_) { Nil })
    option.None -> Ok(Nil)
  }
}

/// What the gate says about acting on this trigger.
fn authorize(
  current: State,
  stored: TriggerRecord,
) -> Result(gate.Acceptance, Refusal) {
  // A trigger the gate did not admit cannot be acted on.
  case stored.admission {
    NotAdmitted(_) -> Error(event.TriggerNotAdmitted(stored.trigger.id))
    Admitted(strength, _, _) -> {
      let trigger = stored.trigger
      let rule = option.map(trigger.inputs.rule, fn(matched) { matched.rule })
      Ok(gate.acceptance(strength, state.pair(current, trigger.source, rule)))
    }
  }
}

/// Carry out an authorized routing by its kind.
fn proceed(current: State, stored: TriggerRecord, routing: Routing) -> Step {
  let id = routing.trigger

  // The route kind decides whether a ticket is opened, extended or reopened.
  case routing.kind {
    Accept(title) -> {
      let opened = work.open(current, stored, title, routing)
      let decision = state.Accepted(model.ticket_for(id))
      Ok(schedule.run(settle(opened, id, decision)))
    }
    Attach(ticket) -> attach(current, routing, ticket)
    Resume(ticket) -> resume(current, routing, ticket)
  }
}

/// Attach a trigger to an open ticket.
fn attach(current: State, routing: Routing, id: TicketId) -> Step {
  use ticket <- result.try(state.ticket(current, id))

  // Only an open ticket with a standing mandate takes an attachment.
  case ticket.authority, ticket.outcome {
    Withdrawn(_), _ -> Error(event.TicketWithdrawn(id))
    Granted, option.Some(_) -> Error(event.TicketEnded(id))
    Granted, option.None ->
      hand_over(current, routing, ticket, state.Attached(id))
  }
}

/// Reopen an ended ticket with a trigger.
fn resume(current: State, routing: Routing, id: TicketId) -> Step {
  use ticket <- result.try(state.ticket(current, id))

  // Only an ended ticket whose mandate stands can be resumed. A person's stop
  // never resumes.
  case ticket.authority, ticket.outcome {
    Withdrawn(_), _ -> Error(event.TicketWithdrawn(id))
    Granted, option.None -> Error(event.TicketNotEnded(id))
    Granted, option.Some(_) -> {
      let reopened = state.Ticket(..ticket, outcome: option.None)
      hand_over(current, routing, reopened, state.Resumed(id))
    }
  }
}

/// Give an open ticket the trigger: subscribe it to the thread, deliver or
/// queue the input, and start a session if one is wanted and a slot is free.
fn hand_over(
  current: State,
  routing: Routing,
  ticket: state.Ticket,
  decision: state.Decision,
) -> Step {
  use stored <- result.try(state.record(current, routing.trigger))
  let noted = state.Ticket(..ticket, routings: [routing, ..ticket.routings])
  let linked =
    work.subscribe(
      state.put_ticket(current, noted),
      ticket.id,
      stored.trigger.thread,
    )
  let #(delivered, effects) =
    work.deliver_to(linked, ticket.id, routing.trigger)
  let #(scheduled, started) =
    schedule.run(settle(delivered, routing.trigger, decision))
  Ok(#(scheduled, list.append(effects, started)))
}

/// Fix a routed trigger's fate and take it off the router's table.
fn settle(current: State, id: TriggerId, decision: state.Decision) -> State {
  let decided = state.set_fate(current, id, Decided(decision))
  state.State(
    ..decided,
    offered: list.filter(decided.offered, fn(other) { other != id }),
  )
}

/// The router stopped a ticket on a person's explicit message.
///
/// ## Examples
///
/// ```gleam
/// // -> Error(NotAPersonsMessage(id)) for an inferred trigger
/// ```
pub fn stop(current: State, trigger: TriggerId, ticket: TicketId) -> Step {
  use stored <- result.try(state.record(current, trigger))

  // Only an offered trigger that the gate admitted as a person's explicit
  // message can stop a ticket.
  case stored.fate {
    Offered ->
      case stored.admission {
        Admitted(Explicit, _, _) -> stop_offered(current, trigger, ticket)
        Admitted(Inferred, _, _) -> Error(event.NotAPersonsMessage(trigger))
        NotAdmitted(_) -> Error(event.NotAPersonsMessage(trigger))
      }
    Decided(_) -> Error(event.NotOffered(trigger))
    state.Awaiting -> Error(event.NotOffered(trigger))
  }
}

/// Withdraw the ticket's mandate on the strength of an offered explicit
/// trigger.
fn stop_offered(current: State, trigger: TriggerId, id: TicketId) -> Step {
  use #(stopped, effects) <- result.try(work.message_stopped(
    current,
    id,
    trigger,
  ))
  Ok(#(settle(stopped, trigger, state.StoppedTicket(id)), effects))
}

/// The router ignored a candidate. The ignore stays in the ledger and a
/// person can requeue the trigger.
///
/// ## Examples
///
/// ```gleam
/// // -> Error(NotOffered(id)) for a trigger the router was not shown
/// ```
pub fn ignore(current: State, trigger: TriggerId) -> Step {
  use stored <- result.try(state.record(current, trigger))

  // Only an offered candidate can be ignored.
  case stored.fate {
    Offered -> Ok(#(settle(current, trigger, state.Ignored), []))
    Decided(_) -> Error(event.NotOffered(trigger))
    state.Awaiting -> Error(event.NotOffered(trigger))
  }
}
