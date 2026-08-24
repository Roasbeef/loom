//// The effect-plane wire protocol from the implementation spec, Part 1.4
//// (frozen), broker side:
////
//// ```
//// frame    := u32_be length ++ msgpack(map)
//// map keys := "v":1, "id":u64, "kind":str, "body":map
//// kinds    : hello, exec_start, exec_stdin, exec_out, exec_exit,
////            cap_call, cap_result, cancel, heartbeat, error
//// ```
////
//// Every inbound frame is parsed and validated as data (two-channel
//// doctrine, design §5.6). Decoding is total: a malformed frame is a
//// value describing the fault — the caller closes the channel and settles
//// the effect in-band per spec §3.3 invariant 6 — never a crash. An
//// unknown but well-formed kind is reported separately so the caller can
//// answer with an in-band `error` frame and keep the channel (forward
//// compatibility, mirroring the helper).
////
//// The incremental `Deframer` is pure: bytes in, frames out, remainder
//// carried. Frame boundaries never depend on how the transport chunks
//// its reads.

import broker/policy.{type Limits, type SandboxPolicy}
import core/corruption.{type CorruptionReport}
import core/msgpack.{type MsgPackValue}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// The protocol version spoken in frame envelopes and hellos.
pub const protocol_version = 1

/// The cap on a frame's msgpack payload, mirroring the Go helper's
/// 16 MiB `MaxFrameLen`: a corrupt or hostile length prefix must not
/// make the broker allocate gigabytes.
pub const max_frame_bytes = 16_777_216

/// One protocol frame: the envelope id plus a typed body. `id`
/// correlates request and response — `exec_out`/`exec_exit` reuse their
/// `exec_start`'s id, heartbeat echoes reuse the heartbeat's. Invariant:
/// `0 <= id < 2^64` (a u64 on the wire).
pub type Frame {
  Frame(id: Int, body: Body)
}

/// Which output stream an `exec_out` chunk belongs to.
pub type OutputStream {
  Stdout
  Stderr
}

/// The typed body of each frame kind. Field vocabulary matches the Go
/// helper's structs byte for byte on the wire.
pub type Body {
  /// The handshake: the helper sends its hello first; the broker must
  /// answer with its own before any other frame.
  Hello(proto: Int, peer: String, features: List(String))
  /// Starts an execution. `policy` overrides the helper's fd-3 base
  /// policy for this execution when present; `limits` is reserved for
  /// per-exec overrides (the helper accepts and ignores it today).
  /// Invariant: `argv` non-empty, `token` non-empty.
  ExecStart(
    argv: List(String),
    env: List(#(String, String)),
    cwd: String,
    policy: Option(SandboxPolicy),
    token: BitArray,
    limits: Option(Limits),
  )
  /// A chunk of stdin for the running execution; `eof: True` closes the
  /// child's stdin after `data` is written. Writes after eof are
  /// refused by the helper.
  ExecStdin(data: BitArray, eof: Bool)
  /// One chunk of child output. `bytes` is the cumulative per-stream
  /// count including this chunk; `truncated` marks the single final
  /// chunk emitted when the per-stream `output_bytes` cap is hit.
  ExecOut(stream: OutputStream, data: BitArray, bytes: Int, truncated: Bool)
  /// The completed execution. `enforcement` lists what was actually
  /// applied (e.g. "bwrap", "landlock:abi=5", "skip:landlock: ...") —
  /// ground truth, checked over hello features. `signal` is 0 on a
  /// normal exit.
  ExecExit(
    code: Int,
    signal: Int,
    stdout_bytes: Int,
    stderr_bytes: Int,
    stdout_truncated: Bool,
    stderr_truncated: Bool,
    enforcement: List(String),
    degraded: Bool,
    wall_ms: Int,
    timed_out: Bool,
  )
  /// A capability RPC from a satellite: `{token, cap, args,
  /// deadline_ms}`. The broker checks the token on every call.
  CapCall(token: BitArray, cap: String, args: MsgPackValue, deadline_ms: Int)
  /// The answer to a `cap_call`.
  CapResult(outcome: CapOutcome, usage: Option(MsgPackValue))
  /// Cancels the running execution. Idempotent; the receiver must kill
  /// its pgroup within 2s or the broker escalates to SIGKILL of the
  /// whole helper.
  Cancel
  /// A liveness probe; the receiver echoes it with the same id.
  Heartbeat
  /// An in-band protocol-level error correlated to the offending
  /// frame's id (0 when there is none).
  ErrorBody(code: String, message: String)
}

/// The outcome half of a `cap_result` body.
pub type CapOutcome {
  /// The capability call succeeded with this value.
  CapOk(value: MsgPackValue)
  /// The capability call failed in-band.
  CapErr(code: String, message: String)
}

/// Why an inbound frame could not be accepted. `Malformed` and
/// `UnsupportedVersion` require closing the channel (spec §3.3.6);
/// `UnknownKind` is answered in-band and the channel stays open.
pub type FrameError {
  /// The bytes were not a well-formed frame of this protocol.
  Malformed(report: CorruptionReport)
  /// The envelope carried a version other than `protocol_version`.
  UnsupportedVersion(version: Int)
  /// A well-formed frame of a kind this broker does not know.
  UnknownKind(id: Int, kind: String)
}

// --- encoding -----------------------------------------------------------

/// Encodes a frame to its wire bytes, including the u32_be length
/// prefix.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(<<_length:size(32), _payload:bytes>>) =
///   framing.encode(framing.Frame(id: 1, body: framing.Heartbeat))
/// ```
///
pub fn encode(frame: Frame) -> Result(BitArray, msgpack.EncodeError) {
  use payload <- result.try(encode_payload(frame))
  let size = bit_array.byte_size(payload)
  case size > max_frame_bytes {
    True -> Error(msgpack.UnencodableLength(length: size))
    False -> Ok(<<size:size(32), payload:bits>>)
  }
}

/// Encodes a frame's msgpack payload without the length prefix. Kept
/// public for golden-fixture tests; `encode` is the wire form.
pub fn encode_payload(frame: Frame) -> Result(BitArray, msgpack.EncodeError) {
  case frame.id < 0 {
    True -> Error(msgpack.IntegerOutOfRange(value: frame.id))
    False ->
      msgpack.encode(
        msgpack.MapValue([
          #(msgpack.StringValue("v"), msgpack.IntValue(protocol_version)),
          #(msgpack.StringValue("id"), msgpack.IntValue(frame.id)),
          #(
            msgpack.StringValue("kind"),
            msgpack.StringValue(kind_name(frame.body)),
          ),
          #(msgpack.StringValue("body"), body_to_msgpack(frame.body)),
        ]),
      )
  }
}

fn kind_name(body: Body) -> String {
  case body {
    Hello(..) -> "hello"
    ExecStart(..) -> "exec_start"
    ExecStdin(..) -> "exec_stdin"
    ExecOut(..) -> "exec_out"
    ExecExit(..) -> "exec_exit"
    CapCall(..) -> "cap_call"
    CapResult(..) -> "cap_result"
    Cancel -> "cancel"
    Heartbeat -> "heartbeat"
    ErrorBody(..) -> "error"
  }
}

fn body_to_msgpack(body: Body) -> MsgPackValue {
  case body {
    Hello(proto:, peer:, features:) ->
      msgpack.MapValue([
        #(msgpack.StringValue("proto"), msgpack.IntValue(proto)),
        #(msgpack.StringValue("peer"), msgpack.StringValue(peer)),
        #(msgpack.StringValue("features"), string_array(features)),
      ])
    ExecStart(argv:, env:, cwd:, policy: exec_policy, token:, limits:) -> {
      let base = [
        #(msgpack.StringValue("argv"), string_array(argv)),
        #(
          msgpack.StringValue("env"),
          msgpack.MapValue(
            list.map(env, fn(pair) {
              #(msgpack.StringValue(pair.0), msgpack.StringValue(pair.1))
            }),
          ),
        ),
        #(msgpack.StringValue("cwd"), msgpack.StringValue(cwd)),
        #(msgpack.StringValue("token"), msgpack.BinaryValue(token)),
      ]
      let with_policy = case exec_policy {
        None -> base
        Some(value) ->
          list.append(base, [
            #(msgpack.StringValue("policy"), policy.to_msgpack(value)),
          ])
      }
      case limits {
        None -> msgpack.MapValue(with_policy)
        Some(value) ->
          msgpack.MapValue(
            list.append(with_policy, [
              #(msgpack.StringValue("limits"), limits_to_msgpack(value)),
            ]),
          )
      }
    }
    ExecStdin(data:, eof:) ->
      msgpack.MapValue([
        #(msgpack.StringValue("data"), msgpack.BinaryValue(data)),
        #(msgpack.StringValue("eof"), msgpack.BoolValue(eof)),
      ])
    ExecOut(stream:, data:, bytes:, truncated:) ->
      msgpack.MapValue([
        #(
          msgpack.StringValue("stream"),
          msgpack.StringValue(stream_name(stream)),
        ),
        #(msgpack.StringValue("data"), msgpack.BinaryValue(data)),
        #(msgpack.StringValue("bytes"), msgpack.IntValue(bytes)),
        #(msgpack.StringValue("truncated"), msgpack.BoolValue(truncated)),
      ])
    ExecExit(
      code:,
      signal:,
      stdout_bytes:,
      stderr_bytes:,
      stdout_truncated:,
      stderr_truncated:,
      enforcement:,
      degraded:,
      wall_ms:,
      timed_out:,
    ) ->
      msgpack.MapValue([
        #(msgpack.StringValue("code"), msgpack.IntValue(code)),
        #(msgpack.StringValue("signal"), msgpack.IntValue(signal)),
        #(msgpack.StringValue("stdout_bytes"), msgpack.IntValue(stdout_bytes)),
        #(msgpack.StringValue("stderr_bytes"), msgpack.IntValue(stderr_bytes)),
        #(
          msgpack.StringValue("stdout_truncated"),
          msgpack.BoolValue(stdout_truncated),
        ),
        #(
          msgpack.StringValue("stderr_truncated"),
          msgpack.BoolValue(stderr_truncated),
        ),
        #(msgpack.StringValue("enforcement"), string_array(enforcement)),
        #(msgpack.StringValue("degraded"), msgpack.BoolValue(degraded)),
        #(msgpack.StringValue("wall_ms"), msgpack.IntValue(wall_ms)),
        #(msgpack.StringValue("timed_out"), msgpack.BoolValue(timed_out)),
      ])
    CapCall(token:, cap:, args:, deadline_ms:) ->
      msgpack.MapValue([
        #(msgpack.StringValue("token"), msgpack.BinaryValue(token)),
        #(msgpack.StringValue("cap"), msgpack.StringValue(cap)),
        #(msgpack.StringValue("args"), args),
        #(msgpack.StringValue("deadline_ms"), msgpack.IntValue(deadline_ms)),
      ])
    CapResult(outcome:, usage:) -> {
      let base = case outcome {
        CapOk(value:) -> [
          #(msgpack.StringValue("ok"), msgpack.BoolValue(True)),
          #(msgpack.StringValue("value"), value),
        ]
        CapErr(code:, message:) -> [
          #(msgpack.StringValue("ok"), msgpack.BoolValue(False)),
          #(
            msgpack.StringValue("error"),
            msgpack.MapValue([
              #(msgpack.StringValue("code"), msgpack.StringValue(code)),
              #(msgpack.StringValue("msg"), msgpack.StringValue(message)),
            ]),
          ),
        ]
      }
      case usage {
        None -> msgpack.MapValue(base)
        Some(value) ->
          msgpack.MapValue(
            list.append(base, [#(msgpack.StringValue("usage"), value)]),
          )
      }
    }
    Cancel -> msgpack.MapValue([])
    Heartbeat -> msgpack.MapValue([])
    ErrorBody(code:, message:) ->
      msgpack.MapValue([
        #(msgpack.StringValue("code"), msgpack.StringValue(code)),
        #(msgpack.StringValue("msg"), msgpack.StringValue(message)),
      ])
  }
}

fn limits_to_msgpack(limits: Limits) -> MsgPackValue {
  msgpack.MapValue([
    #(msgpack.StringValue("cpu_s"), msgpack.IntValue(limits.cpu_s)),
    #(msgpack.StringValue("fsize_bytes"), msgpack.IntValue(limits.fsize_bytes)),
    #(msgpack.StringValue("mem_bytes"), msgpack.IntValue(limits.mem_bytes)),
    #(
      msgpack.StringValue("output_bytes"),
      msgpack.IntValue(limits.output_bytes),
    ),
    #(msgpack.StringValue("pids"), msgpack.IntValue(limits.pids)),
    #(msgpack.StringValue("wall_s"), msgpack.IntValue(limits.wall_s)),
  ])
}

fn stream_name(stream: OutputStream) -> String {
  case stream {
    Stdout -> "stdout"
    Stderr -> "stderr"
  }
}

fn string_array(items: List(String)) -> MsgPackValue {
  msgpack.ArrayValue(list.map(items, msgpack.StringValue))
}

// --- decoding -----------------------------------------------------------

/// Decodes one frame's msgpack payload (without the length prefix),
/// totally and strictly: the envelope must carry exactly `v`, `id`,
/// `kind`, and `body`, the version must match, and each known kind's
/// body must carry exactly its required keys with the right types.
///
/// ## Examples
///
/// ```gleam
/// let frame = framing.Frame(id: 7, body: framing.Heartbeat)
/// let assert Ok(payload) = framing.encode_payload(frame)
/// assert framing.decode_payload(payload) == Ok(frame)
/// ```
///
pub fn decode_payload(payload: BitArray) -> Result(Frame, FrameError) {
  use value <- result.try(
    msgpack.decode(payload) |> result.map_error(Malformed),
  )
  use entries <- result.try(envelope_map(value))
  use Nil <- result.try(check_keys(entries, ["v", "id", "kind", "body"]))
  use v <- result.try(envelope_int(entries, "v"))
  use Nil <- result.try(case v == protocol_version {
    True -> Ok(Nil)
    False -> Error(UnsupportedVersion(version: v))
  })
  use id <- result.try(envelope_int(entries, "id"))
  use Nil <- result.try(case id >= 0 {
    True -> Ok(Nil)
    False -> Error(malformed("id", "a u64", int.to_string(id)))
  })
  use kind <- result.try(envelope_string(entries, "kind"))
  use body_value <- result.try(envelope_field(entries, "body"))
  use body <- result.try(decode_body(id, kind, body_value))
  Ok(Frame(id:, body:))
}

fn decode_body(
  id: Int,
  kind: String,
  value: MsgPackValue,
) -> Result(Body, FrameError) {
  use entries <- result.try(body_map(kind, value))
  case kind {
    "hello" -> decode_hello(entries)
    "exec_start" -> decode_exec_start(entries)
    "exec_stdin" -> decode_exec_stdin(entries)
    "exec_out" -> decode_exec_out(entries)
    "exec_exit" -> decode_exec_exit(entries)
    "cap_call" -> decode_cap_call(entries)
    "cap_result" -> decode_cap_result(entries)
    "cancel" -> Ok(Cancel)
    "heartbeat" -> Ok(Heartbeat)
    "error" -> decode_error_body(entries)
    _ -> Error(UnknownKind(id:, kind:))
  }
}

fn decode_hello(entries: Entries) -> Result(Body, FrameError) {
  use Nil <- result.try(check_keys(entries, ["proto", "peer", "features"]))
  use proto <- result.try(body_int(entries, "hello", "proto"))
  use peer <- result.try(body_string(entries, "hello", "peer"))
  use features <- result.try(body_strings(entries, "hello", "features"))
  Ok(Hello(proto:, peer:, features:))
}

fn decode_exec_start(entries: Entries) -> Result(Body, FrameError) {
  use Nil <- result.try(
    check_keys(entries, ["argv", "env", "cwd", "token", "policy", "limits"]),
  )
  use argv <- result.try(body_strings(entries, "exec_start", "argv"))
  use env_value <- result.try(body_field(entries, "exec_start", "env"))
  use env <- result.try(decode_env(env_value))
  use cwd <- result.try(body_string(entries, "exec_start", "cwd"))
  use token <- result.try(body_binary(entries, "exec_start", "token"))
  use exec_policy <- result.try(case find(entries, "policy") {
    Error(Nil) -> Ok(None)
    Ok(msgpack.NilValue) -> Ok(None)
    Ok(value) ->
      policy.from_msgpack(value)
      |> result.map(Some)
      |> result.map_error(Malformed)
  })
  use limits <- result.try(case find(entries, "limits") {
    Error(Nil) -> Ok(None)
    Ok(msgpack.NilValue) -> Ok(None)
    Ok(value) -> decode_limits(value) |> result.map(Some)
  })
  Ok(ExecStart(argv:, env:, cwd:, policy: exec_policy, token:, limits:))
}

fn decode_env(
  value: MsgPackValue,
) -> Result(List(#(String, String)), FrameError) {
  case value {
    msgpack.MapValue(entries:) ->
      list.try_map(entries, fn(entry) {
        case entry {
          #(msgpack.StringValue(name), msgpack.StringValue(text)) ->
            Ok(#(name, text))
          _ -> Error(malformed("exec_start.env", "string pairs", ""))
        }
      })
    msgpack.NilValue -> Ok([])
    _ -> Error(malformed("exec_start.env", "a map of strings", ""))
  }
}

fn decode_limits(value: MsgPackValue) -> Result(Limits, FrameError) {
  case value {
    msgpack.MapValue(entries:) -> {
      use Nil <- result.try(
        check_keys(entries, [
          "cpu_s", "wall_s", "mem_bytes", "pids", "fsize_bytes", "output_bytes",
        ]),
      )
      use cpu_s <- result.try(body_int(entries, "limits", "cpu_s"))
      use wall_s <- result.try(body_int(entries, "limits", "wall_s"))
      use mem_bytes <- result.try(body_int(entries, "limits", "mem_bytes"))
      use pids <- result.try(body_int(entries, "limits", "pids"))
      use fsize_bytes <- result.try(body_int(entries, "limits", "fsize_bytes"))
      use output_bytes <- result.try(body_int(entries, "limits", "output_bytes"))
      Ok(policy.Limits(
        cpu_s:,
        wall_s:,
        mem_bytes:,
        pids:,
        fsize_bytes:,
        output_bytes:,
      ))
    }
    _ -> Error(malformed("exec_start.limits", "a map", ""))
  }
}

fn decode_exec_stdin(entries: Entries) -> Result(Body, FrameError) {
  use Nil <- result.try(check_keys(entries, ["data", "eof"]))
  use data <- result.try(body_binary(entries, "exec_stdin", "data"))
  use eof <- result.try(body_bool(entries, "exec_stdin", "eof"))
  Ok(ExecStdin(data:, eof:))
}

fn decode_exec_out(entries: Entries) -> Result(Body, FrameError) {
  use Nil <- result.try(
    check_keys(entries, ["stream", "data", "bytes", "truncated"]),
  )
  use stream_text <- result.try(body_string(entries, "exec_out", "stream"))
  use stream <- result.try(case stream_text {
    "stdout" -> Ok(Stdout)
    "stderr" -> Ok(Stderr)
    other -> Error(malformed("exec_out.stream", "stdout or stderr", other))
  })
  use data <- result.try(body_binary(entries, "exec_out", "data"))
  use bytes <- result.try(body_int(entries, "exec_out", "bytes"))
  use truncated <- result.try(body_bool(entries, "exec_out", "truncated"))
  Ok(ExecOut(stream:, data:, bytes:, truncated:))
}

fn decode_exec_exit(entries: Entries) -> Result(Body, FrameError) {
  use Nil <- result.try(
    check_keys(entries, [
      "code", "signal", "stdout_bytes", "stderr_bytes", "stdout_truncated",
      "stderr_truncated", "enforcement", "degraded", "wall_ms", "timed_out",
    ]),
  )
  use code <- result.try(body_int(entries, "exec_exit", "code"))
  use signal <- result.try(body_int(entries, "exec_exit", "signal"))
  use stdout_bytes <- result.try(body_int(entries, "exec_exit", "stdout_bytes"))
  use stderr_bytes <- result.try(body_int(entries, "exec_exit", "stderr_bytes"))
  use stdout_truncated <- result.try(body_bool(
    entries,
    "exec_exit",
    "stdout_truncated",
  ))
  use stderr_truncated <- result.try(body_bool(
    entries,
    "exec_exit",
    "stderr_truncated",
  ))
  use enforcement <- result.try(body_strings(
    entries,
    "exec_exit",
    "enforcement",
  ))
  use degraded <- result.try(body_bool(entries, "exec_exit", "degraded"))
  use wall_ms <- result.try(body_int(entries, "exec_exit", "wall_ms"))
  use timed_out <- result.try(body_bool(entries, "exec_exit", "timed_out"))
  Ok(ExecExit(
    code:,
    signal:,
    stdout_bytes:,
    stderr_bytes:,
    stdout_truncated:,
    stderr_truncated:,
    enforcement:,
    degraded:,
    wall_ms:,
    timed_out:,
  ))
}

fn decode_cap_call(entries: Entries) -> Result(Body, FrameError) {
  use Nil <- result.try(
    check_keys(entries, ["token", "cap", "args", "deadline_ms"]),
  )
  use token <- result.try(body_binary(entries, "cap_call", "token"))
  use cap <- result.try(body_string(entries, "cap_call", "cap"))
  use args <- result.try(body_field(entries, "cap_call", "args"))
  use deadline_ms <- result.try(body_int(entries, "cap_call", "deadline_ms"))
  Ok(CapCall(token:, cap:, args:, deadline_ms:))
}

fn decode_cap_result(entries: Entries) -> Result(Body, FrameError) {
  use Nil <- result.try(check_keys(entries, ["ok", "value", "error", "usage"]))
  use ok <- result.try(body_bool(entries, "cap_result", "ok"))
  let usage = case find(entries, "usage") {
    Error(Nil) -> None
    Ok(msgpack.NilValue) -> None
    Ok(value) -> Some(value)
  }
  case ok {
    True -> {
      use value <- result.try(body_field(entries, "cap_result", "value"))
      Ok(CapResult(outcome: CapOk(value:), usage:))
    }
    False -> {
      use error_value <- result.try(body_field(entries, "cap_result", "error"))
      case error_value {
        msgpack.MapValue(error_entries) -> {
          use Nil <- result.try(check_keys(error_entries, ["code", "msg"]))
          use code <- result.try(body_string(
            error_entries,
            "cap_result.error",
            "code",
          ))
          use message <- result.try(body_string(
            error_entries,
            "cap_result.error",
            "msg",
          ))
          Ok(CapResult(outcome: CapErr(code:, message:), usage:))
        }
        _ -> Error(malformed("cap_result.error", "a map", ""))
      }
    }
  }
}

fn decode_error_body(entries: Entries) -> Result(Body, FrameError) {
  use Nil <- result.try(check_keys(entries, ["code", "msg"]))
  use code <- result.try(body_string(entries, "error", "code"))
  use message <- result.try(body_string(entries, "error", "msg"))
  Ok(ErrorBody(code:, message:))
}

// --- incremental deframing ----------------------------------------------

/// A pure incremental deframer: feed it transport chunks with `push`,
/// get complete frames out, with the partial remainder carried inside.
/// Once a fault is seen the deframer is dead — every later push reports
/// the same fault, matching the close-the-channel contract.
pub opaque type Deframer {
  /// Invariant: `buffer` holds bytes after the last complete frame;
  /// `fault`, once set, never clears.
  Deframer(buffer: BitArray, fault: Option(Fault))
}

/// One well-formed inbound frame, or a well-formed frame of an unknown
/// kind (answered in-band, channel kept).
pub type Inbound {
  /// A fully decoded frame.
  Known(frame: Frame)
  /// A structurally valid frame of a kind this broker does not speak.
  UnknownInbound(id: Int, kind: String)
}

/// A channel-fatal condition met while deframing. The caller must close
/// the channel and settle any in-flight effect as an in-band failure.
pub type Fault {
  /// A frame payload failed to parse.
  CorruptFrame(report: CorruptionReport)
  /// The peer speaks a different protocol version.
  VersionMismatch(version: Int)
  /// A length prefix exceeded `max_frame_bytes`.
  OversizedFrame(declared_bytes: Int)
}

/// The outcome of one `push`: the deframer to continue with, the frames
/// completed by this chunk in arrival order, and the fault that ended
/// the stream, if one did. Frames completed before the fault are still
/// delivered.
pub type Pushed {
  Pushed(deframer: Deframer, inbound: List(Inbound), fault: Option(Fault))
}

/// A fresh deframer with an empty carry.
///
/// ## Examples
///
/// ```gleam
/// assert framing.push(framing.deframer(), <<>>).inbound == []
/// ```
///
pub fn deframer() -> Deframer {
  Deframer(buffer: <<>>, fault: None)
}

/// Feeds one transport chunk to the deframer. Pure; chunking never
/// affects the frames produced — pushing a byte stream one byte at a
/// time yields exactly the frames of pushing it whole.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(bytes) =
///   framing.encode(framing.Frame(id: 1, body: framing.Cancel))
/// let pushed = framing.push(framing.deframer(), bytes)
/// assert pushed.inbound
///   == [framing.Known(framing.Frame(id: 1, body: framing.Cancel))]
/// ```
///
pub fn push(deframer: Deframer, bytes: BitArray) -> Pushed {
  case deframer.fault {
    Some(fault) -> Pushed(deframer:, inbound: [], fault: Some(fault))
    None -> {
      let buffer = bit_array.append(deframer.buffer, bytes)
      push_loop(buffer, [])
    }
  }
}

fn push_loop(buffer: BitArray, seen: List(Inbound)) -> Pushed {
  case buffer {
    <<size:size(32), rest:bits>> ->
      case size > max_frame_bytes {
        True -> {
          let fault = OversizedFrame(declared_bytes: size)
          Pushed(
            deframer: Deframer(buffer:, fault: Some(fault)),
            inbound: list.reverse(seen),
            fault: Some(fault),
          )
        }
        False ->
          case take_frame(rest, size) {
            // Not enough bytes yet: carry and wait for more.
            Error(Nil) ->
              Pushed(
                deframer: Deframer(buffer:, fault: None),
                inbound: list.reverse(seen),
                fault: None,
              )
            Ok(#(payload, remainder)) ->
              case decode_payload(payload) {
                Ok(frame) -> push_loop(remainder, [Known(frame:), ..seen])
                // Well-formed but unrecognized: not a poisoning fault.
                // The deframer keeps scanning `remainder` normally so
                // later, understood frames still arrive — only a
                // genuinely broken envelope kills the channel.
                Error(UnknownKind(id:, kind:)) ->
                  push_loop(remainder, [UnknownInbound(id:, kind:), ..seen])
                // Both faults below poison the deframer via `faulted`:
                // every subsequent `push` reports the same fault instead
                // of resuming the scan, matching the close-the-channel
                // contract (spec §3.3 invariant 6).
                Error(Malformed(report:)) ->
                  faulted(buffer, seen, CorruptFrame(report:))
                Error(UnsupportedVersion(version:)) ->
                  faulted(buffer, seen, VersionMismatch(version:))
              }
          }
      }
    _ ->
      // Fewer than four bytes buffered: carry.
      Pushed(
        deframer: Deframer(buffer:, fault: None),
        inbound: list.reverse(seen),
        fault: None,
      )
  }
}

fn faulted(buffer: BitArray, seen: List(Inbound), fault: Fault) -> Pushed {
  Pushed(
    deframer: Deframer(buffer:, fault: Some(fault)),
    inbound: list.reverse(seen),
    fault: Some(fault),
  )
}

fn take_frame(
  bytes: BitArray,
  size: Int,
) -> Result(#(BitArray, BitArray), Nil) {
  let available = bit_array.byte_size(bytes)
  case available >= size {
    False -> Error(Nil)
    True -> {
      use payload <- result.try(bit_array.slice(from: bytes, at: 0, take: size))
      use remainder <- result.try(bit_array.slice(
        from: bytes,
        at: size,
        take: available - size,
      ))
      Ok(#(payload, remainder))
    }
  }
}

// --- decoding plumbing --------------------------------------------------

type Entries =
  List(#(MsgPackValue, MsgPackValue))

fn malformed(subject: String, expected: String, context: String) -> FrameError {
  Malformed(report: corruption.report(
    at: "broker/framing.decode_payload",
    on: subject,
    expected:,
    context:,
  ))
}

fn envelope_map(value: MsgPackValue) -> Result(Entries, FrameError) {
  case value {
    msgpack.MapValue(entries:) -> Ok(entries)
    _ -> Error(malformed("frame", "a msgpack map envelope", ""))
  }
}

fn body_map(kind: String, value: MsgPackValue) -> Result(Entries, FrameError) {
  case value {
    msgpack.MapValue(entries:) -> Ok(entries)
    _ -> Error(malformed(kind <> ".body", "a msgpack map", ""))
  }
}

// Rejects any key outside `known`. Required keys are enforced by the
// per-field accessors; optional keys (exec_start.policy/limits,
// cap_result.value/error/usage) are simply absent from lookups.
fn check_keys(
  entries: Entries,
  known: List(String),
) -> Result(Nil, FrameError) {
  list.try_each(entries, fn(entry) {
    case entry.0 {
      msgpack.StringValue(key) ->
        case list.contains(known, key) {
          True -> Ok(Nil)
          False -> Error(malformed("frame", "no unknown keys", key))
        }
      _ -> Error(malformed("frame", "string keys", ""))
    }
  })
}

fn find(entries: Entries, key: String) -> Result(MsgPackValue, Nil) {
  list.find_map(entries, fn(entry) {
    case entry.0 == msgpack.StringValue(key) {
      True -> Ok(entry.1)
      False -> Error(Nil)
    }
  })
}

fn envelope_field(
  entries: Entries,
  key: String,
) -> Result(MsgPackValue, FrameError) {
  find(entries, key)
  |> result.replace_error(malformed("frame", "required key " <> key, "missing"))
}

fn envelope_int(entries: Entries, key: String) -> Result(Int, FrameError) {
  use value <- result.try(envelope_field(entries, key))
  case value {
    msgpack.IntValue(number) -> Ok(number)
    _ -> Error(malformed("frame." <> key, "an integer", ""))
  }
}

fn envelope_string(
  entries: Entries,
  key: String,
) -> Result(String, FrameError) {
  use value <- result.try(envelope_field(entries, key))
  case value {
    msgpack.StringValue(text) -> Ok(text)
    _ -> Error(malformed("frame." <> key, "a string", ""))
  }
}

fn body_field(
  entries: Entries,
  kind: String,
  key: String,
) -> Result(MsgPackValue, FrameError) {
  find(entries, key)
  |> result.replace_error(malformed(kind, "required key " <> key, "missing"))
}

fn body_int(
  entries: Entries,
  kind: String,
  key: String,
) -> Result(Int, FrameError) {
  use value <- result.try(body_field(entries, kind, key))
  case value {
    msgpack.IntValue(number) -> Ok(number)
    _ -> Error(malformed(kind <> "." <> key, "an integer", ""))
  }
}

fn body_bool(
  entries: Entries,
  kind: String,
  key: String,
) -> Result(Bool, FrameError) {
  use value <- result.try(body_field(entries, kind, key))
  case value {
    msgpack.BoolValue(flag) -> Ok(flag)
    _ -> Error(malformed(kind <> "." <> key, "a bool", ""))
  }
}

fn body_string(
  entries: Entries,
  kind: String,
  key: String,
) -> Result(String, FrameError) {
  use value <- result.try(body_field(entries, kind, key))
  case value {
    msgpack.StringValue(text) -> Ok(text)
    _ -> Error(malformed(kind <> "." <> key, "a string", ""))
  }
}

// bin on the wire; nil accepted as empty because the Go encoder writes
// nil slices as msgpack nil.
fn body_binary(
  entries: Entries,
  kind: String,
  key: String,
) -> Result(BitArray, FrameError) {
  use value <- result.try(body_field(entries, kind, key))
  case value {
    msgpack.BinaryValue(bytes:) -> Ok(bytes)
    msgpack.NilValue -> Ok(<<>>)
    _ -> Error(malformed(kind <> "." <> key, "a binary", ""))
  }
}

// str array on the wire; nil accepted as empty (Go nil slices).
fn body_strings(
  entries: Entries,
  kind: String,
  key: String,
) -> Result(List(String), FrameError) {
  use value <- result.try(body_field(entries, kind, key))
  case value {
    msgpack.ArrayValue(items:) ->
      list.try_map(items, fn(item) {
        case item {
          msgpack.StringValue(text) -> Ok(text)
          _ -> Error(malformed(kind <> "." <> key, "string elements", ""))
        }
      })
    msgpack.NilValue -> Ok([])
    _ -> Error(malformed(kind <> "." <> key, "an array of strings", ""))
  }
}
