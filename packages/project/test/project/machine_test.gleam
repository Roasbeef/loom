//// A model-based test of the whole engine: random event sequences, with the
//// design's invariants checked after every accepted event.
////
//// The engine is the only thing that can say what a state is, so the model
//// is the engine's own state, advanced by `apply`. What makes the check more
//// than a tautology is the shadow the system under test keeps beside it: a
//// log of accepted events, the commits for which the host's check passed,
//// the tickets a person stopped and the tickets a person's message reached.
//// Each invariant is stated against that shadow or against the effects a step
//// returned, never against a second copy of the engine's own logic.
////
//// ## The invariants, by tag
////
//// - `ready`: a ticket is `Ready` only at a commit the host's check passed
////   for, and only while that commit is its head.
//// - `deliver`: no effect delivers or offers a trigger the gate did not
////   admit, and every offered trigger is marked offered.
//// - `stopped`: a stopped ticket's mandate stays withdrawn, its demand is
////   cleared and it never gets another assignment.
//// - `shed`: no explicit trigger is ever shed.
//// - `slots`: live assignments never exceed `max_workers` plus one, general
////   ones never exceed `max_workers`, reserved ones never exceed one.
//// - `reserved`: only a ticket a person's message reached holds the reserved
////   slot.
//// - `offer`: a batch holds at most twenty candidates, explicit first.
//// - `check`: a check is requested exactly when a worker reports `Waiting`
////   with no question and an unchecked head free of protected paths.
//// - `inferred`: inferred work is accepted, attached or resumed only when
////   the gate says `Proceed`.
//// - `stop`: the router stops a ticket only on an explicit trigger.
//// - `queue`: only admitted triggers are queued, and a trigger is never both
////   queued and offered.
//// - `protected`: a ticket is never `Ready` at a commit whose diff touches a
////   protected path, however the check events are ordered.
//// - `unrouted`: a candidate is offered at most `queue.max_offers` times, and
////   one left unrouted had spent all of them.
//// - `limbo`: a trigger waiting for the router is in the queue and one the
////   router holds is on its table, so no candidate, explicit or inferred,
////   falls out of both.
//// - `replay`: replaying the accepted events rebuilds the final state.
//// - `snapshot`: the final state reads back from its snapshot, as the state
////   that retention keeps, which never drops an open ticket or an unsettled
////   trigger (`retire`).
////
//// A command names no identity by value that it could not find again: tickets
//// and offered triggers are drawn from the model, so deleting a command while
//// shrinking leaves later ones meaningful. The seed is a constant.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import project/engine
import project/event.{type Effect, type Event}
import project/gate
import project/host
import project/model.{
  type CommitId, type TicketId, type TriggerId, CommitId, Head, TriggerId,
}
import project/queue
import project/readiness
import project/snapshot
import project/state.{type State}
import qcheck.{type Generator}
import statem
import support/gen
import support/world

// --- the system under test and its shadow ------------------------------------------

fn project_config() -> state.Config {
  state.Config(..world.config(), queue_limit: 2)
}

fn project_state() -> State {
  state.start(project_config())
}

type Sut {
  Sut(
    state: State,
    log: List(Event),
    passed: Dict(TicketId, List(CommitId)),
    stopped: List(TicketId),
    reached: List(TicketId),
  )
}

fn fresh_sut() -> Sut {
  Sut(project_state(), [], dict.new(), [], [])
}

fn violation(tag: String, detail: String) -> statem.Violation {
  statem.Violation(tag:, detail:)
}

// Hold an invariant or fail with its tag.
fn holds(
  ok ok: Bool,
  tag tag: String,
  detail detail: String,
) -> Result(Nil, statem.Violation) {
  case ok {
    True -> Ok(Nil)
    False -> Error(violation(tag, detail))
  }
}

// --- generators --------------------------------------------------------------------

fn pool(prefix: String, size: Int) -> Generator(String) {
  qcheck.map(qcheck.bounded_int(0, size - 1), fn(n) {
    prefix <> int.to_string(n)
  })
}

// Zero up to, not including, `size`.
fn counted(size: Int) -> List(Int) {
  list.index_map(list.repeat(Nil, size), fn(_, position) { position })
}

// Offered triggers when there are any, doubled in weight, else the pool.
fn trigger_ids(current: State) -> Generator(TriggerId) {
  let pooled =
    list.map(counted(10), fn(n) { TriggerId("k" <> int.to_string(n)) })
  gen.one_of(list.flatten([current.offered, current.offered, pooled]))
}

// Existing tickets when there are any, with an occasional unknown id so
// refusals stay covered.
fn ticket_ids(current: State) -> Generator(TicketId) {
  let derived =
    list.map(counted(10), fn(n) {
      model.ticket_for(TriggerId("k" <> int.to_string(n)))
    })
  case current.order {
    [] -> gen.one_of(derived)
    [_, ..] ->
      gen.one_of(
        list.flatten([current.order, current.order, current.order, derived]),
      )
  }
}

fn arrival() -> Generator(Event) {
  qcheck.map6(
    pool("k", 14),
    pool("th", 4),
    gen.one_of(["me", "pat", "eve", "loom-bot"]),
    qcheck.tuple2(gen.sender(), gen.addressing()),
    qcheck.tuple2(
      gen.one_of([None, world.matched(), world.matched()]),
      qcheck.bounded_int(0, 4),
    ),
    gen.one_of(["github", "slack"]),
    fn(id, thread, actor, who, rule, source) {
      event.TriggerArrived(
        model.Trigger(
          id: TriggerId(id),
          source: model.SourceId(source),
          thread: model.ThreadId(thread),
          actor: model.ActorId(actor),
          inputs: model.Inputs(who.0, who.1, rule.0),
          generation: rule.1,
          at_ms: 1,
        ),
        world.bot,
      )
    },
  )
}

fn routed(current: State) -> Generator(Event) {
  qcheck.bind(trigger_ids(current), fn(trigger) {
    qcheck.bind(ticket_ids(current), fn(ticket) {
      qcheck.from_weighted_generators(
        #(8, qcheck.return(route(trigger, model.Accept(model.title("t"))))),
        [
          #(3, qcheck.return(route(trigger, model.Attach(ticket)))),
          #(2, qcheck.return(route(trigger, model.Resume(ticket)))),
          #(3, qcheck.return(event.RoutedStop(trigger, ticket))),
          #(2, qcheck.return(event.RoutedIgnore(trigger))),
        ],
      )
    })
  })
}

fn route(trigger: TriggerId, kind: model.RouteKind) -> Event {
  event.Routed(model.Routing(trigger, kind, [], [], None))
}

// Project-level controls, leaning towards getting a pair into `Auto` so that
// inferred work is reached: a pair without a current verdict is first given
// one, then switched on. Everything else stays possible.
fn project_controls(current: State) -> Generator(Event) {
  qcheck.bind(
    gen.one_of([model.SourceId("github"), model.SourceId("slack")]),
    fn(source) {
      let ready =
        state.verdict_of(current, source, world.rule) == gate.VerdictCurrent
      let lean = case ready {
        True -> event.ModeSet(source, world.rule, model.Auto)
        False ->
          event.VerdictRecorded(source, world.rule, "v1", model.VerdictPassed)
      }
      qcheck.from_weighted_generators(#(8, qcheck.return(lean)), [
        #(
          2,
          qcheck.map(
            gen.one_of([model.Off, model.Observe, model.Auto]),
            fn(mode) { event.ModeSet(source, world.rule, mode) },
          ),
        ),
        #(
          1,
          qcheck.map2(
            gen.one_of(["v1", "v2"]),
            gen.one_of([model.VerdictPassed, model.VerdictFailed]),
            fn(version, outcome) {
              event.VerdictRecorded(source, world.rule, version, outcome)
            },
          ),
        ),
        #(1, qcheck.map(gen.one_of(["v1", "v2"]), event.PolicyVersionSet)),
        #(
          1,
          qcheck.map(
            gen.one_of([model.CeilingClear, model.CeilingReached]),
            event.CeilingChanged,
          ),
        ),
      ])
    },
  )
}

// Events about one ticket, with the commit chosen from what the ticket holds
// so that checks and publications have a chance to match.
fn ticket_events(current: State) -> Generator(Event) {
  qcheck.bind(ticket_ids(current), fn(ticket) {
    let held = case dict.get(current.tickets, ticket) {
      Ok(found) -> option.or(found.last_checked, found.head)
      Error(Nil) -> None
    }
    let commit = case held {
      Some(commit) -> qcheck.return(commit)
      None -> qcheck.map(pool("c", 3), CommitId)
    }
    let known = case dict.get(current.tickets, ticket) {
      Ok(found) -> list.length(found.assignments)
      Error(Nil) -> 0
    }
    let seq = qcheck.bounded_int(1, int.max(1, known))
    let by = qcheck.return(model.PrincipalId("owner"))
    qcheck.from_weighted_generators(#(10, reported(ticket, seq)), [
      #(6, observed(ticket, seq)),
      #(2, reviews(ticket, commit)),
      #(5, qcheck.map(seq, event.AssignmentLive(ticket, _))),
      #(
        4,
        qcheck.map2(
          seq,
          gen.one_of([model.SessionExited, model.SessionCrashed]),
          fn(s, end) { event.AssignmentEnded(ticket, s, end) },
        ),
      ),
      #(
        1,
        qcheck.map(seq, fn(s) {
          event.SessionBound(
            ticket,
            s,
            model.SessionId("s" <> int.to_string(s)),
          )
        }),
      ),
      #(
        2,
        qcheck.map2(qcheck.bounded_int(1, 2), by, fn(q, who) {
          event.Answered(ticket, q, who)
        }),
      ),
      #(
        1,
        qcheck.map(pool("k", 10), fn(t) {
          event.InputFailed(ticket, TriggerId(t))
        }),
      ),
      #(
        1,
        qcheck.map(pool("k", 10), fn(t) {
          event.InputDelivered(ticket, TriggerId(t))
        }),
      ),
      #(5, qcheck.map2(commit, passes(), fn(c, ok) { check(ticket, c, ok) })),
      #(
        2,
        qcheck.map2(commit, by, fn(c, who) {
          event.PersonPublished(ticket, who, c)
        }),
      ),
      #(3, qcheck.map(by, event.PersonStopped(ticket, _))),
      #(2, qcheck.map(by, event.RetryRequested(ticket, _))),
      #(
        2,
        qcheck.return(event.PullRequestOpened(ticket, model.PullRequestRef("u"))),
      ),
      #(
        2,
        qcheck.map(
          gen.one_of([
            model.Merged,
            model.Closed,
            model.Abandoned,
            model.StoppedByPerson,
          ]),
          event.Concluded(ticket, _),
        ),
      ),
    ])
  })
}

type Verdict {
  Pass
  Fail
}

fn passes() -> Generator(Verdict) {
  qcheck.from_weighted_generators(#(3, qcheck.return(Pass)), [
    #(1, qcheck.return(Fail)),
  ])
}

fn check(ticket: TicketId, commit: CommitId, verdict: Verdict) -> Event {
  case verdict {
    Pass ->
      event.CheckFinished(
        ticket,
        event.CheckOk(host.passed(
          commit,
          model.CommandDigest("d"),
          model.EntryId("e"),
        )),
      )
    Fail ->
      event.CheckFinished(
        ticket,
        event.CheckRejected(commit, model.CommandDigest("d")),
      )
  }
}

fn reported(ticket: TicketId, seq: Generator(Int)) -> Generator(Event) {
  qcheck.map3(seq, report_gen(), report_head(), fn(s, report, head) {
    event.Reported(ticket, s, report, head)
  })
}

// Mostly idle reports with no question, since those are what reach a check.
fn report_gen() -> Generator(model.Report) {
  qcheck.from_weighted_generators(
    #(8, qcheck.return(model.Waiting(model.NoQuestion))),
    [
      #(3, qcheck.return(model.Progress)),
      #(1, qcheck.return(model.Waiting(model.Asking(1)))),
      #(1, qcheck.return(model.Blocked)),
      #(1, qcheck.return(model.Failed)),
      #(1, qcheck.return(model.Dropped)),
    ],
  )
}

// Which commits touch protected paths. A commit's diff is a fact about the
// commit, so the host would report the same scope every time it read it, and
// the generator and the invariants read it from one place.
fn scope_of(commit: CommitId) -> model.PathScope {
  case commit {
    CommitId("c2") -> model.ProtectedPathsTouched
    CommitId(_) -> model.ProtectedPathsUntouched
  }
}

fn head_at(commit: CommitId) -> model.Head {
  Head(commit, scope_of(commit))
}

fn report_head() -> Generator(model.Head) {
  qcheck.from_weighted_generators(#(1, qcheck.return(model.NoHead)), [
    #(5, qcheck.map(pool("c", 3), fn(commit) { head_at(CommitId(commit)) })),
  ])
}

// The host's reading of a worker's head, and its reasons for asking a person.
fn observed(ticket: TicketId, seq: Generator(Int)) -> Generator(Event) {
  qcheck.map2(seq, pool("c", 3), fn(s, commit) {
    event.HeadObserved(ticket, s, head_at(CommitId(commit)))
  })
}

fn reviews(ticket: TicketId, commit: Generator(CommitId)) -> Generator(Event) {
  qcheck.map2(
    commit,
    gen.one_of([
      model.NoCheckConfigured,
      model.PublishingOff,
      model.publish_unavailable("no remote"),
    ]),
    fn(c, reason) { event.ReviewRequested(ticket, c, reason) },
  )
}

// The mix follows what the model can accept: a router with nothing offered
// cannot route, and a project with no tickets has none to report on.
fn command(current: State) -> Generator(Event) {
  let routable = case current.offered {
    [] -> 1
    [_, ..] -> 10
  }
  let ticketed = case current.order {
    [] -> 0
    [_, ..] -> 40
  }
  let turn = case list.append(current.offered, current.queue) {
    [] -> 1
    [_, ..] -> 6
  }
  let weighted = [
    #(routable, routed(current)),
    #(turn, qcheck.return(event.RouterTurnEnded)),
    #(
      2,
      qcheck.map(trigger_ids(current), fn(t) {
        event.Requeued(t, model.PrincipalId("owner"))
      }),
    ),
    #(10, project_controls(current)),
    ..case ticketed {
      0 -> []
      weight -> [#(weight, ticket_events(current))]
    }
  ]
  qcheck.from_weighted_generators(#(16, arrival()), weighted)
}

// --- the specification ---------------------------------------------------------------

fn spec() -> statem.Spec(State, Event, Sut) {
  statem.Spec(
    initial: project_state(),
    command:,
    precondition: fn(_, _) { statem.Admit },
    next_model: fn(model, incoming) {
      case engine.apply(model, incoming) {
        Ok(#(next, _)) -> next
        Error(_) -> model
      }
    },
    new_sut: fresh_sut,
    execute:,
    finish:,
    teardown: fn(_) { Nil },
  )
}

fn execute(
  sut: Sut,
  _model: State,
  incoming: Event,
) -> Result(Sut, statem.Violation) {
  case engine.apply(sut.state, incoming) {
    // A refusal leaves the state as it was; the shadow records nothing.
    Error(_) -> Ok(sut)
    Ok(#(next, effects)) -> {
      use _ <- result.try(check_step(sut, incoming, next, effects))
      let after = shadow(sut, incoming, next)
      use _ <- result.try(check_state(after))
      Ok(after)
    }
  }
}

fn finish(sut: Sut, _model: State) -> Result(Nil, statem.Violation) {
  use _ <- result.try(holds(
    ok: engine.replay(project_config(), list.reverse(sut.log)) == Ok(sut.state),
    tag: "replay",
    detail: "replaying the accepted events did not rebuild the state",
  ))
  use _ <- result.try(holds(
    ok: snapshot.decode(project_config(), snapshot.encode(sut.state))
      == Ok(sut.state),
    tag: "snapshot",
    detail: "the state did not read back from its snapshot",
  ))

  // Retention keeps a state that itself reads back, and keeps every ticket
  // that has not ended and every trigger that is not settled.
  let #(kept, _) = snapshot.retire(sut.state, 1_000_000_000)
  use _ <- result.try(holds(
    ok: snapshot.decode(project_config(), snapshot.encode(kept)) == Ok(kept),
    tag: "retire",
    detail: "a retired state did not read back from its snapshot",
  ))
  holds(
    ok: unsettled_kept(sut.state, kept),
    tag: "retire",
    detail: "retention dropped a ticket still open or a trigger still waiting",
  )
}

// Whether every open ticket and every unsettled trigger of `before` is in
// `after`.
fn unsettled_kept(before: State, after: State) -> Bool {
  let tickets =
    dict.values(before.tickets)
    |> list.all(fn(ticket) {
      ticket.outcome != None || dict.has_key(after.tickets, ticket.id)
    })
  let triggers =
    dict.values(before.triggers)
    |> list.all(fn(stored) {
      case stored.fate {
        state.Decided(state.Unrouted(_)) | state.Awaiting | state.Offered ->
          dict.has_key(after.triggers, stored.trigger.id)
        state.Decided(_) -> True
      }
    })
  tickets && triggers
}

// What the shadow learns from an accepted event.
fn shadow(sut: Sut, incoming: Event, next: State) -> Sut {
  let logged = Sut(..sut, state: next, log: [incoming, ..sut.log])

  case incoming {
    event.CheckFinished(ticket, event.CheckOk(proof)) ->
      Sut(
        ..logged,
        passed: dict.insert(sut.passed, ticket, [
          host.commit(proof),
          ..passed_for(sut, ticket)
        ]),
      )
    event.PersonStopped(ticket, _) ->
      Sut(..logged, stopped: [ticket, ..sut.stopped])
    event.RoutedStop(_, ticket) ->
      Sut(..logged, stopped: [ticket, ..sut.stopped])
    event.TriggerArrived(trigger, _) ->
      case explicit_in(next, trigger.id) {
        True ->
          Sut(
            ..logged,
            reached: list.append(
              subscribed(sut.state, trigger.thread),
              logged.reached,
            ),
          )
        False -> logged
      }
    event.Routed(routing) ->
      case explicit_in(next, routing.trigger) {
        True ->
          Sut(..logged, reached: [routed_ticket(routing), ..logged.reached])
        False -> logged
      }
    _ -> logged
  }
}

fn passed_for(sut: Sut, ticket: TicketId) -> List(CommitId) {
  case dict.get(sut.passed, ticket) {
    Ok(found) -> found
    Error(Nil) -> []
  }
}

fn routed_ticket(routing: model.Routing) -> TicketId {
  case routing.kind {
    model.Accept(_) -> model.ticket_for(routing.trigger)
    model.Attach(ticket) -> ticket
    model.Resume(ticket) -> ticket
  }
}

fn subscribed(current: State, thread: model.ThreadId) -> List(TicketId) {
  current.subscriptions
  |> list.filter(fn(link) { link.thread == thread })
  |> list.map(fn(link) { link.ticket })
}

fn explicit_in(current: State, id: TriggerId) -> Bool {
  case state.record(current, id) {
    Ok(stored) ->
      case stored.admission {
        gate.Admitted(model.Explicit, _, _) -> True
        gate.Admitted(model.Inferred, _, _) -> False
        gate.NotAdmitted(_) -> False
      }
    Error(_) -> False
  }
}

// --- invariants over one step ----------------------------------------------------------

fn check_step(
  sut: Sut,
  incoming: Event,
  next: State,
  effects: List(Effect),
) -> Result(Nil, statem.Violation) {
  use _ <- result.try(check_effects(sut, incoming, next, effects))
  use _ <- result.try(check_check_rule(sut, incoming, effects))
  use _ <- result.try(check_routing(sut, incoming, next))
  check_inferred_delivery(sut, incoming, next, effects)
}

fn check_effects(
  sut: Sut,
  incoming: Event,
  next: State,
  effects: List(Effect),
) -> Result(Nil, statem.Violation) {
  list.try_each(effects, fn(effect) {
    case effect {
      event.Deliver(ticket, _, trigger) ->
        holds(
          ok: admitted_in(next, trigger) || is_answer(incoming, ticket, trigger),
          tag: "deliver",
          detail: "delivered a trigger the gate did not admit",
        )
      event.OfferCandidates(triggers) -> check_offer(next, triggers)
      event.StartSession(ticket, _, _, _) ->
        holds(
          ok: !list.contains(sut.stopped, ticket),
          tag: "stopped",
          detail: "a stopped ticket was given an assignment",
        )
      event.RequestCheck(_, _) -> Ok(Nil)
      event.PublishBranch(_, _, _) -> Ok(Nil)
      event.StopSession(_, _) -> Ok(Nil)
      event.ObserveHead(_, _) -> Ok(Nil)
    }
  })
}

// A person's answer is delivered under the id derived from the ticket and the
// question they echoed, and it is the one delivery the gate did not admit,
// because it is not a trigger: a person typed it into the board.
fn is_answer(incoming: Event, ticket: TicketId, trigger: TriggerId) -> Bool {
  case incoming {
    event.Answered(answered, question, _) ->
      answered == ticket && trigger == model.answer_id(ticket, question)
    _ -> False
  }
}

fn admitted_in(current: State, id: TriggerId) -> Bool {
  case state.record(current, id) {
    Ok(stored) ->
      case stored.admission {
        gate.Admitted(_, _, _) -> True
        gate.NotAdmitted(_) -> False
      }
    Error(_) -> False
  }
}

fn check_offer(
  next: State,
  triggers: List(TriggerId),
) -> Result(Nil, statem.Violation) {
  use _ <- result.try(holds(
    ok: list.length(triggers) <= 20 && triggers != [],
    tag: "offer",
    detail: "a batch must hold between one and twenty candidates",
  ))
  use _ <- result.try(holds(
    ok: list.all(triggers, fn(id) { admitted_in(next, id) }),
    tag: "deliver",
    detail: "offered a trigger the gate did not admit",
  ))

  // Explicit first: once an inferred candidate appears, no explicit follows.
  let flags = list.map(triggers, fn(id) { explicit_in(next, id) })
  holds(
    ok: flags
      == list.append(
      list.filter(flags, fn(f) { f }),
      list.filter(flags, fn(f) { !f }),
    ),
    tag: "offer",
    detail: "an inferred candidate was offered ahead of an explicit one",
  )
}

// A check is requested exactly when a worker is idle with no question and an
// unchecked head free of protected paths.
fn check_check_rule(
  sut: Sut,
  incoming: Event,
  effects: List(Effect),
) -> Result(Nil, statem.Violation) {
  let requested =
    list.filter_map(effects, fn(effect) {
      case effect {
        event.RequestCheck(ticket, commit) -> Ok(#(ticket, commit))
        _ -> Error(Nil)
      }
    })

  case idle_head(incoming) {
    Some(#(ticket, commit)) -> {
      let unchecked = case state.ticket(sut.state, ticket) {
        Ok(found) -> found.last_checked != Some(commit)
        Error(_) -> False
      }
      holds(
        ok: requested
          == case unchecked {
          True -> [#(ticket, commit)]
          False -> []
        },
        tag: "check",
        detail: "a check was requested, or skipped, against the rule",
      )
    }
    None ->
      holds(
        ok: requested == [],
        tag: "check",
        detail: "a check was requested by something other than an idle report",
      )
  }
}

// The ticket and commit of an idle worker's head that is free of protected
// paths, whether it arrived with the report or was read by the host after it.
// Both are the moments the check rule may request a check, and a head that
// touches a protected path is never among them.
fn idle_head(incoming: Event) -> Option(#(TicketId, CommitId)) {
  case incoming {
    event.Reported(
      ticket,
      _,
      model.Waiting(model.NoQuestion),
      Head(commit, model.ProtectedPathsUntouched),
    ) -> Some(#(ticket, commit))
    event.HeadObserved(ticket, _, Head(commit, model.ProtectedPathsUntouched)) ->
      Some(#(ticket, commit))
    _ -> None
  }
}

// An inferred trigger reaches a subscribed worker only when the gate would
// let it be accepted.
fn check_inferred_delivery(
  sut: Sut,
  incoming: Event,
  next: State,
  effects: List(Effect),
) -> Result(Nil, statem.Violation) {
  case incoming {
    event.TriggerArrived(trigger, _) -> {
      let delivered =
        list.any(effects, fn(effect) {
          case effect {
            event.Deliver(_, _, id) -> id == trigger.id
            _ -> False
          }
        })
      let rule = option.map(trigger.inputs.rule, fn(matched) { matched.rule })
      let pair = state.pair(sut.state, trigger.source, rule)

      case delivered, strength_in(next, trigger.id) {
        True, Some(model.Inferred) ->
          holds(
            ok: gate.acceptance(model.Inferred, pair) == gate.Proceed,
            tag: "inferred",
            detail: "an inferred trigger was delivered without the gate's say-so",
          )
        _, _ -> Ok(Nil)
      }
    }
    _ -> Ok(Nil)
  }
}

// Inferred work moves only on the gate's say-so, and only a person's explicit
// message stops a ticket.
fn check_routing(
  sut: Sut,
  incoming: Event,
  next: State,
) -> Result(Nil, statem.Violation) {
  case incoming {
    event.Routed(routing) ->
      case
        strength_in(sut.state, routing.trigger),
        decided_work(next, routing.trigger)
      {
        Some(model.Inferred), True ->
          check_gate_proceeds(sut.state, routing.trigger)
        _, _ -> Ok(Nil)
      }
    event.RoutedStop(trigger, _) ->
      holds(
        ok: strength_in(sut.state, trigger) == Some(model.Explicit),
        tag: "stop",
        detail: "a ticket was stopped on a trigger that is not a person's explicit message",
      )
    _ -> Ok(Nil)
  }
}

fn strength_in(current: State, id: TriggerId) -> Option(model.Strength) {
  case state.record(current, id) {
    Ok(stored) ->
      case stored.admission {
        gate.Admitted(strength, _, _) -> Some(strength)
        gate.NotAdmitted(_) -> None
      }
    Error(_) -> None
  }
}

// Whether the routed trigger turned into work: accepted, attached or resumed.
fn decided_work(next: State, id: TriggerId) -> Bool {
  case state.record(next, id) {
    Ok(stored) ->
      case stored.fate {
        state.Decided(state.Accepted(_)) -> True
        state.Decided(state.Attached(_)) -> True
        state.Decided(state.Resumed(_)) -> True
        state.Decided(_) -> False
        state.Awaiting -> False
        state.Offered -> False
      }
    Error(_) -> False
  }
}

fn check_gate_proceeds(
  before: State,
  id: TriggerId,
) -> Result(Nil, statem.Violation) {
  case state.record(before, id) {
    Error(_) -> Ok(Nil)
    Ok(stored) -> {
      let trigger = stored.trigger
      let rule = option.map(trigger.inputs.rule, fn(matched) { matched.rule })
      let pair = state.pair(before, trigger.source, rule)
      holds(
        ok: gate.acceptance(model.Inferred, pair) == gate.Proceed
          || stored.fate != state.Offered,
        tag: "inferred",
        detail: "inferred work moved without Auto, a rule and a current verdict",
      )
    }
  }
}

// --- invariants over a state -------------------------------------------------------------

fn check_state(sut: Sut) -> Result(Nil, statem.Violation) {
  let current = sut.state
  use _ <- result.try(check_slots(current))
  use _ <- result.try(check_tickets(sut))
  use _ <- result.try(check_triggers(current))
  Ok(Nil)
}

fn check_slots(current: State) -> Result(Nil, statem.Violation) {
  let general = state.slots_used(current, state.General)
  let reserved = state.slots_used(current, state.Reserved)
  use _ <- result.try(holds(
    ok: general <= current.config.max_workers && reserved <= 1,
    tag: "slots",
    detail: "slots used: general "
      <> int.to_string(general)
      <> ", reserved "
      <> int.to_string(reserved),
  ))
  holds(
    ok: general + reserved <= current.config.max_workers + 1,
    tag: "slots",
    detail: "live assignments passed max_workers plus one",
  )
}

fn check_tickets(sut: Sut) -> Result(Nil, statem.Violation) {
  list.try_each(dict.values(sut.state.tickets), fn(ticket) {
    use _ <- result.try(check_readiness(sut, ticket))
    use _ <- result.try(check_withdrawal(ticket))
    check_reserved(sut, ticket)
  })
}

fn check_readiness(
  sut: Sut,
  ticket: state.Ticket,
) -> Result(Nil, statem.Violation) {
  case ticket.readiness {
    readiness.Ready(proof) -> {
      use _ <- result.try(holds(
        ok: list.contains(passed_for(sut, ticket.id), host.commit(proof))
          && ticket.head == Some(host.commit(proof)),
        tag: "ready",
        detail: "a ticket is Ready without a passing check at its head",
      ))

      // A commit that touches a protected path is never checked, so it is
      // never vouched for.
      holds(
        ok: scope_of(host.commit(proof)) == model.ProtectedPathsUntouched,
        tag: "protected",
        detail: "a ticket is Ready at a commit that touches protected paths",
      )
    }
    readiness.Published(_, commit) ->
      holds(
        ok: ticket.head == Some(commit),
        tag: "ready",
        detail: "a published commit is not the ticket's head",
      )
    readiness.InProgress -> Ok(Nil)
    readiness.AwaitingReview -> Ok(Nil)
  }
}

fn check_withdrawal(ticket: state.Ticket) -> Result(Nil, statem.Violation) {
  case ticket.authority {
    state.Granted -> Ok(Nil)
    state.Withdrawn(_) ->
      holds(
        ok: ticket.outcome == Some(model.StoppedByPerson)
          && ticket.demand == model.Satisfied
          && ticket.inbox == [],
        tag: "stopped",
        detail: "a withdrawn ticket still wants a session",
      )
  }
}

fn check_reserved(
  sut: Sut,
  ticket: state.Ticket,
) -> Result(Nil, statem.Violation) {
  list.try_each(ticket.assignments, fn(assignment) {
    case assignment.slot {
      state.General -> Ok(Nil)
      state.Reserved ->
        holds(
          ok: assignment.wanted == model.ByPerson
            && list.contains(sut.reached, ticket.id),
          tag: "reserved",
          detail: "the reserved slot served something other than a person's message",
        )
    }
  })
}

fn check_triggers(current: State) -> Result(Nil, statem.Violation) {
  use _ <- result.try(
    list.try_each(dict.values(current.triggers), fn(stored) {
      case stored.admission, stored.fate {
        gate.Admitted(model.Explicit, _, _), state.Decided(state.Shed) ->
          Error(violation("shed", "an explicit trigger was shed"))
        _, _ -> Ok(Nil)
      }
    }),
  )
  use _ <- result.try(holds(
    ok: list.all(list.append(current.queue, current.offered), fn(id) {
      admitted_in(current, id)
    }),
    tag: "queue",
    detail: "a trigger the gate did not admit reached the router's queue",
  ))
  use _ <- result.try(holds(
    ok: list.all(current.queue, fn(id) { !list.contains(current.offered, id) }),
    tag: "queue",
    detail: "a trigger is both queued and offered",
  ))
  check_offers(current)
}

// The router's second chances are bounded, and no candidate is dropped on the
// way: every queued trigger is in the queue and every offered one is on the
// router's table, and a trigger left unrouted has been offered exactly as many
// times as the bound allows, so it was not given up on early.
fn check_offers(current: State) -> Result(Nil, statem.Violation) {
  list.try_each(dict.values(current.triggers), fn(stored) {
    let id = stored.trigger.id
    let offers = state.offer_count(current, id)
    use _ <- result.try(holds(
      ok: offers <= queue.max_offers,
      tag: "unrouted",
      detail: "a trigger was offered more than the bound allows",
    ))
    case stored.fate {
      state.Awaiting ->
        holds(
          ok: list.contains(current.queue, id),
          tag: "limbo",
          detail: "a waiting trigger is not in the queue",
        )
      state.Offered ->
        holds(
          ok: list.contains(current.offered, id),
          tag: "limbo",
          detail: "an offered trigger is not on the router's table",
        )
      state.Decided(state.Unrouted(state.NoDecision(counted))) ->
        holds(
          ok: counted == queue.max_offers && offers == counted,
          tag: "unrouted",
          detail: "a trigger was left unrouted before its offers were spent",
        )
      state.Decided(_) -> Ok(Nil)
    }
  })
}

// --- the tests -------------------------------------------------------------------------

const seed = 20_261_101

fn config() -> statem.Config {
  statem.default_config(seed:)
  |> statem.with_test_count(300)
  |> statem.with_max_commands(70)
}

fn describe(incoming: Event) -> String {
  string.inspect(incoming)
}

pub fn the_engine_keeps_every_invariant_over_random_event_sequences_test() {
  case statem.check(spec(), config()) {
    Ok(Nil) -> Nil
    Error(failure) -> panic as statem.report(failure, describe)
  }
}

// The generator must reach the states the invariants are about, or the check
// above could pass without ever testing them.
pub fn the_generator_reaches_the_states_the_invariants_guard_test() {
  let runs = counted(600)
  let finals =
    list.flat_map(runs, fn(run) {
      let commands = statem.commands(spec(), config(), run)
      let #(_, states) =
        list.fold(commands, #(project_state(), []), fn(acc, incoming) {
          let #(current, seen) = acc
          case engine.apply(current, incoming) {
            Ok(#(next, effects)) -> #(next, [#(next, effects), ..seen])
            Error(_) -> acc
          }
        })
      states
    })
  let any_state = fn(found: fn(State) -> Bool) {
    list.any(finals, fn(pair) { found(pair.0) })
  }
  let any_effect = fn(found: fn(Effect) -> Bool) {
    list.any(finals, fn(pair) { list.any(pair.1, found) })
  }
  let tickets = fn(current: State, found: fn(state.Ticket) -> Bool) {
    list.any(dict.values(current.tickets), found)
  }

  assert any_state(fn(s) { tickets(s, fn(t) { t.authority != state.Granted }) })
    as "a stopped ticket"
  assert any_state(fn(s) {
    tickets(s, fn(t) {
      case t.readiness {
        readiness.Ready(_) -> True
        _ -> False
      }
    })
  })
    as "a ready ticket"
  assert any_state(fn(s) {
    list.any(dict.values(s.triggers), fn(r) {
      r.fate == state.Decided(state.Shed)
    })
  })
    as "a shed trigger"
  assert any_state(fn(s) { state.slots_used(s, state.Reserved) > 0 })
    as "the reserved slot in use"
  assert any_state(fn(s) {
    tickets(s, fn(t) { t.mandate.strength == model.Inferred })
  })
    as "an inferred ticket"
  assert any_effect(fn(e) {
    case e {
      event.RequestCheck(_, _) -> True
      _ -> False
    }
  })
    as "a check request"
  assert any_effect(fn(e) {
    case e {
      event.OfferCandidates([_, _, ..]) -> True
      _ -> False
    }
  })
    as "a batch of several candidates"
  assert any_effect(fn(e) {
    case e {
      event.ObserveHead(_, _) -> True
      _ -> False
    }
  })
    as "a request to read a worker's head"
  assert any_effect(fn(e) {
    case e {
      event.PublishBranch(_, _, _) -> True
      _ -> False
    }
  })
    as "a branch to publish"
  assert any_state(fn(s) { state.unrouted(s) != [] }) as "an unrouted candidate"
  assert any_state(fn(s) {
    tickets(s, fn(t) { t.review != None && t.readiness != readiness.InProgress })
  })
    as "a ticket the host sent to a person"
  assert any_state(fn(s) {
    tickets(s, fn(t) {
      t.head != None && t.readiness == readiness.AwaitingReview
    })
  })
    as "a protected head waiting for review"
}
