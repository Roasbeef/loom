//// `cap/runtime` — the trusted boot runtime that runs *inside* a jailed
//// satellite node (design/architecture/code-mode.md, "Layer two: the
//// satellite node").
////
//// A vetted code-mode program is compiled together with the cap prelude
//// and a tiny generated entry module, then run inside a disposable `erl`
//// node. That entry calls `boot` (via `run`, the production convenience).
//// `boot` wires the capability channel to the host, installs it as the one
//// door every `cap/*` function uses, runs the submitted program's `main`,
//// and marshals its `report.Outcome` back. The program is untrusted and
//// cannot import `cap/internal/*` (the compiler forbids it, and vetting
//// rejects it); this module legitimately lives in `cap`, so it may.
////
//// ## Injected transport
////
//// The whole runtime takes its transport as plain function values
//// (`Transport`), so the round trip is testable in-process with no socket:
//// a recorder for `send`, a scripted byte source for `recv`, a recorder
//// for `outcome_sink`. `production_transport` builds the real one over an
//// AF_UNIX socket; everything above it is pure orchestration.
////
//// ## Totality
////
//// A malformed inbound frame, a wrong-shape `cap_result`, a closed
//// transport, and a crash inside the submitted `main` are all values, not
//// panics. The program runs in a monitored child, so its death becomes an
//// `Errored` outcome; the satellite always tries to emit an outcome.
//// `BootError` covers only setup failures the runtime cannot recover from
//// (the channel actor would not start, the socket or token is missing).
////
//// ## Env var + token-file contract (pin this)
////
//// The host mints a 32-byte cap-channel token, writes it to a private
//// mode-0600 file inside a mode-0700 directory, and bind-mounts it
//// read-only into the jail. It also creates the AF_UNIX socket the channel
//// speaks over. Two environment variables, set in the jail, locate them:
////
//// - `LOOM_CAP_SOCK` — filesystem path to the AF_UNIX stream socket that
////   carries the capability channel (`cap_call`/`cancel` out, `cap_result`
////   in, and the terminal `outcome` frame back).
//// - `LOOM_CAP_TOKEN_FILE` — path to the private file holding the raw
////   32-byte token. `read_token` reads its bytes and passes them to `boot`;
////   the token is held only inside `cap/internal/channel`'s actor and is
////   never reachable by program code.
////
//// ## Outcome frame shape (pin this)
////
//// When `main` returns, its `report.Outcome` is marshalled with
//// `report.to_msgpack` and framed as a length-prefixed msgpack envelope in
//// the same shape as every other frame (Part 1.4), with a dedicated kind:
////
//// ```
//// frame := u32_be length ++ msgpack({v: 1, id: 0, kind: "outcome", body})
//// body  := report.to_msgpack(outcome)
////        =  {ok: true,  value}              (Completed)
////        |  {ok: false, message, details}   (Errored)
//// ```
////
//// It is written through `outcome_sink`. In production `outcome_sink` is
//// the same socket as `send`, so `outcome` travels on the cap channel as
//// its terminal frame; the host's satellite-channel reader recognizes kind
//// `"outcome"` and settles the execution on it. (The frozen `broker/framing`
//// does not know this kind — it is a satellite→host result, not a broker
//// frame — so the host reads the outcome with its own decoder, and never
//// via `broker/framing`, which would classify it as an unknown kind.)
//// Exactly one `outcome` frame is written per execution.
////
//// ## Generated entry contract (pin this)
////
//// The compile service generates a tiny satellite entry module that
//// imports this runtime and the vetted program module (whatever module
//// name it assigns, here shown as `program`, exposing
//// `pub fn main() -> cap/report.Outcome`) and calls `run` with `main`.
//// Emit it verbatim:
////
//// ```gleam
//// import cap/runtime
//// import program
////
//// pub fn main() -> Nil {
////   runtime.run(program.main)
//// }
//// ```
////
//// `run` reads the environment, connects the socket, reads the token, and
//// boots. On a `BootError` it returns `Nil` without emitting an outcome:
//// the node exits and the host observes the missing outcome as a failure.

import cap/internal/channel.{type Handle}
import cap/internal/dispatch
import cap/internal/ffi_transport.{type Socket}
import cap/internal/inbound
import cap/report.{type Outcome}
import core/msgpack
import gleam/bit_array
import gleam/erlang/process.{type Down, type Pid}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result

/// The environment variable naming the AF_UNIX socket path.
pub const sock_env = "LOOM_CAP_SOCK"

/// The environment variable naming the private cap-token file.
pub const token_env = "LOOM_CAP_TOKEN_FILE"

/// The kind stamped on the terminal outcome frame.
pub const outcome_kind = "outcome"

/// The satellite's link to the host, injected so the runtime is testable
/// without a socket. `send` writes a framed `cap_call`/`cancel` to the
/// channel; `recv` blocks for the next inbound bytes (`Error(Nil)` at end
/// of stream); `outcome_sink` receives the single framed `outcome`.
pub type Transport {
  Transport(
    send: fn(BitArray) -> Nil,
    recv: fn() -> Result(BitArray, Nil),
    outcome_sink: fn(BitArray) -> Nil,
  )
}

/// A setup failure the runtime cannot recover from. Program failures are
/// never a `BootError` — they become an `Errored` outcome instead.
pub type BootError {
  /// The capability channel actor failed to start.
  ChannelStartFailed(reason: String)
  /// The socket path is unset, or the socket could not be connected.
  TransportUnavailable(reason: String)
  /// The token-file path is unset, or the file could not be read.
  TokenUnavailable(reason: String)
}

// What the boot process waits on: the program's outcome, or its death.
type ProgramReport {
  ProgramDone(outcome: Outcome)
  ProgramDown(down: Down)
}

/// Boots the satellite over an injected transport and runs `program`.
///
/// The sequence is: start the channel holding `token`; install it as the
/// one door every `cap/*` call resolves; start the inbound reader; run
/// `program` in a monitored child (so a crash becomes an outcome, not a
/// dead satellite); marshal and frame the outcome and write it to the
/// sink; then tear the channel and reader down. Returns `Ok(Nil)` once the
/// outcome has been written, or a `BootError` if the channel would not
/// start.
pub fn boot(
  token: BitArray,
  transport: Transport,
  program: fn() -> Outcome,
) -> Result(Nil, BootError) {
  use handle <- result.try(
    channel.start(token, transport.send)
    |> result.map_error(fn(error) {
      ChannelStartFailed(describe_start_error(error))
    }),
  )
  dispatch.install(channel.to_channel(handle))
  let reader = start_reader(handle, transport.recv)

  // Run the program to completion (or death) and marshal whatever it
  // produced. The satellite always emits exactly one outcome frame.
  let outcome = run_program(program)
  transport.outcome_sink(frame_outcome(outcome))

  // Clean teardown: the reader is blocked in `recv`, so kill it; killing
  // the satellite would reap both regardless, but tests need it tidy.
  process.kill(reader)
  channel.stop(handle)
  Ok(Nil)
}

/// The production convenience the generated entry calls: read the socket
/// path and token from the environment, build the real transport, and
/// boot. On any `BootError` it returns `Nil` — the node exits and the host
/// treats the missing outcome as a failure.
pub fn run(program: fn() -> Outcome) -> Nil {
  case boot_production(program) {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }
}

fn boot_production(program: fn() -> Outcome) -> Result(Nil, BootError) {
  use token <- result.try(read_token())
  use transport <- result.try(production_transport())
  boot(token, transport, program)
}

/// Reads the raw cap token from the file named by `LOOM_CAP_TOKEN_FILE`.
pub fn read_token() -> Result(BitArray, BootError) {
  use path <- result.try(
    ffi_transport.getenv(token_env)
    |> result.replace_error(TokenUnavailable(token_env <> " is unset")),
  )
  ffi_transport.read_file(path)
  |> result.replace_error(TokenUnavailable("cannot read token file " <> path))
}

/// Builds the production transport over the AF_UNIX socket named by
/// `LOOM_CAP_SOCK`. `outcome_sink` shares the socket, so the terminal
/// `outcome` frame travels on the cap channel.
pub fn production_transport() -> Result(Transport, BootError) {
  use path <- result.try(
    ffi_transport.getenv(sock_env)
    |> result.replace_error(TransportUnavailable(sock_env <> " is unset")),
  )
  use socket <- result.try(
    ffi_transport.connect_unix(path)
    |> result.replace_error(TransportUnavailable("cannot connect to " <> path)),
  )
  Ok(socket_transport(socket))
}

fn socket_transport(socket: Socket) -> Transport {
  let write = fn(bytes) {
    let _ = ffi_transport.socket_send(socket, bytes)
    Nil
  }
  Transport(
    send: write,
    recv: fn() { ffi_transport.socket_recv(socket) },
    outcome_sink: write,
  )
}

// --- the inbound reader -------------------------------------------------

// Spawn the reader on its own unlinked process: it blocks in `recv`, so it
// cannot share the boot process, and its death (via `boot`'s kill) must not
// take the boot process with it.
fn start_reader(handle: Handle, recv: fn() -> Result(BitArray, Nil)) -> Pid {
  process.spawn_unlinked(fn() { reader_loop(handle, recv, inbound.deframer()) })
}

fn reader_loop(
  handle: Handle,
  recv: fn() -> Result(BitArray, Nil),
  deframer: inbound.Deframer,
) -> Nil {
  case recv() {
    // The transport closed. Fail in-flight calls in-band; a program still
    // waiting on a result now unblocks with `Unreachable`.
    Error(Nil) -> channel.fail(handle, "cap channel closed")
    Ok(bytes) -> {
      let inbound.Pushed(deframer:, inbound: frames, fault:) =
        inbound.push(deframer, bytes)
      list.each(frames, fn(frame) { apply_inbound(handle, frame) })
      case fault {
        // A channel-fatal frame: close the channel and stop reading.
        Some(fault) -> channel.fail(handle, inbound.describe_fault(fault))
        None -> reader_loop(handle, recv, deframer)
      }
    }
  }
}

fn apply_inbound(handle: Handle, frame: inbound.Inbound) -> Nil {
  case frame {
    inbound.CapResult(id:, outcome:) -> channel.deliver(handle, id, outcome)
    // A well-formed frame of a kind a satellite does not act on: drop it,
    // keep the channel open.
    inbound.IgnoredKind(..) -> Nil
  }
}

// --- running the program safely -----------------------------------------

// Run `program` in a monitored child so a panic or `let assert` failure in
// vetted code becomes an `Errored` outcome instead of killing the boot
// process — the satellite must always emit an outcome. The child is the
// caller of every `cap_call` it makes, so if it dies mid-call the channel's
// monitor emits the cancel frame (`cap/internal/channel`).
fn run_program(program: fn() -> Outcome) -> Outcome {
  let done = process.new_subject()
  let worker = process.spawn_unlinked(fn() { process.send(done, program()) })
  let monitor = process.monitor(worker)
  let selector =
    process.new_selector()
    |> process.select_map(done, ProgramDone)
    |> process.select_monitors(ProgramDown)
  // The satellite's wall-clock deadline is the real bound on how long a
  // program may run; wait for it here rather than imposing a second limit.
  case process.selector_receive_forever(selector) {
    ProgramDone(outcome:) -> {
      process.demonitor_process(monitor)
      outcome
    }
    ProgramDown(down:) -> report.failure(down_reason(down))
  }
}

fn down_reason(down: Down) -> String {
  case down {
    process.ProcessDown(reason:, ..) ->
      "program crashed: " <> exit_reason_text(reason)
    process.PortDown(..) -> "program crashed: port down"
  }
}

fn exit_reason_text(reason: process.ExitReason) -> String {
  case reason {
    process.Normal -> "normal"
    process.Killed -> "killed"
    process.Abnormal(_) -> "abnormal"
  }
}

// --- outcome framing ----------------------------------------------------

// Frame the outcome, always producing bytes. A `report.Outcome` can carry
// an unencodable value (an integer out of msgpack range, an over-large
// payload); rather than fail the whole boot, fall back to a plain-text
// `Errored`, which is tiny and always encodes.
fn frame_outcome(outcome: Outcome) -> BitArray {
  case encode_outcome(outcome) {
    Ok(bytes) -> bytes
    Error(_) ->
      case encode_outcome(report.failure("outcome did not encode")) {
        Ok(bytes) -> bytes
        // Unreachable: a {ok, message, details} map of small scalars always
        // encodes. An empty frame is a last resort that cannot panic.
        Error(_) -> <<>>
      }
  }
}

fn encode_outcome(outcome: Outcome) -> Result(BitArray, msgpack.EncodeError) {
  let envelope =
    msgpack.MapValue([
      #(msgpack.StringValue("v"), msgpack.IntValue(inbound.protocol_version)),
      #(msgpack.StringValue("id"), msgpack.IntValue(0)),
      #(msgpack.StringValue("kind"), msgpack.StringValue(outcome_kind)),
      #(msgpack.StringValue("body"), report.to_msgpack(outcome)),
    ])
  use payload <- result.try(msgpack.encode(envelope))
  let size = bit_array.byte_size(payload)
  case size > inbound.max_frame_bytes {
    True -> Error(msgpack.UnencodableLength(length: size))
    False -> Ok(<<size:size(32), payload:bits>>)
  }
}

fn describe_start_error(error: actor.StartError) -> String {
  case error {
    actor.InitTimeout -> "channel init timed out"
    actor.InitFailed(reason) -> "channel init failed: " <> reason
    actor.InitExited(_) -> "channel init exited"
  }
}
