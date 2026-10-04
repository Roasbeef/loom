//// Owner Dispatcher with local custody before any possible remote send.
////
//// start parks a guarantor without TLS or journal I/O in the broker's serial
//// handler. Only after successful actor creation does it publish Begin, and it
//// has no StartRefusal path after that publication. The worker durably reserves
//// a logical UUID/link through root's callback, then transfers the typed key to
//// the guarantor via a permit ask before opening any socket. IDs are never
//// derived from seq/token/generation. The immutable already-prepared request
//// must equal the broker-cleared request and actual operation/step exactly.
////
//// The wall deadline is converted once at start into monotonic remaining.
//// Reservation, TLS/challenge and queue time subtract from that one origin.
//// Single-use challenge budget is R-W-100 ms, never reconstructed on reconnect.
//// Reconciliation queries the original key; Submit is never retried as a fresh
//// mutation. Lost admission/result/receipt replies retain the durable link and
//// settle once as ExecutionLost, never NotStarted. Later root recovery updates
//// retained evidence without invoking this call's callback a second time.
////
//// Root's receive callback must commit exact ordered output+terminal bytes before
//// DurableReceipt is sent. Execution.release only ends this guarantor; it is
//// never durable receipt. Root owns final ToolOutcome recovery/session handoff.
//// Input uses bounded asks (8 KiB/item,128 items/1 MiB lifetime), queued before
//// Submit finishes and forwarded only after possible admission. Cancellation
//// runs on a separate supervised exchange while the reader may block; finite
//// executor watchdog is independent. Upstream producer/final-consumer credits
//// remain root's #703 responsibility; this queue alone proves no E2E bound.
////
//// CommandReserved adds the complete service route without changing the native
//// Reserved constructor. validate_route checks the original ChildOrigin and
//// physical correspondence before Reserve transfers custody to the guarantor.
//// exchange_route selects the closed codec for both worker and detached Cancel;
//// no transport closure can replace that selection.

import broker/dispatch
import broker/exec
import core/clock
import core/command
import core/remote_tool
import executor/remote/connection
import executor/remote/identity
import executor/remote/native
import executor/remote/service
import executor/remote/wire
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import weft
import weft/actor
import weft/poll

/// A reservation whose key/link and exact request have already durably committed.
///
/// ## Examples
///
/// ```gleam
/// let command = dispatcher.CommandReserved(key: key, prepared: prepared, ref: ref)
/// assert command.key == key
/// assert command.prepared == prepared
/// ```
///
/// ```gleam
/// let native = dispatcher.Reserved(key: key, prepared: prepared)
/// assert native.key == key
/// ```
pub type Reserved {
  /// Root allocates request UUID outside the connection and binds administrative scope.
  Reserved(
    /// The original durably reserved logical request identity.
    key: identity.RequestKey,
    /// The exact command materialized beside the registered executor.
    prepared: wire.Prepared,
  )

  /// A physical service child retains its complete durable route beside the native key.
  CommandReserved(
    /// The original durably reserved native request identity.
    key: identity.RequestKey,
    /// The unchanged broker-cleared native materialization.
    prepared: wire.Prepared,
    /// The exact parent service and physical command association.
    ref: command.CommandRef,
  )
}

/// Owner assembly keeps approvals, durable request IDs and result custody local.
pub type Config {
  /// No callback is invoked in the broker's serial start handler.
  Config(
    /// Pinned peer/socket budgets; no logical identity is allocated here.
    connection: connection.Config,
    /// The owner dispatcher incarnation for transient broker handles.
    incarnation: Int,
    /// The bounded live callback window; expiry retains durable recovery custody.
    reconcile_ms: Int,
    /// Commits the original request UUID/link and materialization before any send.
    reserve: fn(dispatch.Dispatch) -> Result(Reserved, Nil),
    /// Commits exact bytes under the unchanged reserved child origin before receipt.
    receive: fn(
      remote_tool.ChildOrigin,
      identity.RequestKey,
      identity.Digest,
      List(BitArray),
      BitArray,
    ) -> Result(Nil, Nil),
    /// Retains the original durable link for reconciliation after uncertain I/O.
    uncertain: fn(identity.RequestKey, identity.Digest) -> Nil,
    /// Commits cancellation intent even if the guarantor has already died.
    cancel_reserved: fn(dispatch.Dispatch) -> Nil,
    /// The injected local monotonic elapsed clock, shared with native watchdog.
    now: fn() -> Int,
  )
}

type CommandRoute {
  NativeRoute
  ServiceCommand(command.CommandRef)
}

type State {
  State(
    config: Config,
    request: dispatch.Dispatch,
    subject: process.Subject(Message),
    origin: Int,
    remaining: Int,
    reserved: Option(#(identity.RequestKey, identity.Digest, CommandRoute)),
    inputs: List(#(Int, BitArray, dispatch.Eof)),
    input_count: Int,
    input_bytes: Int,
    input_closed: InputState,
    settled: Settlement,
    cancel: weft.Cancel,
  )
}

type InputState {
  Open
  Closed
}

type Settlement {
  Pending
  Settled
}

type Message {
  Begin
  Reserve(
    key: identity.RequestKey,
    digest: identity.Digest,
    route: CommandRoute,
    reply: process.Subject(Result(Nil, Nil)),
  )
  Input(bytes: BitArray, eof: dispatch.Eof, reply: process.Subject(Nil))
  TakeInput(reply: process.Subject(Option(#(Int, BitArray, dispatch.Eof))))
  Cancel
  Done(outcome: weft.Pulled(dispatch.Terminal, Nil))
  Release
}

/// Provides the existing Dispatcher seam; actual native work stays at executor.
///
/// ## Examples
///
/// ```gleam
/// let remote = dispatcher.dispatcher(config)
/// ```
pub fn dispatcher(config: Config) -> dispatch.Dispatcher {
  dispatch.Dispatcher(start: start(config, _))
}

fn start(
  config: Config,
  request: dispatch.Dispatch,
) -> Result(dispatch.Execution, dispatch.StartRefusal) {
  let #(wall_now, _) = clock.read(request.clock)
  let remaining = case request.deadline_ms {
    0 -> 0
    _ -> request.deadline_ms - wall_now
  }
  use Nil <- result.try(
    case
      config.reconcile_ms > 0
      && config.reconcile_ms <= 86_400_000
      && request.context.origin != None
      && { request.deadline_ms == 0 || remaining >= 1000 }
    {
      True -> Ok(Nil)
      False -> Error(dispatch.NotStarted)
    },
  )
  let origin = config.now()
  let cancel = weft.cancel_signal()
  let started =
    actor.new_with_initialiser(1000, fn(subject) {
      Ok(
        actor.initialised(State(
          config,
          request,
          subject,
          origin,
          remaining,
          None,
          [],
          0,
          0,
          Open,
          Pending,
          cancel,
        ))
        |> actor.returning(subject),
      )
    })
    |> actor.on_message(handle)
    |> actor.unlinked
    |> actor.start
  case started {
    Error(_) -> {
      weft.cancel(cancel)
      Error(dispatch.NotStarted)
    }
    Ok(started) -> {
      let subject = started.data
      let cancel_reserved = config.cancel_reserved

      // From this point no error/refusal path exists. The established guarantor
      // owns all worker permits even if the broker immediately cancels the call.
      process.send(subject, Begin)
      Ok(
        dispatch.Execution(
          dispatch.execution_id(config.incarnation, request.seq),
          started.pid,
          fn() { process.send(subject, Cancel) },
          fn(bytes, eof) { feed(subject, bytes, eof) },
          fn() { process.send(subject, Release) },
          fn() {
            cancel_reserved(request)
            process.send(subject, Cancel)
            process.send(subject, Release)
          },
        ),
      )
    }
  }
}

fn feed(
  subject: process.Subject(Message),
  bytes: BitArray,
  eof: dispatch.Eof,
) -> Nil {
  let reply = process.new_subject()
  process.send(subject, Input(bytes, eof, reply))
  let _ = process.receive(reply, 1000)
  Nil
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Begin -> {
      let target = state.subject
      let run =
        weft.new([fn() { run_remote(state) }])
        |> weft.cancel_with(state.cancel)
        |> weft.cancel_when_exits(
          state.request.caller
          |> result_of_caller
          |> result.lazy_unwrap(process.self),
        )
      let _ = weft.start_relayed(run, to: sink(target))
      actor.continue(state)
    }
    Reserve(key, digest, route, reply) -> {
      process.send(reply, case state.settled {
        Pending -> Ok(Nil)
        Settled -> Error(Nil)
      })
      actor.continue(State(..state, reserved: Some(#(key, digest, route))))
    }
    Input(bytes, eof, reply) -> {
      let size = bit_array.byte_size(bytes)
      let next = case
        state.input_closed == Open
        && size <= 8192
        && state.input_count < 128
        && state.input_bytes + size <= 1_048_576
      {
        True ->
          State(
            ..state,
            inputs: list.append(state.inputs, [#(state.input_count, bytes, eof)]),
            input_count: state.input_count + 1,
            input_bytes: state.input_bytes + size,
            input_closed: case eof {
              dispatch.EndOfInput -> Closed
              dispatch.MoreInput -> Open
            },
          )
        False -> {
          process.send(state.subject, Cancel)
          state
        }
      }
      process.send(reply, Nil)
      actor.continue(next)
    }
    TakeInput(reply) ->
      case state.inputs {
        [] -> {
          process.send(reply, None)
          actor.continue(state)
        }
        [first, ..rest] -> {
          process.send(reply, Some(first))
          actor.continue(State(..state, inputs: rest))
        }
      }
    Cancel -> {
      state.config.cancel_reserved(state.request)
      case state.settled {
        Pending -> cancel_remote(state)
        Settled -> Nil
      }
      weft.cancel(state.cancel)
      actor.continue(settle(state, unknown()))
    }
    Done(outcome) -> {
      let terminal = case outcome {
        weft.PulledOutcome(weft.Completed(_, terminal)) -> terminal
        _ -> {
          state.config.cancel_reserved(state.request)
          cancel_remote(state)
          unknown()
        }
      }
      actor.continue(settle(state, terminal))
    }
    Release -> {
      weft.cancel(state.cancel)
      actor.stop()
    }
  }
}

// A selector-only adapter relays exactly one task outcome, without a cast queue.
fn sink(
  target: process.Subject(Message),
) -> process.Subject(weft.Pulled(dispatch.Terminal, Nil)) {
  // This pump is one leaf owned by the guarantor's linked run. It is bounded by
  // one outcome and exists because Subject has no typed contramap operation.
  let started =
    actor.new_with_initialiser(1000, fn(subject) {
      let input = process.new_subject()
      Ok(
        actor.initialised(target)
        |> actor.selecting(
          process.new_selector()
          |> process.select(subject)
          |> process.select_map(input, fn(value) { value }),
        )
        |> actor.returning(input),
      )
    })
    |> actor.on_message(fn(target, outcome) {
      process.send(target, Done(outcome))
      actor.stop()
    })
    |> actor.start
  case started {
    Ok(started) -> started.data
    Error(_) -> process.new_subject()
  }
}

fn result_of_caller(caller: Option(process.Pid)) -> Result(process.Pid, Nil) {
  case caller {
    Some(pid) -> Ok(pid)
    None -> Error(Nil)
  }
}

fn settle(state: State, terminal: dispatch.Terminal) -> State {
  case state.settled {
    Settled -> state
    Pending -> {
      state.request.settle(terminal)
      State(..state, settled: Settled)
    }
  }
}

fn cancel_remote(state: State) -> Nil {
  case state.reserved {
    Some(#(key, digest, route)) -> {
      let config = state.config
      config.uncertain(key, digest)
      let _ =
        weft.new([
          fn() {
            exchange_route(config.connection, route, wire.Cancel(key, digest))
          },
        ])
        |> weft.deadline(config.connection.within_ms)
        |> weft.start_detached
      Nil
    }
    None -> Nil
  }
}

fn run_remote(state: State) -> Result(dispatch.Terminal, Nil) {
  use reserved <- result.try(state.config.reserve(state.request))
  use digest <- result.try(
    wire.prepared_digest(reserved.prepared) |> result.map_error(fn(_) { Nil }),
  )
  let #(operation, _) = identity.key_fields(reserved.key)
  use Nil <- result.try(
    case
      identity.key_scope(reserved.key) == state.config.connection.scope
      && operation == ids.op_id_to_string(state.request.context.operation)
      && reserved.prepared.step == state.request.context.step
      && reserved.prepared.request == state.request.request
    {
      True -> Ok(Nil)
      False -> Error(Nil)
    },
  )
  let route = case reserved {
    Reserved(_, _) -> NativeRoute
    CommandReserved(_, _, ref) -> ServiceCommand(ref)
  }
  use Nil <- result.try(validate_route(state, reserved, digest, route))
  let reply = process.new_subject()
  process.send(state.subject, Reserve(reserved.key, digest, route, reply))
  use Nil <- result.try(
    process.receive(reply, 1000) |> result.unwrap(Error(Nil)),
  )
  let outcome = submit_and_wait(state, reserved, digest, route)
  case outcome {
    Ok(terminal) -> Ok(terminal)
    Error(Nil) -> {
      state.config.uncertain(reserved.key, digest)
      process.send(state.subject, Cancel)
      Ok(unknown())
    }
  }
}

import core/ids

fn submit_and_wait(
  state: State,
  reserved: Reserved,
  digest: identity.Digest,
  route: CommandRoute,
) -> Result(dispatch.Terminal, Nil) {
  let config = state.config
  use authorization <- result.try(case reserved.prepared.lifetime {
    wire.Session ->
      case state.remaining == 0 {
        True -> Ok(#(<<0:size(256)>>, 0))
        False -> Error(Nil)
      }
    wire.Finite(_) -> {
      use challenge <- result.try(
        exchange_route(
          config.connection,
          route,
          wire.ChallengeRequest(reserved.key, digest),
        )
        |> failed,
      )
      use nonce <- result.try(case challenge {
        wire.Challenge(key, original, nonce, 1000)
          if key == reserved.key && original == digest
        -> Ok(nonce)
        _ -> Error(Nil)
      })
      use budget <- result.try(
        service.attempt_budget(
          state.remaining - { config.now() - state.origin },
        )
        |> failed,
      )
      Ok(#(nonce, budget))
    }
  })

  // Any reply loss after this call is reconciled by Query under the original key.
  let _ =
    exchange_route(
      config.connection,
      route,
      wire.Submit(
        reserved.key,
        digest,
        reserved.prepared,
        authorization.0,
        authorization.1,
      ),
    )
  let within = case state.remaining {
    0 -> config.reconcile_ms
    _ ->
      int.min(
        config.reconcile_ms,
        state.remaining - { config.now() - state.origin },
      )
  }
  let result =
    poll.fold_until(
      within: int.max(1, within),
      every: poll.Fixed(20),
      clock: poll.monotonic(),
      from: #(0, []),
      attempt: fn(acc) { poll_remote(state, route, reserved.key, digest, acc) },
    )
  case result {
    poll.Answer(terminal) -> Ok(terminal)
    _ -> Error(Nil)
  }
}

fn poll_remote(
  state: State,
  route: CommandRoute,
  key: identity.RequestKey,
  digest: identity.Digest,
  acc: #(Int, List(BitArray)),
) -> poll.Pass(dispatch.Terminal, Nil, #(Int, List(BitArray))) {
  let config = state.config
  let input = process.new_subject()
  process.send(state.subject, TakeInput(input))
  let input_outcome = case process.receive(input, 1000) {
    Ok(Some(#(ordinal, bytes, eof))) -> {
      case
        exchange_route(
          config.connection,
          route,
          wire.Stdin(key, digest, ordinal, bytes, eof),
        )
      {
        Ok(wire.Evidence(original, content, _, _))
          if original == key && content == digest
        -> Ok(Nil)
        _ -> Error(Nil)
      }
    }
    Ok(None) -> Ok(Nil)
    Error(_) -> Error(Nil)
  }
  case input_outcome {
    Error(Nil) -> poll.Broken(Nil)
    Ok(Nil) -> poll_query(state, route, key, digest, acc)
  }
}

fn poll_query(
  state: State,
  route: CommandRoute,
  key: identity.RequestKey,
  digest: identity.Digest,
  acc: #(Int, List(BitArray)),
) -> poll.Pass(dispatch.Terminal, Nil, #(Int, List(BitArray))) {
  let #(cursor, outputs) = acc
  let config = state.config
  case
    exchange_route(config.connection, route, wire.Query(key, digest, cursor))
  {
    Ok(wire.Output(original, content, ordinal, bytes))
      if original == key && content == digest && ordinal == cursor
    -> {
      case native.decode_output(bytes) {
        Ok(chunk) -> {
          state.request.deliver(chunk)
          poll.Pending(#(cursor + 1, list.append(outputs, [bytes])))
        }
        Error(_) -> poll.Broken(Nil)
      }
    }
    Ok(wire.Terminal(original, content, bytes))
      if original == key && content == digest
    -> {
      let outcome = {
        use terminal <- result.try(native.decode_terminal(bytes) |> failed)
        use origin <- result.try(case state.request.context.origin {
          Some(origin) -> Ok(origin)
          None -> Error(Nil)
        })
        use Nil <- result.try(config.receive(
          origin,
          key,
          digest,
          outputs,
          bytes,
        ))
        use result_digest <- result.try(wire.digest(bytes) |> failed)
        let _ =
          exchange_route(
            config.connection,
            route,
            wire.DurableReceipt(key, digest, result_digest),
          )
        Ok(terminal)
      }
      case outcome {
        Ok(value) -> poll.Settled(value)
        Error(error) -> poll.Broken(error)
      }
    }
    Ok(wire.Rejected(1)) | Ok(wire.Rejected(2)) | Ok(wire.Rejected(3)) ->
      poll.Broken(Nil)
    _ -> poll.Pending(acc)
  }
}

// The guarantor and worker retain the same closed route, including detached Cancel.
fn exchange_route(
  config: connection.Config,
  route: CommandRoute,
  body: wire.Body,
) -> Result(wire.Body, connection.Error) {
  case route {
    NativeRoute -> connection.exchange(config, body)
    ServiceCommand(ref) -> connection.exchange_command(config, ref, body)
  }
}

fn validate_route(
  state: State,
  reserved: Reserved,
  digest: identity.Digest,
  route: CommandRoute,
) -> Result(Nil, Nil) {
  case route {
    NativeRoute -> Ok(Nil)
    ServiceCommand(ref) -> {
      use Nil <- result.try(
        case state.request.context.origin == Some(command.native_origin(ref)) {
          True -> Ok(Nil)
          False -> Error(Nil)
        },
      )
      let config = state.config.connection
      wire.command_envelope(
        ref,
        wire.Envelope(
          wire.Owner,
          config.owner,
          config.executor,
          config.generation,
          config.scope,
          wire.Submit(
            reserved.key,
            digest,
            reserved.prepared,
            <<0:size(256)>>,
            0,
          ),
        ),
      )
      |> result.map(fn(_) { Nil })
      |> failed
    }
  }
}

fn unknown() -> dispatch.Terminal {
  dispatch.Failed(exec.ExecutionLost(exec.RemoteOutcomeUncertain))
}

fn failed(value: Result(a, e)) -> Result(a, Nil) {
  result.map_error(value, fn(_) { Nil })
}
