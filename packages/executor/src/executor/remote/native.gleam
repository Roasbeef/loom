//// Native custody adapter over the existing broker/executor service.
////
//// The configured service owns a scoped helper pool. There is no owner Broker
//// here and no second budget ledger. The remote service commits LaunchIntent
//// before starting this actor. Its native caller watch and the existing relay's
//// monotonic deadline remain live independently of TLS readers and writers.
//// Output persistence executes on the native relay, through a bounded ask;
//// this actor's cancellation channel never waits for a TLS send or a payload
//// commit. Raw and Compile settlement preserve helper reuse. Launch installs an
//// exact original pool observer before dispatch; its callback belongs to the
//// durable service row and survives this transient adapter's exit.
////
//// Terminal encoding is a closed array of native verdict fields, using the
//// existing broker framing for results/output and explicit failure variants.
//// Every originally observed native failure is retained, including corruption
//// reports; no Erlang term serialization or peer-supplied atom conversion exists.

import broker/dispatch
import broker/exec
import broker/executor as local
import broker/framing
import core/clock
import core/corruption
import core/ids
import core/msgpack as mp
import executor/remote/wire
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import weft
import weft/actor

/// A local control door, owned separately from any transport writer.
pub opaque type Running {
  /// The private bounded request/reply control actor.
  Running(subject: process.Subject(Message), pid: process.Pid)
}

type State {
  State(
    config: Config,
    subject: process.Subject(Message),
    execution: Option(dispatch.Execution),
    publisher: Publisher,
    disposition: Disposition,
  )
}

// The service row owns retirement persistence independently of this adapter.
// The pool retains its send-only callback before any Launch dispatch occurs.
type Disposition {
  Reuse
  RetireLaunch(notify: fn(Result(Nil, exec.RetirementFailure)) -> Nil)
}

/// Already-admitted exact request and persistence callbacks.
pub type Config {
  /// Callbacks run outside control actor; false publication never becomes success.
  Config(
    /// The scoped existing native service; it owns no owner approval ledger.
    service: local.Executor,
    /// The original durable operation owning this physical request.
    operation: ids.OpId,
    /// The exact command materialized beside the registered executor.
    prepared: wire.Prepared,
    /// A local native-service sequence, never the remote logical request ID.
    sequence: Int,
    /// The original frozen local monotonic deadline; zero requires Session.
    deadline_ms: Int,
    /// The injected local monotonic elapsed clock, shared with native watchdog.
    now: fn() -> Int,
    /// Starts linked persistence resources inside this native control actor.
    publisher: fn() -> Result(Publisher, Nil),
    /// Releases only the transient control slot, never native custody evidence.
    control_done: fn() -> Nil,
  )
}

/// Serialized publication callbacks whose resources belong to native control.
pub type Publisher {
  Publisher(
    /// Persists a bounded output chunk before returning success.
    output: fn(dispatch.Chunk) -> Result(Nil, Nil),
    /// Attempts final persistence before the native relay releases custody.
    terminal: fn(dispatch.Terminal) -> Nil,
  )
}

type Message {
  Begin
  Cancel(reply: process.Subject(Nil))
  Input(bytes: BitArray, eof: dispatch.Eof, reply: process.Subject(Nil))
  Settled
}

/// Parks a local control actor before its first native start.
/// The caller must already have committed the one live launch permission.
///
/// ## Examples
///
/// ```gleam
/// native.start(config) // -> Ok(running); cleanup stays independent of TLS.
/// ```
pub fn start(config: Config) -> Result(Running, Nil) {
  start_native(config, Reuse)
}

/// Installs the original exact helper observer before Launch dispatch.
/// Its send-only callback reaches the original service row even after adapter
/// settlement or loss. That row owns durable confirmation and bounded retry.
///
/// ## Examples
///
/// `start_launch(config, confirm_original)` keeps terminal and retirement separate.
pub fn start_launch(
  config: Config,
  notify: fn(Result(Nil, exec.RetirementFailure)) -> Nil,
) -> Result(Running, Nil) {
  start_native(config, RetireLaunch(notify))
}

fn start_native(
  config: Config,
  disposition: Disposition,
) -> Result(Running, Nil) {
  let builder =
    actor.new_with_initialiser(1000, fn(subject) {
      // Resource creation runs in this actor, so linked persistence children
      // cannot outlive a failed startup or a later native-control crash.
      use publisher <- result.try(
        config.publisher()
        |> result.replace_error("remote publication startup failed"),
      )
      let initialised =
        actor.initialised(State(config, subject, None, publisher, disposition))
        |> actor.returning(subject)
      Ok(case disposition {
        Reuse -> actor.continuing(initialised, Begin)
        RetireLaunch(_) -> initialised
      })
    })
    |> actor.on_message(handle)
    |> actor.unlinked
  builder
  |> actor.start
  |> result.map(fn(started) { Running(started.data, started.pid) })
  |> result.map_error(fn(_) { Nil })
}

/// Begins the parked original Launch after its service Row and monitor exist.
/// Weft startup kills its original child on a lost startup acknowledgement; the
/// parked adapter has no helper borrow or dispatch effect before this door.
///
/// ## Examples
///
/// `begin_launch(running)` follows installation in the serialized service loop.
@internal
pub fn begin_launch(running: Running) -> Nil {
  process.send(running.subject, Begin)
}

/// Projects the original adapter identity for its service-row monitor.
/// The monitor observes control termination independently of retirement proof.
///
/// ## Examples
///
/// `process.monitor(native.pid(running))` retains the original control identity.
@internal
pub fn pid(running: Running) -> process.Pid {
  running.pid
}

/// Cancels through local native control with no network-writer dependency.
///
/// ## Examples
///
/// ```gleam
/// native.cancel(running)
/// ```
pub fn cancel(running: Running) -> Nil {
  ask(running, Cancel)
}

/// Sends an already quota-checked stdin item through the local control lane.
///
/// ## Examples
///
/// ```gleam
/// native.stdin(running, bytes, dispatch.EndOfInput)
/// ```
pub fn stdin(
  running: Running,
  bytes: BitArray,
  eof: dispatch.Eof,
) -> Result(Nil, Nil) {
  let subject = running.subject

  // The bounded task owns its reply subject. A late control ACK dies with that
  // task instead of entering the caller service actor's unrelated mailbox.
  case
    weft.new([
      fn() {
        let reply = process.new_subject()
        process.send(subject, Input(bytes, eof, reply))
        process.receive(reply, 1000) |> result.map_error(fn(_) { Nil })
      },
    ])
    |> weft.deadline(1000)
    |> weft.start
  {
    [weft.Completed(_, Nil)] -> Ok(Nil)
    _ -> Error(Nil)
  }
}

fn ask(running: Running, make: fn(process.Subject(Nil)) -> Message) -> Nil {
  let reply = process.new_subject()
  process.send(running.subject, make(reply))
  let _ = process.receive(reply, 1000)
  Nil
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Begin ->
      case state.execution {
        Some(_) -> actor.continue(state)
        None -> begin_native(state)
      }
    Cancel(reply) -> {
      case state.execution {
        Some(execution) -> execution.cancel()
        None -> Nil
      }
      process.send(reply, Nil)
      actor.continue(state)
    }
    Input(bytes, eof, reply) -> {
      case state.execution {
        Some(execution) -> execution.stdin(bytes, eof)
        None -> Nil
      }
      process.send(reply, Nil)
      actor.continue(state)
    }
    Settled -> {
      case state.execution {
        Some(execution) -> execution.release()
        None -> Nil
      }
      state.config.control_done()
      actor.stop()
    }
  }
}

// The original startup door is consumed once; settlement owns subsequent exit.
fn begin_native(state: State) -> actor.Next(State, Message) {
  let config = state.config
  let self = process.self()
  let subject = state.subject
  let output = state.publisher.output
  let terminal_callback = state.publisher.terminal

  // Settlement crosses back only after terminal persistence returns. The
  // relay may block there; native cancel is a separate local service ask.
  let request =
    dispatch.Dispatch(
      system_reservation: None,
      context: dispatch.CallContext(
        config.operation,
        config.prepared.step,
        None,
      ),
      request: config.prepared.request,
      seq: config.sequence,
      deadline_ms: config.deadline_ms,
      clock: clock.from_function(config.now),
      caller: Some(self),
      deliver: fn(chunk) {
        case output(chunk) {
          Ok(Nil) -> Nil
          Error(Nil) -> process.send(subject, Cancel(process.new_subject()))
        }
      },
      settle: fn(terminal) {
        terminal_callback(terminal)
        process.send(subject, Settled)
      },
    )
  let dispatcher = case state.disposition {
    Reuse -> local.dispatcher_with_native_deadline(config.service)
    RetireLaunch(notify) ->
      local.dispatcher_retiring_with_native_deadline(
        config.service,
        fn(_id, outcome) { notify(outcome) },
      )
  }
  case dispatcher.start(request) {
    Ok(execution) -> {
      actor.continue(State(..state, execution: Some(execution)))
    }
    Error(_) -> {
      terminal_callback(
        dispatch.Failed(exec.ExecutionLost(exec.ExecutorClosing)),
      )
      config.control_done()
      actor.stop()
    }
  }
}

/// Encodes one exact output item under the remote 16 KiB item ceiling.
///
/// ## Examples
///
/// ```gleam
/// native.encode_output(chunk)
/// ```
pub fn encode_output(chunk: dispatch.Chunk) -> Result(BitArray, wire.Error) {
  use bytes <- result.try(
    framing.encode_payload(framing.Frame(
      0,
      framing.ExecOut(
        chunk.stream,
        chunk.data,
        chunk.total_bytes,
        chunk.truncated,
      ),
    ))
    |> result.map_error(fn(_) { wire.Invalid }),
  )
  case bit_array.byte_size(bytes) <= 16_384 {
    True -> Ok(bytes)
    False -> Error(wire.Invalid)
  }
}

/// Decodes output without accepting other native helper frame variants.
///
/// ## Examples
///
/// ```gleam
/// native.decode_output(bytes)
/// ```
pub fn decode_output(bytes: BitArray) -> Result(dispatch.Chunk, wire.Error) {
  use _ <- result.try(wire.decode_value(bytes))
  use frame <- result.try(
    framing.decode_payload(bytes) |> result.map_error(fn(_) { wire.Invalid }),
  )
  case frame {
    framing.Frame(0, framing.ExecOut(stream, data, total, truncated)) ->
      Ok(dispatch.Chunk(stream, data, total, truncated))
    _ -> Error(wire.Invalid)
  }
}

/// Encodes exact terminal result or failure as bounded declarative bytes.
///
/// ## Examples
///
/// ```gleam
/// native.encode_terminal(terminal)
/// ```
pub fn encode_terminal(
  terminal: dispatch.Terminal,
) -> Result(BitArray, wire.Error) {
  use value <- result.try(case terminal {
    dispatch.Completed(result) ->
      result_value(result)
      |> result.map(fn(value) { mp.ArrayValue([mp.IntValue(0), value]) })
    dispatch.Failed(failure) ->
      failure_value(failure)
      |> result.map(fn(value) { mp.ArrayValue([mp.IntValue(1), value]) })
  })
  use bytes <- result.try(wire.encode_value(value))
  case bit_array.byte_size(bytes) <= 32_768 {
    True -> Ok(bytes)
    False -> Error(wire.Invalid)
  }
}

/// Recovers the original terminal verdict through a total closed decoder.
///
/// ## Examples
///
/// ```gleam
/// native.decode_terminal(bytes)
/// ```
pub fn decode_terminal(
  bytes: BitArray,
) -> Result(dispatch.Terminal, wire.Error) {
  use value <- result.try(wire.decode_value(bytes))
  case value {
    mp.ArrayValue([mp.IntValue(0), value]) ->
      decode_result(value) |> result.map(dispatch.Completed)
    mp.ArrayValue([mp.IntValue(1), value]) ->
      decode_failure(value) |> result.map(dispatch.Failed)
    _ -> Error(wire.Invalid)
  }
}

fn result_value(
  result: exec.ExecResult,
) -> Result(mp.MsgPackValue, wire.Error) {
  framing.encode_payload(framing.Frame(
    0,
    framing.ExecExit(
      result.code,
      result.signal,
      result.stdout_bytes,
      result.stderr_bytes,
      result.stdout_truncated,
      result.stderr_truncated,
      result.enforcement,
      result.degraded,
      result.wall_ms,
      result.timed_out,
      result.cancelled,
    ),
  ))
  |> result.map(mp.BinaryValue)
  |> result.map_error(fn(_) { wire.Invalid })
}

fn decode_result(
  value: mp.MsgPackValue,
) -> Result(exec.ExecResult, wire.Error) {
  case value {
    mp.BinaryValue(bytes) -> {
      use _ <- result.try(wire.decode_value(bytes))
      use frame <- result.try(
        framing.decode_payload(bytes)
        |> result.map_error(fn(_) { wire.Invalid }),
      )
      case frame {
        framing.Frame(
          0,
          framing.ExecExit(
            code,
            signal,
            stdout,
            stderr,
            out_truncated,
            err_truncated,
            enforcement,
            degraded,
            wall,
            timed_out,
            cancelled,
          ),
        ) ->
          Ok(exec.ExecResult(
            code,
            signal,
            stdout,
            stderr,
            out_truncated,
            err_truncated,
            enforcement,
            degraded,
            wall,
            timed_out,
            cancelled,
          ))
        _ -> Error(wire.Invalid)
      }
    }
    _ -> Error(wire.Invalid)
  }
}

fn failure_value(
  failure: exec.ExecFailure,
) -> Result(mp.MsgPackValue, wire.Error) {
  case failure {
    exec.NotReady -> Ok(mp.ArrayValue([mp.IntValue(0)]))
    exec.HandshakeTimeout -> Ok(mp.ArrayValue([mp.IntValue(1)]))
    exec.HelperBusy -> Ok(mp.ArrayValue([mp.IntValue(2)]))
    exec.SendFailed -> Ok(mp.ArrayValue([mp.IntValue(3)]))
    exec.CancelEscalated -> Ok(mp.ArrayValue([mp.IntValue(4)]))
    exec.HeartbeatMissed -> Ok(mp.ArrayValue([mp.IntValue(5)]))
    exec.HelperUnresponsive -> Ok(mp.ArrayValue([mp.IntValue(6)]))
    exec.DegradedHelper(features) ->
      Ok(
        mp.ArrayValue([
          mp.IntValue(7),
          mp.ArrayValue(list.map(features, mp.StringValue)),
        ]),
      )
    exec.DegradedExecution(result) -> {
      use value <- result.try(result_value(result))
      Ok(mp.ArrayValue([mp.IntValue(8), value]))
    }
    exec.RefusedByHelper(code, message) ->
      Ok(
        mp.ArrayValue([
          mp.IntValue(9),
          mp.StringValue(code),
          mp.StringValue(message),
        ]),
      )
    exec.ChannelClosed(status) ->
      Ok(mp.ArrayValue([mp.IntValue(10), mp.IntValue(status)]))
    exec.ProtocolViolation(kind) ->
      Ok(mp.ArrayValue([mp.IntValue(11), mp.StringValue(kind)]))
    exec.ProtocolVersionMismatch(helper, broker) ->
      Ok(
        mp.ArrayValue([
          mp.IntValue(12),
          mp.IntValue(helper),
          mp.IntValue(broker),
        ]),
      )
    exec.ExecutionLost(cause) ->
      Ok(
        mp.ArrayValue([
          mp.IntValue(13),
          mp.IntValue(case cause {
            exec.HelperActorDown -> 0
            exec.RelayDown -> 1
            exec.ExecutorClosing -> 2
            exec.RemoteOutcomeUncertain -> 3
          }),
        ]),
      )
    exec.ChannelFault(fault) ->
      Ok(
        mp.ArrayValue([
          mp.IntValue(14),
          case fault {
            framing.VersionMismatch(version) ->
              mp.ArrayValue([mp.IntValue(0), mp.IntValue(version)])
            framing.OversizedFrame(bytes) ->
              mp.ArrayValue([mp.IntValue(1), mp.IntValue(bytes)])
            framing.CorruptFrame(report) ->
              mp.ArrayValue([
                mp.IntValue(2),
                mp.StringValue(report.boundary),
                mp.StringValue(report.subject),
                mp.StringValue(report.expected),
                mp.StringValue(report.context),
              ])
          },
        ]),
      )
  }
}

fn decode_failure(
  value: mp.MsgPackValue,
) -> Result(exec.ExecFailure, wire.Error) {
  case value {
    mp.ArrayValue([mp.IntValue(0)]) -> Ok(exec.NotReady)
    mp.ArrayValue([mp.IntValue(1)]) -> Ok(exec.HandshakeTimeout)
    mp.ArrayValue([mp.IntValue(2)]) -> Ok(exec.HelperBusy)
    mp.ArrayValue([mp.IntValue(3)]) -> Ok(exec.SendFailed)
    mp.ArrayValue([mp.IntValue(4)]) -> Ok(exec.CancelEscalated)
    mp.ArrayValue([mp.IntValue(5)]) -> Ok(exec.HeartbeatMissed)
    mp.ArrayValue([mp.IntValue(6)]) -> Ok(exec.HelperUnresponsive)
    mp.ArrayValue([mp.IntValue(7), mp.ArrayValue(features)]) -> {
      use features <- result.try(
        list.try_map(features, fn(value) {
          case value {
            mp.StringValue(text) -> Ok(text)
            _ -> Error(wire.Invalid)
          }
        }),
      )
      Ok(exec.DegradedHelper(features))
    }
    mp.ArrayValue([mp.IntValue(8), result]) ->
      decode_result(result) |> result.map(exec.DegradedExecution)
    mp.ArrayValue([
      mp.IntValue(9),
      mp.StringValue(code),
      mp.StringValue(message),
    ]) -> Ok(exec.RefusedByHelper(code, message))
    mp.ArrayValue([mp.IntValue(10), mp.IntValue(status)]) ->
      Ok(exec.ChannelClosed(status))
    mp.ArrayValue([mp.IntValue(11), mp.StringValue(kind)]) ->
      Ok(exec.ProtocolViolation(kind))
    mp.ArrayValue([mp.IntValue(12), mp.IntValue(helper), mp.IntValue(broker)]) ->
      Ok(exec.ProtocolVersionMismatch(helper, broker))
    mp.ArrayValue([mp.IntValue(13), mp.IntValue(0)]) ->
      Ok(exec.ExecutionLost(exec.HelperActorDown))
    mp.ArrayValue([mp.IntValue(13), mp.IntValue(1)]) ->
      Ok(exec.ExecutionLost(exec.RelayDown))
    mp.ArrayValue([mp.IntValue(13), mp.IntValue(2)]) ->
      Ok(exec.ExecutionLost(exec.ExecutorClosing))
    mp.ArrayValue([mp.IntValue(13), mp.IntValue(3)]) ->
      Ok(exec.ExecutionLost(exec.RemoteOutcomeUncertain))
    mp.ArrayValue([
      mp.IntValue(14),
      mp.ArrayValue([mp.IntValue(0), mp.IntValue(version)]),
    ]) -> Ok(exec.ChannelFault(framing.VersionMismatch(version)))
    mp.ArrayValue([
      mp.IntValue(14),
      mp.ArrayValue([mp.IntValue(1), mp.IntValue(bytes)]),
    ]) -> Ok(exec.ChannelFault(framing.OversizedFrame(bytes)))
    mp.ArrayValue([
      mp.IntValue(14),
      mp.ArrayValue([
        mp.IntValue(2),
        mp.StringValue(boundary),
        mp.StringValue(subject),
        mp.StringValue(expected),
        mp.StringValue(context),
      ]),
    ]) ->
      Ok(
        exec.ChannelFault(
          framing.CorruptFrame(corruption.CorruptionReport(
            boundary,
            subject,
            expected,
            context,
          )),
        ),
      )
    _ -> Error(wire.Invalid)
  }
}
