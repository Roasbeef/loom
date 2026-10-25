//// A recording and a replaying provider transport: the replay lane's seam.
////
//// The replay lane claims one thing: under the same model outputs, the
//// harness produces the same requests. Nothing about model quality can be
//// read from it. Two transports carry that claim across the one seam the
//// provider layer already has, `provider/http.Transport`:
////
//// - `recording` wraps a real transport, forwards every request, and tees
////   each response into a tape keyed by the request's ordinal and its
////   semantic digest (`eval/normalise`).
//// - `replaying` answers the n-th request from the n-th recording, but only
////   after the request's digest matches. A mismatch is the lane's finding,
////   not an error to repair: the transport answers `RequestFailed` naming
////   the divergence and never hands back recorded bytes to a request they
////   were not recorded for.
////
//// Both honour the transport contract by the same means as the native
//// ChatGPT transport: one parked weft managed task owns each request, its
//// scope's pid is the published drain witness, and nothing runs, including
//// the inner transport's preparation, until the begin permit arrives. A
//// cancellation before begin therefore starts nothing. The tape and the
//// divergence list live in weft actors so concurrent requests, should a
//// caller ever make them, cannot interleave an ordinal.
////
//// ## Tape file
////
//// One JSON object per line, every line carrying `"v":1`. A tape is scrubbed
//// as it is encoded, so a credential that a provider echoed in a body, a
//// header or a failure reason never reaches the file, and the decoder is
//// total: any input that is not a valid tape is an `Error`, never a crash.
////
//// ## Flow
////
//// - `start_sink`, `recording`, `finish`: record a run
//// - `start_log`, `replaying`, `divergences`: replay it
//// - `tape_to_jsonl`, `tape_from_jsonl`: the file format

import client/evolution/trace
import core/json.{type JsonValue}
import eval/normalise.{type Leaf}
import eval/wire
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import provider/http.{type HttpEvent, type HttpRequest, type Transport}
import weft
import weft/actor

/// One response event, mirroring `provider/http.HttpEvent` in a form the
/// tape codec owns, so a change to the provider type cannot silently change
/// the file format.
pub type Event {
  /// The status line and lowercase-named headers arrived.
  Status(status: Int, headers: List(#(String, String)))

  /// A fragment of the body arrived, split wherever the wire split it.
  Chunk(bytes: BitArray)

  /// The body ended normally.
  Ended

  /// The transport failed before the response completed.
  Failed(reason: String)

  /// A local admission boundary refused the request before dispatch.
  Refused(status: Int, body: BitArray)
}

/// One request's recording.
pub type Recorded {
  Recorded(
    /// The request's position in its trial, counted from one.
    ordinal: Int,
    /// The semantic digest of the request this response answered.
    digest: String,
    /// The request's leaves, kept so a divergence can name where it began.
    shape: List(Leaf),
    /// The response, ending in exactly one terminal event.
    events: List(Event),
  )
}

/// An ordered tape of recordings, ordinals one through n with no gap.
pub type Tape {
  Tape(
    /// The recordings in request order.
    recordings: List(Recorded),
  )
}

/// A request that did not match its recording.
pub type Divergence {
  Divergence(
    /// The request's position in the replay, counted from one.
    ordinal: Int,
    /// The digest recorded for that position, empty past the end of the tape.
    expected: String,
    /// The digest of the request actually made.
    actual: String,
    /// Where the two first differ, redacted.
    summary: String,
  )
}

/// The recording side's owner of the growing tape.
pub opaque type Sink {
  Sink(subject: Subject(SinkMessage))
}

/// The replaying side's owner of the request counter and the findings.
pub opaque type Log {
  Log(subject: Subject(LogMessage))
}

type SinkMessage {
  Reserve(reply: Subject(Int))
  Append(recorded: Recorded, reply: Subject(Nil))
  Collect(reply: Subject(Tape))
}

type SinkState {
  SinkState(next: Int, recorded: List(Recorded))
}

type LogMessage {
  Take(reply: Subject(Int))
  Note(divergence: Divergence, reply: Subject(Nil))
  Findings(reply: Subject(List(Divergence)))
}

type LogState {
  LogState(next: Int, found: List(Divergence))
}

/// How long a transport waits on the sink or log actor. They answer from
/// memory, so a miss means the actor is gone and the request should crash
/// loudly rather than wait.
const actor_wait_ms = 5000

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
  actor.new(SinkState(next: 1, recorded: []))
  |> actor.on_message(sink_message)
  |> actor.start
  |> result.map(fn(started) { Sink(started.data) })
  |> result.replace_error("the tape sink did not start")
}

/// Starts the actor that will own a replay's counter and divergences.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(log) = cassette.start_log()
/// assert cassette.divergences(log) == []
/// ```
///
pub fn start_log() -> Result(Log, String) {
  actor.new(LogState(next: 1, found: []))
  |> actor.on_message(log_message)
  |> actor.start
  |> result.map(fn(started) { Log(started.data) })
  |> result.replace_error("the divergence log did not start")
}

/// Everything recorded so far, in request order.
///
/// A request still in flight is absent: it joins the tape when its terminal
/// event arrives, so call this once the trial has drained.
///
/// ## Examples
///
/// ```gleam
/// let tape = cassette.finish(sink)
/// ```
///
pub fn finish(sink: Sink) -> Tape {
  actor.call(sink.subject, waiting: actor_wait_ms, sending: Collect)
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
  actor.call(log.subject, waiting: actor_wait_ms, sending: Findings)
}

/// Applies one message to the tape owner's state. `Reserve` hands out ordinals in
/// request order, `Append` files a finished recording, and `Collect` answers with
/// the tape sorted by ordinal.
/// A request's ordinal is reserved when it begins, not when it ends, so the
/// tape keeps request order even if a later request were to finish first.
fn sink_message(
  state: SinkState,
  message: SinkMessage,
) -> actor.Next(SinkState, SinkMessage) {
  // Each message is one step of the tape's life: reserve a slot, file a
  // finished response, or read the whole tape back.
  case message {
    Reserve(reply:) -> {
      process.send(reply, state.next)
      actor.continue(SinkState(..state, next: state.next + 1))
    }

    Append(recorded:, reply:) -> {
      process.send(reply, Nil)
      actor.continue(SinkState(..state, recorded: [recorded, ..state.recorded]))
    }

    Collect(reply:) -> {
      let ordered =
        list.sort(state.recorded, fn(left, right) {
          int.compare(left.ordinal, right.ordinal)
        })
      process.send(reply, Tape(ordered))
      actor.continue(state)
    }
  }
}

/// Applies one message to the replay's state: `Take` hands out the next request
/// ordinal, `Note` files a divergence, and `Findings` answers with them in order.
fn log_message(
  state: LogState,
  message: LogMessage,
) -> actor.Next(LogState, LogMessage) {
  // The same three steps for a replay: count a request, file a finding, or
  // read the findings back.
  case message {
    Take(reply:) -> {
      process.send(reply, state.next)
      actor.continue(LogState(..state, next: state.next + 1))
    }

    Note(divergence:, reply:) -> {
      process.send(reply, Nil)
      actor.continue(LogState(..state, found: [divergence, ..state.found]))
    }

    Findings(reply:) -> {
      process.send(reply, list.reverse(state.found))
      actor.continue(state)
    }
  }
}

/// A transport that forwards to `inner` and records every response.
///
/// `root` is the trial's workspace directory, normalised out of the request
/// digest. The recording is appended when a request's terminal event passes
/// through, before the consumer sees that event, so a consumer that has seen
/// the end of the response can already `finish` a tape containing it. A
/// cancelled request is never recorded.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(sink) = cassette.start_sink()
/// let tee = cassette.recording(http.httpc_transport(), "/work/trial", sink)
/// ```
///
pub fn recording(inner: Transport, root: String, sink: Sink) -> Transport {
  let tape = sink.subject

  http.Transport(prepare_streaming: fn(request, events) {
    parked(events, fn(ledger) {
      let ordinal = actor.call(tape, waiting: actor_wait_ms, sending: Reserve)
      let normalise.View(digest:, leaves: shape) = normalise.view(request, root)
      let settle = fn(recorded: List(Event)) {
        let entry = Recorded(ordinal:, digest:, shape:, events: recorded)
        actor.call(tape, waiting: actor_wait_ms, sending: Append(entry, _))
      }

      tee(inner, request, events, ledger, settle)
    })
  })
}

/// Prepares the inner request under the scope's custody, releases it, and relays
/// its events until the response ends. An inner transport that refuses to prepare
/// is still a response the lane must replay, so it is recorded as a failure.
/// Prepares the inner request under the scope's custody, lets it loose, and
/// relays its events. An inner transport that refuses to prepare is still a
/// response the lane must be able to replay, so it is recorded as a failure.
fn tee(
  inner: Transport,
  request: HttpRequest,
  events: Subject(HttpEvent),
  ledger: weft.Ledger,
  settle: fn(List(Event)) -> Nil,
) -> Result(Nil, String) {
  let mid = process.new_subject()

  // Whether the inner transport can prepare decides whether there is a
  // response to relay or only a failure to record.
  case inner.prepare_streaming(request, mid) {
    Error(reason) -> {
      settle([Failed(reason)])
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
/// recording, until a terminal event or the inner owner's death ends the response.
fn relay(
  mid: Subject(HttpEvent),
  watch: process.Monitor,
  events: Subject(HttpEvent),
  seen: List(Event),
  settle: fn(List(Event)) -> Nil,
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
      settle(list.reverse([Failed(reason), ..seen]))
      process.send(events, http.RequestFailed(reason))
    }

    Inner(event) -> {
      let mirrored = [from_http(event), ..seen]

      // A terminal event closes the recording; anything else is relayed and
      // the loop waits for the next.
      case terminal(event) {
        True -> {
          // The tape holds the response before the consumer can see its end.
          settle(list.reverse(mirrored))
          process.send(events, event)
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

/// A transport that answers from a tape and reports every divergence.
///
/// The n-th request is compared with the n-th recording by semantic digest.
/// On a match the recorded events are delivered. On a mismatch, or for a
/// request beyond the end of the tape, nothing recorded is delivered: the
/// consumer gets `RequestFailed("replay diverged at request n: ...")` and the
/// divergence is noted in `log`. Replay is not byte-exact and makes no claim
/// about model quality.
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
    parked(events, fn(_ledger) {
      let ordinal =
        actor.call(log.subject, waiting: actor_wait_ms, sending: Take)
      let view = normalise.view(request, root)

      // A matching recording is delivered whole; anything else is a finding
      // and the consumer is told, never given bytes recorded for another
      // request.
      case compare(tape, ordinal, view) {
        Ok(recorded) ->
          list.each(deliverable(recorded.events), fn(event) {
            process.send(events, event)
          })
        Error(divergence) -> {
          actor.call(log.subject, waiting: actor_wait_ms, sending: Note(
            divergence,
            _,
          ))
          process.send(
            events,
            http.RequestFailed(
              "replay diverged at request "
              <> int.to_string(ordinal)
              <> ": "
              <> divergence.summary,
            ),
          )
        }
      }

      Ok(Nil)
    })
  })
}

/// Looks up the recording for this ordinal and checks its digest against the
/// request actually made. A missing recording and a changed digest are both
/// divergences, never a replay.
fn compare(
  tape: Tape,
  ordinal: Int,
  actual: normalise.View,
) -> Result(Recorded, Divergence) {
  // The ordinal selects a recording, and running off the tape is a finding.
  case list.drop(tape.recordings, ordinal - 1) {
    [] ->
      Error(Divergence(
        ordinal:,
        expected: "",
        actual: actual.digest,
        summary: "the request is beyond the tape, which holds "
          <> int.to_string(list.length(tape.recordings))
          <> " requests",
      ))

    [recorded, ..] ->
      // Equal digests are the only evidence the request is the recorded one.
      case recorded.digest == actual.digest {
        True -> Ok(recorded)
        False ->
          Error(Divergence(
            ordinal:,
            expected: recorded.digest,
            actual: actual.digest,
            summary: normalise.summary(recorded.shape, actual.leaves),
          ))
      }
  }
}

/// The recorded events as transport events, with a terminal appended when the
/// recording lacks one.
/// A recording always ends in a terminal event, but a tape file is edited by
/// hand, and a consumer waiting on a stream with no end would hang. Supplying
/// the missing terminal turns that into a diagnosed failure.
fn deliverable(events: List(Event)) -> List(HttpEvent) {
  let mirrored = list.map(events, to_http)

  // Only a recording whose last event is terminal can be delivered as is.
  case list.last(events) {
    Ok(Ended) | Ok(Failed(..)) | Ok(Refused(..)) -> mirrored
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
  }
}

/// Parks one managed task per request, released by the begin permit, and
/// publishes its scope as the request's drain witness.
/// One parked managed task per request, released by the begin permit. Only
/// the task can receive the permit, so a request whose preparing process dies
/// or whose owner is cancelled first never runs `operation` at all. The scope
/// is the drain witness: its pid exits normally once the task and every owner
/// it adopted have stopped, and it is cancelled when the consumer exits.
fn parked(
  events: Subject(HttpEvent),
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
            cancel: fn() { weft.cancel_witnessed(witnessed) },
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

/// Encodes a tape as JSON lines, scrubbing credentials first.
///
/// Every text a provider controls (chunks, header values, failure reasons)
/// passes through the harness credential scrubber. A body is scrubbed whole,
/// so a secret split across two chunks is still found; when nothing needed
/// scrubbing the original chunk boundaries are kept, and otherwise the
/// scrubbed body is written as one chunk.
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
  |> list.map(fn(recorded) {
    recorded
    |> scrub_recorded
    |> encode_recorded
    |> json.to_string
  })
  |> list.map(fn(line) { line <> "\n" })
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

fn scrub_recorded(recorded: Recorded) -> Recorded {
  Recorded(..recorded, events: scrub_events(recorded.events))
}

// What the scrubber made of the joined response body.
type Body {
  /// Nothing needed scrubbing, so the wire's chunk boundaries survive.
  Intact

  /// The body changed or could not be read; these bytes replace every chunk.
  Rewritten(BitArray)
}

/// Scrubs the joined response body, so a secret split across two chunks is
/// still seen whole.
fn scrub_joined(body: BitArray) -> Body {
  // A body that is not text cannot be scrubbed, so it is withheld.
  case bit_array.to_string(body) {
    Ok(text) ->
      case scrub_body(text) == text {
        True -> Intact
        False -> Rewritten(<<scrub_body(text):utf8>>)
      }
    Error(Nil) -> Rewritten(<<"[non-UTF-8 body withheld]":utf8>>)
  }
}

/// Scrubs every text a provider controls in one recording's events.
/// Chunks are joined, scrubbed as one body, and kept as they were when the
/// scrubber changed nothing. A body that is not UTF-8 cannot be scrubbed, so
/// it is withheld rather than written.
fn scrub_events(events: List(Event)) -> List(Event) {
  let chunks =
    list.filter_map(events, fn(event) {
      case event {
        Chunk(bytes:) -> Ok(bytes)
        Status(..) | Ended | Failed(..) | Refused(..) -> Error(Nil)
      }
    })
  let scrubbed = scrub_joined(bit_array.concat(chunks))
  let cleaned = list.map(events, scrub_metadata)

  // With no chunks, or nothing scrubbed, only the metadata was cleaned.
  case chunks, scrubbed {
    [], _ | _, Intact -> cleaned
    [_, ..], Rewritten(replacement) -> collapse(cleaned, replacement)
  }
}

/// Replaces every chunk with one carrying `replacement`, at the position of the
/// first chunk.
/// Replaces every chunk with one, at the position of the first, so a damaged
/// tape with scattered chunks still leaves none of the original text behind.
fn collapse(events: List(Event), replacement: BitArray) -> List(Event) {
  let #(before, from_chunks) =
    list.split_while(events, fn(event) {
      case event {
        Chunk(..) -> False
        Status(..) | Ended | Failed(..) | Refused(..) -> True
      }
    })
  let after =
    list.filter(from_chunks, fn(event) {
      case event {
        Chunk(..) -> False
        Status(..) | Ended | Failed(..) | Refused(..) -> True
      }
    })

  list.flatten([before, [Chunk(replacement)], after])
}

/// Scrubs the header values, failure reason or refusal body of one event.
fn scrub_metadata(event: Event) -> Event {
  case event {
    Status(status:, headers:) ->
      Status(
        status:,
        headers: list.map(headers, fn(header) {
          #(header.0, scrub_body(header.1))
        }),
      )
    Failed(reason:) -> Failed(scrub_body(reason))
    Refused(status:, body:) -> Refused(status:, body: scrub_bytes(body))
    Chunk(..) | Ended -> event
  }
}

fn scrub_bytes(bytes: BitArray) -> BitArray {
  case bit_array.to_string(bytes) {
    Ok(text) -> <<scrub_body(text):utf8>>
    Error(Nil) -> <<"[non-UTF-8 body withheld]":utf8>>
  }
}

/// Scrubs credential-shaped tokens from text, a line at a time.
/// The scrubber reads at most 16 KiB of a string and would clip the rest, so
/// the body goes through it a line at a time. A line too long for the scrubber
/// is withheld whole: writing a credential is worse than losing a line.
fn scrub_body(text: String) -> String {
  string.split(text, "\n")
  |> list.map(fn(line) {
    case string.drop_start(line, scrub_line_limit) != "" {
      True -> "[line withheld: too long to scrub]"
      False -> trace.scrub_excerpt(line, scrub_line_limit * 4)
    }
  })
  |> string.join("\n")
}

const scrub_line_limit = 16_000

/// The JSON object for one recording, carrying the format version.
fn encode_recorded(recorded: Recorded) -> JsonValue {
  json.Object([
    #("v", json.Int(1)),
    #("ordinal", json.Int(recorded.ordinal)),
    #("digest", json.String(recorded.digest)),
    #("shape", json.Array(list.map(recorded.shape, encode_leaf))),
    #("events", json.Array(list.map(recorded.events, encode_event))),
  ])
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
    wire.object(value, ["v", "ordinal", "digest", "shape", "events"]),
  )
  use version <- result.try(wire.int(fields, "v"))
  use Nil <- result.try(check_version(version))
  use ordinal <- result.try(wire.int(fields, "ordinal"))
  use digest <- result.try(wire.text(fields, "digest"))
  use shape <- result.try(wire.list_of(fields, "shape", decode_leaf))
  use events <- result.try(wire.list_of(fields, "events", decode_event))
  use Nil <- result.try(single_terminal(events))

  Ok(Recorded(ordinal:, digest:, shape:, events:))
}

/// Only the version this module writes can be read back.
fn check_version(version: Int) -> Result(Nil, String) {
  // Version 1 is the sole format; anything else is refused by number.
  case version {
    1 -> Ok(Nil)
    _ -> Error("unsupported tape version " <> int.to_string(version))
  }
}

/// Checks that a recording ends in exactly one terminal event.
/// A recording that does not end in its only terminal event could not have
/// come from `recording`, so a file claiming one has been damaged.
fn single_terminal(events: List(Event)) -> Result(Nil, String) {
  let terminals =
    list.count(events, fn(event) {
      case event {
        Ended | Failed(..) | Refused(..) -> True
        Status(..) | Chunk(..) -> False
      }
    })

  // Exactly one terminal, and it is the last event.
  case terminals, list.last(events) {
    1, Ok(Ended) | 1, Ok(Failed(..)) | 1, Ok(Refused(..)) -> Ok(Nil)
    _, _ -> Error("a recording must end in exactly one terminal event")
  }
}

/// Decodes one request leaf.
fn decode_leaf(value: JsonValue) -> Result(Leaf, String) {
  use fields <- result.try(
    wire.object(value, ["path", "length", "fingerprint"]),
  )
  use path <- result.try(wire.text(fields, "path"))
  use length <- result.try(wire.int(fields, "length"))
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
