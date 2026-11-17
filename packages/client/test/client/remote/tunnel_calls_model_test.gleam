//// The table of tunnelled calls against a hostile executor, checked against a
//// model (protocol-change/117).
////
//// `statem` draws sequences of the orchestrator's own events (a new `Clear`, a
//// clearance wait passing, a withdraw, a cancel, an asker's death, a dropped
//// connection) interleaved with whatever an executor can send: an honest
//// `cleared` or event, and the forged ones, a frame for an id never issued, for
//// an id held as another request, a second `cleared`, a second settlement,
//// output past the limit, and a `cleared` after an event. After every step the
//// test checks the promises the link makes to its callers:
////
//// - each asker hears at most one clearance answer, and each caller at most
////   one `CallSettled`, and nothing after it;
//// - no event is delivered for an entry that was not running;
//// - the table never holds more than 8 entries for a binding or 64 in all;
//// - no stream's buffered bytes pass the spec's limit;
//// - every entry leaves the table through exactly one removing row;
//// - after a dropped connection the table is empty and every asker was told;
//// - a violation is reported exactly for the rows the proposal names, and a
////   frame that crossed a removal is dropped without one.
////
//// The table is pure, so the system under test is the table itself and what
//// its effects told each asker. The seed and sizes are constants, so a failure
//// names its run and replays.

import broker/broker
import broker/exec
import broker/framing.{type OutputStream}
import client/remote/tunnel_calls.{type Effect, type Table}
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/set.{type Set}
import gleam/string
import qcheck
import statem

const sequence_seed = 1170

const sequence_count = 160

const sequence_length = 220

// --- the model ------------------------------------------------------------------

/// How far a held call has got, with the bytes buffered on each stream.
type Kept {
  KeptClearing
  KeptRunning(out: Int, err: Int)
}

/// One call the model says the table holds.
type Held {
  Held(binding: Int, limit: Int, state: Kept)
}

/// `next_id` is the id the link would mint next; `tunnels` lists every id a
/// tunnelled call was admitted under, oldest first, so a command can name one
/// that has left; `others` lists ids the link issued for other requests.
type Model {
  Model(
    next_id: Int,
    live: Dict(Int, Held),
    tunnels: List(Int),
    others: List(Int),
  )
}

/// Whether a forged frame names an id never issued or another request's.
type Forgery {
  NeverIssued
  AnotherRequest
}

/// What the executor's `cleared` says.
type Clearance {
  Clears
  Refuses
}

type Command {
  // A `Clear` that passed the link's own checks.
  Open(binding: Int, limit: Int)
  // The link issues a request of another kind under the next id.
  Other
  // The executor's frames about a tunnel id, chosen by position.
  Clear(pick: Int, clearance: Clearance)
  Output(pick: Int, stream: OutputStream, size: Int)
  Settle(pick: Int)
  // The orchestrator's own events about a tunnel id.
  Wait(pick: Int)
  Withdraw(pick: Int)
  Cancel(pick: Int)
  Die(pick: Int)
  Drop
  // Forged frames for an id that is not a tunnelled call's.
  ForgeClear(forgery: Forgery)
  ForgeOutput(forgery: Forgery)
  ForgeSettle(forgery: Forgery)
}

fn initial() -> Model {
  Model(next_id: 1, live: dict.new(), tunnels: [], others: [])
}

fn picked(model: Model, pick: Int) -> Int {
  let count = list.length(model.tunnels)
  let assert [id, ..] = list.drop(model.tunnels, pick % count)
    as "a pick is admitted only when a tunnel id exists"
  id
}

// Whether the command is one of the rows the proposal calls a violation, in
// the model before it.
fn violates(model: Model, command: Command) -> Bool {
  case command {
    ForgeClear(..) | ForgeOutput(..) | ForgeSettle(..) -> True
    Clear(pick:, ..) ->
      case dict.get(model.live, picked(model, pick)) {
        Ok(Held(state: KeptRunning(..), ..)) -> True
        Ok(Held(state: KeptClearing, ..)) | Error(Nil) -> False
      }
    Output(pick:, stream:, size:) ->
      case dict.get(model.live, picked(model, pick)) {
        Ok(Held(state: KeptClearing, ..)) -> True
        Ok(Held(state: KeptRunning(out:, err:), limit:, ..)) ->
          buffered(out, err, stream) + size > limit
        Error(Nil) -> False
      }
    Settle(pick:) ->
      case dict.get(model.live, picked(model, pick)) {
        Ok(Held(state: KeptClearing, ..)) -> True
        Ok(Held(state: KeptRunning(..), ..)) | Error(Nil) -> False
      }
    Open(..) | Other | Wait(..) | Withdraw(..) | Cancel(..) | Die(..) | Drop ->
      False
  }
}

fn buffered(out: Int, err: Int, stream: OutputStream) -> Int {
  case stream {
    framing.Stdout -> out
    framing.Stderr -> err
  }
}

fn admits(model: Model, binding: Int, limit: Int) -> Bool {
  let on_binding =
    dict.values(model.live) |> list.count(fn(held) { held.binding == binding })
  limit > 0
  && limit <= tunnel_calls.max_call_output_bytes
  && on_binding < tunnel_calls.max_per_binding
  && dict.size(model.live) < tunnel_calls.max_per_link
}

// The model's whole transition function; each arm is a row of the table.
fn step(model: Model, command: Command) -> Model {
  case violates(model, command) {
    True -> Model(..model, live: dict.new())
    False -> lawful(model, command)
  }
}

fn lawful(model: Model, command: Command) -> Model {
  let without = fn(id) { Model(..model, live: dict.delete(model.live, id)) }
  case command {
    Open(binding:, limit:) ->
      case admits(model, binding, limit) {
        False -> model
        True ->
          Model(
            ..model,
            next_id: model.next_id + 1,
            live: dict.insert(
              model.live,
              model.next_id,
              Held(binding:, limit:, state: KeptClearing),
            ),
            tunnels: list.append(model.tunnels, [model.next_id]),
          )
      }
    Other ->
      Model(..model, next_id: model.next_id + 1, others: [
        model.next_id,
        ..model.others
      ])
    Clear(pick:, clearance:) -> {
      let id = picked(model, pick)
      case dict.get(model.live, id), clearance {
        Ok(held), Clears ->
          Model(
            ..model,
            live: dict.insert(
              model.live,
              id,
              Held(..held, state: KeptRunning(0, 0)),
            ),
          )
        Ok(_held), Refuses -> without(id)
        Error(Nil), _ -> model
      }
    }
    Output(pick:, stream:, size:) -> {
      let id = picked(model, pick)
      case dict.get(model.live, id) {
        Ok(Held(state: KeptRunning(out:, err:), ..) as held) -> {
          let state = case stream {
            framing.Stdout -> KeptRunning(out + size, err)
            framing.Stderr -> KeptRunning(out, err + size)
          }
          Model(
            ..model,
            live: dict.insert(model.live, id, Held(..held, state:)),
          )
        }
        Ok(Held(state: KeptClearing, ..)) | Error(Nil) -> model
      }
    }
    Settle(pick:) -> without(picked(model, pick))
    Wait(pick:) -> {
      let id = picked(model, pick)
      case dict.get(model.live, id) {
        Ok(Held(state: KeptClearing, ..)) -> without(id)
        Ok(Held(state: KeptRunning(..), ..)) | Error(Nil) -> model
      }
    }
    Withdraw(pick:) | Die(pick:) -> without(picked(model, pick))
    Cancel(pick:) -> {
      let id = picked(model, pick)
      case dict.get(model.live, id) {
        Ok(Held(state: KeptRunning(..), ..)) -> without(id)
        Ok(Held(state: KeptClearing, ..)) | Error(Nil) -> model
      }
    }
    Drop -> Model(..model, live: dict.new())
    ForgeClear(..) | ForgeOutput(..) | ForgeSettle(..) -> model
  }
}

fn admitted(model: Model, command: Command) -> statem.Admission {
  case command, model.tunnels, model.others {
    Clear(..), [], _
    | Output(..), [], _
    | Settle(..), [], _
    | Wait(..), [], _
    | Withdraw(..), [], _
    | Cancel(..), [], _
    | Die(..), [], _
    -> statem.Reject
    ForgeClear(AnotherRequest), _, []
    | ForgeOutput(AnotherRequest), _, []
    | ForgeSettle(AnotherRequest), _, []
    -> statem.Reject
    _, _, _ -> statem.Admit
  }
}

// --- the system under test ------------------------------------------------------

/// The table, and what its effects told each asker. A reply and an events
/// handle are the same integer, minted per open, so the counts are per asker.
type Sut {
  Sut(
    table: Table(Int, Int),
    next_reply: Int,
    replies: Dict(Int, Int),
    answers: Dict(Int, List(Result(Nil, broker.Refusal))),
    settled: Set(Int),
    released: Set(Int),
    silenced: Set(Int),
  )
}

fn new_sut() -> Sut {
  Sut(
    table: tunnel_calls.new(),
    next_reply: 1,
    replies: dict.new(),
    answers: dict.new(),
    settled: set.new(),
    released: set.new(),
    silenced: set.new(),
  )
}

fn violation(tag: String, detail: String) -> Result(a, statem.Violation) {
  Error(statem.Violation(tag:, detail:))
}

fn require(
  holds: Bool,
  tag: String,
  detail: String,
) -> Result(Nil, statem.Violation) {
  case holds {
    True -> Ok(Nil)
    False -> violation(tag, detail)
  }
}

fn reply_of(sut: Sut, id: Int) -> Int {
  dict.get(sut.replies, id) |> unwrap_int(-1)
}

fn unwrap_int(found: Result(Int, Nil), default: Int) -> Int {
  case found {
    Ok(value) -> value
    Error(Nil) -> default
  }
}

fn forged_id(model: Model, forgery: Forgery) -> #(Int, tunnel_calls.Origin) {
  case forgery, model.others {
    NeverIssued, _ -> #(model.next_id + 3, tunnel_calls.Unissued)
    AnotherRequest, [id, ..] -> #(id, tunnel_calls.OtherRequest)
    AnotherRequest, [] -> #(0, tunnel_calls.Unissued)
  }
}

fn exited() -> broker.CallOutcome {
  broker.CallExited(exec.ExecResult(
    code: 0,
    signal: 0,
    stdout_bytes: 0,
    stderr_bytes: 0,
    stdout_truncated: False,
    stderr_truncated: False,
    enforcement: [],
    degraded: False,
    wall_ms: 1,
    timed_out: False,
    cancelled: False,
  ))
}

// The event the link would hand the table for the command, and the reply the
// open minted, if it is one.
fn event_of(
  sut: Sut,
  model: Model,
  command: Command,
) -> tunnel_calls.Event(Int, Int) {
  case command {
    Open(binding:, limit:) ->
      tunnel_calls.Opened(
        id: model.next_id,
        binding: <<binding:size(8)>>,
        reply: sut.next_reply,
        events: sut.next_reply,
        limit:,
      )
    // Another request touches no tunnel; a stale wait for an id that never was
    // stands in, which the table must ignore.
    Other -> tunnel_calls.WaitPassed(id: 0)
    Clear(pick:, clearance:) ->
      tunnel_calls.Cleared(
        id: picked(model, pick),
        answer: case clearance {
          Clears -> Ok(Nil)
          Refuses -> Error(broker.OperationAborted)
        },
        origin: tunnel_calls.Issued,
      )
    Output(pick:, stream:, size:) ->
      tunnel_calls.EventOutput(
        id: picked(model, pick),
        stream:,
        data: <<0:size({ size * 8 })>>,
        origin: tunnel_calls.Issued,
      )
    Settle(pick:) ->
      tunnel_calls.EventSettled(
        id: picked(model, pick),
        outcome: exited(),
        origin: tunnel_calls.Issued,
      )
    Wait(pick:) -> tunnel_calls.WaitPassed(id: picked(model, pick))
    Withdraw(pick:) ->
      tunnel_calls.Withdrawn(reply: reply_of(sut, picked(model, pick)))
    Cancel(pick:) ->
      tunnel_calls.Cancelled(reply: reply_of(sut, picked(model, pick)))
    Die(pick:) -> tunnel_calls.AskerDied(id: picked(model, pick))
    Drop -> tunnel_calls.ConnectionDropped
    ForgeClear(forgery:) -> {
      let #(id, origin) = forged_id(model, forgery)
      tunnel_calls.Cleared(id:, answer: Ok(Nil), origin:)
    }
    ForgeOutput(forgery:) -> {
      let #(id, origin) = forged_id(model, forgery)
      tunnel_calls.EventOutput(
        id:,
        stream: framing.Stdout,
        data: <<1>>,
        origin:,
      )
    }
    ForgeSettle(forgery:) -> {
      let #(id, origin) = forged_id(model, forgery)
      tunnel_calls.EventSettled(id:, outcome: exited(), origin:)
    }
  }
}

// Runs one command and checks every promise against the model before and
// after it.
fn execute(
  sut: Sut,
  model: Model,
  command: Command,
) -> Result(Sut, statem.Violation) {
  let after = step(model, command)
  let #(table, effects) =
    tunnel_calls.step(sut.table, event_of(sut, model, command))
  let sut = case command {
    Open(..) ->
      Sut(
        ..sut,
        next_reply: sut.next_reply + 1,
        replies: case dict.size(after.live) > dict.size(model.live) {
          True -> dict.insert(sut.replies, model.next_id, sut.next_reply)
          False -> sut.replies
        },
      )
    _other -> sut
  }
  let sut = silencing(sut, model, command)
  use Nil <- result_try(violation_matches(effects, model, command))
  use sut <- result_try(told(sut, model, effects))
  use sut <- result_try(releases(sut, model, after, effects))
  use Nil <- result_try(frames(effects, model, after, command))
  use Nil <- result_try(matches_model(table, after))
  use Nil <- result_try(dropped_answers_all(effects, model, after, command))
  Ok(Sut(..sut, table:))
}

fn result_try(
  result: Result(a, statem.Violation),
  next: fn(a) -> Result(b, statem.Violation),
) -> Result(b, statem.Violation) {
  case result {
    Ok(value) -> next(value)
    Error(failure) -> Error(failure)
  }
}

// A withdraw and an asker's death leave nobody to answer, so finish does not
// expect those askers to hear anything more.
fn silencing(sut: Sut, model: Model, command: Command) -> Sut {
  case command {
    Withdraw(pick:) | Die(pick:) ->
      case dict.has_key(model.live, picked(model, pick)) {
        True ->
          Sut(
            ..sut,
            silenced: set.insert(
              sut.silenced,
              reply_of(sut, picked(model, pick)),
            ),
          )
        False -> sut
      }
    _other -> sut
  }
}

fn violation_matches(
  effects: List(Effect(Int, Int)),
  model: Model,
  command: Command,
) -> Result(Nil, statem.Violation) {
  let reported =
    list.any(effects, fn(effect) {
      case effect {
        tunnel_calls.Violation(..) -> True
        _other -> False
      }
    })
  require(
    reported == violates(model, command),
    "violation",
    string.inspect(command)
      <> " reported a violation: "
      <> string.inspect(reported),
  )
}

// Each answer and delivery reaches an asker that may hear it.
fn told(
  sut: Sut,
  model: Model,
  effects: List(Effect(Int, Int)),
) -> Result(Sut, statem.Violation) {
  let running =
    dict.to_list(model.live)
    |> list.filter_map(fn(pair) {
      case { pair.1 }.state {
        KeptRunning(..) -> Ok(reply_of(sut, pair.0))
        KeptClearing -> Error(Nil)
      }
    })
  list.try_fold(effects, sut, fn(sut, effect) {
    case effect {
      tunnel_calls.Answer(reply:, answer:) -> answered_once(sut, reply, answer)
      tunnel_calls.Refuse(reply:, ..) ->
        answered_once(sut, reply, Error(broker.BrokerUnavailable))
      tunnel_calls.Deliver(events:, event:) -> {
        use Nil <- result_try(require(
          list.contains(running, events),
          "deliver-running",
          "an event reached caller "
            <> int.to_string(events)
            <> " whose call was not running",
        ))
        use Nil <- result_try(require(
          !set.contains(sut.settled, events),
          "settled-once",
          "caller " <> int.to_string(events) <> " heard after its settlement",
        ))
        case event {
          broker.CallSettled(..) ->
            Ok(Sut(..sut, settled: set.insert(sut.settled, events)))
          broker.CallOutput(..) -> Ok(sut)
        }
      }
      tunnel_calls.SendClear(..)
      | tunnel_calls.SendCancel(..)
      | tunnel_calls.Released(..)
      | tunnel_calls.Violation(..) -> Ok(sut)
    }
  })
}

fn answered_once(
  sut: Sut,
  reply: Int,
  answer: Result(Nil, broker.Refusal),
) -> Result(Sut, statem.Violation) {
  let heard = dict.get(sut.answers, reply) |> list_or_empty
  use Nil <- result_try(require(
    heard == [],
    "answered-once",
    "asker " <> int.to_string(reply) <> " was answered twice",
  ))
  Ok(Sut(..sut, answers: dict.insert(sut.answers, reply, [answer])))
}

fn list_or_empty(found: Result(List(a), Nil)) -> List(a) {
  case found {
    Ok(items) -> items
    Error(Nil) -> []
  }
}

// Exactly the entries that left were released, each once in its life.
fn releases(
  sut: Sut,
  model: Model,
  after: Model,
  effects: List(Effect(Int, Int)),
) -> Result(Sut, statem.Violation) {
  let released =
    list.filter_map(effects, fn(effect) {
      case effect {
        tunnel_calls.Released(id:) -> Ok(id)
        _other -> Error(Nil)
      }
    })
  let left =
    dict.keys(model.live)
    |> list.filter(fn(id) { !dict.has_key(after.live, id) })
    |> set.from_list
  use Nil <- result_try(require(
    list.length(released) == set.size(set.from_list(released))
      && set.from_list(released) == left,
    "released",
    "released " <> string.inspect(released) <> ", left " <> string.inspect(left),
  ))
  use Nil <- result_try(require(
    list.all(released, fn(id) { !set.contains(sut.released, id) }),
    "released-once",
    "an entry was released twice",
  ))
  Ok(
    Sut(
      ..sut,
      released: list.fold(released, sut.released, fn(seen, id) {
        set.insert(seen, id)
      }),
    ),
  )
}

// `clear_call` goes out only for an admitted open, and `cancel` only for the
// four rows that send one.
fn frames(
  effects: List(Effect(Int, Int)),
  model: Model,
  after: Model,
  command: Command,
) -> Result(Nil, statem.Violation) {
  let sent =
    list.filter_map(effects, fn(effect) {
      case effect {
        tunnel_calls.SendClear(id:) -> Ok(#("clear", id))
        tunnel_calls.SendCancel(id:) -> Ok(#("cancel", id))
        _other -> Error(Nil)
      }
    })
  let expected = case command {
    Open(..) ->
      case dict.size(after.live) > dict.size(model.live) {
        True -> [#("clear", model.next_id)]
        False -> []
      }
    Wait(pick:) | Withdraw(pick:) | Cancel(pick:) | Die(pick:) -> {
      let id = picked(model, pick)
      case dict.has_key(model.live, id) && !dict.has_key(after.live, id) {
        True -> [#("cancel", id)]
        False -> []
      }
    }
    _other -> []
  }
  require(
    sent == expected,
    "frames",
    string.inspect(command) <> " sent " <> string.inspect(sent),
  )
}

// The table holds what the model holds, within every bound.
fn matches_model(
  table: Table(Int, Int),
  after: Model,
) -> Result(Nil, statem.Violation) {
  let held = tunnel_calls.entries(table)
  let per_binding =
    list.fold(held, dict.new(), fn(counts, pair) {
      let binding = { pair.1 }.binding
      dict.insert(counts, binding, unwrap_int(dict.get(counts, binding), 0) + 1)
    })
  use Nil <- result_try(require(
    list.length(held) <= tunnel_calls.max_per_link
      && list.all(dict.values(per_binding), fn(count) {
      count <= tunnel_calls.max_per_binding
    }),
    "bounds",
    "the table holds " <> int.to_string(list.length(held)) <> " entries",
  ))
  use Nil <- result_try(require(
    set.from_list(list.map(held, fn(pair) { pair.0 }))
      == set.from_list(dict.keys(after.live)),
    "entries",
    "the table's ids differ from the model's",
  ))
  list.try_each(held, fn(pair) {
    let #(id, entry) = pair
    let want = dict.get(after.live, id)
    let ok = case entry.state, want {
      tunnel_calls.Clearing, Ok(Held(state: KeptClearing, ..)) -> True
      tunnel_calls.Running(stdout:, stderr:),
        Ok(Held(state: KeptRunning(out:, err:), ..))
      ->
        bit_array.byte_size(stdout) == out
        && bit_array.byte_size(stderr) == err
        && out <= entry.limit
        && err <= entry.limit
      _, _ -> False
    }
    require(ok, "state", "entry " <> int.to_string(id) <> " differs")
  })
}

// After a drop or a violation the table is empty and every held asker heard:
// a clearing one its refusal, a running one its loss.
fn dropped_answers_all(
  effects: List(Effect(Int, Int)),
  model: Model,
  after: Model,
  command: Command,
) -> Result(Nil, statem.Violation) {
  let ends_all = command == Drop || violates(model, command)
  case ends_all {
    False -> Ok(Nil)
    True -> {
      use Nil <- result_try(require(
        dict.is_empty(after.live),
        "drop-empty",
        "entries survived a drop",
      ))
      list.try_each(dict.keys(model.live), fn(id) {
        let held = dict.get(model.live, id)
        let lost =
          broker.CallSettled(
            broker.CallFailed(exec.ExecutionLost(exec.RelayDown)),
          )
        let heard =
          list.any(effects, fn(effect) {
            case effect, held {
              tunnel_calls.Answer(answer: Error(broker.BrokerUnavailable), ..),
                Ok(Held(state: KeptClearing, ..))
              -> True
              tunnel_calls.Deliver(event:, ..),
                Ok(Held(state: KeptRunning(..), ..))
              -> event == lost
              _, _ -> False
            }
          })
        require(
          heard,
          "drop-told",
          "entry " <> int.to_string(id) <> " was not told",
        )
      })
    }
  }
}

// Every asker the run left alone heard its clearance, and every one that
// cleared heard its settlement, once the connection finally drops.
fn finish(sut: Sut, model: Model) -> Result(Nil, statem.Violation) {
  use sut <- result_try(execute(sut, model, Drop))
  dict.values(sut.replies)
  |> list.filter(fn(reply) { !set.contains(sut.silenced, reply) })
  |> list.try_each(fn(reply) {
    case dict.get(sut.answers, reply) {
      Ok([Ok(Nil)]) ->
        require(
          set.contains(sut.settled, reply),
          "finish-settled",
          "asker " <> int.to_string(reply) <> " cleared and never settled",
        )
      Ok([Error(_refused)]) -> Ok(Nil)
      Ok(_other) | Error(Nil) ->
        violation(
          "finish-answered",
          "asker " <> int.to_string(reply) <> " never heard",
        )
    }
  })
}

fn commands() -> qcheck.Generator(Command) {
  let pick = qcheck.bounded_int(from: 0, to: 63)
  let stream =
    qcheck.from_generators(qcheck.return(framing.Stdout), [
      qcheck.return(framing.Stderr),
    ])
  let forgery =
    qcheck.from_generators(qcheck.return(NeverIssued), [
      qcheck.return(AnotherRequest),
    ])
  let binding =
    qcheck.from_weighted_generators(#(4, qcheck.return(0)), [
      #(6, qcheck.bounded_int(from: 1, to: 9)),
    ])
  let limit =
    qcheck.from_weighted_generators(#(12, qcheck.return(10)), [
      #(1, qcheck.return(0)),
      #(1, qcheck.return(tunnel_calls.max_call_output_bytes)),
      #(1, qcheck.return(tunnel_calls.max_call_output_bytes + 1)),
    ])
  let clearance =
    qcheck.from_weighted_generators(#(5, qcheck.return(Clears)), [
      #(1, qcheck.return(Refuses)),
    ])
  qcheck.from_weighted_generators(#(30, qcheck.map2(binding, limit, Open)), [
    #(2, qcheck.return(Other)),
    #(10, qcheck.map2(pick, clearance, Clear)),
    #(10, qcheck.map3(pick, stream, qcheck.bounded_int(from: 1, to: 9), Output)),
    #(4, qcheck.map(pick, Settle)),
    #(2, qcheck.map(pick, Wait)),
    #(2, qcheck.map(pick, Withdraw)),
    #(2, qcheck.map(pick, Cancel)),
    #(2, qcheck.map(pick, Die)),
    #(1, qcheck.return(Drop)),
    #(1, qcheck.map(forgery, ForgeClear)),
    #(1, qcheck.map(forgery, ForgeOutput)),
    #(1, qcheck.map(forgery, ForgeSettle)),
  ])
}

// A calmer mix with the same promises, mostly opens and few removals, so a
// table fills to the link's bound and its bindings to theirs.
fn filling() -> qcheck.Generator(Command) {
  let pick = qcheck.bounded_int(from: 0, to: 63)
  let binding =
    qcheck.from_weighted_generators(#(3, qcheck.return(0)), [
      #(7, qcheck.bounded_int(from: 1, to: 9)),
    ])
  qcheck.from_weighted_generators(
    #(40, qcheck.map(binding, fn(binding) { Open(binding:, limit: 24) })),
    [
      #(1, qcheck.map(pick, Wait)),
      #(1, qcheck.map(pick, Withdraw)),
      #(1, qcheck.map(pick, Die)),
      #(1, qcheck.return(Other)),
    ],
  )
}

fn spec(
  generator: qcheck.Generator(Command),
) -> statem.Spec(Model, Command, Sut) {
  statem.Spec(
    initial: initial(),
    command: fn(_model) { generator },
    precondition: admitted,
    next_model: step,
    new_sut: new_sut,
    execute:,
    finish:,
    teardown: fn(_sut) { Nil },
  )
}

fn config() -> statem.Config {
  statem.default_config(seed: sequence_seed)
  |> statem.with_test_count(sequence_count)
  |> statem.with_max_commands(sequence_length)
}

fn checked(generator: qcheck.Generator(Command)) -> Nil {
  case statem.check(spec(generator), config()) {
    Ok(Nil) -> Nil
    Error(failure) ->
      panic as statem.report(failure, fn(command) { string.inspect(command) })
  }
}

// Each generated command with the model before it, over every run.
fn visited(generator: qcheck.Generator(Command)) -> List(#(Command, Model)) {
  int.range(from: 0, to: sequence_count, with: [], run: fn(seen, run) {
    let #(_, steps) =
      list.map_fold(
        statem.commands(spec(generator), config(), run),
        initial(),
        fn(model, command) { #(step(model, command), #(command, model)) },
      )
    list.append(steps, seen)
  })
}

pub fn any_interleaving_of_callers_and_a_hostile_executor_keeps_every_promise_test() {
  checked(commands())
}

pub fn a_table_filled_to_its_bounds_keeps_every_promise_test() {
  checked(filling())
}

// A property that never reaches a bound proves nothing about it, so the
// model is replayed over the generated lists and must reach each bound and
// each kind of frame the promises are about.
pub fn the_generated_sequences_reach_the_bounds_and_the_hostile_rows_test() {
  let filled = visited(filling())
  let hostile = visited(commands())
  assert list.any(filled, fn(each) {
    case each.0 {
      Open(..) -> dict.size({ each.1 }.live) == tunnel_calls.max_per_link
      _other -> False
    }
  })
    as "some open meets a table at the link's bound"
  assert list.any(filled, fn(each) {
    case each.0 {
      Open(binding:, limit:) ->
        dict.size({ each.1 }.live) < tunnel_calls.max_per_link
        && !admits(each.1, binding, limit)
      _other -> False
    }
  })
    as "some open is refused for its binding's bound alone"
  assert list.any(hostile, fn(each) {
    case each.0 {
      Open(limit:, ..) -> limit > tunnel_calls.max_call_output_bytes
      _other -> False
    }
  })
    as "some open names a limit past the cap"
  assert list.any(hostile, fn(each) {
    case each.0 {
      Output(pick:, ..) ->
        case dict.get({ each.1 }.live, picked(each.1, pick)) {
          Ok(Held(state: KeptRunning(..), ..)) -> violates(each.1, each.0)
          _other -> False
        }
      _other -> False
    }
  })
    as "some output passes its limit"
  assert list.any(hostile, fn(each) {
    case each.0 {
      Output(pick:, ..) ->
        case dict.get({ each.1 }.live, picked(each.1, pick)) {
          Ok(Held(state: KeptClearing, ..)) -> True
          _other -> False
        }
      _other -> False
    }
  })
    as "some output comes before the clearance"
  assert list.any(hostile, fn(each) {
    case each.0 {
      Settle(pick:) -> !dict.has_key({ each.1 }.live, picked(each.1, pick))
      _other -> False
    }
  })
    as "some settlement crosses a removal and is dropped"
  assert list.any(hostile, fn(each) {
    case each.0 {
      Clear(pick:, ..) ->
        case dict.get({ each.1 }.live, picked(each.1, pick)) {
          Ok(Held(state: KeptRunning(out:, err:), ..)) -> out + err > 0
          _other -> False
        }
      _other -> False
    }
  })
    as "some clearance arrives after an event"
  assert list.any(hostile, fn(each) {
    case each.0 {
      ForgeOutput(AnotherRequest) | ForgeClear(AnotherRequest) -> True
      _other -> False
    }
  })
    as "some frame names another request's id"
  assert list.any(hostile, fn(each) {
    each.0 == Drop && dict.size({ each.1 }.live) > 1
  })
    as "some connection drops under several calls"
}
