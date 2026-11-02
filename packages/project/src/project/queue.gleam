//// The candidate queue in front of the router: bounded per source, explicit
//// first, and shed from the inferred end.
////
//// The project has an adversary who can write comments, and the resources
//// they can spend are tokens and a person's attention. Tokens are protected
//// before any model runs, which is why every check in this module is pure.
//// An inferred candidate is held back when its source's tickets already wait
//// on a person beyond the attention limit, when the token ceiling is reached,
//// or when the gate would refuse to accept it anyway. Each source's queue is
//// bounded: when it is full an arriving inferred candidate is shed, and an
//// arriving explicit one makes room by shedding the oldest queued inferred
//// candidate of that source. An explicit candidate is never dropped. When no
//// inferred candidate is left to shed, explicit ones queue past the bound,
//// because refusing a person is worse than a long queue.
////
//// The router is offered at most `max_offer` candidates per turn, explicit
//// first, and only one batch is out at a time. Candidates that arrive during
//// a turn wait, and drain together at the next checkpoint.

import gleam/list
import gleam/option
import gleam/result
import project/event.{type Effect, OfferCandidates}
import project/gate.{Admitted, NotAdmitted, Proceed, RecordOnly, Refuse}
import project/model.{type TriggerId, CeilingReached, Explicit, Inferred}
import project/state.{
  type State, type TriggerRecord, Awaiting, Decided, HeldByAttention,
  HeldByCeiling, HeldByGate, Offered, RouterBusy, RouterIdle,
}

/// The most candidates one `OfferCandidates` effect carries.
pub const max_offer: Int = 20

/// Put an admitted, undelivered trigger in front of the router, or hold or
/// shed it. Returns the offer effect when a batch goes out.
///
/// ## Examples
///
/// ```gleam
/// // -> #(state, [OfferCandidates([id])]) for an explicit trigger and an idle router
/// ```
pub fn consider(current: State, id: TriggerId) -> #(State, List(Effect)) {
  case state.record(current, id) {
    Error(_) -> #(current, [])
    Ok(stored) -> consider_record(current, stored)
  }
}

/// Route an admitted trigger by strength; one the gate did not admit never
/// queues.
fn consider_record(
  current: State,
  stored: TriggerRecord,
) -> #(State, List(Effect)) {
  case stored.admission {
    NotAdmitted(_) -> #(current, [])
    Admitted(Explicit, _, _) -> enqueue(current, stored)
    Admitted(Inferred, _, _) -> consider_inferred(current, stored)
  }
}

/// An inferred candidate passes the gate's view of its pair, the attention
/// limit and the ceiling before it is even queued.
fn consider_inferred(
  current: State,
  stored: TriggerRecord,
) -> #(State, List(Effect)) {
  let trigger = stored.trigger
  let rule = option.map(trigger.inputs.rule, fn(matched) { matched.rule })
  let pair = state.pair(current, trigger.source, rule)

  // The gate's view of the pair decides whether an inferred candidate is worth
  // a router turn.
  case gate.acceptance(Inferred, pair) {
    Refuse(reason) -> hold(current, trigger.id, HeldByGate(reason))
    Proceed -> consider_load(current, stored)
    RecordOnly -> consider_load(current, stored)
  }
}

/// Load checks, after the gate has no objection.
fn consider_load(
  current: State,
  stored: TriggerRecord,
) -> #(State, List(Effect)) {
  let trigger = stored.trigger
  let attended =
    state.waiting_on_person(current, trigger.source)
    > current.config.attention_limit

  // Attention and the token ceiling hold inferred candidates back before they
  // cost a model call.
  case attended, current.ceiling {
    True, _ -> hold(current, trigger.id, HeldByAttention)
    False, CeilingReached -> hold(current, trigger.id, HeldByCeiling)
    False, model.CeilingClear -> enqueue(current, stored)
  }
}

/// Settle a trigger as held, with the reason, so that a person can see why it
/// never reached the router.
fn hold(
  current: State,
  id: TriggerId,
  reason: state.Hold,
) -> #(State, List(Effect)) {
  #(state.set_fate(current, id, Decided(state.Held(reason))), [])
}

/// Queue a candidate, shedding to keep its source within the bound.
fn enqueue(current: State, stored: TriggerRecord) -> #(State, List(Effect)) {
  let trigger = stored.trigger
  let full = queued_from(current, trigger.source) >= current.config.queue_limit

  // A full source queue sheds an inferred arrival and makes room for an
  // explicit one; otherwise the candidate queues.
  case full, stored.admission {
    False, _ -> offer(append(current, trigger.id))
    True, Admitted(Inferred, _, _) -> #(
      state.set_fate(current, trigger.id, Decided(state.Shed)),
      [],
    )
    True, Admitted(Explicit, _, _) ->
      offer(append(make_room(current, trigger.source), trigger.id))
    True, NotAdmitted(_) -> #(current, [])
  }
}

fn append(current: State, id: TriggerId) -> State {
  let queued = state.set_fate(current, id, Awaiting)
  state.State(..queued, queue: list.append(queued.queue, [id]))
}

/// Count a source's queued candidates.
fn queued_from(current: State, source: model.SourceId) -> Int {
  list.count(current.queue, fn(id) {
    case state.record(current, id) {
      Ok(stored) -> stored.trigger.source == source
      Error(_) -> False
    }
  })
}

/// Shed the oldest queued inferred candidate of the source, if there is one.
/// With none, nothing is shed and the explicit candidate queues past the bound.
fn make_room(current: State, source: model.SourceId) -> State {
  let victim =
    list.find(current.queue, fn(id) {
      case state.record(current, id) {
        Ok(stored) -> stored.trigger.source == source && is_inferred(stored)
        Error(_) -> False
      }
    })

  // With no queued inferred candidate to shed, nothing is dropped and the
  // explicit candidate queues past the bound.
  case victim {
    Error(Nil) -> current
    Ok(id) -> {
      let shed = state.set_fate(current, id, Decided(state.Shed))
      state.State(
        ..shed,
        queue: list.filter(shed.queue, fn(other) { other != id }),
      )
    }
  }
}

/// Whether the gate admitted the trigger at inferred strength.
fn is_inferred(stored: TriggerRecord) -> Bool {
  case stored.admission {
    Admitted(Inferred, _, _) -> True
    Admitted(Explicit, _, _) -> False
    NotAdmitted(_) -> False
  }
}

/// Offer the router a batch when it is idle and something is eligible.
/// Explicit candidates go first, then inferred ones unless the ceiling is
/// reached, up to `max_offer`.
///
/// ## Examples
///
/// ```gleam
/// // -> #(state, []) while a batch is already out
/// ```
pub fn offer(current: State) -> #(State, List(Effect)) {
  case current.router {
    RouterBusy -> #(current, [])
    RouterIdle -> offer_batch(current, batch(current))
  }
}

/// Hand a batch to the router and mark each candidate offered.
fn offer_batch(current: State, ids: List(TriggerId)) -> #(State, List(Effect)) {
  // An empty batch offers nothing; otherwise the router takes the batch and
  // the rest wait for its turn to end.
  case ids {
    [] -> #(current, [])
    [_, ..] -> {
      let marked =
        list.fold(ids, current, fn(acc, id) { state.set_fate(acc, id, Offered) })
      let remaining =
        list.filter(marked.queue, fn(id) { !list.contains(ids, id) })
      #(
        state.State(
          ..marked,
          queue: remaining,
          offered: list.append(marked.offered, ids),
          router: RouterBusy,
        ),
        [OfferCandidates(ids)],
      )
    }
  }
}

/// The next batch: explicit candidates in arrival order, then inferred ones
/// while the ceiling is clear, at most `max_offer` in all.
fn batch(current: State) -> List(TriggerId) {
  let #(explicit, inferred) =
    list.partition(current.queue, fn(id) {
      case state.record(current, id) {
        Ok(stored) -> !is_inferred(stored)
        Error(_) -> False
      }
    })

  // The ceiling removes inferred candidates from the next batch.
  let eligible = case current.ceiling {
    CeilingReached -> explicit
    model.CeilingClear -> list.append(explicit, inferred)
  }

  list.take(eligible, max_offer)
}

/// End the router's turn: candidates it left unrouted go to the back of the
/// queue, and the next batch is offered.
///
/// ## Examples
///
/// ```gleam
/// // -> #(state, []) with an empty queue
/// ```
pub fn turn_ended(current: State) -> #(State, List(Effect)) {
  let back =
    list.fold(current.offered, current, fn(acc, id) { append(acc, id) })
  offer(state.State(..back, offered: [], router: RouterIdle))
}

/// Queue a stored trigger the router ignored, shed or was never offered, for
/// a fresh evaluation. Triggers still queued, offered or already routed to
/// work are refused.
///
/// ## Examples
///
/// ```gleam
/// // -> Error(NotRequeueable(id)) for a trigger that became a ticket
/// ```
pub fn requeue(current: State, id: TriggerId) -> state.Step {
  use stored <- result.try(state.record(current, id))

  // Only a trigger that was ignored, shed, held or merely recorded as
  // would-accept can be evaluated again.
  case stored.fate {
    Decided(state.Ignored) -> Ok(consider(current, id))
    Decided(state.Shed) -> Ok(consider(current, id))
    Decided(state.Held(_)) -> Ok(consider(current, id))
    Decided(state.WouldAccept) -> Ok(consider(current, id))
    Awaiting -> Error(event.NotRequeueable(id))
    Offered -> Error(event.NotRequeueable(id))
    Decided(state.OwnMessage) -> Error(event.NotRequeueable(id))
    Decided(state.RecordedOnly) -> Error(event.NotRequeueable(id))
    Decided(state.Delivered(_)) -> Error(event.NotRequeueable(id))
    Decided(state.Accepted(_)) -> Error(event.NotRequeueable(id))
    Decided(state.Attached(_)) -> Error(event.NotRequeueable(id))
    Decided(state.Resumed(_)) -> Error(event.NotRequeueable(id))
    Decided(state.StoppedTicket(_)) -> Error(event.NotRequeueable(id))
  }
}
