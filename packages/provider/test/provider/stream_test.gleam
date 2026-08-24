import core/message
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import provider/fixture
import provider/http
import provider/stream

// --- SSE framing --------------------------------------------------------

pub fn sse_simple_event_test() {
  let #(_parser, events) =
    stream.feed(stream.new_parser(), <<"data: hello\n\n":utf8>>)
  assert events == [stream.SseMessage(event: None, data: "hello")]
}

pub fn sse_named_event_test() {
  let #(_parser, events) =
    stream.feed(stream.new_parser(), <<
      "event: message_start\ndata: {\"a\":1}\n\n":utf8,
    >>)
  assert events
    == [stream.SseMessage(event: Some("message_start"), data: "{\"a\":1}")]
}

pub fn sse_multi_line_data_joined_test() {
  let #(_parser, events) =
    stream.feed(stream.new_parser(), <<"data: one\ndata: two\n\n":utf8>>)
  assert events == [stream.SseMessage(event: None, data: "one\ntwo")]
}

pub fn sse_comment_ignored_test() {
  let #(_parser, events) =
    stream.feed(stream.new_parser(), <<": keep-alive\n\ndata: x\n\n":utf8>>)
  assert events == [stream.SseMessage(event: None, data: "x")]
}

pub fn sse_crlf_lines_test() {
  let #(_parser, events) =
    stream.feed(stream.new_parser(), <<"data: hi\r\n\r\n":utf8>>)
  assert events == [stream.SseMessage(event: None, data: "hi")]
}

pub fn sse_lone_cr_lines_test() {
  // \r terminates a line, so \r\r is line-end plus blank line: dispatch.
  let #(_parser, events) =
    stream.feed(stream.new_parser(), <<"data: hi\r\rdata: ho\n\n":utf8>>)
  assert events
    == [
      stream.SseMessage(event: None, data: "hi"),
      stream.SseMessage(event: None, data: "ho"),
    ]
}

pub fn sse_empty_data_buffer_discards_event_test() {
  // An event name with no data lines dispatches nothing and resets.
  let #(_parser, events) =
    stream.feed(stream.new_parser(), <<
      "event: ping\n\ndata: real\n\n":utf8,
    >>)
  assert events == [stream.SseMessage(event: None, data: "real")]
}

pub fn sse_unknown_field_ignored_test() {
  let #(_parser, events) =
    stream.feed(stream.new_parser(), <<
      "id: 7\nretry: 100\nfancy: field\ndata: x\n\n":utf8,
    >>)
  assert events == [stream.SseMessage(event: None, data: "x")]
}

pub fn sse_data_without_space_test() {
  let #(_parser, events) =
    stream.feed(stream.new_parser(), <<"data:tight\n\n":utf8>>)
  assert events == [stream.SseMessage(event: None, data: "tight")]
}

pub fn sse_invalid_utf8_line_is_malformed_not_crash_test() {
  let #(_parser, events) =
    stream.feed(stream.new_parser(), <<
      "data: ok\n":utf8,
      0xFF,
      0xFE,
      "\n":utf8,
    >>)
  assert events == [stream.SseMalformed(reason: "sse line was not valid utf-8")]
}

pub fn sse_incomplete_event_not_dispatched_test() {
  let #(_parser, events) =
    stream.feed(stream.new_parser(), <<"data: incomplete\n":utf8>>)
  assert events == []
}

// --- carry bound (a hostile terminator-less stream) ----------------------

fn megabyte_of(byte: String) -> BitArray {
  bit_array.from_string(string.repeat(byte, 1_048_576))
}

pub fn terminator_less_stream_fails_in_band_at_the_bound_test() {
  // Five 1 MiB chunks with no line terminator anywhere: the parser must
  // report a framing defect as soon as the carry passes max_line_bytes
  // (4 MiB), rather than buffering without limit.
  let chunk = megabyte_of("a")
  let #(parser, events) =
    list.fold(
      [chunk, chunk, chunk, chunk],
      #(stream.new_parser(), []),
      fn(folded, chunk) {
        let #(parser, events) = folded
        let #(parser, new_events) = stream.feed(parser, chunk)
        #(parser, list.append(events, new_events))
      },
    )
  // Exactly at the bound: still buffering, nothing emitted.
  assert events == []
  // One byte past the bound: the malformed event fires.
  let #(parser, events) = stream.feed(parser, <<"a":utf8>>)
  let assert [stream.SseMalformed(reason:)] = events
  assert string.contains(reason, "without a line terminator")
  // The buffered line was discarded and the parser stays usable.
  let #(_parser, events) =
    stream.feed(parser, <<
      "data: after

":utf8,
    >>)
  assert events == [stream.SseMessage(event: None, data: "after")]
}

pub fn long_data_line_just_under_the_bound_parses_test() {
  // A legitimate very long single data line — "data: " plus payload,
  // just under max_line_bytes — must still parse, chunked or not.
  let payload_size = stream.max_line_bytes - 100
  let payload = string.repeat("a", payload_size)
  let bytes = bit_array.from_string("data: " <> payload <> "

")
  let #(_parser, events) =
    list.fold(
      fixture.chunked(bytes, 1_048_576),
      #(stream.new_parser(), []),
      fn(folded, chunk) {
        let #(parser, events) = folded
        let #(parser, new_events) = stream.feed(parser, chunk)
        #(parser, list.append(events, new_events))
      },
    )
  let assert [stream.SseMessage(event: None, data:)] = events
  assert data == payload
}

// --- chunk-boundary invariance ------------------------------------------

fn transcript_bytes() -> BitArray {
  bit_array.from_string(
    "event: message_start\ndata: {\"type\":\"message_start\"}\n\n"
    <> ": comment across the wire\r\n"
    <> "event: content_block_delta\r\ndata: {\"text\":\"héllo → wörld\"}\r\n\r\n"
    <> "data: multi\ndata: line\n\n"
    <> "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
  )
}

fn feed_all(chunks: List(BitArray)) -> List(stream.SseEvent) {
  let #(_parser, events) =
    list.fold(chunks, #(stream.new_parser(), []), fn(folded, chunk) {
      let #(parser, events) = folded
      let #(parser, new_events) = stream.feed(parser, chunk)
      #(parser, list.append(events, new_events))
    })
  events
}

pub fn sse_chunking_at_every_boundary_test() {
  let bytes = transcript_bytes()
  let whole = feed_all([bytes])
  let size = bit_array.byte_size(bytes)
  // Every two-way split point, including splits inside multi-byte UTF-8
  // codepoints and inside \r\n pairs, yields identical events.
  int.range(from: 1, to: size, with: Nil, run: fn(_acc, at) {
    let assert Ok(head) = bit_array.slice(bytes, 0, at)
    let assert Ok(tail) = bit_array.slice(bytes, at, size - at)
    assert feed_all([head, tail]) == whole
    Nil
  })
}

pub fn sse_byte_by_byte_test() {
  let bytes = transcript_bytes()
  let whole = feed_all([bytes])
  assert feed_all(fixture.chunked(bytes, 1)) == whole
}

pub fn sse_three_byte_chunks_test() {
  let bytes = transcript_bytes()
  assert feed_all(fixture.chunked(bytes, 3)) == feed_all([bytes])
}

// --- settled message smart constructor ----------------------------------

pub fn settle_rejects_user_message_test() {
  assert stream.settle(message.UserMessage(content: [], timestamp: 0))
    == Error(Nil)
}

pub fn settle_rejects_pending_test() {
  let pending =
    message.AssistantMessage(
      content: [],
      api: "anthropic-messages",
      provider: "anthropic",
      model: "m",
      response_model: None,
      response_id: None,
      diagnostics: None,
      usage: zero_usage(),
      stop_reason: message.Pending,
      deferred: None,
      error_message: None,
      raw_stop_reason: None,
      end_turn: None,
      timestamp: 0,
    )
  assert stream.settle(pending) == Error(Nil)
}

pub fn settle_accepts_settled_assistant_test() {
  let settled =
    message.AssistantMessage(
      content: [],
      api: "anthropic-messages",
      provider: "anthropic",
      model: "m",
      response_model: None,
      response_id: None,
      diagnostics: None,
      usage: zero_usage(),
      stop_reason: message.Stop,
      deferred: None,
      error_message: None,
      raw_stop_reason: None,
      end_turn: None,
      timestamp: 0,
    )
  let assert Ok(wrapped) = stream.settle(settled)
  assert stream.message(wrapped) == settled
}

fn zero_usage() -> message.Usage {
  message.Usage(
    input: 0,
    output: 0,
    cache_read: 0,
    cache_write: 0,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: 0,
    cost: message.UsageCost(
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.0,
    ),
  )
}

// --- the process pump ----------------------------------------------------

// A trivial machine that emits one delta per chunk and settles on end.
fn echo_machine() -> stream.ResponseMachine(Int) {
  stream.ResponseMachine(
    init: 0,
    on_status: fn(count, _status, _headers) { count },
    on_chunk: fn(count, _chunk) {
      #(count + 1, [
        stream.Delta(stream.TextDelta(index: 0, text: "chunk")),
      ])
    },
    on_end: fn(_count) {
      [stream.Failed(stream.StreamDisconnected(context: "echo done"))]
    },
    on_failure: fn(_count, reason) {
      [stream.Failed(stream.TransportFailed(reason:))]
    },
  )
}

pub fn run_delivers_deltas_and_returns_terminal_test() {
  let transport = fixture.transport(fixture.ok_response("irrelevant"))
  let deltas = process_subject()
  let terminal =
    stream.run(
      transport,
      http.HttpRequest(method: "POST", url: "http://x", headers: [], body: ""),
      echo_machine(),
      fn(delta) { send_to(deltas, delta) },
      within: 1000,
    )
  assert terminal
    == stream.Failed(stream.StreamDisconnected(context: "echo done"))
  assert receive_from(deltas, 100)
    == Ok(stream.TextDelta(index: 0, text: "chunk"))
}

pub fn run_times_out_in_band_test() {
  let silent = http.Transport(send_streaming: fn(_request, _subject) { Nil })
  let terminal =
    stream.run(
      silent,
      http.HttpRequest(method: "POST", url: "http://x", headers: [], body: ""),
      echo_machine(),
      fn(_delta) { Nil },
      within: 50,
    )
  assert terminal
    == stream.Failed(stream.TransportFailed(
      reason: "timed out waiting for the provider",
    ))
}

pub fn run_transport_failure_in_band_test() {
  let failing =
    fixture.transport([http.RequestFailed(reason: "connection refused")])
  let terminal =
    stream.run(
      failing,
      http.HttpRequest(method: "POST", url: "http://x", headers: [], body: ""),
      echo_machine(),
      fn(_delta) { Nil },
      within: 1000,
    )
  assert terminal
    == stream.Failed(stream.TransportFailed(reason: "connection refused"))
}

fn process_subject() -> process.Subject(a) {
  process.new_subject()
}

fn send_to(subject: process.Subject(a), value: a) -> Nil {
  process.send(subject, value)
}

fn receive_from(subject: process.Subject(a), timeout: Int) -> Result(a, Nil) {
  process.receive(subject, within: timeout)
}
