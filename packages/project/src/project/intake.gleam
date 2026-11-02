//// Where a trigger enters the engine: dedupe, own-message drop, the gate,
//// the thread record, subscriptions and the first hop to the router.
////
//// The order of the steps is the safety argument. A trigger already seen is
//// ignored, so a source that re-reads its stream cannot double-count. The
//// project's own messages are dropped before the gate, because an agent that
//// answers itself loops. The gate then fixes strength once, and every later
//// step reads that stored verdict instead of asking again. The thread
//// records the trigger whether or not it was admitted, so a person reading
//// it sees what the system saw. Only an admitted trigger is ever delivered
//// to a subscribed ticket or offered to the router: a comment from an
//// unlisted sender is recorded and goes no further, which is what keeps
//// hostile text away from a worker that holds a ticket on that thread.
////
//// Inferred triggers reach a subscribed ticket only when the gate would let
//// them be accepted, so a bot's comment on a thread never steers a worker
//// from a source whose pair is not in `Auto` with a current verdict.

import gleam/dict
import gleam/list
import gleam/option
import project/event.{type Effect}
import project/gate.{Admitted, NotAdmitted, Proceed}
import project/model.{
  type ActorId, type Reception, type Trigger, Explicit, Inferred, Received,
  Recorded, Thread, ThreadEntry,
}
import project/queue
import project/schedule
import project/state.{
  type State, type Step, type Ticket, type TriggerRecord, Awaiting, Decided,
  Granted, TriggerRecord,
}
import project/work

/// Take a trigger in. Always succeeds: a trigger the engine cannot use is
/// recorded and settled, never refused.
///
/// ## Examples
///
/// ```gleam
/// // -> Ok(#(state, [])) for a trigger seen before
/// ```
pub fn arrive(current: State, trigger: Trigger, bot: ActorId) -> Step {
  case dict.has_key(current.triggers, trigger.id) {
    True -> Ok(#(current, []))
    False ->
      case trigger.actor == bot {
        True -> Ok(drop_own(current, trigger))
        False -> Ok(admit(current, trigger))
      }
  }
}

/// The project's own message is stored settled and never touches a thread.
fn drop_own(current: State, trigger: Trigger) -> #(State, List(Effect)) {
  let stored =
    TriggerRecord(
      trigger:,
      admission: NotAdmitted(gate.OwnOutput),
      fate: Decided(state.OwnMessage),
    )
  #(store(current, stored), [])
}

/// Classify a trigger, record it on its thread, and either settle it or send
/// it on.
fn admit(current: State, trigger: Trigger) -> #(State, List(Effect)) {
  let admission = gate.classify(trigger, relation_of(current, trigger))

  // The gate's verdict decides whether the trigger is only recorded or may
  // travel on.
  case admission {
    NotAdmitted(_) -> {
      let stored =
        TriggerRecord(trigger:, admission:, fate: Decided(state.RecordedOnly))
      #(note_on_thread(store(current, stored), trigger, Recorded), [])
    }
    Admitted(strength, _, _) -> {
      let stored = TriggerRecord(trigger:, admission:, fate: Awaiting)
      let seen = note_on_thread(store(current, stored), trigger, Received)
      follow_or_route(seen, trigger, strength)
    }
  }
}

fn store(current: State, stored: TriggerRecord) -> State {
  state.State(
    ..current,
    triggers: dict.insert(current.triggers, stored.trigger.id, stored),
  )
}

/// Append the trigger to its thread, creating the thread on first use.
fn note_on_thread(
  current: State,
  trigger: Trigger,
  reception: Reception,
) -> State {
  let entry = ThreadEntry(trigger.id, reception)

  // A thread is created by its first entry.
  let thread = case dict.get(current.threads, trigger.thread) {
    Ok(found) -> Thread(..found, entries: [entry, ..found.entries])
    Error(Nil) -> Thread(trigger.thread, [entry])
  }

  state.State(
    ..current,
    threads: dict.insert(current.threads, trigger.thread, thread),
  )
}

/// Whether the sender already owns a ticket on the trigger's thread.
fn relation_of(current: State, trigger: Trigger) -> gate.ThreadRelation {
  let owns =
    list.any(subscribers(current, trigger), fn(ticket) {
      ticket.mandate.actor == trigger.actor
    })

  // Owning a ticket on the thread is what turns a follow-up explicit.
  case owns {
    True -> gate.OwnTicketThread
    False -> gate.UnrelatedThread
  }
}

// Tickets subscribed to the trigger's thread.
fn subscribers(current: State, trigger: Trigger) -> List(Ticket) {
  current.subscriptions
  |> list.filter(fn(link) { link.thread == trigger.thread })
  |> list.filter_map(fn(link) { dict.get(current.tickets, link.ticket) })
}

/// A follow-up goes straight to the tickets that follow its thread. What no
/// subscribed ticket takes is a candidate for the router.
fn follow_or_route(
  current: State,
  trigger: Trigger,
  strength: model.Strength,
) -> #(State, List(Effect)) {
  let takers =
    subscribers(current, trigger)
    |> list.filter(fn(ticket) { takes(current, ticket, trigger, strength) })

  // Tickets that take the trigger get it directly; with none, it is a
  // candidate for the router.
  case takers {
    [] -> queue.consider(current, trigger.id)
    [first, ..] -> {
      let delivered =
        list.fold(takers, #(current, []), fn(acc, ticket) {
          let #(so_far, effects) = acc
          let #(next, more) = work.deliver_to(so_far, ticket.id, trigger.id)
          #(next, list.append(effects, more))
        })
      let #(after, deliveries) = delivered
      let settled =
        state.set_fate(after, trigger.id, Decided(state.Delivered(first.id)))
      let #(scheduled, started) = schedule.run(settled)
      #(scheduled, list.append(deliveries, started))
    }
  }
}

/// An open ticket with a standing mandate takes an explicit trigger, and an
/// inferred one only when the gate would let it be accepted.
fn takes(
  current: State,
  ticket: Ticket,
  trigger: Trigger,
  strength: model.Strength,
) -> Bool {
  let open = ticket.outcome == option.None && ticket.authority == Granted

  // An explicit trigger reaches any open ticket; an inferred one only when the
  // gate would let it be accepted.
  case open, strength {
    False, _ -> False
    True, Explicit -> True
    True, Inferred -> {
      let rule = option.map(trigger.inputs.rule, fn(matched) { matched.rule })
      let pair = state.pair(current, trigger.source, rule)
      gate.acceptance(Inferred, pair) == Proceed
    }
  }
}
