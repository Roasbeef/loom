//// Closed execution errors within workspace completion evidence.
////
//// Each exact array retains the original error fields and discriminant.
//// Diagnostics remain bounded data; no runtime terms gain a wire encoding.

import broker/exec
import broker/framing
import core/corruption
import core/msgpack
import gleam/erlang/process
import gleam/otp/actor
import gleam/result
import tools/workspace_codec/value as v

/// Converts the closed msgpack.EncodeError shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn encode_error_value(value: msgpack.EncodeError) -> msgpack.MsgPackValue {
  case value {
    msgpack.IntegerOutOfRange(value) ->
      msgpack.ArrayValue([msgpack.IntValue(0), v.big_integer_value(value)])
    msgpack.UnencodableLength(length) ->
      msgpack.ArrayValue([msgpack.IntValue(1), v.big_integer_value(length)])
  }
}

/// Converts the closed msgpack.EncodeError shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_encode_error(
  value: msgpack.MsgPackValue,
) -> Result(msgpack.EncodeError, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), value]) -> {
      use value <- result.try(v.big_integer(value))
      Ok(msgpack.IntegerOutOfRange(value))
    }
    msgpack.ArrayValue([msgpack.IntValue(1), length]) -> {
      use length <- result.try(v.big_integer(length))
      Ok(msgpack.UnencodableLength(length))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed exec.SpawnError shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn spawn_error_value(value: exec.SpawnError) -> msgpack.MsgPackValue {
  case value {
    exec.PolicyUnencodable(error) ->
      msgpack.ArrayValue([msgpack.IntValue(0), encode_error_value(error)])
    exec.PolicyFileFailed -> msgpack.ArrayValue([msgpack.IntValue(1)])
    exec.PortOpenFailed -> msgpack.ArrayValue([msgpack.IntValue(2)])
    exec.ActorFailed(error) ->
      msgpack.ArrayValue([msgpack.IntValue(3), actor_error_value(error)])
    exec.HandshakeFailed(failure) ->
      msgpack.ArrayValue([msgpack.IntValue(4), failure_value(failure)])
  }
}

/// Converts the closed exec.SpawnError shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_spawn_error(
  value: msgpack.MsgPackValue,
) -> Result(exec.SpawnError, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), error]) -> {
      use error <- result.try(parse_encode_error(error))
      Ok(exec.PolicyUnencodable(error))
    }
    msgpack.ArrayValue([msgpack.IntValue(1)]) -> {
      Ok(exec.PolicyFileFailed)
    }
    msgpack.ArrayValue([msgpack.IntValue(2)]) -> {
      Ok(exec.PortOpenFailed)
    }

    msgpack.ArrayValue([msgpack.IntValue(3), error]) -> {
      use error <- result.try(parse_actor_error(error))
      Ok(exec.ActorFailed(error))
    }
    msgpack.ArrayValue([msgpack.IntValue(4), failure]) -> {
      use failure <- result.try(parse_failure(failure))
      Ok(exec.HandshakeFailed(failure))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed exec.CheckoutError shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn checkout_error_value(value: exec.CheckoutError) -> msgpack.MsgPackValue {
  case value {
    exec.AllBusy(size) ->
      msgpack.ArrayValue([msgpack.IntValue(0), msgpack.IntValue(size)])
    exec.SpawnFailed(error) ->
      msgpack.ArrayValue([msgpack.IntValue(1), spawn_error_value(error)])
    exec.PoolUnavailable -> msgpack.ArrayValue([msgpack.IntValue(2)])
  }
}

/// Converts the closed exec.CheckoutError shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_checkout_error(
  value: msgpack.MsgPackValue,
) -> Result(exec.CheckoutError, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), size]) -> {
      use size <- result.try(v.natural(size))
      Ok(exec.AllBusy(size))
    }
    msgpack.ArrayValue([msgpack.IntValue(1), error]) -> {
      use error <- result.try(parse_spawn_error(error))
      Ok(exec.SpawnFailed(error))
    }
    msgpack.ArrayValue([msgpack.IntValue(2)]) -> {
      Ok(exec.PoolUnavailable)
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed corruption.CorruptionReport shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn report_value(
  value: corruption.CorruptionReport,
) -> msgpack.MsgPackValue {
  case value {
    corruption.CorruptionReport(boundary, subject, expected, context) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        msgpack.StringValue(boundary),
        msgpack.StringValue(subject),
        msgpack.StringValue(expected),
        msgpack.StringValue(context),
      ])
  }
}

/// Converts the closed corruption.CorruptionReport shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_report(
  value: msgpack.MsgPackValue,
) -> Result(corruption.CorruptionReport, Nil) {
  case value {
    msgpack.ArrayValue([
      msgpack.IntValue(0),
      boundary,
      subject,
      expected,
      context,
    ]) -> {
      use boundary <- result.try(v.text(boundary))
      use subject <- result.try(v.text(subject))
      use expected <- result.try(v.text(expected))
      use context <- result.try(v.text(context))
      Ok(corruption.CorruptionReport(boundary, subject, expected, context))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed framing.Fault shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn fault_value(value: framing.Fault) -> msgpack.MsgPackValue {
  case value {
    framing.CorruptFrame(report) ->
      msgpack.ArrayValue([msgpack.IntValue(0), report_value(report)])
    framing.VersionMismatch(version) ->
      msgpack.ArrayValue([msgpack.IntValue(1), msgpack.IntValue(version)])
    framing.OversizedFrame(declared_bytes) ->
      msgpack.ArrayValue([msgpack.IntValue(2), msgpack.IntValue(declared_bytes)])
  }
}

/// Converts the closed framing.Fault shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_fault(value: msgpack.MsgPackValue) -> Result(framing.Fault, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), report]) -> {
      use report <- result.try(parse_report(report))
      Ok(framing.CorruptFrame(report))
    }
    msgpack.ArrayValue([msgpack.IntValue(1), version]) -> {
      use version <- result.try(v.natural(version))
      Ok(framing.VersionMismatch(version))
    }
    msgpack.ArrayValue([msgpack.IntValue(2), declared_bytes]) -> {
      use declared_bytes <- result.try(v.natural(declared_bytes))
      Ok(framing.OversizedFrame(declared_bytes))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed exec.ExecResult shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn exec_result_value(value: exec.ExecResult) -> msgpack.MsgPackValue {
  case value {
    exec.ExecResult(
      code,
      signal,
      stdout_bytes,
      stderr_bytes,
      stdout_truncated,
      stderr_truncated,
      enforcement,
      degraded,
      wall_ms,
      timed_out,
      cancelled,
    ) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        msgpack.IntValue(code),
        msgpack.IntValue(signal),
        msgpack.IntValue(stdout_bytes),
        msgpack.IntValue(stderr_bytes),
        msgpack.BoolValue(stdout_truncated),
        msgpack.BoolValue(stderr_truncated),
        fn(xs) { v.array(xs, msgpack.StringValue) }(enforcement),
        msgpack.BoolValue(degraded),
        msgpack.IntValue(wall_ms),
        msgpack.BoolValue(timed_out),
        msgpack.BoolValue(cancelled),
      ])
  }
}

/// Converts the closed exec.ExecResult shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_exec_result(
  value: msgpack.MsgPackValue,
) -> Result(exec.ExecResult, Nil) {
  case value {
    msgpack.ArrayValue([
      msgpack.IntValue(0),
      code,
      signal,
      stdout_bytes,
      stderr_bytes,
      stdout_truncated,
      stderr_truncated,
      enforcement,
      degraded,
      wall_ms,
      timed_out,
      cancelled,
    ]) -> {
      use code <- result.try(v.integer(code))
      use signal <- result.try(v.natural(signal))
      use stdout_bytes <- result.try(v.natural(stdout_bytes))
      use stderr_bytes <- result.try(v.natural(stderr_bytes))
      use stdout_truncated <- result.try(v.flag(stdout_truncated))
      use stderr_truncated <- result.try(v.flag(stderr_truncated))
      use enforcement <- result.try(fn(x) { v.inventory(x, 8192, v.text) }(
        enforcement,
      ))
      use degraded <- result.try(v.flag(degraded))
      use wall_ms <- result.try(v.natural(wall_ms))
      use timed_out <- result.try(v.flag(timed_out))
      use cancelled <- result.try(v.flag(cancelled))
      Ok(exec.ExecResult(
        code,
        signal,
        stdout_bytes,
        stderr_bytes,
        stdout_truncated,
        stderr_truncated,
        enforcement,
        degraded,
        wall_ms,
        timed_out,
        cancelled,
      ))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed exec.LossCause shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn loss_value(value: exec.LossCause) -> msgpack.MsgPackValue {
  case value {
    exec.HelperActorDown -> msgpack.ArrayValue([msgpack.IntValue(0)])
    exec.RelayDown -> msgpack.ArrayValue([msgpack.IntValue(1)])
    exec.ExecutorClosing -> msgpack.ArrayValue([msgpack.IntValue(2)])
    exec.RemoteOutcomeUncertain -> msgpack.ArrayValue([msgpack.IntValue(3)])
  }
}

/// Converts the closed exec.LossCause shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_loss(value: msgpack.MsgPackValue) -> Result(exec.LossCause, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0)]) -> {
      Ok(exec.HelperActorDown)
    }
    msgpack.ArrayValue([msgpack.IntValue(1)]) -> {
      Ok(exec.RelayDown)
    }
    msgpack.ArrayValue([msgpack.IntValue(2)]) -> {
      Ok(exec.ExecutorClosing)
    }
    msgpack.ArrayValue([msgpack.IntValue(3)]) -> {
      Ok(exec.RemoteOutcomeUncertain)
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed exec.ExecFailure shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn failure_value(value: exec.ExecFailure) -> msgpack.MsgPackValue {
  case value {
    exec.NotReady -> msgpack.ArrayValue([msgpack.IntValue(0)])
    exec.HandshakeTimeout -> msgpack.ArrayValue([msgpack.IntValue(1)])
    exec.HelperBusy -> msgpack.ArrayValue([msgpack.IntValue(2)])
    exec.DegradedHelper(features) ->
      msgpack.ArrayValue([
        msgpack.IntValue(3),
        fn(xs) { v.array(xs, msgpack.StringValue) }(features),
      ])
    exec.DegradedExecution(result) ->
      msgpack.ArrayValue([msgpack.IntValue(4), exec_result_value(result)])
    exec.RefusedByHelper(code, message) ->
      msgpack.ArrayValue([
        msgpack.IntValue(5),
        msgpack.StringValue(code),
        msgpack.StringValue(message),
      ])
    exec.ChannelFault(fault) ->
      msgpack.ArrayValue([msgpack.IntValue(6), fault_value(fault)])
    exec.ChannelClosed(status) ->
      msgpack.ArrayValue([msgpack.IntValue(7), msgpack.IntValue(status)])
    exec.ProtocolViolation(kind) ->
      msgpack.ArrayValue([msgpack.IntValue(8), msgpack.StringValue(kind)])
    exec.ProtocolVersionMismatch(helper, broker) ->
      msgpack.ArrayValue([
        msgpack.IntValue(9),
        msgpack.IntValue(helper),
        msgpack.IntValue(broker),
      ])
    exec.SendFailed -> msgpack.ArrayValue([msgpack.IntValue(10)])
    exec.CancelEscalated -> msgpack.ArrayValue([msgpack.IntValue(11)])
    exec.HeartbeatMissed -> msgpack.ArrayValue([msgpack.IntValue(12)])
    exec.HelperUnresponsive -> msgpack.ArrayValue([msgpack.IntValue(13)])
    exec.ExecutionLost(cause) ->
      msgpack.ArrayValue([msgpack.IntValue(14), loss_value(cause)])
  }
}

/// Converts the closed exec.ExecFailure shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_failure(
  value: msgpack.MsgPackValue,
) -> Result(exec.ExecFailure, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0)]) -> {
      Ok(exec.NotReady)
    }
    msgpack.ArrayValue([msgpack.IntValue(1)]) -> {
      Ok(exec.HandshakeTimeout)
    }
    msgpack.ArrayValue([msgpack.IntValue(2)]) -> {
      Ok(exec.HelperBusy)
    }
    msgpack.ArrayValue([msgpack.IntValue(3), features]) -> {
      use features <- result.try(fn(x) { v.inventory(x, 8192, v.text) }(
        features,
      ))
      Ok(exec.DegradedHelper(features))
    }
    msgpack.ArrayValue([msgpack.IntValue(4), result]) -> {
      use result <- result.try(parse_exec_result(result))
      Ok(exec.DegradedExecution(result))
    }
    msgpack.ArrayValue([msgpack.IntValue(5), code, message]) -> {
      use code <- result.try(v.text(code))
      use message <- result.try(v.diagnostic(message))
      Ok(exec.RefusedByHelper(code, message))
    }
    msgpack.ArrayValue([msgpack.IntValue(6), fault]) -> {
      use fault <- result.try(parse_fault(fault))
      Ok(exec.ChannelFault(fault))
    }
    msgpack.ArrayValue([msgpack.IntValue(7), status]) -> {
      use status <- result.try(v.integer(status))
      Ok(exec.ChannelClosed(status))
    }
    msgpack.ArrayValue([msgpack.IntValue(8), kind]) -> {
      use kind <- result.try(v.text(kind))
      Ok(exec.ProtocolViolation(kind))
    }
    msgpack.ArrayValue([msgpack.IntValue(9), helper, broker]) -> {
      use helper <- result.try(v.natural(helper))
      use broker <- result.try(v.natural(broker))
      Ok(exec.ProtocolVersionMismatch(helper, broker))
    }
    msgpack.ArrayValue([msgpack.IntValue(10)]) -> {
      Ok(exec.SendFailed)
    }
    msgpack.ArrayValue([msgpack.IntValue(11)]) -> {
      Ok(exec.CancelEscalated)
    }
    msgpack.ArrayValue([msgpack.IntValue(12)]) -> {
      Ok(exec.HeartbeatMissed)
    }
    msgpack.ArrayValue([msgpack.IntValue(13)]) -> {
      Ok(exec.HelperUnresponsive)
    }
    msgpack.ArrayValue([msgpack.IntValue(14), cause]) -> {
      use cause <- result.try(parse_loss(cause))
      Ok(exec.ExecutionLost(cause))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed actor.StartError shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn actor_error_value(value: actor.StartError) -> msgpack.MsgPackValue {
  case value {
    actor.InitTimeout -> msgpack.ArrayValue([msgpack.IntValue(0)])
    actor.InitFailed(reason) ->
      msgpack.ArrayValue([msgpack.IntValue(1), msgpack.StringValue(reason)])
    actor.InitExited(reason) ->
      msgpack.ArrayValue([msgpack.IntValue(2), exit_value(reason)])
  }
}

/// Converts the closed actor.StartError shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_actor_error(
  value: msgpack.MsgPackValue,
) -> Result(actor.StartError, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0)]) -> {
      Ok(actor.InitTimeout)
    }
    msgpack.ArrayValue([msgpack.IntValue(1), reason]) -> {
      use reason <- result.try(v.diagnostic(reason))
      Ok(actor.InitFailed(reason))
    }
    msgpack.ArrayValue([msgpack.IntValue(2), reason]) -> {
      use reason <- result.try(exit_reason(reason))
      Ok(actor.InitExited(reason))
    }
    _ -> Error(Nil)
  }
}

// Abnormal exits contain arbitrary runtime terms, which this boundary cannot carry.
fn exit_value(reason: process.ExitReason) -> msgpack.MsgPackValue {
  case reason {
    process.Normal -> msgpack.ArrayValue([msgpack.IntValue(0)])
    process.Killed -> msgpack.ArrayValue([msgpack.IntValue(1)])
    process.Abnormal(_) -> msgpack.NilValue
  }
}

fn exit_reason(value: msgpack.MsgPackValue) -> Result(process.ExitReason, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0)]) -> Ok(process.Normal)
    msgpack.ArrayValue([msgpack.IntValue(1)]) -> Ok(process.Killed)
    _ -> Error(Nil)
  }
}
