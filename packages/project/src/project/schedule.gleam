//// Slot scheduling: which waiting tickets get a worker session now.
////
//// Capacity is `max_workers` general slots plus one reserved slot. The
//// reserved slot exists so that queued background work can never lock a
//// person out of a running ticket, so only a ticket whose demand comes from a
//// person's message may take it, and only when every general slot is full.
//// Tickets beyond capacity stay queued in the ledger; the engine never
//// pre-empts a running session.
////
//// Waiting tickets are served person-first and, within a kind, oldest first.
//// While the token ceiling is reached, tickets whose mandate is inferred are
//// skipped, and explicit ones still proceed. A ticket whose mandate a person
//// withdrew, or that has ended, is never assigned: the check is here, at the
//// one place an assignment is made, so no caller can forget it.

import gleam/list
import gleam/option.{None, Some}
import project/event.{type Effect, Deliver, StartSession}
import project/model.{
  ByPerson, ByRouting, CeilingReached, Inferred, Satisfied, Wanting,
}
import project/state.{
  type SlotKind, type State, type Ticket, Assignment, AssignmentPending, General,
  Granted, Reserved,
}

/// Assign sessions to as many waiting tickets as capacity allows.
///
/// ## Examples
///
/// ```gleam
/// let #(next, effects) = schedule.run(state.start(config))
/// assert effects == []
/// ```
pub fn run(current: State) -> #(State, List(Effect)) {
  let waiting = waiting_tickets(current)
  list.fold(waiting, #(current, []), fn(acc, ticket) {
    let #(so_far, effects) = acc
    let #(next, more) = assign(so_far, ticket.id)
    #(next, list.append(effects, more))
  })
}

/// Tickets wanting a session, person-demanded first, each group oldest first.
fn waiting_tickets(current: State) -> List(Ticket) {
  let wanting =
    state.tickets_oldest_first(current)
    |> list.filter(wants_session)
  let #(by_person, by_routing) =
    list.partition(wanting, fn(ticket) { ticket.demand == Wanting(ByPerson) })
  list.append(by_person, by_routing)
}

/// Whether a ticket is waiting, open, authorized and without a live session.
fn wants_session(ticket: Ticket) -> Bool {
  case ticket.demand {
    Satisfied -> False
    Wanting(_) ->
      ticket.outcome == None
      && ticket.authority == Granted
      && state.active_assignment(ticket) == None
  }
}

/// Give one waiting ticket a session if a slot it may use is free.
fn assign(current: State, id: model.TicketId) -> #(State, List(Effect)) {
  case state.ticket(current, id) {
    Error(_) -> #(current, [])
    Ok(ticket) ->
      case pick_slot(current, ticket) {
        None -> #(current, [])
        Some(slot) -> start_assignment(current, ticket, slot)
      }
  }
}

/// The slot a ticket may take now, if any. Inferred work stops at the token
/// ceiling; the reserved slot is a person's alone.
fn pick_slot(current: State, ticket: Ticket) -> option.Option(SlotKind) {
  let held_back =
    current.ceiling == CeilingReached && ticket.mandate.strength == Inferred
  let general_free =
    state.slots_used(current, General) < current.config.max_workers
  let reserved_free = state.slots_used(current, Reserved) < 1

  // The ceiling holds inferred work. A free general slot serves anyone, and
  // the reserved slot serves a person's demand only.
  case held_back, general_free, ticket.demand {
    True, _, _ -> None
    False, True, _ -> Some(General)
    False, False, Wanting(ByPerson) ->
      case reserved_free {
        True -> Some(Reserved)
        False -> None
      }
    False, False, Wanting(ByRouting) -> None
    False, False, Satisfied -> None
  }
}

/// Record the assignment and emit the session request, then the inbox as
/// deliveries. The request comes first so the host has a session to deliver to.
fn start_assignment(
  current: State,
  ticket: Ticket,
  slot: SlotKind,
) -> #(State, List(Effect)) {
  let seq = list.length(ticket.assignments) + 1

  // The demand records who wanted the session, which the reserved-slot audit
  // reads later.
  let wanted = case ticket.demand {
    Wanting(by) -> by
    Satisfied -> ByRouting
  }

  let assignment = Assignment(seq, None, slot, wanted, AssignmentPending)

  // The new worker has reported nothing, so the old report, which described
  // a worker that is gone, goes with it. A ticket that rested after an idle
  // report would otherwise read as idle again the moment its next worker
  // started, before that worker had done anything.
  let started =
    state.Ticket(
      ..ticket,
      assignments: [assignment, ..ticket.assignments],
      latest: None,
      failure: None,
      demand: Satisfied,
      inbox: [],
    )
  let key = model.request_key(current.config.project, ticket.id, seq)
  let deliveries =
    list.map(ticket.inbox, fn(trigger) { Deliver(ticket.id, seq, trigger) })

  #(state.put_ticket(current, started), [
    StartSession(ticket.id, seq, key, ticket.mandate),
    ..deliveries
  ])
}
