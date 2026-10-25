//// Tests for the recording and replaying transports: determinism, the
//// divergence finding, scrubbing, the transport contract, and the tape codec.

import eval/cassette.{type Tape}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/string
import provider/http.{
  type HttpEvent, type HttpRequest, type Transport, HttpRequest, RequestFailed,
  ResponseChunk, ResponseEnd, ResponseStatus,
}
import qcheck

const codec_seed = 17

const root = "/work/trial"

type Command {
  Begin
  Cancel
  CreatorExited
}

// A minimal inner transport. Its parked owner honours the same contract the
// real ones do: nothing runs until begin, a cancel before begin runs nothing,
// and a creator that dies first releases the owner. Every start is counted on
// `started`, so a test can prove the inner transport was never touched.
fn scripted(events: List(HttpEvent), started: Subject(Nil)) -> Transport {
  http.Transport(prepare_streaming: fn(_request, subject) {
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
            list.each(events, fn(event) { process.send(subject, event) })
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

fn request(system: String) -> HttpRequest {
  HttpRequest(
    method: "POST",
    url: "https://api.example.test/v1/messages",
    headers: [#("x-api-key", "sk-ant-api03-HEADERSECRET")],
    body: "{\"system\":\""
      <> system
      <> "\",\"messages\":[{\"role\":\"user\",\"content\":\"list /work/trial\"}]}",
  )
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

// Drives one request to its end and then to the owner's normal exit, which
// is the drain acknowledgement the contract promises.
fn collect(transport: Transport, request: HttpRequest) -> List(HttpEvent) {
  let subject = process.new_subject()
  let assert Ok(prepared) = transport.prepare_streaming(request, subject)
  let watch = process.monitor(prepared.running.owner)
  prepared.begin()
  let events = receive_until_terminal(subject, [])
  let assert Ok(Nil) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(_down) { Nil })
    |> process.selector_receive(within: 3000)
    as "the owner must exit after the terminal event"

  events
}

fn record(system: String) -> Tape {
  let started = process.new_subject()
  let assert Ok(sink) = cassette.start_sink()
  let transport = cassette.recording(scripted(exchange(), started), root, sink)

  assert collect(transport, request(system)) == exchange()

  cassette.finish(sink)
}

pub fn replay_is_deterministic_test() {
  let tape = record("You are careful")
  let assert Ok(log) = cassette.start_log()
  let first = cassette.replaying(tape, root, log)
  let one = collect(first, request("You are careful"))
  let assert Ok(log_two) = cassette.start_log()
  let two =
    collect(cassette.replaying(tape, root, log_two), request("You are careful"))

  assert one == exchange()
  assert one == two
  assert cassette.divergences(log) == []
  assert cassette.divergences(log_two) == []
}

pub fn pack_change_diverges_at_first_request_test() {
  let tape = record("You are careful")
  let assert Ok(log) = cassette.start_log()
  let events =
    collect(cassette.replaying(tape, root, log), request("You are careless"))

  let assert [RequestFailed(reason)] = events
  assert string.contains(reason, "replay diverged at request 1")
  assert string.contains(reason, "system")

  let assert [divergence] = cassette.divergences(log)
  assert divergence.ordinal == 1
  assert divergence.expected != divergence.actual
  assert string.contains(divergence.summary, "body.system")
  assert !string.contains(divergence.summary, "careless")
}

pub fn beyond_tape_is_divergence_test() {
  let tape = record("You are careful")
  let assert Ok(log) = cassette.start_log()
  let transport = cassette.replaying(tape, root, log)

  assert collect(transport, request("You are careful")) == exchange()

  let assert [RequestFailed(reason)] =
    collect(transport, request("You are careful"))
  assert string.contains(reason, "replay diverged at request 2")

  let assert [divergence] = cassette.divergences(log)
  assert divergence.ordinal == 2
  assert divergence.expected == ""
  assert string.contains(divergence.summary, "beyond the tape")
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
  let started = process.new_subject()
  let assert Ok(sink) = cassette.start_sink()
  let planted = [
    ResponseStatus(200, [#("x-api-key", "sk-ant-api03-HEADERSECRET")]),
    ResponseChunk(<<"data: hello sk-ant-api03-PLAN":utf8>>),
    ResponseChunk(<<"TEDACROSSCHUNKS\n\ndata: fine\n\n":utf8>>),
    ResponseEnd,
  ]
  let transport = cassette.recording(scripted(planted, started), root, sink)
  let _ = collect(transport, request("s"))
  let jsonl = cassette.tape_to_jsonl(cassette.finish(sink))

  assert !string.contains(jsonl, "PLAN")
  assert !string.contains(jsonl, "HEADERSECRET")
  assert !string.contains(jsonl, "ACROSSCHUNKS")

  let assert Ok(tape) = cassette.tape_from_jsonl(jsonl)
  let assert [recorded] = tape.recordings
  let body =
    list.filter_map(recorded.events, fn(event) {
      case event {
        cassette.Chunk(bytes:) -> bit_array.to_string(bytes)
        cassette.Status(..)
        | cassette.Ended
        | cassette.Failed(..)
        | cassette.Refused(..) -> Error(Nil)
      }
    })
    |> string.concat

  assert string.contains(body, "data: hello")
  assert string.contains(body, "data: fine")
}

pub fn untouched_tape_keeps_its_chunk_boundaries_test() {
  let tape = record("You are careful")
  let assert Ok(back) = cassette.tape_from_jsonl(cassette.tape_to_jsonl(tape))

  assert back == tape
}

pub fn cancel_before_begin_never_starts_test() {
  let started = process.new_subject()
  let assert Ok(sink) = cassette.start_sink()
  let assert Ok(log) = cassette.start_log()
  let tape = record("s")
  let transports = [
    cassette.recording(scripted(exchange(), started), root, sink),
    cassette.replaying(tape, root, log),
  ]

  list.each(transports, fn(transport) {
    let subject = process.new_subject()
    let assert Ok(prepared) = transport.prepare_streaming(request("s"), subject)
    let watch = process.monitor(prepared.running.owner)
    http.cancel(prepared.running)
    http.cancel(prepared.running)
    let assert Ok(Nil) =
      process.new_selector()
      |> process.select_specific_monitor(watch, fn(_down) { Nil })
      |> process.selector_receive(within: 3000)
      as "a cancelled parked owner must exit"

    assert process.receive(subject, within: 100) == Error(Nil)
  })

  assert process.receive(started, within: 100) == Error(Nil)
  assert cassette.finish(sink) == cassette.Tape([])
  assert cassette.divergences(log) == []
}

pub fn tape_codec_is_total_test() {
  let tape_generator =
    qcheck.tuple2(qcheck.string(), qcheck.bounded_int(from: 100, to: 599))
    |> qcheck.map(fn(pair) {
      let #(text, status) = pair
      cassette.Tape([
        cassette.Recorded(ordinal: 1, digest: "d", shape: [], events: [
          cassette.Status(status:, headers: [#("h", text)]),
          cassette.Chunk(<<text:utf8>>),
          cassette.Chunk(<<0, 255, 128>>),
          cassette.Failed(text),
        ]),
      ])
    })

  qcheck.run(
    qcheck.default_config()
      |> qcheck.with_test_count(100)
      |> qcheck.with_seed(qcheck.seed(codec_seed)),
    tape_generator,
    fn(tape) {
      let written = cassette.tape_to_jsonl(tape)
      let assert Ok(back) = cassette.tape_from_jsonl(written)

      assert cassette.tape_to_jsonl(back) == written
    },
  )

  qcheck.run(
    qcheck.default_config()
      |> qcheck.with_test_count(200)
      |> qcheck.with_seed(qcheck.seed(codec_seed)),
    qcheck.string(),
    fn(text) {
      let valid = cassette.tape_to_jsonl(record("s"))
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
}
