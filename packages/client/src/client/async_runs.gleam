//// Session-owned code-mode workers and their durable interaction handles.
////
//// A launch claims its record before starting a weft scope. The launching
//// tool owns neither the scope nor its broker step. Closing custody is a
//// durable transition before child cleanup, and Finished requires the scope's
//// final drain report plus every owned child operation's terminal result.
//// A replacement service records Lost and never replays a volatile satellite.
////
//// ## Flow
////
//// `launch` → `handle` → `admit` → `start_worker` → `reported` → `close` → `sweep` → `tell`
////
//// 1. `start` runs the service actor and sends itself `Recover`, so `recover`
////    fences records a previous incarnation left behind before any request.
////    A record left starting or running is asked about in `ask_survivors`, a
////    run of its own whose answers arrive as `Recovered` messages, so the
////    service keeps answering while the question waits on an executor.
//// 2. `launch` and `interact` are bounded calls through `ask`; `handle`
////    serializes them with the managed-task reports and ends each turn in
////    `resume`, which rebuilds the selector over the live workers.
//// 3. `admit` validates a record and answers a replay from the stored one;
////    `start_worker` claims it durably with `save` before the weft scope runs.
//// 4. `inspect` serves one nonblocking `Action` on an owned handle, such as
////    a check, a cancel, `append_input` or a receive.
//// 5. `reported` takes a worker's ordered outcome and drain proof, and
////    `close` makes the durable Draining transition before child cleanup.
//// 6. `sweep` runs on a timer: it reaps deadlines, `heartbeat`s long runs,
////    and saves the terminal phase once the drain is proven.
//// 7. `tell` then posts a completion note to the launching strand when
////    `worth_telling` says the phase is news.
//// 8. `abort_operation` revokes an initiating operation ahead of the broker.

import client/agency
import client/internal/session_owner
import client/notice
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
import telemetry/owner
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
    /// Cancels the effect plane's executions under an operation. Used for
    /// the children a drained execution stops, so a background job a child
    /// started does not outlive it.
    abort_children: fn(ids.OpId) -> Nil,
    /// How long an owner may sit idle while executions it launched are
    /// still live before it is woken with a listing of them, in
    /// milliseconds; zero turns it off. The same `[jobs].heartbeat_s` the
    /// jobs actor reads, so one number governs every kind of background
    /// work.
    heartbeat_ms: Int,
    /// What recovery may still learn about an execution a previous service
    /// left starting or running.
    surviving_value: Survival,
  )
}

/// Whether an execution's value can outlive the service that ran it, and where
/// recovery asks for it.
pub type Survival {
  /// A local execution's value lived only in the worker. Recovery records
  /// every unfinished execution lost before it serves any request.
  NothingSurvives

  /// An execution on an executor stored its value in the executor's ledger.
  /// Recovery asks `read` about each unfinished execution in a run of its
  /// own, and records a value it finds as the result; anything but a value
  /// records the execution lost. The service answers requests while the
  /// questions wait.
  AskWhere(read: fn(execution.Execution) -> Result(JsonValue, Nil))
}

// The three ends somebody chose. An owner's `cancel`, an operator's abort
// of the launching operation and a session stop are each news to nobody,
// and a completion notice about an abort would wake the strand the abort
// was meant to stop. Named once here because both the paths that record
// them and `worth_telling` read them.
const cancelled_reason = "cancelled"

const aborted_reason = "initiating operation aborted"

const stopped_reason = "session stopped"

/// The service's requests and managed-task reports.
pub type Message {
  /// Claims an execution before starting its worker.
  Launch(
    record: execution.Execution,
    work: fn() -> Result(JsonValue, String),
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
  Reported(id: String, report: weft.Pulled(JsonValue, String))

  /// Reaps deadlines and observes pending child drains.
  Sweep

  /// Fences records left by a previous incarnation before serving requests.
  Recover

  /// One answer from the run that asks where a previous service's executions
  /// stand (`surviving_value`), by the record's place in that run.
  Recovered(pulled: weft.Pulled(Result(JsonValue, Nil), Nil))

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
    reports: Subject(weft.Pulled(JsonValue, String)),
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
    /// The records a previous service left starting or running whose fate
    /// recovery is still asking about, by their place in the asking run.
    asking: Dict(Int, execution.Execution),
    /// Where the asking run's answers arrive, while it runs.
    answers: Option(Subject(weft.Pulled(Result(JsonValue, Nil), Nil))),
    /// How long each owner of a live execution has been idle, for the
    /// heartbeat. Volatile, like the executions it counts.
    idle: notice.IdleClock,
    /// The next instant the heartbeat samples at. The service's own sweep
    /// ticks every 100 ms; sampling on every one of those would read each
    /// owner's strand state ten times a second for an answer measured in
    /// minutes.
    next_sample_ms: Int,
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
    // The initialiser runs in the actor's own process, so this label names
    // it to the ownership inspector under its session.
    session_owner.label(wiring.runtime, owner.AsyncRuns)

    actor.initialised(State(
      wiring:,
      self: subject,
      live: dict.new(),
      recovering: [],
      launches: dict.new(),
      asking: dict.new(),
      answers: None,
      idle: notice.idle_clock(),
      next_sample_ms: 0,
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
            phase: execution.Lost(stopped_reason),
          ),
        )
      state.wiring.abort(held.record.operation, held.record.step)
      weft.cancel(held.cancel)
      let _children =
        agency.drain_execution(
          state.wiring.abort_children,
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
  launch_fallible(name, record, fn() { Ok(work()) })
}

/// `launch` for a worker that can know why it has no value. An `Error(reason)`
/// from the work records the execution as `Lost(reason)` instead of the
/// generic loss a crashed worker gets. A worker on another node uses it to say
/// that the executor restarted or refused to start the program.
///
/// ## Examples
///
/// ```gleam
/// // async_runs.launch_fallible(name, record, fn() { Error("executor lost it") })
/// ```
pub fn launch_fallible(
  name: address.Address(Message),
  record: execution.Execution,
  work: fn() -> Result(JsonValue, String),
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

  // Poll for completion or return immediately for non-waiting actions.
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

      // Map polling outcome into result.
      case outcome {
        poll.Answered(value) -> Ok(value)
        poll.Failed(reason) -> Error(reason)
        poll.Expired -> probe()
      }
    }
    _, _ -> probe()
  }
}

/// Checks whether an action should continue waiting for updates.
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

/// Sends a synchronous message to the service actor and awaits a reply.
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

/// Handles incoming actor messages and steps the service state.
fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  // Dispatch on incoming message variant.
  case message {
    Recover ->
      case recover(state.wiring) {
        Ok(#(recovering, launches, asking)) ->
          State(..state, recovering:, launches:)
          |> ask_survivors(asking)
          |> resume
        Error(reason) -> actor.stop_abnormal(reason)
      }
    Recovered(pulled:) ->
      case recovered(state, pulled) {
        Ok(state) -> resume(state)
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

      // Ensure abort marker was persisted successfully.
      case marked {
        Error(reason) -> {
          process.send(reply, Error(reason))
          resume(state)
        }
        Ok(_) -> {
          let state =
            dict.fold(state.live, state, fn(state, id, held) {
              case held.record.operation == operation {
                True -> close(state, id, Some(execution.Lost(aborted_reason)))
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

/// Rebuilds message selectors and continues actor execution.
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

  // Include recovery answer selector if waiting on recovery.
  let selector = case state.answers {
    None -> selector
    Some(answers) -> process.select_map(selector, answers, Recovered)
  }

  actor.continue(state) |> actor.with_selector(selector)
}

/// Validates an execution launch request against current capacity and stored facts.
fn admit(
  state: State,
  record: execution.Execution,
  work: fn() -> Result(JsonValue, String),
) -> Result(#(State, JsonValue), String) {
  use _decoded <- result.try(
    execution.decode(execution.encode(record))
    |> result.replace_error("invalid execution terms"),
  )
  use aborted <- result.try(
    api.fact_cell(state.wiring.runtime, execution.abort_key(record.operation))
    |> result.map_error(string.inspect),
  )

  // Verify initiating operation was not aborted.
  use Nil <- result.try(case aborted {
    None -> Ok(Nil)
    Some(_) -> Error("initiating operation has been aborted")
  })

  use existing <- result.try(load(state.wiring.runtime, record.id))

  // Check if execution record already exists.
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

/// Spawns a new managed task worker for an admitted execution.
fn start_worker(
  state: State,
  record: execution.Execution,
  work: fn() -> Result(JsonValue, String),
) -> Result(#(State, JsonValue), String) {
  let #(now, _) = clock.read(state.wiring.clock)
  let operation = ids.op_id_to_string(record.operation)
  let launches = dict.get(state.launches, operation) |> result.unwrap(0)

  // Verify capacity limits before spawning worker.
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

  // Prepare worker reporting and cancellation signals.
  let reports = process.new_subject()
  let cancel = weft.cancel_signal()
  let _scope =
    weft.new([work])
    |> weft.deadline(record.deadline_ms - now)
    |> weft.cancel_with(cancel)
    |> weft.start_relayed(reports)

  // Track the running execution in live state.
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

/// Loads an execution record from runtime storage.
fn load(
  runtime: api.Runtime,
  id: String,
) -> Result(Option(execution.Execution), String) {
  // Validate execution identifier format.
  use Nil <- result.try(case execution.valid_id(id) {
    True -> Ok(Nil)
    False -> Error("invalid execution handle")
  })

  use cell <- result.try(
    api.fact(runtime, execution.key(id)) |> result.map_error(string.inspect),
  )

  // Decode execution record if present.
  case cell {
    None -> Ok(None)
    Some(value) ->
      execution.decode(value)
      |> result.map(Some)
      |> result.replace_error("corrupt execution record")
  }
}

/// Reads an execution's durable record by its handle, without asking the
/// service. `Ok(None)` means there is no such record.
///
/// An owner answering a program on another node reads it on every owner-bound
/// call the program makes, and the reconciler reads it for every execution the
/// executor reports running. Neither may wait behind the service's mailbox, and
/// neither needs its volatile state: the record decides.
///
/// ## Examples
///
/// ```gleam
/// // async_runs.record(runtime, handle)
/// ```
pub fn record(
  runtime: api.Runtime,
  id: String,
) -> Result(Option(execution.Execution), String) {
  load(runtime, id)
}

/// Saves an execution record to runtime storage.
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

/// Evaluates an inspection action against an execution record.
fn inspect(
  state: State,
  strand: String,
  id: String,
  action: Action,
) -> #(State, Result(JsonValue, String)) {
  let state = promote_progress(state, id)
  let answer = {
    use record <- result.try(load(state.wiring.runtime, id))

    // Ensure execution is owned by requesting strand.
    case record {
      Some(record) if record.strand == strand -> Ok(record)
      Some(_) | None -> Error("execution handle is not owned by this strand")
    }
  }

  // Dispatch on inspection result and action type.
  case answer {
    Error(reason) -> #(state, Error(reason))
    Ok(record) ->
      case action {
        Check -> #(state, inspect_value(state, record))
        Cancel -> {
          let state = close(state, id, Some(execution.Lost(cancelled_reason)))
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

/// Serializes an execution record into a JSON inspection value.
fn inspect_value(
  state: State,
  record: execution.Execution,
) -> Result(JsonValue, String) {
  use readiness <- result.try(readiness(state.wiring.runtime, record.id))

  // Determine readiness status fields.
  let readiness_fields = case readiness {
    None -> [#("readiness", json.String("preparing"))]
    Some(readiness) -> [
      #("readiness", json.String("ready")),
      #("endpoints", json.Array(list.map(readiness.endpoints, json.String))),
    ]
  }

  // Include volatile progress and delivery fields.
  let volatile_fields = case dict.get(state.live, record.id) {
    Error(Nil) -> []
    Ok(held) ->
      list.append(
        progress_fields(held.progress),
        delivery_fields(held.delivery),
      )
  }

  // Combine static and volatile fields into final JSON object.
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

/// Formats progress snapshot into JSON object fields.
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

/// Formats delivery snapshot into JSON object fields.
fn delivery_fields(
  delivery: Option(DeliverySnapshot),
) -> List(#(String, JsonValue)) {
  // Check if delivery observation is present.
  case delivery {
    None -> []
    Some(delivery) -> {
      // Map delivery status and optional rejection reason.
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

/// Reads execution readiness status from runtime storage.
fn readiness(
  runtime: api.Runtime,
  id: String,
) -> Result(Option(execution.Readiness), String) {
  use value <- result.try(
    api.fact(runtime, execution.readiness_key(id))
    |> result.map_error(string.inspect),
  )

  // Decode readiness fact if present.
  case value {
    None -> Ok(None)
    Some(value) ->
      execution.decode_readiness(value)
      |> result.map(Some)
      |> result.replace_error("corrupt execution readiness")
  }
}

/// Validates and records execution readiness.
fn publish_readiness(
  wiring: Wiring,
  record: execution.Execution,
  endpoints: List(String),
  idle_within_ms: Int,
) -> Result(JsonValue, String) {
  let #(now, _) = clock.read(wiring.clock)

  // Verify execution admits readiness publication.
  use Nil <- result.try(case execution.admits(record, now) {
    True -> Ok(Nil)
    False -> Error("execution is closed before readiness")
  })

  use aborted <- result.try(
    api.fact_cell(wiring.runtime, execution.abort_key(record.operation))
    |> result.map_error(string.inspect),
  )

  // Ensure initiating operation is not aborted.
  use Nil <- result.try(case aborted {
    None -> Ok(Nil)
    Some(_) -> Error("initiating operation has been aborted")
  })

  // Validate endpoint registration and idle timeouts.
  use Nil <- result.try(case execution.valid_endpoints(endpoints) {
    True -> Ok(Nil)
    False -> Error("ready requires one to sixteen unique endpoint names")
  })

  // Ensure idle timeout interval is valid.
  use Nil <- result.try(case endpoints, idle_within_ms {
    ["default"], 0 -> Ok(Nil)
    _, value if value >= 1 && value <= 300_000 -> Ok(Nil)
    _, _ ->
      Error("typed readiness requires an idle interval from 1 to 300000 ms")
  })

  // Record verified readiness for the execution.
  let ready = execution.Readiness(endpoints:, idle_within_ms:)
  use existing <- result.try(readiness(wiring.runtime, record.id))

  // Persist readiness if not already registered.
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

/// Updates execution live state with published readiness.
fn publish_ready(
  state: State,
  record: execution.Execution,
  endpoints: List(String),
  idle_within_ms: Int,
) -> #(State, Result(JsonValue, String)) {
  let answer =
    publish_readiness(state.wiring, record, endpoints, idle_within_ms)

  // Check publication answer and live worker presence.
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

/// Ensures default readiness is registered for an execution.
fn ready_default(
  wiring: Wiring,
  record: execution.Execution,
) -> Result(execution.Readiness, String) {
  use existing <- result.try(readiness(wiring.runtime, record.id))

  // Return existing default readiness or publish default.
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

/// Records a progress snapshot for a live execution.
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

          // Rate-limit progress updates.
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

/// Records delivery observation for an execution input.
/// Records delivery observation for an execution input.
fn publish_delivery(
  state: State,
  id: String,
  sequence: Int,
  endpoint: String,
  outcome: DeliveryOutcome,
) -> #(State, Result(JsonValue, String)) {
  // Validate delivery outcome reason length.
  let valid_reason = case outcome {
    Delivered -> True
    Rejected(reason) -> string.byte_size(reason) <= 1024
  }

  let answer = {
    // Validate sequence number and rejection reason.
    use Nil <- result.try(case sequence > 0 && valid_reason {
      True -> Ok(Nil)
      False -> Error("invalid delivery observation")
    })

    use ready <- result.try(readiness(state.wiring.runtime, id))
    use ready <- result.try(option.to_result(
      ready,
      "execution has not published readiness",
    ))

    // Verify target endpoint was registered.
    use Nil <- result.try(case list.contains(ready.endpoints, endpoint) {
      True -> Ok(Nil)
      False -> Error("delivery endpoint was not registered")
    })

    Ok(Nil)
  }

  // Update live delivery state if execution is active.
  case answer, dict.get(state.live, id) {
    Error(reason), _ -> #(state, Error(reason))
    _, Error(Nil) -> #(state, Error("execution is not live"))
    Ok(Nil), Ok(held) -> {
      let delivery = DeliverySnapshot(sequence:, endpoint:, outcome:)

      // Reset idle anchor timestamp on successful delivery.
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

/// Receives the next enveloped input message for an execution.
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

    // Ensure typed readiness is active.
    use Nil <- result.try(case ready.idle_within_ms > 0 {
      True -> Ok(Nil)
      False -> Error("enveloped receive requires typed readiness")
    })

    Ok(ready)
  }

  // Check live state and idle timeout before consuming input.
  case answer, dict.get(state.live, record.id) {
    Error(reason), _ -> #(state, Error(reason))
    _, Error(Nil) -> #(
      state,
      Ok(json.Object([#("closed", json.String("execution closed"))])),
    )
    Ok(ready), Ok(held) -> {
      let #(now, _) = clock.read(state.wiring.clock)

      // Test whether execution exceeded its idle timeout.
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

/// Promotes pending rate-limited progress if interval has elapsed.
fn promote_progress(state: State, id: String) -> State {
  // Check if live worker has pending progress.
  case dict.get(state.live, id) {
    Ok(
      Held(progress: Some(current), pending_progress: Some(pending), ..) as held,
    ) -> {
      let #(now, _) = clock.read(state.wiring.clock)

      // Test whether 100ms throttle interval has passed.
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

/// Transitions an execution to draining phase and cancels its worker scope.
fn close(state: State, id: String, outcome: Option(execution.Phase)) -> State {
  // Locate live worker to close.
  case dict.get(state.live, id) {
    Error(Nil) -> state
    Ok(held) -> {
      let record = execution.Execution(..held.record, phase: execution.Draining)

      // Save draining phase to storage.
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

/// Processes worker outcome and drain proof reports.
fn reported(
  state: State,
  id: String,
  report: weft.Pulled(JsonValue, String),
) -> State {
  // Dispatch on pulled report variant.
  case report {
    weft.NotYet -> state
    weft.PulledOutcome(outcome) -> {
      // Map worker outcome to execution phase.
      let phase = case outcome {
        weft.Completed(value:, ..) -> execution.Finished(value)

        // A worker that knows why it has no result says so, as a remote one
        // does when the executor restarted or refused the start.
        weft.Failed(error:, ..) -> execution.Lost(error)
        weft.Crashed(..)
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

/// Records drain status proof for an execution.
fn mark_drain(state: State, id: String, drain: Drain) -> State {
  // Look up live worker to mark drain status.
  case dict.get(state.live, id) {
    Error(Nil) -> state
    Ok(held) -> {
      // Map drain proof status to execution outcome.
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

// --- telling the owner ----------------------------------------------------

/// Delivers a completion notice to the launching strand if the terminal phase is notable.
/// A settled execution's notice to the strand that launched it, if its end
/// is news. Called once the terminal phase is saved: after the drain proof
/// for an ordinary end, and from recovery for one a restart ended. A
/// delivery that fails is dropped, because the record is terminal and a
/// `check` or `join` reads it.
fn tell(runtime: api.Runtime, record: execution.Execution) -> Nil {
  // Check whether notice delivery is warranted.
  case worth_telling(record.phase) {
    True -> {
      let _delivered =
        notice.deliver(
          runtime,
          record.strand,
          notice.Execution(id: record.id),
          completion_text(record),
        )
      Nil
    }
    False -> Nil
  }
}

/// Determines whether an execution phase change should notify the owner strand.
fn worth_telling(phase: execution.Phase) -> Bool {
  case phase {
    execution.Finished(_) -> True
    execution.Lost(reason:) ->
      !list.contains([cancelled_reason, aborted_reason, stopped_reason], reason)
    execution.Starting | execution.Running | execution.Draining -> False
  }
}

// How many bytes of a finished program's result a notice quotes: enough
// for the common small report, with the rest a `join` away.
const notice_result_bytes = 2048

/// Formats the completion notice text for a finished or lost execution.
/// The completion notice's text. Its first line names it completely, as a
/// client's collapsed view of a `[loom]` message expects.
fn completion_text(record: execution.Execution) -> String {
  // Describe terminal outcome.
  let ended = case record.phase {
    execution.Finished(result) ->
      "finished\n\nIts result:\n"
      <> clipped(json.to_string(result), notice_result_bytes)
    execution.Lost(reason:) ->
      "was lost: "
      <> reason
      <> ". Anything it did before that is not undone and not replayed."
    execution.Starting | execution.Running | execution.Draining ->
      "is still running"
  }

  "[loom] async code-mode execution "
  <> record.id
  <> " "
  <> ended
  <> "\n\nRead its full record with `code_mode` mode `check` (handle "
  <> record.id
  <> ")."
}

fn clipped(text: String, limit: Int) -> String {
  case string.byte_size(text) > limit {
    False -> text
    True -> string.slice(text, 0, limit) <> " [clipped]"
  }
}

// --- the idle heartbeat ---------------------------------------------------

/// Periodically samples active executions and notifies idle strands.
/// One heartbeat sample, when one is due. Every owner of a live execution
/// is asked whether its strand has an open run, and one that has been idle
/// for the whole interval is woken with a listing of what is still running.
fn heartbeat(state: State, now: Int) -> State {
  let interval = state.wiring.heartbeat_ms

  // Check if heartbeat sampling interval has elapsed.
  case interval > 0 && now >= state.next_sample_ms {
    False -> state
    True -> {
      let owners = live_by_owner(state.live)
      let idle = notice.retain(state.idle, dict.keys(owners))
      let idle =
        dict.fold(owners, idle, fn(idle, owner, records) {
          notice.sample_runtime(
            state.wiring.runtime,
            idle,
            owner,
            now:,
            interval_ms: interval,
            lines: fn() { list.map(records, heartbeat_line(_, now)) },
          )
        })
      State(..state, idle:, next_sample_ms: now + notice.heartbeat_tick_ms)
    }
  }
}

/// Formats a single status line for a running execution in a heartbeat notice.
fn heartbeat_line(record: execution.Execution, now: Int) -> String {
  "async execution "
  <> record.id
  <> " ("
  <> record.seam
  <> " seam), deadline in "
  <> notice.minutes(int.max(record.deadline_ms - now, 0))
}

/// Groups active live executions by their owner strand.
/// Every execution still running, grouped by the strand that launched it.
/// A draining one is on its way out and is not work the owner is waiting
/// on.
fn live_by_owner(
  live: Dict(String, Held),
) -> Dict(String, List(execution.Execution)) {
  dict.fold(live, dict.new(), fn(owners, _id, held) {
    case held.record.phase {
      execution.Starting | execution.Running ->
        dict.upsert(owners, held.record.strand, fn(existing) {
          [held.record, ..option.unwrap(existing, [])]
        })
      execution.Draining | execution.Finished(_) | execution.Lost(_) -> owners
    }
  })
}

/// Sweeps active executions to enforce deadlines and finalize drained executions.
fn sweep(state: State) -> State {
  let recovering =
    list.filter(state.recovering, fn(record) {
      agency.drain_execution(
        state.wiring.abort_children,
        state.wiring.runtime,
        record.operation,
        record.id,
      )
      != Ok(True)
    })
  let state = State(..state, recovering:)
  let state =
    list.fold(dict.keys(state.live), state, fn(state, id) {
      promote_progress(state, id)
    })
  let #(now, _) = clock.read(state.wiring.clock)
  let state = heartbeat(state, now)
  dict.fold(state.live, state, fn(state, id, held) {
    // Check execution deadline and abort status.
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
          Ok(Some(_)) -> close(state, id, Some(execution.Lost(aborted_reason)))
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
            state.wiring.abort_children,
            state.wiring.runtime,
            held.record.operation,
            id,
          )

        // Finalize execution once drain is proven and children are stopped.
        case drained, held.drain, held.outcome {
          Ok(True), Proven, Some(phase) | Ok(True), LostProof, Some(phase) -> {
            let settled = execution.Execution(..held.record, phase:)

            // Save settled execution record.
            case save(state.wiring.runtime, settled) {
              Ok(Nil) -> {
                tell(state.wiring.runtime, settled)
                State(..state, live: dict.delete(state.live, id))
              }
              Error(_) -> state
            }
          }
          _, _, _ -> state
        }
      }

      execution.Finished(_) | execution.Lost(_) -> state
    }
  })
}

/// Fences orphaned executions and initializes survivor recovery queries.
fn recover(
  wiring: Wiring,
) -> Result(
  #(List(execution.Execution), Dict(String, Int), List(execution.Execution)),
  String,
) {
  use cells <- result.try(
    api.reserved_facts(wiring.runtime, execution.prefix <> "record/")
    |> result.map_error(string.inspect),
  )
  use records <- result.try(
    list.try_map(cells, fn(pair) {
      execution.decode(pair.1)
      |> result.replace_error("corrupt saved execution")
    }),
  )

  // A record that was starting or running may have a value that outlived the
  // service when it ran on an executor; asking takes a round trip per record
  // to wherever the value is kept, so those are asked about in a run of their
  // own (`ask_survivors`) and the service answers requests meanwhile. Every
  // other record is settled here, before any request is served.
  use settled <- result.try(
    list.try_map(records, fn(record) {
      // Determine recovery disposition based on saved phase.
      case record.phase {
        execution.Finished(_) -> Ok(Settled(record))
        execution.Lost(_) -> {
          wiring.abort(record.operation, record.step)
          Ok(Drains(record))
        }
        execution.Starting | execution.Running ->
          case wiring.surviving_value {
            AskWhere(..) -> Ok(Asked(record))
            NothingSurvives -> {
              use record <- result.try(conclude(
                wiring,
                record,
                execution.Lost(restarted_reason),
              ))
              Ok(Drains(record))
            }
          }
        execution.Draining -> {
          use record <- result.try(conclude(
            wiring,
            record,
            execution.Lost(restarted_reason),
          ))
          Ok(Drains(record))
        }
      }
    }),
  )
  let launches =
    list.fold(records, dict.new(), fn(counts, record) {
      increment_launch(counts, record.operation)
    })
  Ok(#(
    list.filter_map(settled, fn(found) {
      case found {
        Drains(record) -> Ok(record)
        Settled(..) | Asked(..) -> Error(Nil)
      }
    }),
    launches,
    list.filter_map(settled, fn(found) {
      case found {
        Asked(record) -> Ok(record)
        Settled(..) | Drains(..) -> Error(Nil)
      }
    }),
  ))
}

// What recovery does with one saved record: nothing more, sweep its owned
// children until they drain, or ask whether its value outlived the service.
type Found {
  Settled(record: execution.Execution)
  Drains(record: execution.Execution)
  Asked(record: execution.Execution)
}

const restarted_reason = "execution service restarted"

/// Saves recovered execution phase and stops child operations.
/// Saves the phase recovery decided for a record a previous service left
/// unfinished, stops what may still run, and tells the launcher. This recovery
/// is what ended the execution, so nobody has been told; one already terminal
/// was told, or chose not to be, by the incarnation that wrote it. An execution
/// recovered as finished still has its owned children drained by the sweep, as
/// a finished one always does.
fn conclude(
  wiring: Wiring,
  record: execution.Execution,
  phase: execution.Phase,
) -> Result(execution.Execution, String) {
  let record = execution.Execution(..record, phase:)
  use Nil <- result.try(save(wiring.runtime, record))

  // Abort lingering child operations if execution is not finished.
  case phase {
    execution.Finished(_) -> Nil
    execution.Lost(_)
    | execution.Starting
    | execution.Running
    | execution.Draining -> wiring.abort(record.operation, record.step)
  }

  tell(wiring.runtime, record)
  Ok(record)
}

// Starts the run that asks, for every record a previous service left starting
// or running, whether its value outlived the service, all at once. Each
// answer comes back as a `Recovered` message, so a store that is slow or an
// executor that cannot be reached delays only these records and never the
// service's other requests.
/// Queries executors for surviving values of unfinished executions.
fn ask_survivors(state: State, asking: List(execution.Execution)) -> State {
  // Check if executor inquiry is configured and items remain.
  case asking, state.wiring.surviving_value {
    [], _ | _, NothingSurvives -> state
    _, AskWhere(read:) -> {
      let answers = process.new_subject()
      let _relay =
        weft.new(list.map(asking, fn(record) { fn() { Ok(read(record)) } }))
        |> weft.start_relayed(to: answers)
      State(
        ..state,
        asking: dict.from_list(
          list.index_map(asking, fn(record, index) { #(index, record) }),
        ),
        answers: Some(answers),
      )
    }
  }
}

// One report from the asking run. A value that outlived the service is the
// program's result, as a tool call recovers a stored outcome; any other
// ending, including a question that crashed, means the program's end is
// unknown, so the record is lost and never resumed.
/// Ingests recovered execution values from background inquiries.
fn recovered(
  state: State,
  pulled: weft.Pulled(Result(JsonValue, Nil), Nil),
) -> Result(State, String) {
  case pulled {
    weft.NotYet -> Ok(state)
    weft.PulledOutcome(outcome:) ->
      case outcome {
        weft.Completed(index:, value: Ok(value)) ->
          answered(state, index, execution.Finished(value))
        weft.Completed(index:, value: Error(Nil))
        | weft.Failed(index:, error: Nil)
        | weft.Crashed(index:, reason: _)
        | weft.Abandoned(index:)
        | weft.NeverStarted(index:)
        | weft.DrainProofLost(index:, reason: _)
        | weft.CancellationUnconfirmed(index:) ->
          answered(state, index, execution.Lost(restarted_reason))
      }

    // The run is over. A record it never reported on is lost.
    weft.AllDelivered | weft.RunLost(reason: _) -> {
      use state <- result.try(
        list.try_fold(dict.keys(state.asking), state, fn(state, index) {
          answered(state, index, execution.Lost(restarted_reason))
        }),
      )
      Ok(State(..state, answers: None))
    }
  }
}

/// Updates recovered execution status after inquiry completes.
/// Updates recovered execution status after inquiry completes.
fn answered(
  state: State,
  index: Int,
  phase: execution.Phase,
) -> Result(State, String) {
  // Look up asked execution by index.
  case dict.get(state.asking, index) {
    Error(Nil) -> Ok(state)
    Ok(record) -> {
      use record <- result.try(conclude(state.wiring, record, phase))
      Ok(
        State(..state, asking: dict.delete(state.asking, index), recovering: [
          record,
          ..state.recovering
        ]),
      )
    }
  }
}

/// Increments the count of launches performed by an operation.
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

/// Reads the input journal values for an execution from runtime storage.
fn inputs(runtime: api.Runtime, id: String) -> Result(List(JsonValue), String) {
  use value <- result.try(
    api.fact(runtime, input_key(id)) |> result.map_error(string.inspect),
  )

  // Decode array of input journal entries.
  case value {
    None -> Ok([])
    Some(json.Array(values)) -> Ok(values)
    Some(_) -> Error("invalid execution input journal")
  }
}

/// Appends a new input entry to an execution's input journal.
fn append_input(
  wiring: Wiring,
  record: execution.Execution,
  endpoint: String,
  value: JsonValue,
) -> Result(JsonValue, String) {
  let #(now, _) = clock.read(wiring.clock)

  // Verify execution admits input.
  use Nil <- result.try(case execution.admits(record, now) {
    True -> Ok(Nil)
    False -> Error("execution is closed to input")
  })

  use aborted <- result.try(
    api.fact_cell(wiring.runtime, execution.abort_key(record.operation))
    |> result.map_error(string.inspect),
  )

  // Verify operation was not aborted.
  use Nil <- result.try(case aborted {
    None -> Ok(Nil)
    Some(_) -> Error("initiating operation has been aborted")
  })

  // Verify readiness and endpoint membership before staging input.
  use ready <- result.try(readiness(wiring.runtime, record.id))
  use ready <- result.try(option.to_result(
    ready,
    "execution is not ready for input",
  ))

  // Verify endpoint registration.
  use Nil <- result.try(case list.contains(ready.endpoints, endpoint) {
    True -> Ok(Nil)
    False -> Error("execution endpoint is not registered")
  })

  use values <- result.try(inputs(wiring.runtime, record.id))
  let entry =
    json.Object([#("endpoint", json.String(endpoint)), #("value", value)])
  let next = list.append(values, [entry])

  // Ensure appended input fits within bounded journal limits.
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

/// Reads the next input entry after the given cursor position.
fn input_after(
  runtime: api.Runtime,
  record: execution.Execution,
  after: Int,
  view: InputView,
) -> Result(JsonValue, String) {
  use values <- result.try(inputs(runtime, record.id))

  // Fetch the next available input item after cursor.
  case list.first(list.drop(values, int.max(0, after))) {
    Ok(value) -> {
      use pair <- result.try(input_entry(value))

      // Format input item based on requested view.
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

/// Parses a raw or typed input journal entry into an endpoint-payload pair.
fn input_entry(value: JsonValue) -> Result(#(String, JsonValue), String) {
  // Parse input payload shape.
  case value {
    json.Object(fields) -> {
      use endpoint <- result.try(
        list.key_find(fields, "endpoint")
        |> result.replace_error("input endpoint"),
      )

      // Validate endpoint text type.
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
