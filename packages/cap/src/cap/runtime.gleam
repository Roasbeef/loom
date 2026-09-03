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
//// ## The serving loop (the persistent satellite)
////
//// `boot` is the single-shot shape: run one program, emit one `outcome`,
//// die. `serve` is the other one, and it is what an installed extension
//// runs (`protocol-change/012`, ADR-007 Decision 3). The node boots the
//// same channel over the same socket and then *waits*: the harness sends
//// a `hook_call` naming a tool or an event, the loop answers it with a
//// `hook_result` carrying the same frame id, and it goes on waiting. No
//// `outcome` frame is ever written, because there is no execution to end.
////
//// Three rules make that safe, and each is enforced here rather than
//// assumed of the harness.
////
//// - **The token belongs to the invocation, not to the node.** A
////   `hook_call` carries the token the harness minted for it. The loop
////   installs it on the channel before the answer starts and clears it
////   after the answer ends, so a process the extension kept alive between
////   invocations frames its `cap_call`s with bytes the harness has
////   already revoked. The token file the boot contract reads is not a
////   working token for a serving node; it satisfies the boot sequence and
////   nothing else.
//// - **One invocation at a time.** A second `hook_call` arriving while
////   one is open is answered `busy` on the spot and never queued: the
////   protocol serialises on the harness side, so a second one is a fault
////   to name rather than work to schedule.
//// - **A crash is an answer.** The invocation runs in a monitored child,
////   so a `panic` in extension code becomes `crashed` on the wire and the
////   loop carries on with the next invocation.
////
//// The loop ends on a `cancel` frame or a closed channel, in both cases
//// by returning — the node then exits, and the harness observes the
//// socket closing.
////
//// ## Why the exclusive install is load-bearing here
////
//// `install_channel` refuses to claim the VM-global channel slot while a
//// prior execution's channel actor is alive. Under the single-shot shape
//// that guard never fires, because every execution gets a fresh node.
//// Under the serving shape it is the thing that would catch a host which
//// started a second satellite for one extension without reaping the
//// first: the survivor would otherwise read the new node's channel and
//// act under the new invocation's token. `codemode/satellite`'s host
//// upholds the other half — a host reaps its node before the session's
//// next host for that extension starts — and this refusal is what makes
//// a breach of it fail loudly.
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
import cap/internal/wire
import cap/report.{type Outcome, type Value}
import core/msgpack
import gleam/bit_array
import gleam/erlang/process.{type Down, type Monitor, type Pid, type Subject}
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

  /// A prior execution's capability channel still occupies the VM-global
  /// slot. Only reachable in the kept-alive satellite mode, and only when
  /// the executor has not reaped the prior execution first.
  ChannelSlotOccupied(reason: String)
}

// What the boot process waits on: the program's outcome, or its death.
type ProgramReport {
  ProgramDone(outcome: Outcome)
  ProgramDown(down: Down)
}

/// Boots the satellite over an injected transport and runs `program`.
///
/// The sequence is: start the channel holding `token`; claim the one door
/// every `cap/*` call resolves, refusing if a prior execution's channel is
/// still installed; start the inbound reader; run `program` in a monitored
/// child (so a crash becomes an outcome, not a dead satellite); marshal and
/// frame the outcome and write it to the sink; then tear the channel and
/// reader down and release the door. Returns `Ok(Nil)` once the outcome has
/// been written, or a `BootError` if the channel would not start or the
/// door was still held.
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
  use owner <- result.try(install_channel(handle))
  let reader = start_reader(handle, transport.recv, dropped())

  // Run the program to completion (or death) and marshal whatever it
  // produced. The satellite always emits exactly one outcome frame.
  let outcome = run_program(program)
  transport.outcome_sink(frame_outcome(outcome))

  // Clean teardown: the reader is blocked in `recv`, so kill it; killing
  // the satellite would reap both regardless, but tests need it tidy.
  // Releasing the slot leaves any process that survived this execution
  // with no channel at all, so its next cap call is `Unreachable` rather
  // than a call under the *next* execution's token.
  process.kill(reader)
  channel.stop(handle)
  dispatch.release(owner)
  Ok(Nil)
}

// Claims the VM-global channel slot for this execution, refusing if a
// prior execution's channel actor is still alive (see
// `dispatch.install_exclusive`). On refusal the channel just started is
// stopped again, so a refused boot leaves nothing behind.
fn install_channel(handle: Handle) -> Result(Pid, BootError) {
  case process.subject_owner(channel.subject(handle)) {
    Error(Nil) -> {
      channel.stop(handle)
      Error(ChannelStartFailed("the channel actor has no owner"))
    }
    Ok(owner) ->
      case dispatch.install_exclusive(channel.to_channel(handle), owner) {
        Ok(Nil) -> Ok(owner)
        Error(Nil) -> {
          channel.stop(handle)
          Error(ChannelSlotOccupied(
            "a prior execution's capability channel is still installed; the "
            <> "executor must reap it before this one boots",
          ))
        }
      }
  }
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

// What the reader does with the frames that are not `cap_result`.
//
// `cap_result` always goes to the channel actor, so it is not in here.
// The other two are the serving shape's, and a single-shot boot supplies
// closures that drop them: a code-mode node runs a program nobody calls
// into, and a `cancel` on that path is already handled by the host
// killing the node.
type Reception {
  Reception(asked: fn(Ask) -> Nil, ended: fn(String) -> Nil)
}

// One `hook_call` as the serving loop reads it.
type Ask {
  Ask(
    id: Int,
    token: BitArray,
    kind: String,
    name: String,
    args: msgpack.MsgPackValue,
    deadline_ms: Int,
  )
}

// The reception a single-shot boot installs: neither frame can arrive on
// that path, and if one did it would be a harness bug rather than
// anything the program could act on.
fn dropped() -> Reception {
  Reception(asked: fn(_ask) { Nil }, ended: fn(_reason) { Nil })
}

// Spawn the reader on its own unlinked process: it blocks in `recv`, so it
// cannot share the boot process, and its death (via `boot`'s kill) must not
// take the boot process with it.
fn start_reader(
  handle: Handle,
  recv: fn() -> Result(BitArray, Nil),
  reception: Reception,
) -> Pid {
  process.spawn_unlinked(fn() {
    reader_loop(handle, recv, inbound.deframer(), reception)
  })
}

fn reader_loop(
  handle: Handle,
  recv: fn() -> Result(BitArray, Nil),
  deframer: inbound.Deframer,
  reception: Reception,
) -> Nil {
  case recv() {
    // The transport closed. Fail in-flight calls in-band; a program still
    // waiting on a result now unblocks with `Unreachable`, and a serving
    // loop learns there is nothing left to answer to.
    Error(Nil) -> {
      channel.fail(handle, "cap channel closed")
      reception.ended("the capability channel closed")
    }
    Ok(bytes) -> {
      let inbound.Pushed(deframer:, inbound: frames, fault:) =
        inbound.push(deframer, bytes)
      list.each(frames, fn(frame) { apply_inbound(handle, frame, reception) })
      case fault {
        // A channel-fatal frame: close the channel and stop reading.
        Some(fault) -> {
          channel.fail(handle, inbound.describe_fault(fault))
          reception.ended(inbound.describe_fault(fault))
        }
        None -> reader_loop(handle, recv, deframer, reception)
      }
    }
  }
}

fn apply_inbound(
  handle: Handle,
  frame: inbound.Inbound,
  reception: Reception,
) -> Nil {
  case frame {
    inbound.CapResult(id:, outcome:) -> channel.deliver(handle, id, outcome)

    inbound.HookCall(id:, token:, kind:, name:, args:, deadline_ms:) ->
      reception.asked(Ask(id:, token:, kind:, name:, args:, deadline_ms:))

    // `cancel` on this channel means the harness is done with the node.
    // The serving loop returns and the node exits; a single-shot boot
    // drops it, because the host kills that node outright.
    inbound.IgnoredKind(id: _, kind: "cancel") ->
      reception.ended("the harness cancelled this satellite")

    // Any other well-formed frame of a kind a satellite does not act on:
    // drop it, keep the channel open (forward compatibility).
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

// --- the serving loop ----------------------------------------------------

/// Which kind of thing the harness is asking for.
///
/// The wire carries `"tool"` or `"event"` as a string (Part 1.4); this is
/// that string turned into a closed set at the edge, so nothing past this
/// module branches on text. A `kind` that is neither is refused rather
/// than guessed at.
pub type Invocation {
  /// A model-made tool call. `name` is the manifest tool's name.
  Tool(name: String)

  /// A hook event on the harness's timeline. `name` is the event's.
  Event(name: String)
}

/// What one invocation produced. Mirrors the `hook_result` body.
pub type Answer {
  /// The invocation produced this value, which becomes `{ok: true,
  /// value}`.
  Answered(value: Value)

  /// The invocation produced no value, under this in-band code, which
  /// becomes `{ok: false, error: {code, msg}}`. The codes this module
  /// mints itself are `bad_kind`, `busy` and `crashed`; everything else
  /// is the serving function's own vocabulary.
  Refused(code: String, message: String)
}

/// How long an invocation's deadline is, and what it is for. Handed to
/// the serving function so an extension can decide to refuse rather than
/// run past its own bound.
pub type Asked {
  Asked(invocation: Invocation, args: Value, deadline_ms: Int)
}

/// The production entry for a persistent satellite: read the environment,
/// connect the socket, boot the channel, and serve invocations until the
/// harness cancels or the channel closes.
///
/// The mirror of `run` for the other shape. On a `BootError` it returns
/// `Nil` without serving anything; the node exits and the host observes
/// the socket closing, exactly as it does for a boot that failed.
///
/// ## Examples
///
/// ```gleam
/// // pub fn main() -> Nil {
/// //   runtime.serve(fn(asked) { runtime.Answered(report.string("hi")) })
/// // }
/// ```
///
pub fn serve(answer: fn(Asked) -> Answer) -> Nil {
  case serve_production(answer) {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }
}

fn serve_production(answer: fn(Asked) -> Answer) -> Result(Nil, BootError) {
  use token <- result.try(read_token())
  use transport <- result.try(production_transport())
  serve_over(token, transport, answer)
}

/// Serves invocations over an injected transport, so the whole loop is
/// exercisable in-process with no socket — the same seam `boot` takes and
/// for the same reason.
///
/// `token` is what the node read from `LOOM_CAP_TOKEN_FILE`. For a
/// serving node it is deliberately *not* a working token: the harness
/// mints one per invocation and hands it over on the `hook_call`, and
/// this one only satisfies the boot sequence. It is installed anyway
/// rather than replaced with empty bytes, because the channel's shape
/// should not differ between the two boot modes.
///
/// Returns once the channel closes or the harness cancels, having stopped
/// the reader, the channel actor and its claim on the VM-global slot.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = runtime.serve_over(<<0>>, transport, answer)
/// ```
///
pub fn serve_over(
  token: BitArray,
  transport: Transport,
  answer: fn(Asked) -> Answer,
) -> Result(Nil, BootError) {
  use handle <- result.try(
    channel.start(token, transport.send)
    |> result.map_error(fn(error) {
      ChannelStartFailed(describe_start_error(error))
    }),
  )
  use owner <- result.try(install_channel(handle))

  // The loop runs in *this* process, so `serve_over` returning is the
  // node being done. The reader is the only other process the serving
  // shape starts, and it feeds this one.
  let signals = process.new_subject()
  let reader =
    start_reader(
      handle,
      transport.recv,
      Reception(
        asked: fn(ask) { process.send(signals, Invoked(ask:)) },
        ended: fn(reason) { process.send(signals, Ended(reason:)) },
      ),
    )
  serving(handle, transport, signals, answer, Idle)

  process.kill(reader)
  channel.stop(handle)
  dispatch.release(owner)
  Ok(Nil)
}

// What the loop is doing right now. Two states and no third: the protocol
// admits one open invocation, so there is nothing to hold a queue in.
type Phase {
  Idle

  /// One invocation is open. `id` is the frame the answer must carry, and
  /// `monitor` is how the loop learns the worker died instead of
  /// answering.
  Answering(id: Int, worker: Pid, monitor: Monitor)
}

// Everything the loop selects on. The worker's answer and its death are
// two signals from the same process, so exactly one of them arrives
// first and the loop acts on whichever it is.
type Signal {
  Invoked(ask: Ask)
  Settled(id: Int, answer: Answer)
  WorkerDown(down: Down)
  Ended(reason: String)
}

fn serving(
  handle: Handle,
  transport: Transport,
  signals: Subject(Signal),
  answer: fn(Asked) -> Answer,
  phase: Phase,
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select(signals)
    |> process.select_monitors(WorkerDown)
  case process.selector_receive_forever(selector), phase {
    // A fresh invocation with nothing open: install its token, then start
    // the worker. The order is the whole authority rule — a worker that
    // reached a capability before its token was installed would present
    // the previous invocation's, which the harness has already revoked.
    Invoked(ask:), Idle -> {
      channel.set_token(handle, ask.token)
      let #(worker, monitor) = start_worker(signals, answer, ask)
      serving(
        handle,
        transport,
        signals,
        answer,
        Answering(id: ask.id, worker:, monitor:),
      )
    }

    // A second invocation while one is open. The harness serialises, so
    // this is a fault on its side; answering `busy` on the spot is both
    // the honest reply and the one that cannot deadlock. It is never
    // queued: a queue would mean a second token installed under the first
    // invocation's worker.
    Invoked(ask:), Answering(..) -> {
      emit_answer(
        transport,
        ask.id,
        Refused(
          code: "busy",
          message: "this satellite is already answering an invocation; the "
            <> "protocol allows one at a time",
        ),
      )
      serving(handle, transport, signals, answer, phase)
    }

    // The worker answered. Drop its monitor before clearing the token, so
    // the loop is back to a state where nothing it holds can reach a
    // capability.
    Settled(id:, answer: produced), Answering(id: open, monitor:, ..)
      if id == open
    -> {
      process.demonitor_process(monitor)
      emit_answer(transport, id, produced)
      channel.set_token(handle, <<>>)
      serving(handle, transport, signals, answer, Idle)
    }

    // The worker died instead of answering: a `panic`, a `let assert`, a
    // kill. That is an answer too, and the loop goes on — one bad
    // invocation must not cost the session its satellite.
    WorkerDown(down:), Answering(id:, ..) -> {
      emit_answer(
        transport,
        id,
        Refused(code: "crashed", message: down_reason(down)),
      )
      channel.set_token(handle, <<>>)
      serving(handle, transport, signals, answer, Idle)
    }

    // The channel is gone, so there is nobody to answer and nothing to
    // wait for. Returning ends the node.
    Ended(reason: _), Idle | Ended(reason: _), Answering(..) -> Nil

    // A settlement for an invocation that is no longer open, and a
    // worker death with none open. Both are stale signals from a worker
    // whose answer or death the loop has already acted on — a monitor
    // fires after a normal exit the loop demonitored a moment too late —
    // and dropping them is the whole handling.
    Settled(..), Idle | Settled(..), Answering(..) -> {
      serving(handle, transport, signals, answer, phase)
    }
    WorkerDown(..), Idle -> serving(handle, transport, signals, answer, phase)
  }
}

// Runs one invocation on a monitored child of the loop.
//
// A child rather than the loop itself for two reasons that both matter:
// extension code may `panic`, which must become an answer rather than a
// dead satellite; and the loop has to stay in its selector so a second
// `hook_call` is answered `busy` instead of sitting in the mailbox behind
// an invocation that may run for its whole deadline.
fn start_worker(
  signals: Subject(Signal),
  answer: fn(Asked) -> Answer,
  ask: Ask,
) -> #(Pid, Monitor) {
  let worker =
    process.spawn_unlinked(fn() {
      let produced = case invocation_of(ask.kind, ask.name) {
        Ok(invocation) ->
          answer(Asked(
            invocation:,
            args: ask.args,
            deadline_ms: ask.deadline_ms,
          ))
        Error(refusal) -> refusal
      }
      process.send(signals, Settled(id: ask.id, answer: produced))
    })
  #(worker, process.monitor(worker))
}

// The wire's `kind` string as the closed set, or the refusal that names
// what arrived. A harness and a satellite from one tree never disagree
// here, so this is the forward-compatibility arm rather than a case the
// current pair reaches.
fn invocation_of(kind: String, name: String) -> Result(Invocation, Answer) {
  case kind {
    "tool" -> Ok(Tool(name:))
    "event" -> Ok(Event(name:))
    other ->
      Error(Refused(
        code: "bad_kind",
        message: "a hook_call named kind `"
          <> other
          <> "`, which this satellite does not know; it serves `tool` and "
          <> "`event`",
      ))
  }
}

// Writes one `hook_result`. A value that will not encode falls back to a
// refusal that always will, for the reason `frame_outcome` does the same:
// the harness is waiting on this frame and a silence costs the satellite
// its node at the deadline.
fn emit_answer(transport: Transport, id: Int, answer: Answer) -> Nil {
  let bytes = case encode_answer(id, answer) {
    Ok(bytes) -> Ok(bytes)
    Error(_) ->
      encode_answer(
        id,
        Refused(
          code: "unencodable",
          message: "the answer to this invocation did not encode",
        ),
      )
  }
  case bytes {
    Ok(bytes) -> transport.send(bytes)

    // Unreachable: a `{code, msg}` map of small strings always encodes.
    Error(_) -> Nil
  }
}

fn encode_answer(
  id: Int,
  answer: Answer,
) -> Result(BitArray, msgpack.EncodeError) {
  case answer {
    Answered(value:) -> wire.encode_hook_result(id, wire.Answered(value:))
    Refused(code:, message:) ->
      wire.encode_hook_result(id, wire.Refused(code:, message:))
  }
}
