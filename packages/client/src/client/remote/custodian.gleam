//// One supervised actor owns one session's remote tool journal.
////
//// `execute` asks for an atomic fresh reservation and a bounded final ticket.
//// Only a fresh reservation starts a weft-owned worker. Caller death loses
//// its ticket, never the worker or committed report. `reported` consumes task
//// reports, commits exact final bytes and only then answers the ticket.
//// A restarted owner has no active worker and never re-executes retained rows.
////
//// Requests are typed and byte bounded; task admission is bounded by four
//// active runs. These properties do not bound an OTP mailbox: root must bind
//// the handle to its bounded ingress/effect pool. No unbounded cast writer,
//// observer list, arbitrary SQL closure or process ledger is exposed here.

import broker/internal/call
import client/remote/outcome
import core/ids
import core/msgpack
import core/remote_tool
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/otp/supervision
import gleam/result
import runtime/effects
import storage/owner_custody as custody
import storage/storage
import weft
import weft/actor
import weft/registry

/// Immutable dependencies and bounded worker policy.
pub opaque type Config {
  Config(
    /// Separate owner journal pathname.
    path: String,
    /// Durable session identity bound in SQLite metadata.
    session: ids.SessionId,
    /// Persistent row and byte quotas.
    limits: custody.Limits,
    /// Maximum independently owned active tool bodies.
    active: Int,
    /// Hard lifetime of one live owner task, in milliseconds.
    task_ms: Int,
    /// Remote runner receives original runtime identity and grants unchanged.
    runner: fn(remote_tool.ToolKey, effects.ToolRun) -> effects.ToolOutcome,
  )
}

/// A reclaimable address, resolving the current supervised owner each ask.
pub opaque type Handle {
  Handle(address: registry.Address(Message), task_ms: Int)
}

/// Closed actor vocabulary; no caller can submit a query closure.
pub opaque type Message {
  Execute(
    remote_tool.ToolKey,
    BitArray,
    BitArray,
    effects.ToolRun,
    process.Subject(Result(effects.ToolOutcome, custody.Error)),
    process.Subject(Result(Nil, custody.Error)),
  )
  Lookup(
    remote_tool.ToolKey,
    BitArray,
    BitArray,
    process.Subject(Result(custody.Evidence, custody.Error)),
  )
  ReserveChild(
    remote_tool.ChildOrigin,
    ids.EntryId,
    BitArray,
    process.Subject(Result(#(ids.EntryId, BitArray), custody.Error)),
  )
  ReadChild(
    remote_tool.ChildOrigin,
    process.Subject(
      Result(#(ids.EntryId, BitArray, option.Option(BitArray)), custody.Error),
    ),
  )
  ReceiveChild(
    remote_tool.ChildOrigin,
    ids.EntryId,
    BitArray,
    process.Subject(Result(Nil, custody.Error)),
  )
  CancelChild(
    remote_tool.ChildOrigin,
    process.Subject(Result(Nil, custody.Error)),
  )
  Collect(
    remote_tool.ToolKey,
    storage.Storage(Nil),
    process.Subject(Result(Nil, custody.Error)),
  )
  Reported(String, weft.Pulled(effects.ToolOutcome, Nil))
  Stop(process.Subject(Result(Nil, custody.Error)))
}

type Held {
  Held(
    key: remote_tool.ToolKey,
    original: effects.ToolRun,
    reports: process.Subject(weft.Pulled(effects.ToolOutcome, Nil)),
    cancel: weft.Cancel,
    disposition: Disposition,
    reply: process.Subject(Result(effects.ToolOutcome, custody.Error)),
  )
}

type Disposition {
  AwaitingReport
  ReportedFinal
}

type State {
  State(
    config: Config,
    store: custody.Store,
    live: Dict(String, Held),
    self: process.Subject(Message),
  )
}

/// Checks active capacity and a finite owner task lifetime.
///
/// ## Examples
///
/// ```gleam
/// // custodian.config(path, session, limits, 4, 60_000, remote_runner)
/// ```
pub fn config(
  path: String,
  session: ids.SessionId,
  limits: custody.Limits,
  active: Int,
  task_ms: Int,
  runner: fn(remote_tool.ToolKey, effects.ToolRun) -> effects.ToolOutcome,
) -> Result(Config, custody.Error) {
  case active > 0 && active <= 4 && task_ms > 0 && task_ms <= 86_400_000 {
    True -> Ok(Config(path:, session:, limits:, active:, task_ms:, runner:))
    False -> Error(custody.Invalid("invalid owner task capacity or lifetime"))
  }
}

/// Allocates an address outside every transport connection.
///
/// ## Examples
///
/// ```gleam
/// // let owner = custodian.new(names, config)
/// ```
pub fn new(names: registry.Registry, config: Config) -> Handle {
  Handle(registry.new_address(names), config.task_ms)
}

/// Starts the actor; production embeds supervised instead.
///
/// ## Examples
///
/// ```gleam
/// // custodian.start(owner, config)
/// ```
pub fn start(
  owner: Handle,
  config: Config,
) -> actor.StartResult(process.Subject(Message)) {
  builder(owner, config) |> actor.start
}

/// Embeds journal custody under the session's existing supervisor.
///
/// ## Examples
///
/// ```gleam
/// // supervisor.add(supervisor, custodian.supervised(owner, config))
/// ```
pub fn supervised(
  owner: Handle,
  config: Config,
) -> supervision.ChildSpecification(process.Subject(Message)) {
  builder(owner, config) |> actor.supervised
}

fn builder(owner: Handle, config: Config) {
  actor.new_with_initialiser(5000, fn(subject) {
    use store <- result.try(
      custody.open(config.path, config.session, config.limits)
      |> result.replace_error("owner custody open failed"),
    )
    Ok(
      actor.initialised(State(config:, store:, live: dict.new(), self: subject))
      |> actor.returning(subject),
    )
  })
  |> actor.addressed(owner.address)
  |> actor.on_message(handle)
  |> actor.trapping_exits(True)
  |> actor.on_shutdown(fn(state, _reason) {
    list.each(dict.values(state.live), fn(held) { weft.cancel(held.cancel) })
    let _closed = custody.close(state.store)
    Nil
  })
}

/// Starts only a fresh admitted task, then awaits a bounded final ticket.
/// A timeout is uncertainty; the supervised owner retains committed evidence.
///
/// ## Examples
///
/// ```gleam
/// // custodian.execute(owner, key, arguments, request, original_run)
/// ```
pub fn execute(
  owner: Handle,
  key: remote_tool.ToolKey,
  arguments: BitArray,
  request: BitArray,
  original: effects.ToolRun,
) -> Result(effects.ToolOutcome, custody.Error) {
  use Nil <- result.try(input_bound(arguments, 262_144))
  use Nil <- result.try(input_bound(request, 262_144))
  let ticket = process.new_subject()
  use Nil <- result.try(
    ask(owner, fn(reply) {
      Execute(key, arguments, request, original, ticket, reply)
    }),
  )
  process.receive(ticket, owner.task_ms + 1000)
  |> result.unwrap(Error(custody.Unavailable("owner final ticket timed out")))
}

/// Checks exact immutable request bytes before exposing final or child evidence.
/// Missing evidence never grants fresh execution permission.
///
/// ## Examples
///
/// ```gleam
/// // custodian.lookup(owner, key, arguments, request)
/// ```
pub fn lookup(
  owner: Handle,
  key: remote_tool.ToolKey,
  arguments: BitArray,
  request: BitArray,
) -> Result(custody.Evidence, custody.Error) {
  use Nil <- result.try(input_bound(arguments, 262_144))
  use Nil <- result.try(input_bound(request, 262_144))
  ask(owner, fn(reply) { Lookup(key, arguments, request, reply) })
}

/// Reserves once or returns the original UUID and exact request on retry.
/// Root mints proposed_id outside connections; retained origins ignore a new
/// candidate only after exact parent identity and request equality checks.
///
/// ## Examples
///
/// ```gleam
/// // custodian.reserve_child(owner, original_origin, proposed_id, request)
/// ```
pub fn reserve_child(
  owner: Handle,
  origin: remote_tool.ChildOrigin,
  proposed_id: ids.EntryId,
  request: BitArray,
) -> Result(#(ids.EntryId, BitArray), custody.Error) {
  use Nil <- result.try(input_bound(request, 131_072))
  ask(owner, fn(reply) { ReserveChild(origin, proposed_id, request, reply) })
}

/// Retrieves stable UUID, outgoing bytes and optional exact child receipt.
///
/// ## Examples
///
/// ```gleam
/// // custodian.child(owner, original_origin)
/// ```
pub fn child(
  owner: Handle,
  origin: remote_tool.ChildOrigin,
) -> Result(#(ids.EntryId, BitArray, option.Option(BitArray)), custody.Error) {
  ask(owner, fn(reply) { ReadChild(origin, reply) })
}

/// Commits exact child result bytes before the dispatcher advertises receipt.
///
/// ## Examples
///
/// ```gleam
/// // custodian.receive_child(owner, origin, id, receipt)
/// ```
pub fn receive_child(
  owner: Handle,
  origin: remote_tool.ChildOrigin,
  id: ids.EntryId,
  receipt: BitArray,
) -> Result(Nil, custody.Error) {
  use Nil <- result.try(input_bound(receipt, 2_097_152))
  ask(owner, fn(reply) { ReceiveChild(origin, id, receipt, reply) })
}

/// Encodes bounded ordered output and terminal bytes without text conversion.
/// Each encoded remote output is retained byte for byte with its boundary.
///
/// ## Examples
///
/// ```gleam
/// // custodian.receipt(outputs, terminal)
/// ```
pub fn receipt(
  outputs: List(BitArray),
  terminal: BitArray,
) -> Result(BitArray, custody.Error) {
  use Nil <- result.try(input_bound(terminal, 32_768))
  let within =
    list.fold(outputs, #(0, 0), fn(acc, bytes) {
      #(acc.0 + 1, acc.1 + bit_array.byte_size(bytes))
    })
  use Nil <- result.try(case within.0 <= 64 && within.1 <= 1_048_576 {
    True -> Ok(Nil)
    False -> Error(custody.Capacity)
  })
  use _ <- result.try(
    list.try_map(outputs, fn(bytes) { input_bound(bytes, 16_384) }),
  )
  msgpack.encode(
    msgpack.ArrayValue([
      msgpack.ArrayValue(list.map(outputs, msgpack.BinaryValue)),
      msgpack.BinaryValue(terminal),
    ]),
  )
  |> result.replace_error(custody.Invalid("invalid exact child receipt"))
}

/// Durably fences the same original origin, including before UUID reservation.
/// A refusal must stop managed dispatch; it is not an acknowledged cancel.
///
/// ## Examples
///
/// ```gleam
/// // custodian.cancel_child(owner, original_origin)
/// ```
pub fn cancel_child(
  owner: Handle,
  origin: remote_tool.ChildOrigin,
) -> Result(Nil, custody.Error) {
  ask(owner, fn(reply) { CancelChild(origin, reply) })
}

/// Reads actual reserved session storage and collects only an exact handoff.
/// ToolFailed records stay retained because their synthetic message is not exact.
///
/// ## Examples
///
/// ```gleam
/// // custodian.collect(owner, key, actual_session_storage)
/// ```
pub fn collect(
  owner: Handle,
  key: remote_tool.ToolKey,
  source: storage.Storage(a),
) -> Result(Nil, custody.Error) {
  let erased =
    storage.Storage(
      handle: Nil,
      commit: fn(_, tx) { storage.commit(source, tx) },
      get_entries: fn(_, ids) { storage.get_entries(source, ids) },
      get_register: fn(_, ns, key) { storage.get_register(source, ns, key) },
      list_registers: fn(_, ns, prefix) {
        storage.list_registers(source, ns, prefix)
      },
      scan_branch: fn(_, query) { storage.scan_branch(source, query) },
      scan_entries: fn(_, query) { storage.scan_entries(source, query) },
      scan_usage: fn(_, query) { storage.scan_usage(source, query) },
      stats: fn(_) { storage.stats(source) },
      close: fn(_) { storage.close(source) },
    )
  ask(owner, fn(reply) { Collect(key, erased, reply) })
}

/// Stops journal ownership after requesting cancellation of active weft runs.
/// This is not a native retirement witness and grants no collection authority.
///
/// ## Examples
///
/// ```gleam
/// // custodian.stop(owner)
/// ```
pub fn stop(owner: Handle) -> Result(Nil, custody.Error) {
  ask(owner, Stop)
}

fn ask(
  owner: Handle,
  message: fn(process.Subject(Result(a, custody.Error))) -> Message,
) -> Result(a, custody.Error) {
  use subject <- result.try(
    registry.lookup(owner.address)
    |> result.replace_error(custody.Unavailable(
      "owner not supervised or unavailable",
    )),
  )
  call.try_call(subject, waiting: 5000, sending: message)
  |> result.unwrap(Error(custody.Unavailable("owner ask failed")))
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Execute(key, args, request, original, ticket, reply) ->
      begin(state, key, args, request, original, ticket, reply)
    Lookup(key, args, request, reply) -> {
      let outcome = {
        use args <- result.try(custody.payload(state.config.limits, args))
        use request <- result.try(custody.payload(state.config.limits, request))
        use Nil <- result.try(custody.validate_request(
          state.store,
          key,
          args,
          request,
        ))
        custody.lookup(state.store, key)
      }
      process.send(reply, outcome)
      resume(state)
    }
    ReserveChild(origin, candidate, request, reply) -> {
      process.send(reply, reserve(state, origin, candidate, request))
      resume(state)
    }
    ReadChild(origin, reply) -> {
      process.send(
        reply,
        custody.child(state.store, origin)
          |> result.map(fn(row) {
            #(row.0, custody.bytes(row.1), option.map(row.2, custody.bytes))
          }),
      )
      resume(state)
    }
    ReceiveChild(origin, id, bytes, reply) -> {
      let outcome = {
        use payload <- result.try(custody.payload(state.config.limits, bytes))
        custody.receive_child(state.store, origin, id, payload)
      }
      process.send(reply, outcome)
      resume(state)
    }
    CancelChild(origin, reply) -> {
      process.send(reply, custody.cancel_child(state.store, origin))
      resume(state)
    }
    Collect(key, source, reply) -> {
      let outcome = {
        use proof <- result.try(custody.verify_commit(
          state.store,
          key,
          source,
          outcome.validate_commit,
        ))
        custody.collect(state.store, proof)
      }
      process.send(reply, outcome)
      resume(state)
    }
    Reported(address, report) -> resume(reported(state, address, report))
    Stop(reply) -> {
      process.send(reply, Ok(Nil))
      actor.stop()
    }
  }
}

fn begin(
  state: State,
  key: remote_tool.ToolKey,
  args: BitArray,
  request: BitArray,
  original: effects.ToolRun,
  ticket: process.Subject(Result(effects.ToolOutcome, custody.Error)),
  reply: process.Subject(Result(Nil, custody.Error)),
) -> actor.Next(State, Message) {
  let admitted = {
    use args <- result.try(custody.payload(state.config.limits, args))
    use request <- result.try(custody.payload(state.config.limits, request))
    use Nil <- result.try(case dict.size(state.live) < state.config.active {
      True -> Ok(Nil)
      False -> Error(custody.Capacity)
    })
    custody.admit_fresh(state.store, key, args, request)
  }
  case admitted {
    Ok(custody.Fresh) -> {
      let runner = state.config.runner
      let reports = process.new_subject()
      let cancel = weft.cancel_signal()
      let _relay =
        weft.new_prepared([
          weft.managed(fn(_ledger) { Ok(runner(key, original)) }),
        ])
        |> weft.cancel_with(cancel)
        |> weft.deadline(state.config.task_ms)
        |> weft.start_relayed(to: reports)
      process.send(reply, Ok(Nil))
      resume(
        State(
          ..state,
          live: dict.insert(
            state.live,
            remote_tool.address(key),
            Held(key, original, reports, cancel, AwaitingReport, ticket),
          ),
        ),
      )
    }
    Ok(custody.Retained) -> {
      process.send(
        reply,
        Error(custody.Invalid("retained admission cannot rerun tool body")),
      )
      resume(state)
    }
    Error(error) -> {
      process.send(reply, Error(error))
      resume(state)
    }
  }
}

fn reserve(
  state: State,
  origin: remote_tool.ChildOrigin,
  candidate: ids.EntryId,
  request: BitArray,
) -> Result(#(ids.EntryId, BitArray), custody.Error) {
  use payload <- result.try(custody.payload(state.config.limits, request))
  case custody.child(state.store, origin) {
    Ok(#(id, original, _)) -> {
      use Nil <- result.try(custody.admit_child(
        state.store,
        origin,
        id,
        payload,
      ))
      Ok(#(id, custody.bytes(original)))
    }
    Error(custody.Missing) -> {
      use Nil <- result.try(custody.admit_child(
        state.store,
        origin,
        candidate,
        payload,
      ))
      Ok(#(candidate, request))
    }
    Error(error) -> Error(error)
  }
}

// The selector retains the report subject until weft confirms all delivery.
// Dropping it at the first result would lose the drain notification and make
// finished task slots appear available before their owner scope has retired.
fn resume(state: State) -> actor.Next(State, Message) {
  let selector =
    list.fold(
      dict.to_list(state.live),
      process.new_selector() |> process.select(state.self),
      fn(selector, row) {
        let #(address, held) = row
        process.select_map(selector, held.reports, fn(report) {
          Reported(address, report)
        })
      },
    )
  actor.continue(state) |> actor.with_selector(selector)
}

fn reported(
  state: State,
  address: String,
  report: weft.Pulled(effects.ToolOutcome, Nil),
) -> State {
  case dict.get(state.live, address) {
    Error(Nil) -> state
    Ok(held) -> report_held(state, address, held, report)
  }
}

fn report_held(
  state: State,
  address: String,
  held: Held,
  report: weft.Pulled(effects.ToolOutcome, Nil),
) -> State {
  case report {
    weft.PulledOutcome(weft.Completed(_, value)) -> {
      let committed = {
        use Nil <- result.try(
          outcome.validate_outcome(held.original, value)
          |> result.map_error(custody.Invalid),
        )
        use bytes <- result.try(
          effects.encode_tool_outcome(value)
          |> result.map_error(custody.Invalid),
        )
        use payload <- result.try(custody.payload(state.config.limits, bytes))
        use Nil <- result.try(custody.finish(state.store, held.key, payload))
        Ok(value)
      }
      answer_once(state, address, held, committed)
    }
    weft.PulledOutcome(weft.Failed(..))
    | weft.PulledOutcome(weft.Crashed(..))
    | weft.PulledOutcome(weft.Abandoned(..))
    | weft.PulledOutcome(weft.NeverStarted(..))
    | weft.PulledOutcome(weft.DrainProofLost(..))
    | weft.PulledOutcome(weft.CancellationUnconfirmed(..)) ->
      answer_once(
        state,
        address,
        held,
        Error(custody.Unavailable(
          "owner worker lost; exact final report unknown",
        )),
      )
    weft.AllDelivered -> {
      let state =
        answer_once(
          state,
          address,
          held,
          Error(custody.Unavailable("owner completed without exact report")),
        )
      State(..state, live: dict.delete(state.live, address))
    }
    weft.RunLost(_) -> {
      let state =
        answer_once(
          state,
          address,
          held,
          Error(custody.Unavailable(
            "owner run lost; exact final report unknown",
          )),
        )
      State(..state, live: dict.delete(state.live, address))
    }
    weft.NotYet -> state
  }
}

fn answer_once(
  state: State,
  address: String,
  held: Held,
  result: Result(effects.ToolOutcome, custody.Error),
) -> State {
  case held.disposition {
    ReportedFinal -> state
    AwaitingReport -> {
      process.send(held.reply, result)
      State(
        ..state,
        live: dict.insert(
          state.live,
          address,
          Held(..held, disposition: ReportedFinal),
        ),
      )
    }
  }
}

fn input_bound(bytes: BitArray, maximum: Int) -> Result(Nil, custody.Error) {
  case
    bit_array.bit_size(bytes) % 8 == 0 && bit_array.byte_size(bytes) <= maximum
  {
    True -> Ok(Nil)
    False -> Error(custody.Capacity)
  }
}
