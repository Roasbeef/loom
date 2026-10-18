//// The daemon session registry under concurrent callers, checked for
//// linearizability against a pure model.
////
//// ## What races
////
//// The registry is one actor, so every message is applied atomically. What
//// can go wrong is the protocol around it: callers read an operation token
//// from one reply and present it in a later request, and the registry must
//// compare that token with the slot's *at the moment it handles the second
//// request*. Concurrent callers open, stop and probe the same two sessions
//// while others present tokens of incarnations that have already retired.
////
//// ## The commands
////
//// Every command names a session by an index taken modulo the number of
//// sessions, so deleting commands while shrinking leaves the rest meaningful.
////
//// - `Open` admits the session, retrying while the registry answers
////   `Unavailable` (the slot is closing and replacement is forbidden until
////   its custody retires). It therefore always ends admitted, as if atomic.
//// - `Stop` is the compare-and-set in use. It reads the session's token and
////   calls `stop_if_incarnation` with it, losing and retrying when a
////   concurrent stop-and-reopen made the token stale, then waits for the
////   slot to retire and tells the ledger which token is now dead.
//// - `Probe` reads the status without waking anything.
//// - `ResolveStale`, `OperationStale` and `StopStale` present the most
////   recently retired token of the session (or one never issued) to
////   `resolve_incarnation`, `operation` and `stop_if_incarnation`.
////
//// ## What the model claims
////
//// The model is the set of sessions that have a live slot. `Open` makes a
//// session live and `Stop` makes it not live. A `Probe` must see
//// `Opening` or `Resident` while the model says live, and `Saved` or
//// `Stopping` while it does not: `Stopping` is the closing window of a stop,
//// which the stop's own interval covers, so it is only ever seen after the
//// model has linearized that stop. A stale token must be answered
//// `StaleOperation` whatever the model says, because tokens are never
//// reissued. A stale `StopStale` that disturbed the live incarnation would
//// show up as a later `Probe` seeing `Stopping` where the model says live.
////
//// ## What only a quiet registry can show
////
//// `finish` reads the ledger of every token any caller was handed. Each must
//// have been retired by a stop, or be the incarnation still standing, and the
//// standing one must not be retired: two simultaneous incarnations of one
//// session (a second claimer winning) leave a token that was issued and never
//// retired, and nothing in any single response shows it. The census of
//// reserved slots is also read here, because a slot leaked by a lost race
//// would still occupy capacity once everything is idle.
////
//// The model does not predict token strings: they carry a counter shared by
//// every session, so no per-session model could.

import client/daemon/domain as domain_service
import client/daemon/manager
import core/clock
import core/ids
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import qcheck
import statem
import statem_parallel.{type Spec, Case, Spec}
import storage/catalogue
import storage/domain
import weft/actor
import weft/poll

/// How many sessions the registry knows. Two is the least that lets a stale
/// token of one session be presented while another stays live.
const sessions = 2

/// The seed every run derives from, fixed so the generated cases reproduce.
/// The interleavings do not, which is why each case repeats.
const seed = 20_261_018

/// How many cases the check generates. Each builds a registry and a
/// catalogue, so the count is what bounds the wall time.
const test_count = 100

/// How many times a generated case runs before it counts as passing. A race
/// that needs a particular schedule gets several draws at it.
const repeat = 3

/// How many branches race. Three lets one caller present a token while two
/// others retire and replace the incarnation it names.
const branches = 3

/// The longest sequential prefix, in commands.
const max_prefix = 3

/// The longest branch, in commands.
const max_branch = 3

/// How long a command may wait for the registry to settle, in milliseconds.
const patience = 5000

/// A token no registry has issued, standing in when a session has not
/// retired anything yet.
const never_issued = "daemon-test:never-issued"

/// What a caller can ask of the registry.
pub type Cmd {
  /// Admit the session, waiting out a closing slot.
  Open(session: Int)
  /// Stop the session's current incarnation and wait for it to retire.
  Stop(session: Int)
  /// Read the session's status.
  Probe(session: Int)
  /// Resolve with a retired token.
  ResolveStale(session: Int)
  /// Look up an operation by a retired token.
  OperationStale(session: Int)
  /// Stop by a retired token.
  StopStale(session: Int)
}

/// What the registry's status told a probe, reduced to the part a model can
/// predict.
pub type Presence {
  Live
  Closing
  Gone
}

/// What a command saw.
pub type Response {
  Admitted
  Stopped
  Present(Presence)
  /// A stale-token request's answer, with a success reduced to `Ok(Nil)`.
  Refused(Result(Nil, manager.Error))
  /// The command could not do its job; the reason is for the report.
  Broken(reason: String)
}

/// The set of sessions with a live slot.
type Model =
  Set(Int)

/// The mailbox of the ledger, an actor so branch processes and the test
/// process can use it at once.
type Entry {
  Issued(session: Int, token: String)
  Retired(session: Int, token: String)
  Latest(session: Int, reply: Subject(String))
  Snapshot(reply: Subject(#(Dict(Int, List(String)), Dict(Int, List(String)))))
  Halt
}

/// What the callers collectively learned: tokens handed out by `open`, and
/// tokens a stop watched retire, per session.
type Ledger =
  Subject(Entry)

/// The system under test: the real registry over a real in-memory catalogue,
/// the ledger, and the sessions' identities.
type Sut {
  Sut(
    registry: manager.Manager(String),
    ledger: Ledger,
    store: catalogue.Catalogue,
    ids: List(String),
  )
}

// --- the system -----------------------------------------------------------

fn start_ledger() -> Ledger {
  let assert Ok(started) =
    actor.new(#(dict.new(), dict.new()))
    |> actor.on_message(ledger_step)
    |> actor.start
    as "the ledger actor starts"

  started.data
}

fn ledger_step(
  state: #(Dict(Int, List(String)), Dict(Int, List(String))),
  entry: Entry,
) -> actor.Next(#(Dict(Int, List(String)), Dict(Int, List(String))), Entry) {
  let #(issued, retired) = state

  case entry {
    Issued(session, token) ->
      actor.continue(#(prepend(issued, session, token), retired))

    Retired(session, token) ->
      actor.continue(#(issued, prepend(retired, session, token)))

    Latest(session, reply) -> {
      let latest = case dict.get(retired, session) {
        Ok([token, ..]) -> token
        Ok([]) | Error(Nil) -> never_issued
      }
      process.send(reply, latest)
      actor.continue(state)
    }

    Snapshot(reply) -> {
      process.send(reply, state)
      actor.continue(state)
    }

    Halt -> actor.stop()
  }
}

fn prepend(
  book: Dict(Int, List(String)),
  session: Int,
  token: String,
) -> Dict(Int, List(String)) {
  let held = dict.get(book, session) |> option_of |> option.unwrap([])
  dict.insert(book, session, [token, ..held])
}

fn option_of(found: Result(a, Nil)) -> Option(a) {
  option.from_result(found)
}

fn registration(seed: Int) -> catalogue.Registration {
  let generator = ids.generator(clock.fixed(at: 1_700_000_000_000), seed:)
  let #(id, _) = ids.mint_session(generator)
  let id = ids.session_id_to_string(id)

  catalogue.Registration(
    id:,
    path: "/unopened-manager-parallel-test/" <> id <> ".db",
    workspace: "/workspace/project",
    name: "session " <> int.to_string(seed),
    configuration: "",
    created_at: 1_700_000_000_000,
    request_key: "request-" <> int.to_string(seed),
    state: catalogue.Reserved,
    profile: option.None,
    model: option.None,
    executor: "",
    pool: "",
    subtitle: option.None,
  )
}

/// A confirmed session with its domain bound, which is what admission needs
/// before it will build anything.
fn saved(store: catalogue.Catalogue, seed: Int) -> String {
  let record = registration(seed)
  assert catalogue.reserve(store, record) == Ok(record)
  let assert Ok(record) = catalogue.confirm(store, record.id)
    as "the fixture is initialized metadata whose path is never opened"
  let selected =
    domain.Domain(
      domain.key(domain.SessionOnly, record.workspace, record.id),
      domain.SessionOnly,
      record.workspace,
      "",
      "/fixture-domains/" <> record.id <> "/memory.db",
      "/fixture-domains/" <> record.id <> "/search.db",
    )
  assert domain.bind(store, record.id, selected) == Ok(selected)
  record.id
}

/// A registry whose builds succeed at once, with room for every session so
/// that `Capacity` never explains a refusal.
fn new_sut() -> Sut {
  let assert Ok(store) = catalogue.open(":memory:") as "the catalogue opens"
  let ids = list.map(indices(sessions), fn(n) { saved(store, 7000 + n) })
  let assert Ok(registry) =
    manager.start(
      store,
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(record, _domain, _services, _owner, _directory) {
          Ok(record.id)
        },
        drain: fn(_, _) { Nil },
        fatal: fn(_) { [] },
      ),
      epoch: "daemon-test",
      limit: sessions + 1,
    )
    as "the registry starts without invoking assembly"

  Sut(registry:, ledger: start_ledger(), store:, ids:)
}

fn teardown(sut: Sut) -> Nil {
  let watch = process.monitor(manager.pid(sut.registry))
  manager.shutdown(sut.registry)
  let _ =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(patience)
  let _ = catalogue.close(sut.store)
  process.send(sut.ledger, Halt)
}

fn id_of(sut: Sut, session: Int) -> String {
  let at = session % sessions
  case list.drop(sut.ids, at) {
    [id, ..] -> id
    [] -> ""
  }
}

// --- running a command ----------------------------------------------------

fn run(sut: Sut, cmd: Cmd) -> Response {
  let session = cmd.session % sessions
  let id = id_of(sut, session)

  case cmd {
    Open(..) -> open(sut, session, id)
    Stop(..) -> stop(sut, session, id)
    Probe(..) -> probe(sut, id)

    // A retired token is read from the ledger at the moment of the call. It
    // can only name an incarnation that has finished retiring, so every one
    // of these requests must be refused as stale.
    ResolveStale(..) ->
      refused(
        manager.resolve_incarnation(sut.registry, id, stale(sut, session))
        |> result_nil,
      )

    OperationStale(..) ->
      refused(
        manager.operation(sut.registry, id, stale(sut, session))
        |> result_nil,
      )

    StopStale(..) ->
      refused(
        manager.stop_if_incarnation(sut.registry, id, stale(sut, session))
        |> result_nil,
      )
  }
}

fn result_nil(answer: Result(a, manager.Error)) -> Result(Nil, manager.Error) {
  result_map(answer)
}

fn result_map(answer: Result(a, manager.Error)) -> Result(Nil, manager.Error) {
  case answer {
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(error)
  }
}

fn refused(answer: Result(Nil, manager.Error)) -> Response {
  Refused(answer)
}

fn stale(sut: Sut, session: Int) -> String {
  process.call(sut.ledger, patience, Latest(session, _))
}

/// Admit, waiting out a closing slot. `Unavailable` is the registry saying
/// "not yet" while custody drains, which a caller of the daemon retries.
fn open(sut: Sut, session: Int, id: String) -> Response {
  let outcome =
    poll.until(within: patience, every: 1, attempt: fn() {
      case manager.open(sut.registry, id) {
        Ok(manager.Opening(token)) | Ok(manager.Resident(token)) ->
          poll.Done(token)

        Error(manager.Unavailable) -> poll.Retry
        Ok(other) -> poll.Fail("open answered " <> string.inspect(other))
        Error(error) -> poll.Fail("open refused " <> string.inspect(error))
      }
    })

  case outcome {
    poll.Answered(token) -> {
      process.send(sut.ledger, Issued(session, token))
      Admitted
    }
    poll.Failed(reason) -> Broken(reason)
    poll.Expired -> Broken("open never left Unavailable")
  }
}

/// Where a stop has got to: nothing done, or waiting on one token's slot.
type Waiting =
  Option(String)

/// Stop by compare-and-set, then wait for the slot to retire.
///
/// A token read in one reply and presented in the next can be overtaken by a
/// concurrent stop that reopens, so a refused comparison is a lost race to
/// run again, never a failure. Once a slot is seen closing, the stop is done
/// when that token is no longer the slot's, and only then is it recorded as
/// dead: while the slot closes, its own token is still the current one.
fn stop(sut: Sut, session: Int, id: String) -> Response {
  let verdict =
    poll.fold_until(
      clock: poll.monotonic(),
      within: patience,
      every: poll.Fixed(1),
      from: None,
      attempt: fn(waiting: Waiting) { stop_pass(sut, session, id, waiting) },
    )

  case verdict {
    poll.Answer(Nil) -> Stopped
    poll.Failure(reason) -> Broken(reason)
    poll.RanOut(_) -> Broken("the slot never retired")
  }
}

fn stop_pass(
  sut: Sut,
  session: Int,
  id: String,
  waiting: Waiting,
) -> poll.Pass(Nil, String, Waiting) {
  case manager.get(sut.registry, id), waiting {
    Ok(manager.View(status: manager.Saved, ..)), None -> poll.Settled(Nil)

    Ok(manager.View(status: manager.Saved, ..)), Some(token) -> {
      process.send(sut.ledger, Retired(session, token))
      poll.Settled(Nil)
    }

    Ok(manager.View(status: manager.Stopping(token), ..)), Some(held)
      if token == held
    -> poll.Pending(waiting)

    Ok(manager.View(status: manager.Stopping(token), ..)), None ->
      poll.Pending(Some(token))

    // The slot is no longer the one this stop was waiting on: it retired,
    // and a concurrent open may already have replaced it.
    Ok(manager.View(status: manager.Stopping(_), ..)), Some(held)
    | Ok(manager.View(status: manager.Opening(_), ..)), Some(held)
    | Ok(manager.View(status: manager.Resident(_), ..)), Some(held)
    -> {
      process.send(sut.ledger, Retired(session, held))
      poll.Settled(Nil)
    }

    Ok(manager.View(status: manager.Opening(token), ..)), None
    | Ok(manager.View(status: manager.Resident(token), ..)), None
    ->
      case manager.stop_if_incarnation(sut.registry, id, token) {
        Ok(_) -> poll.Pending(Some(token))
        Error(manager.StaleOperation) -> poll.Pending(None)
        Error(error) -> poll.Broken("stop refused " <> string.inspect(error))
      }

    Ok(manager.View(status: other, ..)), _ ->
      poll.Broken("stop saw " <> string.inspect(other))

    Error(error), _ -> poll.Broken("get refused " <> string.inspect(error))
  }
}

fn probe(sut: Sut, id: String) -> Response {
  case manager.get(sut.registry, id) {
    Ok(manager.View(status: manager.Opening(_), ..))
    | Ok(manager.View(status: manager.Resident(_), ..)) -> Present(Live)

    Ok(manager.View(status: manager.Stopping(_), ..)) -> Present(Closing)
    Ok(manager.View(status: manager.Saved, ..)) -> Present(Gone)
    Ok(manager.View(status: other, ..)) ->
      Broken("probe saw " <> string.inspect(other))
    Error(error) -> Broken("probe refused " <> string.inspect(error))
  }
}

// --- the model ------------------------------------------------------------

fn next_model(model: Model, cmd: Cmd) -> Model {
  let session = cmd.session % sessions

  case cmd {
    Open(..) -> set.insert(model, session)
    Stop(..) -> set.delete(model, session)
    Probe(..) | ResolveStale(..) | OperationStale(..) | StopStale(..) -> model
  }
}

fn postcondition(
  model: Model,
  cmd: Cmd,
  response: Response,
) -> Result(Nil, statem.Violation) {
  let live = set.contains(model, cmd.session % sessions)

  case cmd, response {
    _, Broken(reason) -> fail("broken", reason)
    Open(..), Admitted -> Ok(Nil)
    Stop(..), Stopped -> Ok(Nil)

    Probe(..), Present(Live) if live -> Ok(Nil)
    Probe(..), Present(Gone) | Probe(..), Present(Closing) if !live -> Ok(Nil)
    Probe(..), Present(seen) ->
      fail(
        "presence",
        "the model says "
          <> case live {
          True -> "live"
          False -> "not live"
        }
          <> " but the registry showed "
          <> string.inspect(seen),
      )

    ResolveStale(..), Refused(Error(manager.StaleOperation))
    | OperationStale(..), Refused(Error(manager.StaleOperation))
    | StopStale(..), Refused(Error(manager.StaleOperation))
    -> Ok(Nil)

    _, other ->
      fail(
        "answer",
        "unexpected response "
          <> string.inspect(other)
          <> " to "
          <> describe(cmd),
      )
  }
}

fn fail(tag: String, detail: String) -> Result(Nil, statem.Violation) {
  Error(statem.Violation(tag:, detail:))
}

/// The laws a quiet registry must satisfy.
fn finish(sut: Sut) -> Result(Nil, statem.Violation) {
  let #(issued, retired) = process.call(sut.ledger, patience, Snapshot)

  list.try_each(indices(sessions), fn(session) {
    let id = id_of(sut, session)
    let current = case manager.get(sut.registry, id) {
      Ok(manager.View(status: manager.Opening(token), ..))
      | Ok(manager.View(status: manager.Resident(token), ..)) -> Some(token)
      Ok(_) | Error(_) -> None
    }
    let dead = dict.get(retired, session) |> result.unwrap([])
    let handed = dict.get(issued, session) |> result.unwrap([])

    case current {
      Some(token) ->
        case list.contains(dead, token) {
          True ->
            fail(
              "retired-yet-live",
              "session "
                <> int.to_string(session)
                <> " stands on "
                <> token
                <> ", which a stop saw retire",
            )
          False -> never_retired(session, handed, dead, current)
        }

      None -> never_retired(session, handed, dead, current)
    }
  })
  |> result_then(fn() { census(sut) })
}

/// Every token `open` handed out names an incarnation that is either dead or
/// the one standing; anything else is a second live slot that was lost.
fn never_retired(
  session: Int,
  handed: List(String),
  dead: List(String),
  current: Option(String),
) -> Result(Nil, statem.Violation) {
  let orphan =
    list.find(handed, fn(token) {
      !list.contains(dead, token) && Some(token) != current
    })

  case orphan {
    Error(Nil) -> Ok(Nil)
    Ok(token) ->
      fail(
        "orphaned-incarnation",
        "session "
          <> int.to_string(session)
          <> " was handed "
          <> token
          <> ", which neither retired nor stands",
      )
  }
}

fn census(sut: Sut) -> Result(Nil, statem.Violation) {
  case manager.summary(sut.registry) {
    Ok(manager.Summary(occupied:, stopping:, blocked:, ..))
      if stopping == 0 && blocked == 0 && occupied <= sessions
    -> Ok(Nil)
    Ok(summary) ->
      fail("census", "a quiet registry reports " <> string.inspect(summary))
    Error(error) -> fail("census", "summary refused " <> string.inspect(error))
  }
}

fn result_then(
  first: Result(Nil, statem.Violation),
  next: fn() -> Result(Nil, statem.Violation),
) -> Result(Nil, statem.Violation) {
  case first {
    Ok(Nil) -> next()
    Error(violation) -> Error(violation)
  }
}

// --- generation and the test ---------------------------------------------

/// A command, simplest first, so shrinking moves toward `Open 0`. Racing
/// commands are drawn often: opens and stops of the same two sessions.
fn command(_model: Model) -> qcheck.Generator(Cmd) {
  qcheck.map2(
    qcheck.bounded_int(from: 0, to: 9),
    qcheck.bounded_int(from: 0, to: sessions - 1),
    fn(kind, session) {
      case kind {
        0 | 1 | 2 -> Open(session)
        3 | 4 -> Stop(session)
        5 | 6 -> Probe(session)
        7 -> ResolveStale(session)
        8 -> OperationStale(session)
        _ -> StopStale(session)
      }
    },
  )
}

fn describe(cmd: Cmd) -> String {
  let at = int.to_string(cmd.session)

  case cmd {
    Open(..) -> "Open " <> at
    Stop(..) -> "Stop " <> at
    Probe(..) -> "Probe " <> at
    ResolveStale(..) -> "ResolveStale " <> at
    OperationStale(..) -> "OperationStale " <> at
    StopStale(..) -> "StopStale " <> at
  }
}

fn spec() -> Spec(Model, Cmd, Sut, Response) {
  Spec(
    initial: set.new(),
    command:,
    precondition: fn(_, _) { statem.Admit },
    next_model:,
    new_sut:,
    run:,
    postcondition:,
    finish:,
    teardown:,
  )
}

fn config() -> statem_parallel.Config {
  statem_parallel.default_config(seed:)
  |> statem_parallel.with_test_count(test_count)
  |> statem_parallel.with_repeat(repeat)
  |> statem_parallel.with_branches(branches)
  |> statem_parallel.with_max_prefix(max_prefix)
  |> statem_parallel.with_max_branch(max_branch)
}

/// The registry is linearizable: every concurrent history has an order the
/// model agrees with, and a quiet registry holds no orphaned incarnation.
pub fn concurrent_callers_see_a_linearizable_registry_test() {
  case statem_parallel.check(spec(), config()) {
    Ok(Nil) -> Nil
    Error(failure) -> panic as statem_parallel.report(failure, describe)
  }
}

/// The test is only worth its green if generation keeps producing the pattern
/// it exists for: an `Open` and a `Stop` of the same session in different
/// branches, and a stale token presented while some branch opens or stops.
pub fn generation_keeps_racing_opens_against_stops_test() {
  let cases =
    list.map(indices(test_count), statem_parallel.generate_case(
      spec(),
      config(),
      _,
    ))

  assert list.any(cases, fn(generated) {
    let Case(branches:, ..) = generated
    contending(branches, is_open, is_stop)
  })
    as "no case races an Open against a Stop of one session"

  assert list.any(cases, fn(generated) {
    let Case(branches:, ..) = generated
    contending(branches, is_stop, is_stop)
  })
    as "no case races two Stops of one session"

  assert list.any(cases, fn(generated) {
    let Case(branches:, ..) = generated
    contending(branches, is_stale, is_stop)
  })
    as "no case presents a stale token while a Stop runs"
}

fn is_open(cmd: Cmd) -> Bool {
  case cmd {
    Open(..) -> True
    _ -> False
  }
}

fn is_stop(cmd: Cmd) -> Bool {
  case cmd {
    Stop(..) -> True
    _ -> False
  }
}

fn is_stale(cmd: Cmd) -> Bool {
  case cmd {
    ResolveStale(..) | OperationStale(..) | StopStale(..) -> True
    _ -> False
  }
}

/// Whether two different branches hold a command satisfying `left` and one
/// satisfying `right` that name the same session.
fn contending(
  branches: List(List(Cmd)),
  left: fn(Cmd) -> Bool,
  right: fn(Cmd) -> Bool,
) -> Bool {
  list.index_map(branches, fn(first, at) {
    list.index_map(branches, fn(second, other) {
      at != other
      && list.any(first, fn(a) {
        left(a)
        && list.any(second, fn(b) { right(b) && a.session == b.session })
      })
    })
    |> list.any(fn(found) { found })
  })
  |> list.any(fn(found) { found })
}

/// The numbers `0` up to but not including `count`.
fn indices(count: Int) -> List(Int) {
  list.repeat(Nil, count) |> list.index_map(fn(_, at) { at })
}
