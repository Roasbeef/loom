//// Tests for the recording and replaying transports: determinism, matching by
//// digest, the divergence finding, redaction, the transport contract, and the
//// tape codec.

import eval/cassette.{type Tape}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/string
import provider/http.{
  type HttpEvent, type HttpRequest, type PreparedRequest, type Transport,
  HttpRequest, RequestFailed, ResponseChunk, ResponseEnd, ResponseStatus,
}
import qcheck

const codec_seed = 17

const root = "/work/trial"

const signature =
  "Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFla"

type Command {
  Begin
  Cancel
  CreatorExited
}

// Whether the scripted inner transport ends its response or leaves it open
// until it is cancelled.
type Hold {
  Finish
  Stall
}

// A minimal inner transport. Its parked owner honours the same contract the
// real ones do: nothing runs until begin, a cancel before begin runs nothing,
// and a creator that dies first releases the owner. Every start is counted on
// `started`, so a test can prove the inner transport was never touched.
fn scripted(
  script: fn(HttpRequest) -> List(HttpEvent),
  hold: Hold,
  started: Subject(Nil),
) -> Transport {
  http.Transport(prepare_streaming: fn(request, subject) {
    let creator = process.self()
    let ready = process.new_subject()
    let owner =
      process.spawn_unlinked(fn() {
        let control = process.new_subject()
        let creator_monitor = process.monitor(creator)
        process.send(ready, control)
        let command =
          process.new_selector()
          |> process.select_map(control, fn(command) { command })
          |> process.select_specific_monitor(creator_monitor, fn(_down) {
            CreatorExited
          })
          |> process.selector_receive_forever
        process.demonitor_process(creator_monitor)

        case command {
          Begin -> {
            process.send(started, Nil)
            list.each(script(request), fn(event) {
              process.send(subject, event)
            })
            case hold {
              Stall -> process.receive_forever(control)
              Finish -> Cancel
            }
            Nil
          }
          Cancel | CreatorExited -> Nil
        }
      })
    let control = process.receive_forever(ready)

    Ok(
      http.PreparedRequest(
        running: http.RunningRequest(owner:, cancel: fn() {
          process.send(control, Cancel)
        }),
        begin: fn() { process.send(control, Begin) },
      ),
    )
  })
}

fn exchange() -> List(HttpEvent) {
  [
    ResponseStatus(200, [#("content-type", "text/event-stream")]),
    ResponseChunk(<<"data: one\n\n":utf8>>),
    ResponseChunk(<<"data: two\n\n":utf8>>),
    ResponseEnd,
  ]
}

fn fixed(events: List(HttpEvent)) -> fn(HttpRequest) -> List(HttpEvent) {
  fn(_request) { events }
}

fn request_saying(system: String, content: String) -> HttpRequest {
  HttpRequest(
    method: "POST",
    url: "https://api.example.test/v1/messages",
    headers: [#("x-api-key", "sk-ant-api03-HEADERSECRET")],
    body: "{\"system\":\""
      <> system
      <> "\",\"messages\":[{\"role\":\"user\",\"content\":\""
      <> content
      <> "\"}]}",
  )
}

fn request(system: String) -> HttpRequest {
  request_saying(system, "list /work/trial")
}

fn terminal(event: HttpEvent) -> Bool {
  case event {
    ResponseEnd | RequestFailed(..) | http.RequestRefused(..) -> True
    ResponseStatus(..) | ResponseChunk(..) -> False
  }
}

fn receive_until_terminal(
  subject: Subject(HttpEvent),
  seen: List(HttpEvent),
) -> List(HttpEvent) {
  let assert Ok(event) = process.receive(subject, within: 3000)
    as "a transport must deliver a terminal event"

  case terminal(event) {
    True -> list.reverse([event, ..seen])
    False -> receive_until_terminal(subject, [event, ..seen])
  }
}

fn await_exit(prepared: PreparedRequest) -> Nil {
  let watch = process.monitor(prepared.running.owner)
  let assert Ok(Nil) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(_down) { Nil })
    |> process.selector_receive(within: 3000)
    as "the owner must exit"
  Nil
}

// A request prepared but not yet released.
fn prepare(
  transport: Transport,
  request: HttpRequest,
) -> #(Subject(HttpEvent), PreparedRequest) {
  let subject = process.new_subject()
  let assert Ok(prepared) = transport.prepare_streaming(request, subject)
  #(subject, prepared)
}

// Releases a prepared request, reads it to its end, and waits for the owner's
// normal exit, which is the drain acknowledgement the contract promises.
fn run(pair: #(Subject(HttpEvent), PreparedRequest)) -> List(HttpEvent) {
  let watch = process.monitor({ pair.1 }.running.owner)
  { pair.1 }.begin()
  let events = receive_until_terminal(pair.0, [])
  let assert Ok(Nil) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(_down) { Nil })
    |> process.selector_receive(within: 3000)
    as "the owner must exit after the terminal event"

  events
}

fn collect(transport: Transport, request: HttpRequest) -> List(HttpEvent) {
  run(prepare(transport, request))
}

fn recorder(
  script: fn(HttpRequest) -> List(HttpEvent),
) -> #(Transport, cassette.Sink) {
  let assert Ok(sink) = cassette.start_sink()

  #(
    cassette.recording(
      scripted(script, Finish, process.new_subject()),
      root,
      sink,
    ),
    sink,
  )
}

fn record(system: String) -> Tape {
  let #(transport, sink) = recorder(fixed(exchange()))

  assert collect(transport, request(system)) == exchange()

  cassette.finish(sink)
}

fn replayer(tape: Tape) -> #(Transport, cassette.Log) {
  let assert Ok(log) = cassette.start_log()

  #(cassette.replaying(tape, root, log), log)
}

pub fn replay_is_deterministic_test() {
  let tape = record("You are careful")
  let #(first, log) = replayer(tape)
  let #(second, log_two) = replayer(tape)
  let one = collect(first, request("You are careful"))
  let two = collect(second, request("You are careful"))

  assert one == exchange()
  assert one == two
  assert cassette.divergences(log) == []
  assert cassette.divergences(log_two) == []
}

pub fn pack_change_diverges_at_first_request_test() {
  let tape = record("You are careful")
  let #(transport, log) = replayer(tape)
  let events = collect(transport, request("You are careless"))

  let assert [RequestFailed(reason)] = events
  assert string.contains(reason, "replay diverged at request 1")
  assert string.contains(reason, "system")

  let assert [divergence] = cassette.divergences(log)
  assert divergence.ordinal == 1
  assert divergence.expected != divergence.actual
  assert string.contains(divergence.summary, "body.\"system\"")
  assert !string.contains(divergence.summary, "careless")
}

pub fn beyond_tape_is_divergence_test() {
  let tape = record("You are careful")
  let #(transport, log) = replayer(tape)

  assert collect(transport, request("You are careful")) == exchange()

  let assert [RequestFailed(reason)] =
    collect(transport, request("You are careful"))
  assert string.contains(reason, "replay diverged at request 2")

  let assert [divergence] = cassette.divergences(log)
  assert divergence.ordinal == 2
  assert string.contains(divergence.summary, "already replayed")

  let #(empty, empty_log) = replayer(cassette.Tape([]))
  let assert [RequestFailed(_)] = collect(empty, request("x"))
  let assert [empty_divergence] = cassette.divergences(empty_log)
  assert empty_divergence.summary == "the tape is empty"
}

pub fn replay_ignores_root_and_credentials_test() {
  let tape = record("You are careful")
  let assert Ok(log) = cassette.start_log()
  let moved =
    HttpRequest(
      ..request("You are careful"),
      headers: [#("x-api-key", "another-key")],
      body: string.replace(request("You are careful").body, root, "/else/where"),
    )

  assert collect(cassette.replaying(tape, "/else/where", log), moved)
    == exchange()
  assert cassette.divergences(log) == []
}

pub fn tape_is_scrubbed_test() {
  let planted = [
    ResponseStatus(200, [
      #("content-type", "text/event-stream"),
      #("set-cookie", "session=COOKIEVALUE"),
    ]),
    ResponseChunk(<<"data: hello sk-ant-api03-PLAN":utf8>>),
    ResponseChunk(<<"TEDACROSSCHUNKS echo plainheaderkey12345\n\n":utf8>>),
    ResponseChunk(<<"data: fine Bearer other0123456789\n\n":utf8>>),
    ResponseEnd,
  ]
  let #(transport, sink) = recorder(fixed(planted))
  let keyed =
    HttpRequest(..request("s"), headers: [
      #("x-api-key", "plainheaderkey12345"),
      #("authorization", "Bearer abcdef0123456789"),
    ])
  let _ = collect(transport, keyed)
  let tape = cassette.finish(sink)
  let jsonl = cassette.tape_to_jsonl(tape)

  assert !string.contains(jsonl, "PLAN")
  assert !string.contains(jsonl, "ACROSSCHUNKS")
  assert !string.contains(jsonl, "plainheaderkey12345")
  assert !string.contains(jsonl, "abcdef0123456789")
  assert !string.contains(jsonl, "other0123456789")
  assert !string.contains(jsonl, "COOKIEVALUE")
  assert !string.contains(jsonl, "set-cookie")

  let assert [recorded] = tape.recordings
  assert recorded.redaction == cassette.Redacted

  let body =
    list.filter_map(recorded.events, fn(event) {
      case event {
        cassette.Chunk(bytes:) -> bit_array.to_string(bytes)
        cassette.Status(..)
        | cassette.Ended
        | cassette.Failed(..)
        | cassette.Refused(..)
        | cassette.Cancelled -> Error(Nil)
      }
    })
    |> string.concat

  assert string.contains(body, "data: hello")
  assert string.contains(body, "data: fine Bearer <redacted>")

  // Altered bytes are reported, never served as the original response.
  let #(replay, log) = replayer(tape)
  let assert [RequestFailed(reason)] = collect(replay, keyed)
  assert string.contains(reason, "redacted on write")
  assert list.length(cassette.divergences(log)) == 1
}

pub fn untouched_tape_keeps_its_bytes_and_boundaries_test() {
  let tape = record("You are careful")
  let assert Ok(back) = cassette.tape_from_jsonl(cassette.tape_to_jsonl(tape))
  let assert [recorded] = tape.recordings

  assert back == tape
  assert recorded.redaction == cassette.Verbatim
  assert list.length(recorded.events) == 4
}

pub fn disk_round_trip_replays_signatures_test() {
  let sha = "0123456789abcdef0123456789abcdef01234567"
  let script = fn(request: HttpRequest) {
    case string.contains(request.body, signature) {
      True -> [
        ResponseStatus(200, [#("content-type", "text/event-stream")]),
        ResponseChunk(<<"data: done\n\n":utf8>>),
        ResponseEnd,
      ]
      False -> [
        ResponseStatus(200, [#("content-type", "text/event-stream")]),
        ResponseChunk(<<
          "data: {\"signature\":\"",
          signature:utf8,
          "\",\"text\":\"git show ",
          sha:utf8,
          "\"}\n\n",
        >>),
        ResponseEnd,
      ]
    }
  }
  let #(transport, sink) = recorder(script)
  let first = request_saying("s", "start")
  let second = request_saying("s", signature)
  let recorded_events = [collect(transport, first), collect(transport, second)]
  let jsonl = cassette.tape_to_jsonl(cassette.finish(sink))

  let assert Ok(tape) = cassette.tape_from_jsonl(jsonl)
  let #(replay, log) = replayer(tape)

  assert [collect(replay, first), collect(replay, second)] == recorded_events
  assert cassette.divergences(log) == []

  let assert [one, _] = tape.recordings
  let body =
    list.filter_map(one.events, fn(event) {
      case event {
        cassette.Chunk(bytes:) -> bit_array.to_string(bytes)
        cassette.Status(..)
        | cassette.Ended
        | cassette.Failed(..)
        | cassette.Refused(..)
        | cassette.Cancelled -> Error(Nil)
      }
    })
    |> string.concat

  assert string.contains(body, signature)
  assert string.contains(body, "git show " <> sha)
}

pub fn cancel_before_begin_never_starts_test() {
  let started = process.new_subject()
  let assert Ok(sink) = cassette.start_sink()
  let tape = record("s")
  let #(replay, log) = replayer(tape)
  let transports = [
    cassette.recording(scripted(fixed(exchange()), Finish, started), root, sink),
    replay,
  ]

  list.each(transports, fn(transport) {
    let #(subject, prepared) = prepare(transport, request("s"))
    http.cancel(prepared.running)
    http.cancel(prepared.running)
    await_exit(prepared)

    assert process.receive(subject, within: 100) == Error(Nil)
  })

  assert process.receive(started, within: 100) == Error(Nil)

  // The cancelled request still holds its ordinal, as a cancellation.
  let assert [cancelled] = cassette.finish(sink).recordings
  assert cancelled.events == [cassette.Cancelled]
  assert cassette.divergences(log) == []
}

pub fn cancelled_request_keeps_ordinals_contiguous_test() {
  let assert Ok(sink) = cassette.start_sink()
  let started = process.new_subject()
  let partial =
    fixed([ResponseStatus(200, []), ResponseChunk(<<"data: one":utf8>>)])
  let stalled = scripted(partial, Stall, started)
  let transport = cassette.recording(stalled, root, sink)

  // Request 1 streams its status and is cancelled before it ends.
  let #(subject, prepared) = prepare(transport, request("first"))
  prepared.begin()
  let assert Ok(ResponseStatus(..)) = process.receive(subject, within: 3000)
  http.cancel(prepared.running)
  await_exit(prepared)

  let finishing =
    cassette.recording(scripted(fixed(exchange()), Finish, started), root, sink)
  assert collect(finishing, request("second")) == exchange()

  let tape = cassette.finish(sink)
  assert list.map(tape.recordings, fn(recorded) { recorded.ordinal }) == [1, 2]
  let assert [cancelled, _] = tape.recordings
  assert cancelled.events == [cassette.Cancelled]

  let assert Ok(back) = cassette.tape_from_jsonl(cassette.tape_to_jsonl(tape))
  assert back == tape

  // Replay: each request takes its own recording, not its list position.
  let #(replay, log) = replayer(back)
  let assert [RequestFailed(reason)] = collect(replay, request("first"))
  assert string.contains(reason, "cancelled")
  assert collect(replay, request("second")) == exchange()
  assert cassette.divergences(log) == []
}

pub fn concurrent_requests_replay_by_digest_test() {
  let answer_a = [
    ResponseStatus(200, []),
    ResponseChunk(<<"answer a":utf8>>),
    ResponseEnd,
  ]
  let answer_b = [
    ResponseStatus(200, []),
    ResponseChunk(<<"answer b":utf8>>),
    ResponseEnd,
  ]
  let script = fn(request: HttpRequest) {
    case string.contains(request.body, "strand-a") {
      True -> answer_a
      False -> answer_b
    }
  }
  let #(transport, sink) = recorder(script)

  // Both in flight together when recorded.
  let one = prepare(transport, request("strand-a"))
  let two = prepare(transport, request("strand-b"))
  let recorded_a = run(one)
  let recorded_b = run(two)

  assert recorded_a == answer_a
  assert recorded_b == answer_b

  // And in the opposite order when replayed.
  let #(replay, log) = replayer(cassette.finish(sink))
  let later = prepare(replay, request("strand-b"))
  let earlier = prepare(replay, request("strand-a"))

  assert run(earlier) == answer_a
  assert run(later) == answer_b
  assert cassette.divergences(log) == []
}

pub fn dead_sink_fails_cleanly_test() {
  let started = process.new_subject()
  let assert Ok(sink) = cassette.start_sink()
  cassette.close_sink(sink)
  let transport =
    cassette.recording(scripted(fixed(exchange()), Finish, started), root, sink)

  let assert [RequestFailed(reason)] = collect(transport, request("s"))
  assert string.contains(reason, "replay lane unavailable")
  assert process.receive(started, within: 100) == Error(Nil)

  let assert Ok(log) = cassette.start_log()
  cassette.close_log(log)
  let replay = cassette.replaying(record("s"), root, log)
  let assert [RequestFailed(replay_reason)] = collect(replay, request("s"))
  assert string.contains(replay_reason, "replay lane unavailable")
}

pub fn tape_codec_is_total_test() {
  let tape_generator =
    qcheck.tuple2(qcheck.string(), qcheck.bounded_int(from: 100, to: 599))
    |> qcheck.map(fn(pair) {
      let #(text, status) = pair
      let recording = fn(ordinal, redaction, terminal) {
        cassette.Recorded(
          ordinal:,
          digest: "d" <> text,
          shape: [],
          events: [
            cassette.Status(status:, headers: [#("content-type", text)]),
            cassette.Chunk(<<text:utf8>>),
            cassette.Chunk(<<0, 255, 128>>),
            terminal,
          ],
          redaction:,
        )
      }

      cassette.Tape([
        recording(1, cassette.Verbatim, cassette.Failed(text)),
        recording(2, cassette.Redacted, cassette.Ended),
        cassette.Recorded(
          ordinal: 3,
          digest: "c",
          shape: [],
          events: [cassette.Cancelled],
          redaction: cassette.Verbatim,
        ),
      ])
    })

  qcheck.run(
    qcheck.default_config()
      |> qcheck.with_test_count(100)
      |> qcheck.with_seed(qcheck.seed(codec_seed)),
    tape_generator,
    fn(tape) {
      assert cassette.tape_from_jsonl(cassette.tape_to_jsonl(tape)) == Ok(tape)
    },
  )

  let valid = cassette.tape_to_jsonl(record("s"))

  qcheck.run(
    qcheck.default_config()
      |> qcheck.with_test_count(200)
      |> qcheck.with_seed(qcheck.seed(codec_seed)),
    qcheck.string(),
    fn(text) {
      let cut = string.slice(valid, 0, string.length(text))

      // Arbitrary text, and a valid tape cut at an arbitrary point, are each
      // answered with a result; the assertion is that neither crashes.
      let _ = cassette.tape_from_jsonl(text)
      let _ = cassette.tape_from_jsonl(cut)
      Nil
    },
  )
}

pub fn tape_decoder_refuses_damage_test() {
  let valid = cassette.tape_to_jsonl(record("s"))

  assert cassette.tape_from_jsonl("") == Ok(cassette.Tape([]))
  let assert Error(_) = cassette.tape_from_jsonl("{}\n")
  let assert Error(_) =
    cassette.tape_from_jsonl(string.replace(valid, "\"v\":1", "\"v\":2"))
  let assert Error(_) =
    cassette.tape_from_jsonl(string.replace(
      valid,
      "\"ordinal\":1",
      "\"ordinal\":4",
    ))
  let assert Error(_) =
    cassette.tape_from_jsonl(string.replace(valid, "{\"t\":\"end\"}", ""))
  let assert Error(_) =
    cassette.tape_from_jsonl(string.replace(
      valid,
      "\"length\":",
      "\"length\":-",
    ))
}
