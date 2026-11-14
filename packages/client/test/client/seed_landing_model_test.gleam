//// The decisions of a seeded spawn's landing against a model, and the delegate key
//// as an injective name (protocol-change/107, slice 4b).
////
//// `seed_on_executor_test` runs the real executor, a real repository and the
//// sandboxed Git through the cases the design names. This module asks a smaller
//// question about the decisions the landing takes: whatever order asks, failures,
//// retries and joins arrive in, does each failure get the treatment the design
//// gives it? `statem` draws sequences of those events for two children of one
//// parent, runs each against a simulation of the steps in the order
//// `spawn_seed.land` takes them, and compares the outcome with a pure model after
//// every command.
////
//// ## What it proves
////
//// The four functions of `client/seed_landing` (`gate`, `of_declined`,
//// `of_failure`, `keeps_verdict`) classify the generated faults as the table in
//// `expected` says: a failure that passes is retried and keeps no verdict, a
//// refusal of the content keeps one and ends the session, a record that cannot be
//// read is asked about again, and a fault-free ask after any of them converges.
//// Around that, the simulation checks at most one session for a child, a first
//// turn only on a seeded workspace, one effective apply however many were sent,
//// and a settled child holding no session. A census that refuses keeps no
//// verdict, and a child asked for again after its join starts afresh, as the code
//// does (the addendum lists that as open).
////
//// ## What it does not prove
////
//// It does not call `spawn_seed`. The simulation restates the order of the steps,
//// and a change to that order in the code is not seen here. It has no concurrency,
//// no claim, no restart and no real join; those are the P model's
//// (`protocol/models/seeded-spawn`) and `seed_on_executor_test`'s.
////
//// The seed and the sizes are constants, so the gate is deterministic.

import client/delegate_key.{type Key, Key}
import client/seed_landing
import client/session_states
import client/state_transfer
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import qcheck
import statem

const sequence_seed = 10_701

const sequence_count = 200

const sequence_length = 14

const property_seed = 10_702

const property_count = 300

// --- the delegate key ----------------------------------------------------------------

fn part() -> qcheck.Generator(String) {
  qcheck.string_from(qcheck.alphanumeric_ascii_codepoint())
  |> qcheck.map(fn(text) { "p" <> text })
}

fn keys() -> qcheck.Generator(Key) {
  qcheck.return({
    use spawner <- qcheck.parameter
    use parent <- qcheck.parameter
    use child <- qcheck.parameter
    Key(spawner:, parent:, child:)
  })
  |> qcheck.apply(part())
  |> qcheck.apply(part())
  |> qcheck.apply(qcheck.from_generators(qcheck.return(""), [part()]))
}

fn properties() -> qcheck.Config {
  qcheck.default_config()
  |> qcheck.with_test_count(property_count)
  |> qcheck.with_seed(qcheck.seed(property_seed))
}

pub fn the_key_of_a_child_is_never_the_key_of_the_pair_or_another_child_test() {
  qcheck.run(properties(), qcheck.tuple2(keys(), keys()), fn(drawn) {
    let #(one, other) = drawn
    assert { delegate_key.key(one) == delegate_key.key(other) }
      == { one == other }
  })
}

// --- what a failure means ----------------------------------------------------------

pub fn only_a_refusal_the_same_inputs_would_get_again_keeps_a_verdict_test() {
  // The executor's states that change are asked again.
  assert !seed_landing.keeps_verdict(
    seed_landing.of_declined(state_transfer.NoRoom("at its cap")),
  )
  assert !seed_landing.keeps_verdict(
    seed_landing.of_declined(state_transfer.OutOfOrder(4)),
  )
  assert !seed_landing.keeps_verdict(
    seed_landing.of_declined(state_transfer.Mismatch("another bundle")),
  )

  // The content the executor judges malformed is refused for good.
  assert seed_landing.keeps_verdict(
    seed_landing.of_declined(state_transfer.BadState("no")),
  )
  assert seed_landing.keeps_verdict(
    seed_landing.of_declined(state_transfer.BadPiece("no")),
  )
  assert seed_landing.keeps_verdict(
    seed_landing.of_declined(state_transfer.TooLarge(1)),
  )
  assert seed_landing.keeps_verdict(seed_landing.of_declined(
    state_transfer.NotServing,
  ))

  // An apply that must be asked again, and one the workspace refuses.
  assert !seed_landing.keeps_verdict(
    seed_landing.of_failure(session_states.Later("no answer")),
  )
  assert seed_landing.keeps_verdict(
    seed_landing.of_failure(session_states.Final("no")),
  )
}

pub fn a_record_that_cannot_be_read_is_asked_again_and_never_taken_for_begun_test() {
  assert seed_landing.gate(session_states.Unreadable) == seed_landing.AskAgain
  assert seed_landing.gate(session_states.Begun) == seed_landing.LeaveAlone
  assert seed_landing.gate(session_states.Fresh) == seed_landing.PutIn
}

// --- the model --------------------------------------------------------------------

// What can go wrong at a step of one ask.
type Fault {
  NoFault
  // The bundle is not all in this machine's store yet.
  HoldMissing
  // The registry could not find or make the child's session.
  SessionFails
  // The session's record could not be read.
  Unreadable
  // The census says the workspace takes no state.
  CensusShared
  // The executor's store has no room.
  NoRoom
  // The apply is answered from a fence that has moved on.
  StaleFence
  // The workspace refuses the state.
  ApplyRefused
  // The apply happened and its reply was lost.
  ReplyLost
  // The placement ran out of time.
  Deadline
  // The Agency's spawn failed for a reason that may pass.
  SpawnFails
}

type Command {
  Land(child: Int, fault: Fault)
  Join(child: Int)
}

// Where a child is in its life, as a sender who asks again sees it.
type Phase {
  NotStarted
  // A session exists and the child has not begun: an earlier ask failed after the
  // session was made.
  Pending
  Begun
  Refused
  Joined
}

type Model =
  Dict(Int, Phase)

// What an ask is answered with.
type Answer {
  Started
  AskAgain
  Declined
}

fn phase(model: Model, child: Int) -> Phase {
  result.unwrap(dict.get(model, child), NotStarted)
}

// What the design says an ask is answered with, from the phase and the fault
// alone. Reading it beside `ask` is the review.
fn expected(held: Phase, fault: Fault) -> Answer {
  case held, fault {
    // A refusal that was kept is answered again with no step taken.
    Refused, _ -> Declined

    // A child that began is answered, unless its record cannot be read, which is
    // not a reason to say it has begun.
    Begun, Unreadable -> AskAgain
    Begun, _ -> Started

    // A child whose session was ended at its join has no record of having begun,
    // so an ask for it again is an ask for a fresh child.
    Joined, found -> expected(NotStarted, found)

    // A child with a session already is not asked to find or make one, and its
    // census was read when the session was first made.
    Pending, NoFault | Pending, CensusShared | Pending, SessionFails -> Started
    Pending, ApplyRefused -> Declined
    Pending, HoldMissing
    | Pending, Unreadable
    | Pending, NoRoom
    | Pending, StaleFence
    | Pending, ReplyLost
    | Pending, Deadline
    | Pending, SpawnFails
    -> AskAgain

    NotStarted, NoFault -> Started
    NotStarted, CensusShared | NotStarted, ApplyRefused -> Declined
    NotStarted, HoldMissing
    | NotStarted, SessionFails
    | NotStarted, Unreadable
    | NotStarted, NoRoom
    | NotStarted, StaleFence
    | NotStarted, ReplyLost
    | NotStarted, Deadline
    | NotStarted, SpawnFails
    -> AskAgain
  }
}

// A joined child is asked about as a fresh one.
fn fresh_of(held: Phase) -> Phase {
  case held {
    Joined -> NotStarted
    NotStarted | Pending | Begun | Refused -> held
  }
}

fn step(model: Model, command: Command) -> Model {
  case command {
    Join(child) -> dict.insert(model, child, Joined)
    Land(child, fault) ->
      case expected(phase(model, child), fault) {
        Started -> dict.insert(model, child, Begun)

        // A census that refuses keeps no verdict, and the same ask is refused
        // again; any other refusal is kept.
        Declined ->
          case fault {
            CensusShared -> model
            _ -> dict.insert(model, child, Refused)
          }
        AskAgain ->
          case fresh_of(phase(model, child)), fault {
            // The session is made before these steps and left by their failure.
            NotStarted, Unreadable
            | NotStarted, NoRoom
            | NotStarted, StaleFence
            | NotStarted, ReplyLost
            | NotStarted, Deadline
            | NotStarted, SpawnFails
            -> dict.insert(model, child, Pending)
            _, _ -> model
          }
      }
  }
}

fn admitted(model: Model, command: Command) -> statem.Admission {
  case command {
    Join(child) ->
      case phase(model, child) {
        Begun -> statem.Admit
        NotStarted | Pending | Refused | Joined -> statem.Reject
      }
    Land(_, _) -> statem.Admit
  }
}

// --- the simulation ---------------------------------------------------------------

type Held {
  NoSession
  Session
}

type Workspace {
  Empty
  Seeded
}

type Turn {
  Waiting
  Running
}

// One child's session, workspace and counters on the machines that serve it.
type Child {
  Child(
    session: Held,
    workspace: Workspace,
    turn: Turn,
    // What the workspace held when the first turn began, once it has.
    first_turn_on: Option(Workspace),
    verdict: Option(String),
    makes: Int,
    releases: Int,
    requests: Int,
    effective: Int,
  )
}

fn new_child() -> Child {
  Child(
    session: NoSession,
    workspace: Empty,
    turn: Waiting,
    first_turn_on: None,
    verdict: None,
    makes: 0,
    releases: 0,
    requests: 0,
    effective: 0,
  )
}

fn freshness(held: Child, fault: Fault) -> session_states.Freshness {
  case fault, held.turn {
    Unreadable, _ -> session_states.Unreadable
    _, Running -> session_states.Begun
    _, Waiting -> session_states.Fresh
  }
}

// A failed placement. A deterministic refusal is kept and ends the session; any
// other is not kept and leaves the session.
fn unplaced(held: Child, why: seed_landing.Unplaced) -> #(Child, Answer) {
  case seed_landing.keeps_verdict(why) {
    False -> #(held, AskAgain)
    True -> {
      let reason = case why {
        seed_landing.Retry(reason:) | seed_landing.Refuse(reason:) -> reason
      }
      #(release(Child(..held, verdict: Some(reason))), Declined)
    }
  }
}

fn release(held: Child) -> Child {
  case held.session {
    Session -> Child(..held, session: NoSession, releases: held.releases + 1)
    NoSession -> held
  }
}

// The executor takes an apply request: the workspace is seeded the first time,
// and a state it already holds is answered and touches nothing.
fn requested(held: Child) -> Child {
  case held.workspace {
    Empty ->
      Child(
        ..held,
        workspace: Seeded,
        requests: held.requests + 1,
        effective: held.effective + 1,
      )
    Seeded -> Child(..held, requests: held.requests + 1)
  }
}

fn apply(held: Child, fault: Fault) -> #(Child, Answer) {
  case fault {
    StaleFence ->
      unplaced(
        requested_not(held),
        seed_landing.of_failure(session_states.Later("fence moved")),
      )
    ApplyRefused ->
      unplaced(
        Child(..held, requests: held.requests + 1),
        seed_landing.of_failure(session_states.Final("not a state it takes")),
      )
    ReplyLost ->
      unplaced(
        requested(held),
        seed_landing.of_failure(session_states.Later("no answer")),
      )
    _ -> #(requested(held), Started)
  }
}

// A stale fence is refused before the executor does anything.
fn requested_not(held: Child) -> Child {
  Child(..held, requests: held.requests + 1)
}

// The delivery and the apply behind the begun check.
fn place(held: Child, fault: Fault) -> #(Child, Answer) {
  case fault {
    Deadline -> unplaced(held, seed_landing.Retry("did not finish in time"))
    NoRoom ->
      unplaced(
        held,
        seed_landing.of_declined(state_transfer.NoRoom("at its cap")),
      )
    _ ->
      case seed_landing.gate(freshness(held, fault)) {
        seed_landing.AskAgain ->
          unplaced(held, seed_landing.Retry(session_states.unreadable))
        seed_landing.LeaveAlone -> #(held, Started)
        seed_landing.PutIn -> apply(held, fault)
      }
  }
}

fn ask(held: Child, fault: Fault) -> #(Child, Answer) {
  case held.verdict, held.session {
    Some(_), _ -> #(held, Declined)
    None, Session ->
      case seed_landing.gate(freshness(held, fault)) {
        seed_landing.LeaveAlone -> #(held, Started)
        seed_landing.AskAgain -> #(held, AskAgain)

        // A session that is fresh still needs the whole bundle in the store.
        seed_landing.PutIn ->
          case fault {
            HoldMissing -> #(held, AskAgain)
            _ -> place(held, fault)
          }
      }
    None, NoSession ->
      case fault {
        HoldMissing | SessionFails -> #(held, AskAgain)

        // The census refuses before the claim, and the session just made is ended
        // with no verdict kept.
        CensusShared -> {
          let made = Child(..held, session: Session, makes: held.makes + 1)
          #(release(made), Declined)
        }
        _ ->
          place(Child(..held, session: Session, makes: held.makes + 1), fault)
      }
  }
}

// The Agency's spawn is the child's first turn, and it is made only after the
// landing answered started.
fn spawn(held: Child, fault: Fault) -> #(Child, Answer) {
  case held.turn, fault {
    Running, _ -> #(held, Started)
    Waiting, SpawnFails -> #(held, AskAgain)
    Waiting, _ -> #(
      Child(..held, turn: Running, first_turn_on: Some(held.workspace)),
      Started,
    )
  }
}

fn land(held: Child, fault: Fault) -> #(Child, Answer) {
  let #(after, answer) = ask(held, fault)
  case answer {
    Started -> spawn(after, fault)
    AskAgain | Declined -> #(after, answer)
  }
}

type World =
  Dict(Int, Child)

fn child_of(world: World, child: Int) -> Child {
  result.unwrap(dict.get(world, child), new_child())
}

fn violation(tag: String, detail: String) -> Result(a, statem.Violation) {
  Error(statem.Violation(tag:, detail:))
}

fn execute(
  world: World,
  model: Model,
  command: Command,
) -> Result(World, statem.Violation) {
  case command {
    Join(child) -> {
      // The session is ended, and with it the record of having begun and the
      // workspace: a session made for the child afterwards is fresh.
      let held =
        Child(
          ..release(child_of(world, child)),
          workspace: Empty,
          turn: Waiting,
          first_turn_on: None,
          effective: 0,
        )
      let next = dict.insert(world, child, held)
      use Nil <- result.map(check(next, step(model, command)))
      next
    }
    Land(child, fault) -> {
      let #(after, answer) = land(child_of(world, child), fault)
      let wanted = expected(phase(model, child), fault)
      case answer == wanted {
        True -> {
          let next = dict.insert(world, child, after)
          use Nil <- result.map(check(next, step(model, command)))
          next
        }
        False ->
          violation(
            "answer",
            string.inspect(command)
              <> " was answered "
              <> string.inspect(answer)
              <> " and the model expects "
              <> string.inspect(wanted),
          )
      }
    }
  }
}

// Every child, after every command.
fn check(world: World, model: Model) -> Result(Nil, statem.Violation) {
  list.try_each([0, 1], fn(child) {
    let held = child_of(world, child)
    let here = phase(model, child)
    let live = held.makes - held.releases

    // At most one session exists for a child, and it is the one the record says.
    use Nil <- result.try(case live, held.session {
      0, NoSession | 1, Session -> Ok(Nil)
      _, _ ->
        violation(
          "one-session",
          "child " <> int.to_string(child) <> " has " <> string.inspect(held),
        )
    })

    // The first turn never ran on a workspace that holds no seed.
    use Nil <- result.try(case held.first_turn_on {
      Some(Empty) ->
        violation(
          "apply-before-first-turn",
          "child " <> int.to_string(child) <> " started on an empty workspace",
        )
      Some(Seeded) | None -> Ok(Nil)
    })

    // A state is applied at most once however many requests were sent.
    use Nil <- result.try(case held.effective <= 1 {
      True -> Ok(Nil)
      False ->
        violation(
          "one-apply",
          "child " <> int.to_string(child) <> " applied twice",
        )
    })

    // A verdict exists exactly for a child that was refused for good.
    use Nil <- result.try(case held.verdict, here {
      Some(_), Refused
      | None, NotStarted
      | None, Pending
      | None, Begun
      | None, Joined
      -> Ok(Nil)
      _, _ ->
        violation(
          "verdict",
          "child "
            <> int.to_string(child)
            <> " is "
            <> string.inspect(here)
            <> " with the verdict "
            <> string.inspect(held.verdict),
        )
    })

    // A child that began started on its seed, and a refused or joined child holds
    // no session.
    case here, held.session {
      Begun, Session ->
        case held.workspace, held.turn {
          Seeded, Running -> Ok(Nil)
          _, _ -> violation("begun", "child began unseeded")
        }
      Refused, NoSession
      | Joined, NoSession
      | NotStarted, NoSession
      | Pending, Session
      -> Ok(Nil)
      NotStarted, Session | Pending, NoSession ->
        violation("pending", "the session does not match the child's phase")
      Begun, NoSession -> violation("begun", "a begun child has no session")
      Refused, Session | Joined, Session ->
        violation("released", "a settled child still holds its session")
    }
  })
}

fn faults() -> qcheck.Generator(Fault) {
  qcheck.from_weighted_generators(#(5, qcheck.return(NoFault)), [
    #(1, qcheck.return(HoldMissing)),
    #(1, qcheck.return(SessionFails)),
    #(2, qcheck.return(Unreadable)),
    #(1, qcheck.return(CensusShared)),
    #(2, qcheck.return(NoRoom)),
    #(2, qcheck.return(StaleFence)),
    #(1, qcheck.return(ApplyRefused)),
    #(2, qcheck.return(ReplyLost)),
    #(1, qcheck.return(Deadline)),
    #(2, qcheck.return(SpawnFails)),
  ])
}

fn commands() -> qcheck.Generator(Command) {
  let which = qcheck.bounded_int(from: 0, to: 1)
  qcheck.from_weighted_generators(
    #(8, qcheck.map2(which, faults(), fn(child, fault) { Land(child, fault) })),
    [#(2, qcheck.map(which, fn(child) { Join(child) }))],
  )
}

fn landing() -> statem.Spec(Model, Command, World) {
  statem.Spec(
    initial: dict.new(),
    command: fn(_model) { commands() },
    precondition: admitted,
    next_model: step,
    new_sut: fn() { dict.new() },
    execute:,
    finish: fn(world, model) {
      // A fault-free ask of every child still to start converges on a started
      // child, which is the retry after any failure point.
      list.try_each([0, 1], fn(child) {
        case phase(model, child) {
          NotStarted | Pending | Joined -> {
            let #(after, answer) = land(child_of(world, child), NoFault)
            case answer, after.effective {
              Started, 1 -> Ok(Nil)
              _, _ ->
                violation(
                  "converge",
                  "a fault-free ask of child "
                    <> int.to_string(child)
                    <> " did not converge: "
                    <> string.inspect(answer),
                )
            }
          }
          Begun | Refused -> Ok(Nil)
        }
      })
    },
    teardown: fn(_world) { Nil },
  )
}

fn runs() -> List(Int) {
  int.range(0, sequence_count, [], fn(found, n) { [n, ..found] })
  |> list.reverse
}

fn config() -> statem.Config {
  statem.default_config(seed: sequence_seed)
  |> statem.with_test_count(sequence_count)
  |> statem.with_max_commands(sequence_length)
}

pub fn any_order_of_asks_failures_retries_and_joins_keeps_every_promise_test() {
  case statem.check(landing(), config()) {
    Ok(Nil) -> Nil
    Error(failure) ->
      panic as statem.report(failure, fn(command) { string.inspect(command) })
  }
}

// A property that never reaches a state proves nothing about it, so the model is
// replayed over the generated lists and must visit the situations the promises
// are about: every failure point followed by a retry that converges, a refusal
// that stays, a resend of a begun child and a join.
pub fn the_generated_sequences_reach_the_situations_the_promises_are_about_test() {
  let spec = landing()
  let seen =
    runs()
    |> list.flat_map(fn(run) {
      let #(_, trace) =
        list.map_fold(
          statem.commands(spec, config(), run),
          spec.initial,
          fn(model, command) {
            let before = case command {
              Land(child, _) -> phase(model, child)
              Join(child) -> phase(model, child)
            }
            #(step(model, command), #(before, command))
          },
        )
      trace
    })
  let faults_after_retry = [
    HoldMissing, SessionFails, Unreadable, NoRoom, StaleFence, ReplyLost,
    Deadline, SpawnFails,
  ]
  list.each(faults_after_retry, fn(fault) {
    assert list.any(seen, fn(each) {
      each.0 == NotStarted
      && case each.1 {
        Land(_, found) -> found == fault
        Join(_) -> False
      }
    })
      as {
        "some sequence meets " <> string.inspect(fault) <> " on a fresh child"
      }
  })
  assert list.any(seen, fn(each) {
    each.0 == Refused
    && case each.1 {
      Land(..) -> True
      Join(_) -> False
    }
  })
    as "some sequence asks again of a refused child"
  assert list.any(seen, fn(each) {
    each.0 == Begun
    && case each.1 {
      Land(..) -> True
      Join(_) -> False
    }
  })
    as "some sequence resends a spawn that began"
  assert list.any(seen, fn(each) {
    case each.1 {
      Join(_) -> True
      Land(..) -> False
    }
  })
    as "some sequence joins a child"
}
