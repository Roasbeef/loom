//// Session-owned code-mode workers and their durable interaction handles.
////
//// A launch claims its record before starting a weft scope. The launching
//// tool owns neither the scope nor its broker step. Closing custody is a
//// durable transition before child cleanup, and Finished requires the scope's
//// final drain report plus every owned child operation's terminal result.
//// A replacement service records Lost and never replays a volatile satellite.

import client/agency
import core/clock
import core/ids
import core/json.{type JsonValue}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import runtime/api
import runtime/async_execution as execution
import weft
import weft/actor
import weft/poll
import weft/registry as address

/// Fixed session dependencies; no model-supplied authority enters here.
pub type Wiring {
  Wiring(
    /// The session whose writer owns all records.
    runtime: api.Runtime,
    /// The same time base used by child admission.
    clock: clock.Clock,
    /// Cancels only this execution's distinct broker step.
    abort: fn(ids.OpId, String) -> Nil,
  )
}

/// The service's requests and managed-task reports.
pub type Message {
  /// Claims an execution before starting its worker.
  Launch(
    record: execution.Execution,
    work: fn() -> JsonValue,
    reply: Subject(Result(JsonValue, String)),
  )

  /// Performs one bounded interaction with an owned handle.
  Inspect(
    strand: String,
    id: String,
    action: Action,
    reply: Subject(Result(JsonValue, String)),
  )

  /// A single worker's ordered outcome and scope drain proof.
  Reported(id: String, report: weft.Pulled(JsonValue, Nil))

  /// Reaps deadlines and observes pending child drains.
  Sweep

  /// Fences records left by a previous incarnation before serving requests.
  Recover

  /// Revokes one initiating operation before its broker sweep.
  AbortOperation(operation: ids.OpId, reply: Subject(Result(JsonValue, String)))
}

/// Nonblocking operations serialized by the service.
pub type Action {
  /// Reads the durable lifecycle and result.
  Check

  /// Fences admission and requests cancellation.
  Cancel

  /// Appends one bounded, durably sequenced input.
  Send(value: JsonValue)

  /// Reads the first value after a cursor without consuming it.
  Receive(after: Int)
}

type Drain {
  Awaiting
  Proven
  LostProof
}

type Held {
  Held(
    record: execution.Execution,
    reports: Subject(weft.Pulled(JsonValue, Nil)),
    cancel: weft.Cancel,
    outcome: Option(execution.Phase),
    drain: Drain,
  )
}

type State {
  State(
    wiring: Wiring,
    self: Subject(Message),
    live: Dict(String, Held),
    recovering: List(execution.Execution),
  )
}

/// Starts a named service under the session's supervision tree.
///
/// ## Examples
///
/// ```gleam
/// // async_runs.start(name, wiring)
/// ```
pub fn start(
  name: address.Address(Message),
  wiring: Wiring,
) -> actor.StartResult(Subject(Message)) {
  actor.new_with_initialiser(5000, fn(subject) {
    actor.initialised(
      State(wiring:, self: subject, live: dict.new(), recovering: []),
    )
    |> actor.returning(subject)
    |> actor.continuing(Recover)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.addressed(name)
  |> actor.periodic(100, Sweep)
  |> actor.trapping_exits(True)
  |> actor.on_shutdown(fn(state, _reason) {
    list.each(dict.values(state.live), fn(held) {
      let _fenced =
        save(
          state.wiring.runtime,
          execution.Execution(
            ..held.record,
            phase: execution.Lost("session stopped"),
          ),
        )
      state.wiring.abort(held.record.operation, held.record.step)
      weft.cancel(held.cancel)
      let _children =
        agency.drain_execution(
          state.wiring.runtime,
          held.record.operation,
          held.record.id,
        )
      Nil
    })
  })
  |> actor.start
}

/// Admits a worker under its original fixed terms.
///
/// ## Examples
///
/// ```gleam
/// // async_runs.launch(name, record, work)
/// ```
pub fn launch(
  name: address.Address(Message),
  record: execution.Execution,
  work: fn() -> JsonValue,
) -> Result(JsonValue, String) {
  ask(name, fn(reply) { Launch(record:, work:, reply:) })
}

/// Inspects or interacts with a handle owned by the authenticated strand.
/// A join waits outside the actor, so one waiting tool never blocks delivery.
///
/// ## Examples
///
/// ```gleam
/// // async_runs.interact(name, "main", handle, Check, 0)
/// ```
pub fn interact(
  name: address.Address(Message),
  strand: String,
  id: String,
  action: Action,
  within_ms: Int,
) -> Result(JsonValue, String) {
  let probe = fn() {
    ask(name, fn(reply) { Inspect(strand:, id:, action:, reply:) })
  }
  case action, within_ms > 0 {
    Check, True | Receive(_), True -> {
      let outcome =
        poll.until(within: int.min(within_ms, 30_000), every: 25, attempt: fn() {
          case probe() {
            Error(reason) -> poll.Fail(reason)
            Ok(value) ->
              case waiting(value, action) {
                True -> poll.Retry
                False -> poll.Done(value)
              }
          }
        })
      case outcome {
        poll.Answered(value) -> Ok(value)
        poll.Failed(reason) -> Error(reason)
        poll.Expired -> probe()
      }
    }
    _, _ -> probe()
  }
}

fn waiting(value: JsonValue, action: Action) -> Bool {
  case action, value {
    Receive(_), json.Null -> True
    Check, value ->
      case execution.decode(value) {
        Ok(record) -> !execution.terminal(record.phase)
        Error(_) -> False
      }
    _, _ -> False
  }
}

fn ask(
  name: address.Address(Message),
  build: fn(Subject(Result(JsonValue, String))) -> Message,
) -> Result(JsonValue, String) {
  use subject <- result.try(
    address.lookup(name)
    |> result.replace_error("async execution service unavailable"),
  )
  let reply = process.new_subject()
  process.send(subject, build(reply))
  process.receive(reply, 5000)
  |> result.unwrap(Error("async execution service did not answer"))
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Recover ->
      case recover(state.wiring) {
        Ok(recovering) -> resume(State(..state, recovering:))
        Error(reason) -> actor.stop_abnormal(reason)
      }
    AbortOperation(operation:, reply:) -> {
      let marked =
        api.put_reserved_fact(
          state.wiring.runtime,
          execution.abort_key(operation),
          json.Null,
        )
        |> result.map_error(string.inspect)
      case marked {
        Error(reason) -> {
          process.send(reply, Error(reason))
          resume(state)
        }
        Ok(_) -> {
          let state =
            dict.fold(state.live, state, fn(state, id, held) {
              case held.record.operation == operation {
                True ->
                  close(
                    state,
                    id,
                    Some(execution.Lost("initiating operation aborted")),
                  )
                False -> state
              }
            })
          process.send(reply, Ok(json.Null))
          resume(state)
        }
      }
    }
    Launch(record:, work:, reply:) ->
      case admit(state, record, work) {
        Error(reason) -> {
          process.send(reply, Error(reason))
          resume(state)
        }
        Ok(#(state, value)) -> {
          process.send(reply, Ok(value))
          resume(state)
        }
      }
    Inspect(strand:, id:, action:, reply:) -> {
      let #(state, answer) = inspect(state, strand, id, action)
      process.send(reply, answer)
      resume(state)
    }
    Reported(id:, report:) -> resume(reported(state, id, report))
    Sweep -> resume(sweep(state))
  }
}

fn resume(state: State) -> actor.Next(State, Message) {
  let selector =
    dict.fold(
      state.live,
      process.new_selector() |> process.select(state.self),
      fn(selector, id, held) {
        process.select_map(selector, held.reports, fn(report) {
          Reported(id:, report:)
        })
      },
    )
  actor.continue(state) |> actor.with_selector(selector)
}

fn admit(
  state: State,
  record: execution.Execution,
  work: fn() -> JsonValue,
) -> Result(#(State, JsonValue), String) {
  use _decoded <- result.try(
    execution.decode(execution.encode(record))
    |> result.replace_error("invalid execution terms"),
  )
  use aborted <- result.try(
    api.fact_cell(state.wiring.runtime, execution.abort_key(record.operation))
    |> result.map_error(string.inspect),
  )
  use Nil <- result.try(case aborted {
    None -> Ok(Nil)
    Some(_) -> Error("initiating operation has been aborted")
  })
  use existing <- result.try(load(state.wiring.runtime, record.id))
  case existing {
    Some(existing) ->
      case
        existing.strand == record.strand
        && existing.operation == record.operation
        && existing.seam == record.seam
        && existing.source == record.source
      {
        True -> Ok(#(state, execution.encode(existing)))
        False -> Error("execution handle collision")
      }
    None -> start_worker(state, record, work)
  }
}

fn start_worker(
  state: State,
  record: execution.Execution,
  work: fn() -> JsonValue,
) -> Result(#(State, JsonValue), String) {
  let #(now, _) = clock.read(state.wiring.clock)
  use Nil <- result.try(
    case
      dict.size(state.live) < 8
      && record.deadline_ms > now
      && string.byte_size(record.source) <= 262_144
    {
      True -> Ok(Nil)
      False ->
        Error("async execution capacity, source size, or deadline exceeded")
    },
  )
  let record = execution.Execution(..record, phase: execution.Running)
  use _seq <- result.try(
    api.claim_reserved_fact(
      state.wiring.runtime,
      execution.key(record.id),
      execution.encode(record),
      unless: execution.abort_key(record.operation),
    )
    |> result.map_error(string.inspect),
  )
  let reports = process.new_subject()
  let cancel = weft.cancel_signal()
  let _scope =
    weft.new([fn() { Ok(work()) }])
    |> weft.deadline(record.deadline_ms - now)
    |> weft.cancel_with(cancel)
    |> weft.start_relayed(reports)
  let held = Held(record:, reports:, cancel:, outcome: None, drain: Awaiting)
  Ok(#(
    State(..state, live: dict.insert(state.live, record.id, held)),
    execution.encode(record),
  ))
}

fn load(
  runtime: api.Runtime,
  id: String,
) -> Result(Option(execution.Execution), String) {
  use Nil <- result.try(case execution.valid_id(id) {
    True -> Ok(Nil)
    False -> Error("invalid execution handle")
  })
  use cell <- result.try(
    api.fact(runtime, execution.key(id)) |> result.map_error(string.inspect),
  )
  case cell {
    None -> Ok(None)
    Some(value) ->
      execution.decode(value)
      |> result.map(Some)
      |> result.replace_error("corrupt execution record")
  }
}

fn save(
  runtime: api.Runtime,
  record: execution.Execution,
) -> Result(Nil, String) {
  use cell <- result.try(
    api.fact_cell(runtime, execution.key(record.id))
    |> result.map_error(string.inspect),
  )
  api.put_reserved_fact_expecting(
    runtime,
    execution.key(record.id),
    execution.encode(record),
    option.map(cell, fn(cell) { cell.seq }),
  )
  |> result.replace(Nil)
  |> result.map_error(string.inspect)
}

fn inspect(
  state: State,
  strand: String,
  id: String,
  action: Action,
) -> #(State, Result(JsonValue, String)) {
  let answer = {
    use record <- result.try(load(state.wiring.runtime, id))
    case record {
      Some(record) if record.strand == strand -> Ok(record)
      Some(_) | None -> Error("execution handle is not owned by this strand")
    }
  }
  case answer {
    Error(reason) -> #(state, Error(reason))
    Ok(record) ->
      case action {
        Check -> #(state, Ok(execution.encode(record)))
        Cancel -> {
          let state = close(state, id, Some(execution.Lost("cancelled")))
          #(
            state,
            load(state.wiring.runtime, id)
              |> result.map(fn(record) {
                option.map(record, execution.encode) |> option.unwrap(json.Null)
              }),
          )
        }
        Send(value) -> #(state, append_input(state.wiring, record, value))
        Receive(after) -> #(
          state,
          input_after(state.wiring.runtime, record, after),
        )
      }
  }
}

fn close(state: State, id: String, outcome: Option(execution.Phase)) -> State {
  case dict.get(state.live, id) {
    Error(Nil) -> state
    Ok(held) -> {
      let record = execution.Execution(..held.record, phase: execution.Draining)
      case save(state.wiring.runtime, record) {
        Error(_) -> state
        Ok(Nil) -> {
          state.wiring.abort(record.operation, record.step)
          weft.cancel(held.cancel)
          let held =
            Held(..held, record:, outcome: option.or(held.outcome, outcome))
          State(..state, live: dict.insert(state.live, id, held))
        }
      }
    }
  }
}

fn reported(
  state: State,
  id: String,
  report: weft.Pulled(JsonValue, Nil),
) -> State {
  case report {
    weft.NotYet -> state
    weft.PulledOutcome(outcome) -> {
      let phase = case outcome {
        weft.Completed(value:, ..) -> execution.Finished(value)
        weft.Failed(..)
        | weft.Crashed(..)
        | weft.Abandoned(..)
        | weft.NeverStarted(..)
        | weft.DrainProofLost(..)
        | weft.CancellationUnconfirmed(..) ->
          execution.Lost("execution worker lost")
      }
      close(state, id, Some(phase))
    }
    weft.AllDelivered -> mark_drain(state, id, Proven)
    weft.RunLost(..) -> {
      let state = close(state, id, Some(execution.Lost("execution scope lost")))
      mark_drain(state, id, LostProof)
    }
  }
}

fn mark_drain(state: State, id: String, drain: Drain) -> State {
  case dict.get(state.live, id) {
    Error(Nil) -> state
    Ok(held) -> {
      let outcome = case drain {
        LostProof -> Some(execution.Lost("execution scope lost"))
        Awaiting | Proven -> held.outcome
      }
      State(
        ..state,
        live: dict.insert(state.live, id, Held(..held, drain:, outcome:)),
      )
    }
  }
}

fn sweep(state: State) -> State {
  let recovering =
    list.filter(state.recovering, fn(record) {
      agency.drain_execution(state.wiring.runtime, record.operation, record.id)
      != Ok(True)
    })
  let state = State(..state, recovering:)
  let #(now, _) = clock.read(state.wiring.clock)
  dict.fold(state.live, state, fn(state, id, held) {
    case held.record.phase {
      execution.Starting | execution.Running ->
        case
          api.fact_cell(
            state.wiring.runtime,
            execution.abort_key(held.record.operation),
          )
        {
          Ok(None) if now < held.record.deadline_ms -> state
          Ok(None) ->
            close(state, id, Some(execution.Lost("execution deadline expired")))
          Ok(Some(_)) ->
            close(
              state,
              id,
              Some(execution.Lost("initiating operation aborted")),
            )
          Error(_) ->
            close(
              state,
              id,
              Some(execution.Lost("operation custody unavailable")),
            )
        }
      execution.Draining -> {
        weft.cancel(held.cancel)
        let drained =
          agency.drain_execution(
            state.wiring.runtime,
            held.record.operation,
            id,
          )
        case drained, held.drain, held.outcome {
          Ok(True), Proven, Some(phase) | Ok(True), LostProof, Some(phase) ->
            case
              save(
                state.wiring.runtime,
                execution.Execution(..held.record, phase:),
              )
            {
              Ok(Nil) -> State(..state, live: dict.delete(state.live, id))
              Error(_) -> state
            }
          _, _, _ -> state
        }
      }
      execution.Finished(_) | execution.Lost(_) -> state
    }
  })
}

fn recover(wiring: Wiring) -> Result(List(execution.Execution), String) {
  use cells <- result.try(
    api.reserved_facts(wiring.runtime, execution.prefix <> "record/")
    |> result.map_error(string.inspect),
  )
  use records <- result.try(
    list.try_map(cells, fn(pair) {
      use record <- result.try(
        execution.decode(pair.1)
        |> result.replace_error("corrupt saved execution"),
      )
      case record.phase {
        execution.Finished(_) -> Ok(None)
        execution.Lost(_) -> {
          wiring.abort(record.operation, record.step)
          Ok(Some(record))
        }
        execution.Starting | execution.Running | execution.Draining -> {
          let record =
            execution.Execution(
              ..record,
              phase: execution.Lost("execution service restarted"),
            )
          use Nil <- result.try(save(wiring.runtime, record))
          wiring.abort(record.operation, record.step)
          Ok(Some(record))
        }
      }
    }),
  )
  Ok(list.filter_map(records, option.to_result(_, Nil)))
}

/// Fences existing and delayed launches before an operation-wide broker abort.
///
/// ## Examples
///
/// ```gleam
/// // async_runs.abort_operation(service, operation)
/// ```
pub fn abort_operation(
  name: address.Address(Message),
  operation: ids.OpId,
) -> Result(Nil, String) {
  ask(name, fn(reply) { AbortOperation(operation:, reply:) })
  |> result.replace(Nil)
}

fn input_key(id: String) -> String {
  execution.prefix <> "input/" <> id
}

fn inputs(runtime: api.Runtime, id: String) -> Result(List(JsonValue), String) {
  use value <- result.try(
    api.fact(runtime, input_key(id)) |> result.map_error(string.inspect),
  )
  case value {
    None -> Ok([])
    Some(json.Array(values)) -> Ok(values)
    Some(_) -> Error("invalid execution input journal")
  }
}

fn append_input(
  wiring: Wiring,
  record: execution.Execution,
  value: JsonValue,
) -> Result(JsonValue, String) {
  let #(now, _) = clock.read(wiring.clock)
  use Nil <- result.try(case execution.admits(record, now) {
    True -> Ok(Nil)
    False -> Error("execution is closed to input")
  })
  use values <- result.try(inputs(wiring.runtime, record.id))
  let next = list.append(values, [value])
  use Nil <- result.try(
    case
      list.length(next) <= 128
      && string.byte_size(json.to_string(json.Array(next))) <= 65_536
    {
      True -> Ok(Nil)
      False -> Error("execution input journal limit exceeded")
    },
  )
  use _ <- result.try(
    api.put_reserved_fact(
      wiring.runtime,
      input_key(record.id),
      json.Array(next),
    )
    |> result.map_error(string.inspect),
  )
  Ok(json.Int(list.length(next)))
}

fn input_after(
  runtime: api.Runtime,
  record: execution.Execution,
  after: Int,
) -> Result(JsonValue, String) {
  use values <- result.try(inputs(runtime, record.id))
  case list.first(list.drop(values, int.max(0, after))) {
    Ok(value) ->
      Ok(
        json.Object([
          #("sequence", json.Int(int.max(0, after) + 1)),
          #("value", value),
        ]),
      )
    Error(Nil) ->
      case
        execution.terminal(record.phase) || record.phase == execution.Draining
      {
        True -> Ok(json.Object([#("closed", json.String("execution closed"))]))
        False -> Ok(json.Null)
      }
  }
}
