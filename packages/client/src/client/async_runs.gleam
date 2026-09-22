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

  /// Appends one bounded, durably sequenced raw default input.
  Send(value: JsonValue)

  /// Appends one bounded, durably sequenced named endpoint input.
  SendTo(endpoint: String, value: JsonValue)

  /// Reads the first raw default-endpoint value after a cursor.
  Receive(after: Int)

  /// Reads the first endpoint envelope after a cursor.
  ReceiveEnveloped(after: Int)

  /// Publishes the immutable endpoint set after setup completes.
  Ready(endpoints: List(String), idle_within_ms: Int)

  /// Coalesces the latest volatile progress snapshot.
  Progress(value: JsonValue)

  /// Records the latest volatile typed-delivery observation.
  Delivery(sequence: Int, endpoint: String, outcome: DeliveryOutcome)
}

/// The typed dispatcher result retained for inspection.
pub type DeliveryOutcome {
  /// The endpoint decoded and handled the admitted value.
  Delivered

  /// The endpoint rejected the admitted value without stopping service.
  Rejected(reason: String)
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
    progress: Option(Snapshot),
    pending_progress: Option(PendingProgress),
    delivery: Option(DeliverySnapshot),
    idle_anchor_ms: Option(Int),
  )
}

type Snapshot {
  Snapshot(sequence: Int, updated_ms: Int, value: JsonValue)
}

type PendingProgress {
  PendingProgress(value: JsonValue)
}

type DeliverySnapshot {
  DeliverySnapshot(sequence: Int, endpoint: String, outcome: DeliveryOutcome)
}

type State {
  State(
    wiring: Wiring,
    self: Subject(Message),
    live: Dict(String, Held),
    recovering: List(execution.Execution),
    launches: Dict(String, Int),
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
    actor.initialised(State(
      wiring:,
      self: subject,
      live: dict.new(),
      recovering: [],
      launches: dict.new(),
    ))
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
    Check, True | Receive(_), True | ReceiveEnveloped(_), True -> {
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
    Receive(_), json.Null | ReceiveEnveloped(_), json.Null -> True
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
        Ok(#(recovering, launches)) ->
          resume(State(..state, recovering:, launches:))
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
        && existing.step == record.step
        && existing.deadline_ms == record.deadline_ms
        && existing.seam == record.seam
        && existing.source == record.source
      {
        True -> {
          use value <- result.try(inspect_value(state, existing))
          Ok(#(state, value))
        }
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
  let operation = ids.op_id_to_string(record.operation)
  let launches = dict.get(state.launches, operation) |> result.unwrap(0)
  use Nil <- result.try(
    case
      dict.size(state.live) < 8
      && launches < 32
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
  let held =
    Held(
      record:,
      reports:,
      cancel:,
      outcome: None,
      drain: Awaiting,
      progress: None,
      pending_progress: None,
      delivery: None,
      idle_anchor_ms: None,
    )
  let state =
    State(
      ..state,
      live: dict.insert(state.live, record.id, held),
      launches: dict.insert(state.launches, operation, launches + 1),
    )
  use value <- result.try(inspect_value(state, record))
  Ok(#(state, value))
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
  let state = promote_progress(state, id)
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
        Check -> #(state, inspect_value(state, record))
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
        Send(value) -> #(
          state,
          append_input(state.wiring, record, "default", value),
        )
        SendTo(endpoint, value) -> #(
          state,
          append_input(state.wiring, record, endpoint, value),
        )
        Receive(after) -> {
          let answer = {
            use _ <- result.try(ready_default(state.wiring, record))
            input_after(state.wiring.runtime, record, after, Raw)
          }
          #(state, answer)
        }
        ReceiveEnveloped(after) -> receive_enveloped(state, record, after)
        Ready(endpoints, idle_within_ms) ->
          publish_ready(state, record, endpoints, idle_within_ms)
        Progress(value) -> publish_progress(state, id, value)
        Delivery(sequence:, endpoint:, outcome:) ->
          publish_delivery(state, id, sequence, endpoint, outcome)
      }
  }
}

type InputView {
  Raw
  Enveloped
}

fn inspect_value(
  state: State,
  record: execution.Execution,
) -> Result(JsonValue, String) {
  use readiness <- result.try(readiness(state.wiring.runtime, record.id))
  let readiness_fields = case readiness {
    None -> [#("readiness", json.String("preparing"))]
    Some(readiness) -> [
      #("readiness", json.String("ready")),
      #("endpoints", json.Array(list.map(readiness.endpoints, json.String))),
    ]
  }
  let volatile_fields = case dict.get(state.live, record.id) {
    Error(Nil) -> []
    Ok(held) ->
      list.append(
        progress_fields(held.progress),
        delivery_fields(held.delivery),
      )
  }
  case execution.encode(record) {
    json.Object(fields) ->
      Ok(
        json.Object(list.append(
          fields,
          list.append(readiness_fields, volatile_fields),
        )),
      )
    _ -> Error("invalid execution record")
  }
}

fn progress_fields(progress: Option(Snapshot)) -> List(#(String, JsonValue)) {
  case progress {
    None -> []
    Some(snapshot) -> [
      #(
        "progress",
        json.Object([
          #("sequence", json.Int(snapshot.sequence)),
          #("updated_ms", json.Int(snapshot.updated_ms)),
          #("value", snapshot.value),
        ]),
      ),
    ]
  }
}

fn delivery_fields(
  delivery: Option(DeliverySnapshot),
) -> List(#(String, JsonValue)) {
  case delivery {
    None -> []
    Some(delivery) -> {
      let #(status, reason) = case delivery.outcome {
        Delivered -> #("delivered", [])
        Rejected(reason) -> #("rejected", [#("reason", json.String(reason))])
      }
      [
        #(
          "latest_delivery",
          json.Object([
            #("sequence", json.Int(delivery.sequence)),
            #("endpoint", json.String(delivery.endpoint)),
            #("status", json.String(status)),
            ..reason
          ]),
        ),
      ]
    }
  }
}

fn readiness(
  runtime: api.Runtime,
  id: String,
) -> Result(Option(execution.Readiness), String) {
  use value <- result.try(
    api.fact(runtime, execution.readiness_key(id))
    |> result.map_error(string.inspect),
  )
  case value {
    None -> Ok(None)
    Some(value) ->
      execution.decode_readiness(value)
      |> result.map(Some)
      |> result.replace_error("corrupt execution readiness")
  }
}

fn publish_readiness(
  wiring: Wiring,
  record: execution.Execution,
  endpoints: List(String),
  idle_within_ms: Int,
) -> Result(JsonValue, String) {
  let #(now, _) = clock.read(wiring.clock)
  use Nil <- result.try(case execution.admits(record, now) {
    True -> Ok(Nil)
    False -> Error("execution is closed before readiness")
  })
  use aborted <- result.try(
    api.fact_cell(wiring.runtime, execution.abort_key(record.operation))
    |> result.map_error(string.inspect),
  )
  use Nil <- result.try(case aborted {
    None -> Ok(Nil)
    Some(_) -> Error("initiating operation has been aborted")
  })
  use Nil <- result.try(case execution.valid_endpoints(endpoints) {
    True -> Ok(Nil)
    False -> Error("ready requires one to sixteen unique endpoint names")
  })
  use Nil <- result.try(case endpoints, idle_within_ms {
    ["default"], 0 -> Ok(Nil)
    _, value if value >= 1 && value <= 300_000 -> Ok(Nil)
    _, _ ->
      Error("typed readiness requires an idle interval from 1 to 300000 ms")
  })
  let ready = execution.Readiness(endpoints:, idle_within_ms:)
  use existing <- result.try(readiness(wiring.runtime, record.id))
  case existing {
    Some(existing) if existing == ready -> Ok(json.Null)
    Some(_) -> Error("execution readiness is immutable")
    None ->
      api.put_reserved_fact_expecting(
        wiring.runtime,
        execution.readiness_key(record.id),
        execution.encode_readiness(ready),
        None,
      )
      |> result.replace(json.Null)
      |> result.map_error(string.inspect)
  }
}

fn publish_ready(
  state: State,
  record: execution.Execution,
  endpoints: List(String),
  idle_within_ms: Int,
) -> #(State, Result(JsonValue, String)) {
  let answer =
    publish_readiness(state.wiring, record, endpoints, idle_within_ms)
  case answer, dict.get(state.live, record.id) {
    Error(reason), _ -> #(state, Error(reason))
    _, Error(Nil) -> #(state, Error("execution is not live"))
    Ok(value), Ok(held) -> {
      let #(now, _) = clock.read(state.wiring.clock)
      let anchor = option.or(held.idle_anchor_ms, Some(now))
      let held = Held(..held, idle_anchor_ms: anchor)
      #(
        State(..state, live: dict.insert(state.live, record.id, held)),
        Ok(value),
      )
    }
  }
}

fn ready_default(
  wiring: Wiring,
  record: execution.Execution,
) -> Result(execution.Readiness, String) {
  use existing <- result.try(readiness(wiring.runtime, record.id))
  case existing {
    Some(
      execution.Readiness(endpoints: ["default"], idle_within_ms: 0) as ready,
    ) -> Ok(ready)
    Some(_) -> Error("raw receive is unavailable for named endpoints")
    None -> {
      use _ <- result.try(publish_readiness(wiring, record, ["default"], 0))
      Ok(execution.Readiness(endpoints: ["default"], idle_within_ms: 0))
    }
  }
}

fn publish_progress(
  state: State,
  id: String,
  value: JsonValue,
) -> #(State, Result(JsonValue, String)) {
  case dict.get(state.live, id) {
    Error(Nil) -> #(state, Error("execution is not live"))
    Ok(held) ->
      case string.byte_size(json.to_string(value)) <= 16_384 {
        False -> #(state, Error("execution progress exceeds 16384 bytes"))
        True -> {
          let #(now, _) = clock.read(state.wiring.clock)
          let #(held, snapshot) = case held.progress {
            None -> {
              let snapshot = Snapshot(sequence: 1, updated_ms: now, value:)
              #(Held(..held, progress: Some(snapshot)), snapshot)
            }
            Some(current) if now - current.updated_ms >= 100 -> {
              let snapshot =
                Snapshot(
                  sequence: current.sequence + 1,
                  updated_ms: now,
                  value:,
                )
              #(
                Held(..held, progress: Some(snapshot), pending_progress: None),
                snapshot,
              )
            }
            Some(current) -> #(
              Held(..held, pending_progress: Some(PendingProgress(value))),
              current,
            )
          }
          let state = State(..state, live: dict.insert(state.live, id, held))
          #(
            state,
            Ok(
              json.Object([
                #("sequence", json.Int(snapshot.sequence)),
                #("updated_ms", json.Int(snapshot.updated_ms)),
              ]),
            ),
          )
        }
      }
  }
}

fn publish_delivery(
  state: State,
  id: String,
  sequence: Int,
  endpoint: String,
  outcome: DeliveryOutcome,
) -> #(State, Result(JsonValue, String)) {
  let valid_reason = case outcome {
    Delivered -> True
    Rejected(reason) -> string.byte_size(reason) <= 1024
  }
  let answer = {
    use Nil <- result.try(case sequence > 0 && valid_reason {
      True -> Ok(Nil)
      False -> Error("invalid delivery observation")
    })
    use ready <- result.try(readiness(state.wiring.runtime, id))
    use ready <- result.try(option.to_result(
      ready,
      "execution has not published readiness",
    ))
    use Nil <- result.try(case list.contains(ready.endpoints, endpoint) {
      True -> Ok(Nil)
      False -> Error("delivery endpoint was not registered")
    })
    Ok(Nil)
  }
  case answer, dict.get(state.live, id) {
    Error(reason), _ -> #(state, Error(reason))
    _, Error(Nil) -> #(state, Error("execution is not live"))
    Ok(Nil), Ok(held) -> {
      let delivery = DeliverySnapshot(sequence:, endpoint:, outcome:)
      let idle_anchor_ms = case outcome {
        Delivered -> {
          let #(now, _) = clock.read(state.wiring.clock)
          Some(now)
        }
        Rejected(_) -> held.idle_anchor_ms
      }
      let held = Held(..held, delivery: Some(delivery), idle_anchor_ms:)
      #(State(..state, live: dict.insert(state.live, id, held)), Ok(json.Null))
    }
  }
}

fn receive_enveloped(
  state: State,
  record: execution.Execution,
  after: Int,
) -> #(State, Result(JsonValue, String)) {
  let answer = {
    use ready <- result.try(readiness(state.wiring.runtime, record.id))
    use ready <- result.try(option.to_result(
      ready,
      "execution has not published readiness",
    ))
    use Nil <- result.try(case ready.idle_within_ms > 0 {
      True -> Ok(Nil)
      False -> Error("enveloped receive requires typed readiness")
    })
    Ok(ready)
  }
  case answer, dict.get(state.live, record.id) {
    Error(reason), _ -> #(state, Error(reason))
    _, Error(Nil) -> #(
      state,
      Ok(json.Object([#("closed", json.String("execution closed"))])),
    )
    Ok(ready), Ok(held) -> {
      let #(now, _) = clock.read(state.wiring.clock)
      case held.idle_anchor_ms {
        Some(anchor) if now - anchor >= ready.idle_within_ms -> {
          let state =
            close(
              state,
              record.id,
              Some(execution.Lost("execution idle timeout")),
            )
          #(state, Ok(json.Object([#("idle", json.Bool(True))])))
        }
        _ -> #(
          state,
          input_after(state.wiring.runtime, record, after, Enveloped),
        )
      }
    }
  }
}

fn promote_progress(state: State, id: String) -> State {
  case dict.get(state.live, id) {
    Ok(
      Held(progress: Some(current), pending_progress: Some(pending), ..) as held,
    ) -> {
      let #(now, _) = clock.read(state.wiring.clock)
      case now - current.updated_ms >= 100 {
        False -> state
        True -> {
          let snapshot =
            Snapshot(
              sequence: current.sequence + 1,
              updated_ms: now,
              value: pending.value,
            )
          let held =
            Held(..held, progress: Some(snapshot), pending_progress: None)
          State(..state, live: dict.insert(state.live, id, held))
        }
      }
    }
    _ -> state
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
  let state =
    list.fold(dict.keys(state.live), state, fn(state, id) {
      promote_progress(state, id)
    })
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

fn recover(
  wiring: Wiring,
) -> Result(#(List(execution.Execution), Dict(String, Int)), String) {
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
        execution.Finished(_) -> Ok(#(record, None))
        execution.Lost(_) -> {
          wiring.abort(record.operation, record.step)
          Ok(#(record, Some(record)))
        }
        execution.Starting | execution.Running | execution.Draining -> {
          let record =
            execution.Execution(
              ..record,
              phase: execution.Lost("execution service restarted"),
            )
          use Nil <- result.try(save(wiring.runtime, record))
          wiring.abort(record.operation, record.step)
          Ok(#(record, Some(record)))
        }
      }
    }),
  )
  let launches =
    list.fold(records, dict.new(), fn(counts, pair) {
      increment_launch(counts, pair.0.operation)
    })
  Ok(#(
    list.filter_map(records, fn(pair) { option.to_result(pair.1, Nil) }),
    launches,
  ))
}

fn increment_launch(
  launches: Dict(String, Int),
  operation: ids.OpId,
) -> Dict(String, Int) {
  let operation = ids.op_id_to_string(operation)
  let count = dict.get(launches, operation) |> result.unwrap(0)
  dict.insert(launches, operation, count + 1)
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
  endpoint: String,
  value: JsonValue,
) -> Result(JsonValue, String) {
  let #(now, _) = clock.read(wiring.clock)
  use Nil <- result.try(case execution.admits(record, now) {
    True -> Ok(Nil)
    False -> Error("execution is closed to input")
  })
  use aborted <- result.try(
    api.fact_cell(wiring.runtime, execution.abort_key(record.operation))
    |> result.map_error(string.inspect),
  )
  use Nil <- result.try(case aborted {
    None -> Ok(Nil)
    Some(_) -> Error("initiating operation has been aborted")
  })
  use ready <- result.try(readiness(wiring.runtime, record.id))
  use ready <- result.try(option.to_result(
    ready,
    "execution is not ready for input",
  ))
  use Nil <- result.try(case list.contains(ready.endpoints, endpoint) {
    True -> Ok(Nil)
    False -> Error("execution endpoint is not registered")
  })
  use values <- result.try(inputs(wiring.runtime, record.id))
  let entry =
    json.Object([#("endpoint", json.String(endpoint)), #("value", value)])
  let next = list.append(values, [entry])
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
  view: InputView,
) -> Result(JsonValue, String) {
  use values <- result.try(inputs(runtime, record.id))
  case list.first(list.drop(values, int.max(0, after))) {
    Ok(value) -> {
      use pair <- result.try(input_entry(value))
      case view, pair.0 {
        Raw, "default" ->
          Ok(
            json.Object([
              #("sequence", json.Int(int.max(0, after) + 1)),
              #("value", pair.1),
            ]),
          )
        Raw, _ -> Error("raw receive cannot consume named endpoint input")
        Enveloped, endpoint ->
          Ok(
            json.Object([
              #("sequence", json.Int(int.max(0, after) + 1)),
              #("endpoint", json.String(endpoint)),
              #("value", pair.1),
            ]),
          )
      }
    }
    Error(Nil) ->
      case
        execution.terminal(record.phase) || record.phase == execution.Draining
      {
        True -> Ok(json.Object([#("closed", json.String("execution closed"))]))
        False -> Ok(json.Null)
      }
  }
}

fn input_entry(value: JsonValue) -> Result(#(String, JsonValue), String) {
  case value {
    json.Object(fields) -> {
      use endpoint <- result.try(
        list.key_find(fields, "endpoint")
        |> result.replace_error("input endpoint"),
      )
      use endpoint <- result.try(case endpoint {
        json.String(endpoint) -> Ok(endpoint)
        _ -> Error("text input endpoint")
      })
      use value <- result.try(
        list.key_find(fields, "value") |> result.replace_error("input value"),
      )
      Ok(#(endpoint, value))
    }

    // Records written before endpoint registration belong to the raw default.
    legacy -> Ok(#("default", legacy))
  }
}
