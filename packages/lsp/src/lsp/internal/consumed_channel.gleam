//// Original local attachment ownership for Registered LSP consumption.
////
//// One actor owns the writer window and two fixed output-credit slots. The
//// client admits complete logical writes without waiting on server output.
//// Only one managed input task calls the original backend at a time, in 8KiB
//// slices. Its thirty-second deadline cancels and fences this attachment.
//// The writer retains each whole frame until its final physical feed and task
//// drain complete: at most 16 MiB plus 8192 bytes and 128 logical messages.
//// Lifetime admission is at most 64 MiB and 8192 feeds including reserved EOF;
//// completed feeds never renew it. The frame ceiling therefore permits at most
//// 8191 data feeds, or 67100672 bytes when every data feed is full.
//// These are logical limits, not a claim about process RSS or native pipe memory.
////
//// Output delivery is not consumption. An opaque grant names this original
//// actor, stream, incarnation and client owner. Only that owner can consume
//// the current grant once. The native publisher is answered only after the
//// matching managed credit wait has completed and drained. No callback alone
//// invents a credit, and no deadline proves original native retirement.
////
//// ## Flow
//// `open` installs the original `Session` and starts `handle`. `publish` enters
//// `offer_output`; `consume` enters `consume_output` and `output_report` releases
//// the original publisher. `admit` reserves before `pump` starts `input_report`.
//// `credit_ready` binds the worker-owned wait subject before output delivery.
//// `fence` cancels tasks and closes the original session; `closed` records its
//// separate original close event. `shutdown` preserves cancellation on exit.

import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/erlang/reference
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lsp/call
import weft
import weft/actor

/// Complete logical input retained before physical feed begins.
pub const writer_bytes = 16_785_408

/// Logical messages, including the currently feeding original.
pub const writer_messages = 128

/// Original pending-credit deadline; it never renews a native lease.
pub const credit_ms = 30_000

/// Physical input slices under one original credit.
pub const feed_bytes = 8192

const lifetime_bytes = 67_108_864

const lifetime_frames = 8192

const output_bytes = 32_768

const admission_ms = 1000

/// The two producer streams each have their own fixed current credit.
pub type Stream {
  /// Protocol bytes must reach framing, parsing and bounded client state.
  Stdout

  /// Diagnostic bytes must enter the client's bounded 8KiB ring.
  Stderr
}

/// Producer truncation has a closed representation, independent of bytes.
pub type Integrity {
  /// The original producer reports complete bytes.
  Intact

  /// The producer lost bytes; stdout cannot be repaired or resynchronized.
  Truncated
}

/// Trusted local backend, installed for one actual original lease attachment.
/// The feed callback returns only after that slice's real input credit settles;
/// close requests original cancellation and must return without waiting on output.
pub type Session {
  Session(
    /// Checked original physical feed, invoked only by the sole managed pump.
    feed: fn(BitArray) -> Result(Nil, Nil),
    /// Original cancellation request; independent close evidence uses `closed`.
    close: fn() -> Nil,
  )
}

/// Original producer endpoint. It cannot address another attachment by an ID.
pub opaque type Sink {
  Sink(
    /// The immutable original window owner, never a replacement lookup.
    subject: Subject(Msg),
  )
}

/// Current one-shot output authority; only this module can mint its fields.
pub opaque type Grant {
  Grant(
    /// The original owner whose current slot must match.
    sink: Sink,
    /// The closed original producer lane.
    stream: Stream,
    /// The incarnation-specific current one-shot identity.
    nonce: reference.Reference,
  )
}

/// Events delivered to the actual client owner, with explicit consumption.
pub type Event {
  /// One bounded original producer chunk and its sole consumption grant.
  Output(
    /// The original producer lane.
    stream: Stream,
    /// At most one native 32 KiB chunk, kept exact.
    bytes: BitArray,
    /// Authority only for this chunk and original consumer.
    grant: Grant,
  )

  /// The original attachment is fenced; this is no native close witness.
  Failed(
    /// The retained local protocol or credit failure.
    reason: String,
  )

  /// Trusted backend reports its original attachment closed independently.
  Closed(
    /// The original trusted attachment's close disposition.
    reason: String,
  )
}

/// Admission-only writer and nonblocking original cancellation request.
pub type Connection {
  Connection(
    /// Reserves a whole framed logical message before queueing it.
    send: fn(String) -> Result(Nil, Nil),
    /// Requests closure of this exact original session.
    close: fn() -> Nil,
  )
}

type Lifecycle {
  Accepting
  Fenced
}

type Frame {
  Frame(rest: BitArray, reserved: Int)
}

type Input {
  Input(cancel: weft.Cancel, outcome: Option(Result(Nil, Nil)))
}

type CreditPhase {
  Waiting
  Consumed
}

type Credit {
  Credit(
    nonce: reference.Reference,
    phase: CreditPhase,
    consumed: Option(Subject(Nil)),
    publisher: Subject(Result(Nil, String)),
    cancel: weft.Cancel,
    outcome: Option(Result(Nil, Nil)),
    consumer: Option(Subject(Result(Nil, String))),
  )
}

type Msg {
  Admit(frame: String, caller: process.Pid, reply: Subject(Result(Nil, Nil)))
  Offer(
    stream: Stream,
    bytes: BitArray,
    integrity: Integrity,
    reply: Subject(Result(Nil, String)),
  )
  Consume(
    stream: Stream,
    nonce: reference.Reference,
    caller: process.Pid,
    reply: Subject(Result(Nil, String)),
  )
  CreditReady(Stream, reference.Reference, Subject(Nil), BitArray)
  InputReport(weft.Pulled(Nil, Nil))
  OutputReport(Stream, weft.Pulled(Nil, Nil))
  Close
  OriginalClosed(String)
  OwnerDown
}

type State {
  State(
    self: Subject(Msg),
    owner: process.Pid,
    events: Subject(Event),
    session: Session,
    lifecycle: Lifecycle,
    queue: List(Frame),
    charged_bytes: Int,
    charged_messages: Int,
    lifetime_bytes: Int,
    lifetime_frames: Int,
    input: Option(Input),
    input_reports: Subject(weft.Pulled(Nil, Nil)),
    stdout_reports: Subject(weft.Pulled(Nil, Nil)),
    stderr_reports: Subject(weft.Pulled(Nil, Nil)),
    stdout: Option(Credit),
    stderr: Option(Credit),
  )
}

/// Opens one original owner and installs only trusted local attachment callbacks.
///
/// ## Examples
/// `open(connect, events)` yields admission-only writes; `publish` waits for consumption.
pub fn open(
  connect: fn(Sink) -> Result(Session, String),
  events: Subject(Event),
) -> Result(Connection, String) {
  use owner <- result.try(
    process.subject_owner(events)
    |> result.replace_error("the consumed client owner is gone"),
  )
  use started <- result.try(
    actor.new_with_initialiser(1000, fn(self) {
      let sink = Sink(self)
      use session <- result.try(connect(sink))
      let input_reports = process.new_subject()
      let stdout_reports = process.new_subject()
      let stderr_reports = process.new_subject()
      let selector =
        process.new_selector()
        |> process.select(self)
        |> process.select_map(input_reports, InputReport)
        |> process.select_map(stdout_reports, OutputReport(Stdout, _))
        |> process.select_map(stderr_reports, OutputReport(Stderr, _))
        |> process.select_specific_monitor(process.monitor(owner), fn(_) {
          OwnerDown
        })
      actor.initialised(State(
        self,
        owner,
        events,
        session,
        Accepting,
        [],
        0,
        0,
        0,
        1,
        None,
        input_reports,
        stdout_reports,
        stderr_reports,
        None,
        None,
      ))
      |> actor.selecting(selector)
      |> actor.returning(sink)
      |> Ok
    })
    |> actor.on_message(handle)
    |> actor.on_shutdown(shutdown)
    |> actor.unlinked
    |> actor.start
    |> result.replace_error("the consumed attachment owner did not start"),
  )
  let subject = started.data.subject
  Ok(
    Connection(
      send: fn(frame) {
        call.try_call(subject, admission_ms, Admit(frame, process.self(), _))
        |> result.replace_error(Nil)
        |> result.flatten
      },
      close: fn() { process.send(subject, Close) },
    ),
  )
}

/// Publishes one original chunk, answering only after actual client consumption.
/// Native assembly must retain its physical output credit until this returns Ok.
///
/// ## Examples
/// `publish(sink, Stdout, bytes, Intact)` grants no next output on failure.
pub fn publish(
  sink: Sink,
  stream: Stream,
  bytes: BitArray,
  integrity: Integrity,
) -> Result(Nil, String) {
  let answer =
    call.try_call(sink.subject, credit_ms + 1000, Offer(
      stream,
      bytes,
      integrity,
      _,
    ))
    |> result.replace_error("the original consumed attachment did not answer")
    |> result.flatten
  case answer {
    Ok(Nil) -> answer
    Error(_) -> {
      process.send(sink.subject, Close)
      answer
    }
  }
}

/// Consumes the exact current grant once, from its original client owner only.
///
/// ## Examples
/// A copied grant cannot grant consumption twice or from another process.
pub fn consume(grant: Grant) -> Result(Nil, String) {
  call.try_call(grant.sink.subject, admission_ms, Consume(
    grant.stream,
    grant.nonce,
    process.self(),
    _,
  ))
  |> result.replace_error("the original consumption owner is gone")
  |> result.flatten
}

/// Reports the trusted backend's separate original close witness.
///
/// ## Examples
/// `closed(sink, reason)` conveys no replacement lookup or reusable permission.
pub fn closed(sink: Sink, reason: String) -> Nil {
  process.send(sink.subject, OriginalClosed(reason))
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Admit(frame, caller, reply) -> admit(state, frame, caller, reply)
    Offer(stream, bytes, integrity, reply) ->
      actor.continue(offer_output(state, stream, bytes, integrity, reply))
    Consume(stream, nonce, caller, reply) ->
      actor.continue(consume_output(state, stream, nonce, caller, reply))
    CreditReady(stream, nonce, consumed, bytes) ->
      actor.continue(credit_ready(state, stream, nonce, consumed, bytes))
    InputReport(report) -> actor.continue(input_report(state, report))
    OutputReport(stream, report) ->
      actor.continue(output_report(state, stream, report))
    Close | OwnerDown ->
      actor.continue(fence(state, "the original attachment closed"))
    OriginalClosed(reason) -> {
      let _ = fence(state, reason)
      process.send(state.events, Closed(reason))
      actor.stop()
    }
  }
}

fn admit(
  state: State,
  frame: String,
  caller: process.Pid,
  reply: Subject(Result(Nil, Nil)),
) -> actor.Next(State, Msg) {
  let size = string.byte_size(frame)
  let chunks = { size + feed_bytes - 1 } / feed_bytes
  case
    state.lifecycle == Accepting
    && caller == state.owner
    && size > 0
    && state.charged_bytes + size <= writer_bytes
    && state.charged_messages < writer_messages
    && state.lifetime_bytes + size <= lifetime_bytes
    && state.lifetime_frames + chunks <= lifetime_frames
  {
    False -> {
      process.send(reply, Error(Nil))
      actor.continue(fence(
        state,
        "the original writer window or lifetime is exhausted",
      ))
    }
    True -> {
      let next =
        State(
          ..state,
          queue: list.append(state.queue, [
            Frame(bit_array.from_string(frame), size),
          ]),
          charged_bytes: state.charged_bytes + size,
          charged_messages: state.charged_messages + 1,
          lifetime_bytes: state.lifetime_bytes + size,
          lifetime_frames: state.lifetime_frames + chunks,
        )
      process.send(reply, Ok(Nil))
      actor.continue(pump(next))
    }
  }
}

fn pump(state: State) -> State {
  case state.lifecycle, state.input, state.queue {
    Accepting, None, [Frame(rest, reserved), ..tail] -> {
      let size = int.min(bit_array.byte_size(rest), feed_bytes)
      let slice =
        bit_array.slice(rest, 0, size) |> result.lazy_unwrap(fn() { <<>> })
      let remaining =
        bit_array.slice(rest, size, bit_array.byte_size(rest) - size)
        |> result.lazy_unwrap(fn() { <<>> })
      let cancel = weft.cancel_signal()
      let feed = state.session.feed
      let _ =
        weft.new_prepared([weft.managed(fn(_) { feed(slice) })])
        |> weft.deadline(credit_ms)
        |> weft.cancel_grace(1000)
        |> weft.cancel_with(cancel)
        |> weft.cancel_when_exits(process.self())
        |> weft.start_relayed(to: state.input_reports)
      State(
        ..state,
        queue: [Frame(remaining, reserved), ..tail],
        input: Some(Input(cancel, None)),
      )
    }
    _, _, _ -> state
  }
}

fn input_report(state: State, report: weft.Pulled(Nil, Nil)) -> State {
  case state.input {
    None -> state
    Some(Input(cancel, outcome)) -> {
      case report {
        weft.PulledOutcome(result) -> {
          let outcome = task_result(result)
          let next = State(..state, input: Some(Input(cancel, Some(outcome))))
          case outcome {
            Ok(Nil) -> next
            Error(Nil) ->
              fence(next, "the original input credit failed or expired")
          }
        }
        weft.AllDelivered -> {
          weft.cancel(cancel)
          case state.lifecycle, outcome, state.queue {
            Accepting, Some(Ok(Nil)), [Frame(<<>>, reserved), ..tail] ->
              pump(
                State(
                  ..state,
                  input: None,
                  queue: tail,
                  charged_bytes: state.charged_bytes - reserved,
                  charged_messages: state.charged_messages - 1,
                ),
              )
            Accepting, Some(Ok(Nil)), _ -> pump(State(..state, input: None))
            _, _, _ -> State(..state, input: None)
          }
        }
        weft.RunLost(_) ->
          fence(state, "the original input task lost its drain proof")
        weft.NotYet -> state
      }
    }
  }
}

fn offer_output(
  state: State,
  stream: Stream,
  bytes: BitArray,
  integrity: Integrity,
  reply: Subject(Result(Nil, String)),
) -> State {
  let size = bit_array.byte_size(bytes)
  case state.lifecycle, current_credit(state, stream), integrity {
    Accepting, None, Intact if size <= output_bytes -> {
      let nonce = reference.new()
      let self = state.self
      let cancel = weft.cancel_signal()
      let reports = case stream {
        Stdout -> state.stdout_reports
        Stderr -> state.stderr_reports
      }
      let _ =
        weft.new_prepared([
          weft.managed(fn(_) {
            let consumed = process.new_subject()
            process.send(self, CreditReady(stream, nonce, consumed, bytes))
            process.receive_forever(consumed)
            Ok(Nil)
          }),
        ])
        |> weft.deadline(credit_ms)
        |> weft.cancel_grace(1000)
        |> weft.cancel_with(cancel)
        |> weft.cancel_when_exits(process.self())
        |> weft.start_relayed(to: reports)
      let credit = Credit(nonce, Waiting, None, reply, cancel, None, None)
      put_credit(state, stream, Some(credit))
    }
    _, _, _ -> {
      process.send(
        reply,
        Error("the original output credit is invalid or truncated"),
      )
      fence(state, "the original output credit is invalid or truncated")
    }
  }
}

// A credit becomes deliverable only after its sole worker owns the wait subject.
// Subject ownership determines the mailbox, so creating it in this actor would
// send consumption to the actor rather than waking the managed credit task.
fn credit_ready(
  state: State,
  stream: Stream,
  nonce: reference.Reference,
  consumed: Subject(Nil),
  bytes: BitArray,
) -> State {
  case state.lifecycle, current_credit(state, stream) {
    Accepting, Some(Credit(consumed: None, ..) as credit)
      if credit.nonce == nonce && credit.phase == Waiting
    -> {
      process.send(
        state.events,
        Output(stream, bytes, Grant(Sink(state.self), stream, nonce)),
      )
      put_credit(
        state,
        stream,
        Some(Credit(..credit, consumed: Some(consumed))),
      )
    }
    _, _ -> state
  }
}

fn consume_output(
  state: State,
  stream: Stream,
  nonce: reference.Reference,
  caller: process.Pid,
  reply: Subject(Result(Nil, String)),
) -> State {
  case state.lifecycle, current_credit(state, stream) {
    Accepting, Some(Credit(consumed: Some(consumed), ..) as credit)
      if credit.nonce == nonce
      && credit.phase == Waiting
      && caller == state.owner
    -> {
      process.send(consumed, Nil)
      put_credit(
        state,
        stream,
        Some(Credit(..credit, phase: Consumed, consumer: Some(reply))),
      )
    }
    _, _ -> {
      process.send(
        reply,
        Error("the exact original output grant is not current"),
      )
      state
    }
  }
}

fn output_report(
  state: State,
  stream: Stream,
  report: weft.Pulled(Nil, Nil),
) -> State {
  case current_credit(state, stream) {
    None -> state
    Some(credit) -> {
      case report {
        weft.PulledOutcome(result) -> {
          let outcome = task_result(result)
          let next =
            put_credit(
              state,
              stream,
              Some(Credit(..credit, outcome: Some(outcome))),
            )
          case outcome {
            Ok(Nil) -> next
            Error(Nil) ->
              fence(next, "the original output consumption failed or expired")
          }
        }
        weft.AllDelivered -> {
          weft.cancel(credit.cancel)
          let answer = case state.lifecycle, credit.phase, credit.outcome {
            Accepting, Consumed, Some(Ok(Nil)) -> Ok(Nil)
            _, _, _ -> Error("original output consumption is fenced")
          }
          process.send(credit.publisher, answer)
          option.map(credit.consumer, fn(reply) { process.send(reply, answer) })
          put_credit(state, stream, None)
        }
        weft.RunLost(_) ->
          fence(state, "the original output task lost its drain proof")
        weft.NotYet -> state
      }
    }
  }
}

fn current_credit(state: State, stream: Stream) -> Option(Credit) {
  case stream {
    Stdout -> state.stdout
    Stderr -> state.stderr
  }
}

fn put_credit(state: State, stream: Stream, credit: Option(Credit)) -> State {
  case stream {
    Stdout -> State(..state, stdout: credit)
    Stderr -> State(..state, stderr: credit)
  }
}

fn task_result(outcome: weft.Outcome(Nil, Nil)) -> Result(Nil, Nil) {
  case outcome {
    weft.Completed(_, Nil) -> Ok(Nil)
    weft.Failed(_, Nil)
    | weft.Crashed(..)
    | weft.Abandoned(..)
    | weft.NeverStarted(..)
    | weft.DrainProofLost(..)
    | weft.CancellationUnconfirmed(..) -> Error(Nil)
  }
}

fn fence(state: State, reason: String) -> State {
  case state.lifecycle {
    Fenced -> state
    Accepting -> {
      shutdown(state, process.Normal)
      process.send(state.events, Failed(reason))
      State(..state, lifecycle: Fenced)
    }
  }
}

fn shutdown(state: State, _reason: process.ExitReason) -> Nil {
  case state.lifecycle {
    Fenced -> Nil
    Accepting -> {
      option.map(state.input, fn(input) { weft.cancel(input.cancel) })
      option.map(state.stdout, fn(credit) { weft.cancel(credit.cancel) })
      option.map(state.stderr, fn(credit) { weft.cancel(credit.cancel) })
      state.session.close()
    }
  }
}
