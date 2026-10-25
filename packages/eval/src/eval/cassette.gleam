//// A recording and a replaying provider transport: the replay lane's seam.
////
//// The replay lane claims one thing: under the same model outputs, the
//// harness produces the same requests. Nothing about model quality can be
//// read from it. Two transports carry that claim across the one seam the
//// provider layer already has, `provider/http.Transport`:
////
//// - `recording` wraps a real transport, forwards every request, and tees
////   each response into a tape keyed by the request's semantic digest
////   (`eval/normalise`).
//// - `replaying` answers a request with a recording of the same digest. If
////   there is none left, that is the lane's finding, not an error to repair:
////   the transport answers `RequestFailed` naming the divergence and never
////   hands back bytes recorded for a different request.
////
//// ## Why digests, not positions
////
//// A session runs several strands at once: the primary, the advisor, subagents,
//// the summarizer. The order in which their requests reach a transport depends
//// on the scheduler, so "the n-th request" names a different request from run to
//// run. Replay therefore matches by digest: each request takes the first
//// recording with an equal digest that no earlier request has taken. The
//// ordinal survives only for reporting, and for reading the tape in order.
////
//// ## What a tape holds
////
//// A response is stored verbatim. It is the model output being replayed, and a
//// thinking signature, an encrypted reasoning blob or a commit hash in it will
//// be echoed into a later request; one altered byte makes that request diverge.
//// So redaction is narrow. Only the exact credentials the request itself carried
//// (held in memory while the request runs, never written), and the vendor
//// prefixes `sk-`, `xai-`, `ghp_`, `gho_`, `ghs_`, `ghu_`, `github_pat_` and
//// `Bearer`, are replaced. A recording in which anything changed is marked
//// `Redacted`, and replay reports that rather than serving altered bytes.
//// Response headers other than the status and `content-type` are never stored.
////
//// ## Transport contract
////
//// Both transports honour it the way the native ChatGPT transport does: one
//// parked weft managed task per request, its scope's pid the drain witness,
//// nothing running (including the inner transport's preparation) before the
//// begin permit. A request is entered on the tape when it is prepared, so a
//// request cancelled at any point, even before begin, is recorded as
//// `Cancelled` and the ordinals stay contiguous. The tape and the replay log
//// live in weft actors; a call to one that has died fails the request cleanly
//// instead of crashing its task.
////
//// ## Tape file
////
//// One JSON object per line, every line carrying `"v":1`. The decoder is
//// total: any input that is not a valid tape is an `Error`, never a crash.
////
//// ## Flow
////
//// - `start_sink`, `recording`, `finish`: record a run
//// - `start_log`, `replaying`, `divergences`: replay it
//// - `tape_to_jsonl`, `tape_from_jsonl`: the file format
//// - `close_sink`, `close_log`: release the actors when the lane is done

import core/json.{type JsonValue}
import eval/normalise.{type Leaf}
import eval/wire
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import provider/http.{type HttpEvent, type HttpRequest, type Transport}
import weft
import weft/actor

/// One response event, mirroring `provider/http.HttpEvent` in a form the
/// tape codec owns, so a change to the provider type cannot silently change
/// the file format.
pub type Event {
  /// The status line arrived. Only `content-type` is kept of the headers.
  Status(status: Int, headers: List(#(String, String)))

  /// A fragment of the body arrived, split wherever the wire split it.
  Chunk(bytes: BitArray)

  /// The body ended normally.
  Ended

  /// The transport failed before the response completed.
  Failed(reason: String)

  /// A local admission boundary refused the request before dispatch.
  Refused(status: Int, body: BitArray)

  /// The request was cancelled, or never finished, so it has no response.
  Cancelled
}

/// Whether redaction changed any byte of a recording.
pub type Redaction {
  /// Every byte is as the transport delivered it.
  Verbatim

  /// A credential was replaced, so replaying these bytes would not reproduce
  /// the original response.
  Redacted
}

/// One request's recording.
pub type Recorded {
  Recorded(
    /// The request's position on the tape, counted from one, in the order the
    /// requests were prepared.
    ordinal: Int,
    /// The semantic digest of the request this response answered.
    digest: String,
    /// The request's leaves, kept so a divergence can name where it began.
    shape: List(Leaf),
    /// The response, ending in exactly one terminal event.
    events: List(Event),
    /// Whether the events are the transport's bytes or an edited copy.
    redaction: Redaction,
  )
}

/// An ordered tape of recordings, ordinals one through n with no gap.
pub type Tape {
  Tape(
    /// The recordings in ordinal order.
    recordings: List(Recorded),
  )
}

/// A request that did not match a recording it could replay.
pub type Divergence {
  Divergence(
    /// The request's position in the replay, counted from one.
    ordinal: Int,
    /// The digest of the nearest recording, empty when the tape is empty.
    expected: String,
    /// The digest of the request actually made.
    actual: String,
    /// Where the two first differ, redacted.
    summary: String,
  )
}

/// The recording side's owner of the growing tape.
pub opaque type Sink {
  Sink(subject: Subject(SinkMessage), pid: Pid)
}

/// The replaying side's owner of the request counter, the recordings already
/// taken, and the findings.
pub opaque type Log {
  Log(subject: Subject(LogMessage), pid: Pid)
}

type SinkMessage {
  Open(digest: String, shape: List(Leaf), reply: Subject(Int))
  Close(
    ordinal: Int,
    events: List(Event),
    redaction: Redaction,
    reply: Subject(Nil),
  )
  Abort(ordinal: Int, reply: Subject(Nil))
  Collect(reply: Subject(Tape))
  StopSink
}

type Pending {
  Pending(digest: String, shape: List(Leaf))
}

type SinkState {
  SinkState(next: Int, open: Dict(Int, Pending), recorded: List(Recorded))
}

type LogMessage {
  Claim(equal: List(Int), reply: Subject(#(Int, Option(Int))))
  Note(divergence: Divergence, reply: Subject(Nil))
  Findings(reply: Subject(List(Divergence)))
  StopLog
}

type LogState {
  LogState(next: Int, taken: Set(Int), found: List(Divergence))
}

/// How long a transport waits on the sink or log actor. They answer from
/// memory, so a miss means the actor is wedged and the request should fail
/// rather than wait.
const actor_wait_ms = 5000

const redacted_marker = "<redacted>"

/// Starts the actor that will own a recording's tape.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(sink) = cassette.start_sink()
/// assert cassette.finish(sink) == cassette.Tape([])
/// ```
///
pub fn start_sink() -> Result(Sink, String) {
  actor.new(SinkState(next: 1, open: dict.new(), recorded: []))
  |> actor.on_message(sink_message)
  |> actor.start
  |> result.map(fn(started) { Sink(started.data, started.pid) })
  |> result.replace_error("the tape sink did not start")
}

/// Starts the actor that will own a replay's counter and findings.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(log) = cassette.start_log()
/// assert cassette.divergences(log) == []
/// ```
///
pub fn start_log() -> Result(Log, String) {
  actor.new(LogState(next: 1, taken: set.new(), found: []))
  |> actor.on_message(log_message)
  |> actor.start
  |> result.map(fn(started) { Log(started.data, started.pid) })
  |> result.replace_error("the divergence log did not start")
}

/// Stops the sink and waits for it to exit. Requests prepared afterwards fail
/// with a `replay lane unavailable` diagnostic.
///
/// ## Examples
///
/// ```gleam
/// cassette.close_sink(sink)
/// ```
///
pub fn close_sink(sink: Sink) -> Nil {
  stop(sink.pid, fn() { process.send(sink.subject, StopSink) })
}

/// Stops the log and waits for it to exit. Requests prepared afterwards fail
/// with a `replay lane unavailable` diagnostic.
///
/// ## Examples
///
/// ```gleam
/// cassette.close_log(log)
/// ```
///
pub fn close_log(log: Log) -> Nil {
  stop(log.pid, fn() { process.send(log.subject, StopLog) })
}

/// Sends a stop message to an actor and waits for its exit.
fn stop(pid: Pid, send_stop: fn() -> Nil) -> Nil {
  let watch = process.monitor(pid)
  send_stop()

  let _ =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(_down) { Nil })
    |> process.selector_receive(actor_wait_ms)

  Nil
}

/// Everything recorded so far, in ordinal order.
///
/// A request still in flight is closed off as `Cancelled`: it has no response
/// yet, and an ordinal with no recording would leave a gap that no decoder
/// accepts. Call this once the trial has drained.
///
/// ## Examples
///
/// ```gleam
/// let tape = cassette.finish(sink)
/// ```
///
pub fn finish(sink: Sink) -> Tape {
  case ask(sink.subject, sink.pid, Collect) {
    Ok(tape) -> tape
    Error(_) -> Tape([])
  }
}

/// Every divergence the replay has found, in request order.
///
/// ## Examples
///
/// ```gleam
/// assert cassette.divergences(log) == []
/// ```
///
pub fn divergences(log: Log) -> List(Divergence) {
  ask(log.subject, log.pid, Findings)
  |> result.unwrap([])
}

/// A call to a weft actor that cannot crash its caller. The actor is monitored
/// for the duration, so a dead actor answers at once instead of after the wait,
/// and a wedged one after `actor_wait_ms`. `weft` has no monitored call against
/// a pre-existing pid yet (docs/weft.md names the gap), so this is the small
/// stand-in.
fn ask(
  subject: Subject(message),
  pid: Pid,
  make: fn(Subject(reply)) -> message,
) -> Result(reply, String) {
  let reply = process.new_subject()
  let watch = process.monitor(pid)
  process.send(subject, make(reply))

  let answer =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(watch, fn(_down) {
      Error("the tape actor exited")
    })
    |> process.selector_receive(actor_wait_ms)

  process.demonitor_process(watch)

  // The actor's own answer, which may itself be a refusal, or silence.
  case answer {
    Ok(result) -> result
    Error(Nil) -> Error("the tape actor did not answer")
  }
}

/// Applies one message to the tape owner's state. `Open` hands out the next
/// ordinal, `Close` and `Abort` end a request's entry, and `Collect` reads the
/// tape back with every unfinished entry closed off as cancelled.
fn sink_message(
  state: SinkState,
  message: SinkMessage,
) -> actor.Next(SinkState, SinkMessage) {
  // Each message is one step of a request's life on the tape, or the end of
  // the tape's own.
  case message {
    Open(digest:, shape:, reply:) -> {
      process.send(reply, state.next)
      actor.continue(
        SinkState(
          ..state,
          next: state.next + 1,
          open: dict.insert(state.open, state.next, Pending(digest:, shape:)),
        ),
      )
    }

    Close(ordinal:, events:, redaction:, reply:) -> {
      process.send(reply, Nil)
      actor.continue(file(state, ordinal, events, redaction))
    }

    Abort(ordinal:, reply:) -> {
      process.send(reply, Nil)
      actor.continue(file(state, ordinal, [Cancelled], Verbatim))
    }

    Collect(reply:) -> {
      let closed =
        dict.keys(state.open)
        |> list.fold(state, fn(so_far, ordinal) {
          file(so_far, ordinal, [Cancelled], Verbatim)
        })
      process.send(reply, Tape(ordered(closed.recorded)))
      actor.continue(state)
    }

    StopSink -> actor.stop()
  }
}

/// Moves an open entry to the tape. An entry already closed is left alone, so
/// the first of a response and a cancellation to arrive is the one recorded.
fn file(
  state: SinkState,
  ordinal: Int,
  events: List(Event),
  redaction: Redaction,
) -> SinkState {
  // Only an entry that is still open can be filed.
  case dict.get(state.open, ordinal) {
    Ok(Pending(digest:, shape:)) ->
      SinkState(..state, open: dict.delete(state.open, ordinal), recorded: [
        Recorded(ordinal:, digest:, shape:, events:, redaction:),
        ..state.recorded
      ])
    Error(Nil) -> state
  }
}

fn ordered(recorded: List(Recorded)) -> List(Recorded) {
  list.sort(recorded, fn(left, right) {
    int.compare(left.ordinal, right.ordinal)
  })
}

/// Applies one message to the replay's state. `Claim` counts a request and
/// takes the first equal-digest recording nobody has taken, `Note` files a
/// finding, and `Findings` reads them back.
fn log_message(
  state: LogState,
  message: LogMessage,
) -> actor.Next(LogState, LogMessage) {
  // The same three steps as the sink, for a replay.
  case message {
    Claim(equal:, reply:) -> {
      let chosen =
        list.find(equal, fn(ordinal) { !set.contains(state.taken, ordinal) })
        |> option.from_result
      process.send(reply, #(state.next, chosen))
      actor.continue(
        LogState(..state, next: state.next + 1, taken: case chosen {
          Some(ordinal) -> set.insert(state.taken, ordinal)
          None -> state.taken
        }),
      )
    }

    Note(divergence:, reply:) -> {
      process.send(reply, Nil)
      actor.continue(LogState(..state, found: [divergence, ..state.found]))
    }

    Findings(reply:) -> {
      process.send(reply, list.reverse(state.found))
      actor.continue(state)
    }

    StopLog -> actor.stop()
  }
}

/// A transport that forwards to `inner` and records every response.
///
/// `root` is the trial's workspace directory, normalised out of the request
/// digest. A request is entered on the tape when it is prepared, and its
/// response is filed when the terminal event passes through, before the
/// consumer sees that event. A request cancelled before it finishes is filed as
/// `Cancelled`. Credentials the request carried in its headers are held in
/// memory while it runs and redacted wherever they reappear in the response.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(sink) = cassette.start_sink()
/// let tee = cassette.recording(http.httpc_transport(), "/work/trial", sink)
/// ```
///
pub fn recording(inner: Transport, root: String, sink: Sink) -> Transport {
  http.Transport(prepare_streaming: fn(request, events) {
    let normalise.View(digest:, leaves: shape) = normalise.view(request, root)
    let secrets = credentials(request)
    let opened = ask(sink.subject, sink.pid, Open(digest, shape, _))

    parked(events, fn() { abort(sink, opened) }, fn(ledger) {
      case opened {
        Error(reason) -> unavailable(events, reason)
        Ok(ordinal) ->
          tee(inner, request, events, ledger, fn(seen) {
            let #(kept, redaction) = redact(seen, secrets)
            ask(sink.subject, sink.pid, Close(ordinal, kept, redaction, _))
          })
      }
    })
  })
}

/// Closes off a request's entry as cancelled, if it ever reached the tape.
fn abort(sink: Sink, opened: Result(Int, String)) -> Nil {
  // A request that never reached the tape has nothing to close off.
  case opened {
    Ok(ordinal) -> {
      let _ = ask(sink.subject, sink.pid, Abort(ordinal, _))
      Nil
    }
    Error(_) -> Nil
  }
}

/// Fails a request whose tape or log is gone, with a diagnosis, rather than
/// crashing its task.
fn unavailable(
  events: Subject(HttpEvent),
  reason: String,
) -> Result(Nil, String) {
  process.send(
    events,
    http.RequestFailed("replay lane unavailable: " <> reason),
  )
  Ok(Nil)
}

/// Prepares the inner request under the scope's custody, releases it, and
/// relays its events until the response ends. An inner transport that refuses
/// to prepare is still a response the lane must replay, so it is recorded as a
/// failure.
fn tee(
  inner: Transport,
  request: HttpRequest,
  events: Subject(HttpEvent),
  ledger: weft.Ledger,
  settle: fn(List(Event)) -> Result(Nil, String),
) -> Result(Nil, String) {
  let mid = process.new_subject()

  // Whether the inner transport can prepare decides whether there is a
  // response to relay or only a failure to record.
  case inner.prepare_streaming(request, mid) {
    Error(reason) -> {
      let _ = settle([Failed(reason)])
      process.send(events, http.RequestFailed(reason))
      Ok(Nil)
    }

    Ok(prepared) ->
      // The scope must hold the inner owner before the inner request is
      // released, or a crash in between would orphan a socket.
      case weft.adopt(ledger, prepared.running.owner, prepared.running.cancel) {
        weft.Refused -> Ok(Nil)
        weft.Adopted -> {
          let watch = process.monitor(prepared.running.owner)
          prepared.begin()
          relay(mid, watch, events, [], settle)
          Ok(Nil)
        }
      }
  }
}

// One inner event, or the inner owner's death. The owner dying before a
// terminal event is the transport contract's other way to end, and the tape
// records it as the failure it is.
type Arrival {
  Inner(HttpEvent)
  InnerDown
}

/// Forwards inner events to the consumer one at a time, accumulating the
/// recording, until a terminal event or the inner owner's death ends the
/// response.
fn relay(
  mid: Subject(HttpEvent),
  watch: process.Monitor,
  events: Subject(HttpEvent),
  seen: List(Event),
  settle: fn(List(Event)) -> Result(Nil, String),
) -> Nil {
  let arrival =
    process.new_selector()
    |> process.select_map(mid, Inner)
    |> process.select_specific_monitor(watch, fn(_down) { InnerDown })
    |> process.selector_receive_forever

  // Either the inner transport spoke, or its owner died without a terminal
  // event; the second is recorded as the failure it is.
  case arrival {
    InnerDown -> {
      let reason = "the recorded transport exited before the response ended"
      let _ = settle(list.reverse([Failed(reason), ..seen]))
      process.send(events, http.RequestFailed(reason))
    }

    Inner(event) -> {
      let mirrored = [from_http(event), ..seen]

      // A terminal event closes the recording; anything else is relayed and
      // the loop waits for the next.
      case terminal(event) {
        True -> {
          // The tape holds the response before the consumer can see its end,
          // and a tape that could not take it turns the end into a failure.
          case settle(list.reverse(mirrored)) {
            Ok(Nil) -> process.send(events, event)
            Error(reason) ->
              process.send(
                events,
                http.RequestFailed("replay lane unavailable: " <> reason),
              )
          }

          drain(watch)
        }
        False -> {
          process.send(events, event)
          relay(mid, watch, events, mirrored, settle)
        }
      }
    }
  }
}

// After the terminal event the scope still owes its caller the inner owner's
// exit; waiting here keeps this task, and so the witness, alive until then.
fn drain(watch: process.Monitor) -> Nil {
  process.new_selector()
  |> process.select_specific_monitor(watch, fn(_down) { Nil })
  |> process.selector_receive_forever
}

// What a replayed request will do once its begin permit arrives. The choice is
// made when the request is prepared, in the caller's own order, so the
// recording a request takes does not depend on how the tasks are scheduled.
type Plan {
  Serve(Recorded)
  Refuse(Divergence)
  Unavailable(String)
}

/// A transport that answers from a tape and reports every divergence.
///
/// A request takes the first recording with an equal semantic digest that no
/// earlier request has taken, so strands running together replay the same
/// whatever order they arrive in. If none is left the consumer gets
/// `RequestFailed("replay diverged at request n: ...")`, naming the nearest
/// recording, and the divergence is noted in `log`. A recording that was
/// redacted on write is reported, not served. Replay is not byte-exact and makes
/// no claim about model quality.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(log) = cassette.start_log()
/// let transport = cassette.replaying(tape, "/work/trial", log)
/// ```
///
pub fn replaying(tape: Tape, root: String, log: Log) -> Transport {
  http.Transport(prepare_streaming: fn(request, events) {
    let plan = plan(tape, normalise.view(request, root), log)

    parked(events, fn() { Nil }, fn(_ledger) { carry_out(plan, log, events) })
  })
}

/// Chooses the recording a request will take, or why it cannot take one.
fn plan(tape: Tape, view: normalise.View, log: Log) -> Plan {
  let equal =
    list.filter(tape.recordings, fn(recorded) { recorded.digest == view.digest })
  let ordinals = list.map(equal, fn(recorded) { recorded.ordinal })

  // The log decides which equal recording is free; the tape says what it holds.
  case ask(log.subject, log.pid, Claim(ordinals, _)) {
    Error(reason) -> Unavailable(reason)

    Ok(#(request_number, Some(ordinal))) ->
      case list.find(equal, fn(recorded) { recorded.ordinal == ordinal }) {
        Ok(recorded) -> served(recorded, request_number, view)
        Error(Nil) -> Unavailable("a claimed recording is missing")
      }

    Ok(#(request_number, None)) ->
      Refuse(nearest(tape, request_number, view, equal))
  }
}

/// Serves a recording unless redaction altered it, in which case the request
/// is refused and the alteration reported.
fn served(
  recorded: Recorded,
  request_number: Int,
  view: normalise.View,
) -> Plan {
  // Altered bytes must never pass for the original response.
  case recorded.redaction {
    Verbatim -> Serve(recorded)
    Redacted ->
      Refuse(Divergence(
        ordinal: request_number,
        expected: recorded.digest,
        actual: view.digest,
        summary: "recording "
          <> int.to_string(recorded.ordinal)
          <> " was redacted on write, so its bytes are not the original response",
      ))
  }
}

/// Describes the recording a request that matched nothing came nearest to:
/// the one agreeing longest before the first difference, preferring the one at
/// the same position.
fn nearest(
  tape: Tape,
  request_number: Int,
  view: normalise.View,
  equal: List(Recorded),
) -> Divergence {
  // An empty tape and a spent one are different findings from a changed
  // request, and each has its own words.
  case tape.recordings, equal {
    [], _ ->
      Divergence(
        ordinal: request_number,
        expected: "",
        actual: view.digest,
        summary: "the tape is empty",
      )

    _, [spent, ..] ->
      Divergence(
        ordinal: request_number,
        expected: spent.digest,
        actual: view.digest,
        summary: "every recording of this request was already replayed ("
          <> int.to_string(list.length(equal))
          <> " of "
          <> int.to_string(list.length(equal))
          <> ")",
      )

    [first, ..rest], [] -> {
      let best =
        list.fold(rest, first, fn(best, candidate) {
          case
            closeness(candidate, request_number, view)
            > closeness(best, request_number, view)
          {
            True -> candidate
            False -> best
          }
        })

      Divergence(
        ordinal: request_number,
        expected: best.digest,
        actual: view.digest,
        summary: normalise.summary(best.shape, view.leaves),
      )
    }
  }
}

/// Scores how near a recording is to a request: leading agreement first, then
/// sharing its position.
fn closeness(
  recorded: Recorded,
  request_number: Int,
  view: normalise.View,
) -> Int {
  // Sitting at the request's own position breaks a tie between recordings
  // that agree equally far.
  let same_place = case recorded.ordinal == request_number {
    True -> 1
    False -> 0
  }

  normalise.agreement(recorded.shape, view.leaves) * 2 + same_place
}

/// Does what the plan says once the begin permit arrives: deliver the recording,
/// report the divergence, or fail cleanly.
fn carry_out(
  plan: Plan,
  log: Log,
  events: Subject(HttpEvent),
) -> Result(Nil, String) {
  // A recording is delivered whole; a refusal is a finding and the consumer is
  // told, never given bytes recorded for another request.
  case plan {
    Serve(recorded) -> {
      list.each(deliverable(recorded.events), fn(event) {
        process.send(events, event)
      })
      Ok(Nil)
    }

    Refuse(divergence) ->
      case ask(log.subject, log.pid, Note(divergence, _)) {
        Ok(Nil) -> {
          process.send(
            events,
            http.RequestFailed(
              "replay diverged at request "
              <> int.to_string(divergence.ordinal)
              <> ": "
              <> divergence.summary,
            ),
          )
          Ok(Nil)
        }
        Error(reason) -> unavailable(events, reason)
      }

    Unavailable(reason) -> unavailable(events, reason)
  }
}

/// The recorded events as transport events, with a terminal appended when the
/// recording lacks one. A recording always ends in a terminal event, but a tape
/// file is edited by hand, and a consumer waiting on a stream with no end would
/// hang.
fn deliverable(events: List(Event)) -> List(HttpEvent) {
  let mirrored = list.map(events, to_http)

  // Only a recording whose last event is terminal can be delivered as is.
  case list.last(events) {
    Ok(Ended) | Ok(Failed(..)) | Ok(Refused(..)) | Ok(Cancelled) -> mirrored
    Ok(Status(..)) | Ok(Chunk(..)) | Error(Nil) ->
      list.append(mirrored, [
        http.RequestFailed("the recording ended without a terminal event"),
      ])
  }
}

fn terminal(event: HttpEvent) -> Bool {
  case event {
    http.ResponseEnd | http.RequestFailed(..) | http.RequestRefused(..) -> True
    http.ResponseStatus(..) | http.ResponseChunk(..) -> False
  }
}

/// Mirrors a transport event into the tape's own vocabulary.
fn from_http(event: HttpEvent) -> Event {
  case event {
    http.ResponseStatus(status:, headers:) -> Status(status:, headers:)
    http.ResponseChunk(chunk:) -> Chunk(chunk)
    http.ResponseEnd -> Ended
    http.RequestFailed(reason:) -> Failed(reason)
    http.RequestRefused(status:, body:) -> Refused(status:, body:)
  }
}

/// Mirrors a tape event back into the transport's vocabulary.
fn to_http(event: Event) -> HttpEvent {
  case event {
    Status(status:, headers:) -> http.ResponseStatus(status:, headers:)
    Chunk(bytes:) -> http.ResponseChunk(bytes)
    Ended -> http.ResponseEnd
    Failed(reason:) -> http.RequestFailed(reason)
    Refused(status:, body:) -> http.RequestRefused(status:, body:)
    Cancelled -> http.RequestFailed("the recorded request was cancelled")
  }
}

/// Parks one managed task per request, released by the begin permit, and
/// publishes its scope as the request's drain witness. Only the task can
/// receive the permit, so a request whose preparing process dies or whose owner
/// is cancelled first never runs `operation` at all. The scope's pid exits
/// normally once the task and every owner it adopted have stopped, and the
/// scope is cancelled when the consumer exits. `on_cancel` runs before the scope
/// is cancelled, so the recorder can close off the request's entry.
fn parked(
  events: Subject(HttpEvent),
  on_cancel: fn() -> Nil,
  operation: fn(weft.Ledger) -> Result(Nil, String),
) -> Result(http.PreparedRequest, String) {
  use consumer <- result.try(
    process.subject_owner(events)
    |> result.replace_error("the response consumer is not a live process"),
  )
  let ready = process.new_subject()
  let witnessed =
    weft.new_prepared([
      weft.managed(fn(ledger) {
        let begin = process.new_subject()
        process.send(ready, begin)
        process.receive_forever(begin)
        operation(ledger)
      }),
    ])
    |> weft.on_failure(weft.CancelSiblings)
    |> weft.cancel_when_exits(consumer)
    |> weft.start_witnessed
  let watch = process.monitor(weft.witness_pid(witnessed))
  let readiness =
    process.new_selector()
    |> process.select_map(ready, Ok)
    |> process.select_specific_monitor(watch, fn(_down) { Error(Nil) })
  let publication = process.selector_receive(readiness, 5000)
  process.demonitor_process(watch)

  // A scope that died before publishing its permit can never be released, so
  // it is cancelled rather than handed out as a request that would hang.
  case publication {
    Ok(Ok(begin)) ->
      Ok(
        http.PreparedRequest(
          running: http.RunningRequest(
            owner: weft.witness_pid(witnessed),
            cancel: fn() {
              on_cancel()
              weft.cancel_witnessed(witnessed)
            },
          ),
          begin: fn() { process.send(begin, Nil) },
        ),
      )
    Ok(Error(Nil)) | Error(Nil) -> {
      weft.cancel_witnessed(witnessed)
      Error("the replay lane could not park the request")
    }
  }
}

/// The values the request carried as credentials: header values whose names
/// say they are secret, and the token after `Bearer`. Too-short values are
/// dropped, since redacting a few characters would shred ordinary text.
fn credentials(request: HttpRequest) -> List(String) {
  request.headers
  |> list.filter(fn(header) { secret_header(header.0) })
  |> list.flat_map(fn(header) {
    [header.1, string.replace(header.1, "Bearer ", "")]
  })
  |> list.filter(fn(value) { string.drop_start(value, 7) != "" })
  |> list.unique
}

/// Whether a header name says its value is a credential.
fn secret_header(name: String) -> Bool {
  let folded = string.lowercase(name)

  list.any(
    ["auth", "key", "token", "secret", "cookie", "credential", "session"],
    fn(word) { string.contains(folded, word) },
  )
}

/// Redacts one recording's events and reports whether any byte changed.
/// Headers are reduced to `content-type`, which is not redaction: the rest were
/// never part of the response being replayed.
fn redact(
  events: List(Event),
  secrets: List(String),
) -> #(List(Event), Redaction) {
  let reduced = list.map(events, keep_content_type)
  let rewritten = list.map(reduced, redact_event(_, secrets))
  let chunks = joined_chunks(rewritten)
  let body = redact_joined(chunks, secrets)

  // Verbatim only when neither the pieces nor the joined body changed.
  case rewritten == reduced, body {
    True, Intact -> #(reduced, Verbatim)
    False, Intact -> #(rewritten, Redacted)
    _, Rewritten(replacement) -> #(collapse(rewritten, replacement), Redacted)
  }
}

/// Reduces a status event's headers to `content-type`; nothing else is stored.
fn keep_content_type(event: Event) -> Event {
  case event {
    Status(status:, headers:) ->
      Status(
        status:,
        headers: list.filter(headers, fn(header) {
          string.lowercase(header.0) == "content-type"
        }),
      )
    Chunk(..) | Ended | Failed(..) | Refused(..) | Cancelled -> event
  }
}

/// Redacts the failure reason or refusal body of one event.
fn redact_event(event: Event, secrets: List(String)) -> Event {
  case event {
    Failed(reason:) -> Failed(redact_text(reason, secrets))
    Refused(status:, body:) ->
      Refused(status:, body: redact_bytes(body, secrets))
    Status(..) | Chunk(..) | Ended | Cancelled -> event
  }
}

// What redaction made of the joined response body.
type Body {
  /// Nothing changed, so the wire's chunk boundaries survive.
  Intact

  /// The body changed; these bytes replace every chunk.
  Rewritten(BitArray)
}

/// The response body as the transport delivered it, chunks joined.
fn joined_chunks(events: List(Event)) -> BitArray {
  list.filter_map(events, fn(event) {
    case event {
      Chunk(bytes:) -> Ok(bytes)
      Status(..) | Ended | Failed(..) | Refused(..) | Cancelled -> Error(Nil)
    }
  })
  |> bit_array.concat
}

/// Redacts the joined body, so a credential split across two chunks is still
/// seen whole. A body that is not text is left as it is.
fn redact_joined(body: BitArray, secrets: List(String)) -> Body {
  // Bytes that are not UTF-8 cannot hold a textual credential the redactor
  // could find, and verbatim is the rule for everything it cannot find.
  case bit_array.to_string(body) {
    Ok(text) ->
      case redact_text(text, secrets) {
        redacted if redacted == text -> Intact
        redacted -> Rewritten(<<redacted:utf8>>)
      }
    Error(Nil) -> Intact
  }
}

fn redact_bytes(bytes: BitArray, secrets: List(String)) -> BitArray {
  case bit_array.to_string(bytes) {
    Ok(text) -> <<redact_text(text, secrets):utf8>>
    Error(Nil) -> bytes
  }
}

/// Replaces every chunk with one carrying `replacement`, at the position of the
/// first chunk.
fn collapse(events: List(Event), replacement: BitArray) -> List(Event) {
  let #(before, from_chunks) =
    list.split_while(events, fn(event) {
      case event {
        Chunk(..) -> False
        Status(..) | Ended | Failed(..) | Refused(..) | Cancelled -> True
      }
    })
  let after =
    list.filter(from_chunks, fn(event) {
      case event {
        Chunk(..) -> False
        Status(..) | Ended | Failed(..) | Refused(..) | Cancelled -> True
      }
    })

  list.flatten([before, [Chunk(replacement)], after])
}

const key_prefixes = [
  "sk-", "xai-", "ghp_", "gho_", "ghs_", "ghu_", "github_pat_",
]

/// Replaces the request's own credentials and every vendor-prefixed token.
fn redact_text(text: String, secrets: List(String)) -> String {
  let exact =
    list.fold(secrets, text, fn(so_far, secret) {
      string.replace(so_far, secret, redacted_marker)
    })
  let keyed =
    list.fold(key_prefixes, exact, fn(so_far, prefix) {
      redact_after(so_far, prefix, "")
    })

  redact_after(keyed, "Bearer ", "Bearer ")
}

/// Redacts the token that begins at each standalone occurrence of `prefix`,
/// writing `keep` in front of the marker. An occurrence inside a longer word, or
/// followed by nothing, is not a credential and is left alone.
fn redact_after(text: String, prefix: String, keep: String) -> String {
  case string.split(text, prefix) {
    [] -> text
    [first, ..rest] ->
      list.fold(rest, first, fn(kept, part) {
        let #(token, remainder) = split_token(part, "")

        // A prefix inside a longer word, or with no token after it, is prose.
        case token_character(string.slice(kept, -1, 1)) || token == "" {
          True -> kept <> prefix <> part
          False -> kept <> keep <> redacted_marker <> remainder
        }
      })
  }
}

/// Splits the run of credential characters off the front of `text`.
fn split_token(text: String, token: String) -> #(String, String) {
  // The token is the longest run of credential characters at the front.
  case string.pop_grapheme(text) {
    Ok(#(char, rest)) ->
      case token_character(char) {
        True -> split_token(rest, token <> char)
        False -> #(token, text)
      }
    Error(Nil) -> #(token, "")
  }
}

/// Whether a grapheme can be part of a credential token.
fn token_character(char: String) -> Bool {
  char != ""
  && {
    string.lowercase(char) != string.uppercase(char)
    || string.contains("0123456789-_.", char)
  }
}

/// Encodes a tape as JSON lines.
///
/// Redaction has already happened where the tape was recorded, so this is a
/// plain encoding and `tape_from_jsonl` reads back exactly what it wrote.
///
/// ## Examples
///
/// ```gleam
/// let jsonl = cassette.tape_to_jsonl(cassette.Tape([]))
/// assert jsonl == ""
/// ```
///
pub fn tape_to_jsonl(tape: Tape) -> String {
  tape.recordings
  |> list.map(fn(recorded) { json.to_string(encode_recorded(recorded)) <> "\n" })
  |> string.concat
}

/// Decodes a tape written by `tape_to_jsonl`.
///
/// Total: a malformed line, an unknown key or version, ordinals that are not
/// one through n in order, or a recording without exactly one terminal event
/// at its end is an `Error` naming the line, never a crash.
///
/// ## Examples
///
/// ```gleam
/// assert cassette.tape_from_jsonl("") == Ok(cassette.Tape([]))
/// let assert Error(_) = cassette.tape_from_jsonl("not json\n")
/// ```
///
pub fn tape_from_jsonl(text: String) -> Result(Tape, String) {
  let lines =
    string.split(text, "\n")
    |> list.filter(fn(line) { string.trim(line) != "" })

  use recordings <- result.try(
    list.index_map(lines, fn(line, index) { #(index + 1, line) })
    |> list.try_map(fn(numbered) {
      decode_line(numbered.1)
      |> result.try(fn(recorded) {
        // The file's order is its meaning, so a line out of place is damage.
        case recorded.ordinal == numbered.0 {
          True -> Ok(recorded)
          False -> Error("ordinal out of sequence")
        }
      })
      |> result.map_error(fn(reason) {
        "tape line " <> int.to_string(numbered.0) <> ": " <> reason
      })
    }),
  )

  Ok(Tape(recordings))
}

/// The JSON object for one recording, carrying the format version.
fn encode_recorded(recorded: Recorded) -> JsonValue {
  json.Object([
    #("v", json.Int(1)),
    #("ordinal", json.Int(recorded.ordinal)),
    #("digest", json.String(recorded.digest)),
    #("redaction", json.String(redaction_name(recorded.redaction))),
    #("shape", json.Array(list.map(recorded.shape, encode_leaf))),
    #("events", json.Array(list.map(recorded.events, encode_event))),
  ])
}

fn redaction_name(redaction: Redaction) -> String {
  case redaction {
    Verbatim -> "verbatim"
    Redacted -> "redacted"
  }
}

/// The JSON object for one request leaf.
fn encode_leaf(leaf: Leaf) -> JsonValue {
  json.Object([
    #("path", json.String(leaf.path)),
    #("length", json.Int(leaf.length)),
    #("fingerprint", json.String(leaf.fingerprint)),
  ])
}

/// The JSON object for one event, tagged by `t`.
fn encode_event(event: Event) -> JsonValue {
  case event {
    Status(status:, headers:) ->
      json.Object([
        #("t", json.String("status")),
        #("status", json.Int(status)),
        #(
          "headers",
          json.Array(
            list.map(headers, fn(header) {
              json.Array([json.String(header.0), json.String(header.1)])
            }),
          ),
        ),
      ])
    Chunk(bytes:) ->
      json.Object([
        #("t", json.String("chunk")),
        #("b64", json.String(bit_array.base64_encode(bytes, True))),
      ])
    Ended -> json.Object([#("t", json.String("end"))])
    Cancelled -> json.Object([#("t", json.String("cancelled"))])
    Failed(reason:) ->
      json.Object([
        #("t", json.String("failed")),
        #("reason", json.String(reason)),
      ])
    Refused(status:, body:) ->
      json.Object([
        #("t", json.String("refused")),
        #("status", json.Int(status)),
        #("b64", json.String(bit_array.base64_encode(body, True))),
      ])
  }
}

/// Decodes one tape line, refusing any version other than 1 and any recording
/// that does not end in a single terminal event.
fn decode_line(line: String) -> Result(Recorded, String) {
  use value <- result.try(
    json.parse(line) |> result.replace_error("not valid JSON"),
  )
  use fields <- result.try(
    wire.object(value, [
      "v", "ordinal", "digest", "redaction", "shape", "events",
    ]),
  )
  use version <- result.try(wire.int(fields, "v"))
  use Nil <- result.try(check_version(version))
  use ordinal <- result.try(wire.int(fields, "ordinal"))
  use digest <- result.try(wire.text(fields, "digest"))
  use redaction <- result.try(decode_redaction(fields))
  use shape <- result.try(wire.list_of(fields, "shape", decode_leaf))
  use events <- result.try(wire.list_of(fields, "events", decode_event))
  use Nil <- result.try(single_terminal(events))

  Ok(Recorded(ordinal:, digest:, shape:, events:, redaction:))
}

/// Only the version this module writes can be read back.
fn check_version(version: Int) -> Result(Nil, String) {
  // Version 1 is the sole format; anything else is refused by number.
  case version {
    1 -> Ok(Nil)
    _ -> Error("unsupported tape version " <> int.to_string(version))
  }
}

/// Decodes the `redaction` field, which holds exactly the two names written.
fn decode_redaction(fields: wire.Fields) -> Result(Redaction, String) {
  use name <- result.try(wire.text(fields, "redaction"))

  // Exactly the two names this module writes.
  case name {
    "verbatim" -> Ok(Verbatim)
    "redacted" -> Ok(Redacted)
    _ -> Error("\"redaction\" must be \"verbatim\" or \"redacted\"")
  }
}

/// Checks that a recording ends in exactly one terminal event. A recording
/// that does not end in its only terminal event could not have come from
/// `recording`, so a file claiming one has been damaged.
fn single_terminal(events: List(Event)) -> Result(Nil, String) {
  let terminals =
    list.count(events, fn(event) {
      case event {
        Ended | Failed(..) | Refused(..) | Cancelled -> True
        Status(..) | Chunk(..) -> False
      }
    })

  // The terminal must also be last, or the stream continues past its end.
  let last_is_terminal = case list.last(events) {
    Ok(Ended) | Ok(Failed(..)) | Ok(Refused(..)) | Ok(Cancelled) -> True
    Ok(Status(..)) | Ok(Chunk(..)) | Error(Nil) -> False
  }

  // One terminal, in last place, is the only well-formed ending.
  case terminals == 1 && last_is_terminal {
    True -> Ok(Nil)
    False -> Error("a recording must end in exactly one terminal event")
  }
}

/// Decodes one request leaf.
fn decode_leaf(value: JsonValue) -> Result(Leaf, String) {
  use fields <- result.try(
    wire.object(value, ["path", "length", "fingerprint"]),
  )
  use path <- result.try(wire.text(fields, "path"))
  use length <- result.try(wire.int_between(fields, "length", 0, 1_000_000_000))
  use fingerprint <- result.try(wire.text(fields, "fingerprint"))

  Ok(normalise.Leaf(path:, length:, fingerprint:))
}

/// Decodes one event by its `t` tag, refusing unknown tags.
fn decode_event(value: JsonValue) -> Result(Event, String) {
  use fields <- result.try(
    wire.object(value, ["t", "status", "headers", "b64", "reason"]),
  )
  use kind <- result.try(wire.text(fields, "t"))

  // The tag names the event; a tag this version does not know is refused
  // rather than skipped, since a skipped event is a changed response.
  case kind {
    "status" -> {
      use status <- result.try(wire.int(fields, "status"))
      use headers <- result.try(wire.list_of(fields, "headers", decode_header))
      Ok(Status(status:, headers:))
    }
    "chunk" -> {
      use bytes <- result.try(decode_bytes(fields))
      Ok(Chunk(bytes))
    }
    "end" -> Ok(Ended)
    "cancelled" -> Ok(Cancelled)
    "failed" -> {
      use reason <- result.try(wire.text(fields, "reason"))
      Ok(Failed(reason))
    }
    "refused" -> {
      use status <- result.try(wire.int(fields, "status"))
      use body <- result.try(decode_bytes(fields))
      Ok(Refused(status:, body:))
    }
    other ->
      Error("unknown event kind \"" <> string.slice(other, 0, 40) <> "\"")
  }
}

fn decode_bytes(fields: wire.Fields) -> Result(BitArray, String) {
  use encoded <- result.try(wire.text(fields, "b64"))

  bit_array.base64_decode(encoded)
  |> result.replace_error("\"b64\" is not base64")
}

/// Decodes one `[name, value]` header pair.
fn decode_header(value: JsonValue) -> Result(#(String, String), String) {
  case value {
    json.Array(items: [json.String(name), json.String(content)]) ->
      Ok(#(name, content))
    json.Array(..)
    | json.Object(..)
    | json.String(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> Error("a header must be a [name, value] pair of strings")
  }
}
