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

pub fn terminated_data_lines_cannot_grow_one_event_without_bound_test() {
  // Complete lines leave the carry buffer empty, so the event needs its own
  // cumulative budget. Two half-bound values exceed that budget by the newline
  // which dispatch would insert between them.
  let value = string.repeat("a", stream.max_event_bytes / 2)
  let #(parser, first) =
    stream.feed(
      stream.new_parser(),
      bit_array.from_string("data: " <> value <> "\n"),
    )
  assert first == []
  let #(parser, second) =
    stream.feed(parser, bit_array.from_string("data: " <> value <> "\n"))
  let assert [stream.SseMalformed(reason:)] = second
  assert string.contains(reason, "before a blank-line terminator")

  // The rejected event is discarded, so subsequent well-formed traffic does
  // not inherit its bytes or event name.
  let #(_parser, after) = stream.feed(parser, <<"\ndata: after\n\n":utf8>>)
  assert after == [stream.SseMessage(event: None, data: "after")]
}

pub fn empty_data_lines_are_bounded_by_count_test() {
  // Empty fields contribute no payload bytes but each still occupies one list
  // cell. The independent count cap keeps that representation bounded.
  let transcript =
    string.repeat("data\n", stream.max_event_data_lines + 1)
    |> bit_array.from_string()
  let #(_parser, events) = stream.feed(stream.new_parser(), transcript)
  let assert [stream.SseMalformed(reason:)] = events
  assert string.contains(reason, "data fields")
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
  let control = process_subject()
  let terminal =
    stream.run(
      transport,
      http.HttpRequest(method: "POST", url: "http://x", headers: [], body: ""),
      echo_machine(),
      fn(delta) { send_to(deltas, delta) },
      control:,
      consumer: process.self(),
      within: 1000,
    )
  assert terminal
    == stream.AttemptTerminal(
      stream.Failed(stream.StreamDisconnected(context: "echo done")),
    )
  assert receive_from(deltas, 100)
    == Ok(stream.TextDelta(index: 0, text: "chunk"))
}

pub fn run_times_out_in_band_test() {
  let cancelled = process_subject()
  let silent = silent_transport(cancelled)
  let control = process_subject()
  let terminal =
    stream.run(
      silent,
      http.HttpRequest(method: "POST", url: "http://x", headers: [], body: ""),
      echo_machine(),
      fn(_delta) { Nil },
      control:,
      consumer: process.self(),
      within: 50,
    )
  assert terminal
    == stream.AttemptTerminal(
      stream.Failed(stream.TransportFailed(
        reason: "timed out waiting for the provider",
      )),
    )
  assert receive_from(cancelled, 100) == Ok(Nil)
}

pub fn run_deadline_is_not_refreshed_by_active_chunks_test() {
  let cancelled = process_subject()
  let active = repeating_transport(cancelled, <<"x":utf8>>, every_ms: 1)
  let outcome =
    stream.run(
      active,
      http.HttpRequest(method: "POST", url: "http://x", headers: [], body: ""),
      echo_machine(),
      fn(_delta) { Nil },
      control: process_subject(),
      consumer: process.self(),
      within: 40,
    )
  assert outcome
    == stream.AttemptTerminal(
      stream.Failed(stream.TransportFailed(
        reason: "timed out waiting for the provider",
      )),
    )
  assert receive_from(cancelled, 100) == Ok(Nil)
}

pub fn run_rejects_a_response_over_the_cumulative_byte_budget_test() {
  let cancelled = process_subject()
  let oversized =
    string.repeat("x", stream.max_response_bytes + 1)
    |> bit_array.from_string()
  let outcome =
    stream.run(
      repeating_transport(cancelled, oversized, every_ms: 1000),
      http.HttpRequest(method: "POST", url: "http://x", headers: [], body: ""),
      echo_machine(),
      fn(_delta) { Nil },
      control: process_subject(),
      consumer: process.self(),
      within: 1000,
    )
  let assert stream.AttemptTerminal(stream.Failed(stream.MalformedStream(
    report: report,
  ))) = outcome
  assert string.contains(report.context, "cumulative byte budget")
  assert receive_from(cancelled, 100) == Ok(Nil)
}

pub fn run_transport_failure_in_band_test() {
  let failing =
    fixture.transport([http.RequestFailed(reason: "connection refused")])
  let control = process_subject()
  let terminal =
    stream.run(
      failing,
      http.HttpRequest(method: "POST", url: "http://x", headers: [], body: ""),
      echo_machine(),
      fn(_delta) { Nil },
      control:,
      consumer: process.self(),
      within: 1000,
    )
  assert terminal
    == stream.AttemptTerminal(
      stream.Failed(stream.TransportFailed(reason: "connection refused")),
    )
}

pub fn run_explicit_cancel_stops_transport_test() {
  let cancelled = process_subject()
  let control = process_subject()
  process.send(control, stream.Cancel)
  let outcome =
    stream.run(
      silent_transport(cancelled),
      http.HttpRequest(method: "POST", url: "http://x", headers: [], body: ""),
      echo_machine(),
      fn(_delta) { Nil },
      control:,
      consumer: process.self(),
      within: 1000,
    )
  assert outcome == stream.AttemptCancelled
  assert receive_from(cancelled, 100) == Ok(Nil)
}

pub fn run_cancel_between_chunks_drops_late_http_terminal_test() {
  let ready = process_subject()
  let owners = process_subject()
  let cancelled = process_subject()
  let deltas = process_subject()
  let outcomes = process_subject()
  let transport =
    http.Transport(prepare_streaming: fn(_request, events) {
      let begin_ready = process.new_subject()
      let stop_ready = process.new_subject()
      let owner =
        process.spawn_unlinked(fn() {
          let begin = process.new_subject()
          process.send(begin_ready, begin)
          let stop = process.new_subject()
          process.send(stop_ready, stop)
          let _permit = process.receive_forever(begin)
          process.send(events, http.ResponseStatus(status: 200, headers: []))
          process.send(events, http.ResponseChunk(<<"first":utf8>>))
          let _stop = process.receive_forever(stop)
          Nil
        })
      let begin = process.receive_forever(begin_ready)
      let stop = process.receive_forever(stop_ready)
      process.send(owners, owner)
      Ok(http.PreparedRequest(
        running: http.RunningRequest(owner:, cancel: fn() {
          process.send(cancelled, Nil)
          // This simulates an HTTP terminal already in flight when cancellation
          // wins. The attempt's private subject may receive it, but no second
          // public outcome can escape the completed run loop.
          process.send(events, http.ResponseEnd)
          process.send(stop, Nil)
        }),
        begin: fn() { process.send(begin, Nil) },
      ))
    })
  let _runner =
    process.spawn_unlinked(fn() {
      let control = process.new_subject()
      process.send(ready, control)
      let outcome =
        stream.run(
          transport,
          http.HttpRequest(
            method: "POST",
            url: "http://x",
            headers: [],
            body: "",
          ),
          echo_machine(),
          fn(delta) { process.send(deltas, delta) },
          control:,
          consumer: process.self(),
          within: 1000,
        )
      process.send(outcomes, outcome)
    })
  let assert Ok(control) = receive_from(ready, 100)
  let assert Ok(owner) = receive_from(owners, 100)
  let owner_monitor = process.monitor(owner)
  let assert Ok(stream.TextDelta(text: "chunk", ..)) = receive_from(deltas, 100)

  process.send(control, stream.Cancel)

  assert receive_from(outcomes, 1000) == Ok(stream.AttemptCancelled)
  assert receive_from(cancelled, 100) == Ok(Nil)
  let assert Ok(True) =
    process.new_selector()
    |> process.select_specific_monitor(owner_monitor, fn(_down) { True })
    |> process.selector_receive(1000)
  assert receive_from(outcomes, 20) == Error(Nil)
}

pub fn run_timeout_refuses_to_retry_stubborn_transport_owner_test() {
  let owners = process_subject()
  let cancelled = process_subject()
  let stubborn =
    http.Transport(prepare_streaming: fn(_request, _events) {
      let owner =
        process.spawn_unlinked(fn() {
          process.receive_forever(process.new_subject())
        })
      process.send(owners, owner)
      Ok(
        http.PreparedRequest(
          running: http.RunningRequest(owner:, cancel: fn() {
            process.send(cancelled, Nil)
          }),
          begin: fn() { Nil },
        ),
      )
    })
  let outcome =
    stream.run(
      stubborn,
      http.HttpRequest(method: "POST", url: "http://x", headers: [], body: ""),
      echo_machine(),
      fn(_delta) { Nil },
      control: process_subject(),
      consumer: process.self(),
      within: 20,
    )
  let assert Ok(owner) = receive_from(owners, 100)
  assert outcome == stream.AttemptCancellationUnconfirmed
  assert receive_from(cancelled, 100) == Ok(Nil)
  assert process.is_alive(owner)
  process.kill(owner)
}

pub fn run_transport_death_fails_in_band_test() {
  let dead =
    http.Transport(prepare_streaming: fn(_request, _subject) {
      let begin_ready = process.new_subject()
      let owner =
        process.spawn_unlinked(fn() {
          let begin = process.new_subject()
          process.send(begin_ready, begin)
          let _permit = process.receive_forever(begin)
          Nil
        })
      let begin = process.receive_forever(begin_ready)
      Ok(
        http.PreparedRequest(
          running: http.RunningRequest(owner:, cancel: fn() {
            process.kill(owner)
          }),
          begin: fn() { process.send(begin, Nil) },
        ),
      )
    })
  let outcome =
    stream.run(
      dead,
      http.HttpRequest(method: "POST", url: "http://x", headers: [], body: ""),
      echo_machine(),
      fn(_delta) { Nil },
      control: process_subject(),
      consumer: process.self(),
      within: 1000,
    )
  assert outcome
    == stream.AttemptTerminal(
      stream.Failed(stream.TransportFailed(
        reason: "provider transport stopped before a terminal response",
      )),
    )
}

pub fn run_start_failure_fails_once_in_band_test() {
  let failed =
    http.Transport(prepare_streaming: fn(_request, _events) {
      Error("unavailable")
    })
  let outcome =
    stream.run(
      failed,
      http.HttpRequest(method: "POST", url: "http://x", headers: [], body: ""),
      echo_machine(),
      fn(_delta) { Nil },
      control: process_subject(),
      consumer: process.self(),
      within: 1000,
    )
  assert outcome
    == stream.AttemptTerminal(
      stream.Failed(stream.TransportFailed(reason: "start failed: unavailable")),
    )
}

pub fn run_tracked_publishes_owner_before_transport_start_test() {
  let published = process_subject()
  let transport_started = process_subject()
  let outcomes = process_subject()
  let transport =
    http.Transport(prepare_streaming: fn(_request, _events) {
      let owner =
        process.spawn_unlinked(fn() {
          process.receive_forever(process.new_subject())
        })
      Ok(
        http.PreparedRequest(
          running: http.RunningRequest(owner:, cancel: fn() {
            process.kill(owner)
          }),
          begin: fn() {
            process.send(transport_started, Nil)
            process.kill(owner)
          },
        ),
      )
    })
  let _runner =
    process.spawn_unlinked(fn() {
      let outcome =
        stream.run_tracked(
          transport,
          http.HttpRequest(
            method: "POST",
            url: "http://x",
            headers: [],
            body: "",
          ),
          echo_machine(),
          fn(_delta) { Nil },
          fn(running) {
            let permit = process_subject()
            process.send(published, #(running, permit))
            let _permit = process.receive_forever(permit)
            Nil
          },
          control: process_subject(),
          consumer: process.self(),
          within: 1000,
        )
      process.send(outcomes, outcome)
    })

  let assert Ok(#(_running, permit)) = receive_from(published, 1000)
  assert receive_from(transport_started, 20) == Error(Nil)
  process.send(permit, Nil)
  assert receive_from(transport_started, 1000) == Ok(Nil)
  assert receive_from(outcomes, 1000) == Ok(stream.AttemptDrainProofLost)
}

pub fn run_tracked_publishes_cancel_capability_before_runner_death_test() {
  let published = process_subject()
  let inner_ready = process_subject()
  let cancelled = process_subject()
  let transport =
    http.Transport(prepare_streaming: fn(_request, _events) {
      let ready = process_subject()
      let inner =
        process.spawn_unlinked(fn() {
          let release = process_subject()
          process.send(ready, release)
          let _release = process.receive_forever(release)
          Nil
        })
      let release = process.receive_forever(ready)
      process.send(inner_ready, #(inner, release))
      Ok(
        http.PreparedRequest(
          running: http.RunningRequest(owner: inner, cancel: fn() {
            process.send(cancelled, Nil)
          }),
          begin: fn() { Nil },
        ),
      )
    })
  let runner =
    process.spawn_unlinked(fn() {
      let _outcome =
        stream.run_tracked(
          transport,
          http.HttpRequest(
            method: "POST",
            url: "http://x",
            headers: [],
            body: "",
          ),
          echo_machine(),
          fn(_delta) { Nil },
          fn(running) { process.send(published, running) },
          control: process_subject(),
          consumer: process.self(),
          within: 1000,
        )
      Nil
    })
  let assert Ok(running) = receive_from(published, 1000)
  let assert Ok(#(inner, release)) = receive_from(inner_ready, 1000)
  let owner_monitor = process.monitor(http.owner(running))

  process.kill(runner)

  http.cancel(running)
  assert receive_from(cancelled, 1000) == Ok(Nil)
  assert process.is_alive(inner)
  assert process.is_alive(http.owner(running))
  process.send(release, Nil)
  let assert Ok(True) =
    process.new_selector()
    |> process.select_specific_monitor(owner_monitor, fn(_down) { True })
    |> process.selector_receive(1000)
}

fn silent_transport(cancelled: process.Subject(Nil)) -> http.Transport {
  http.Transport(prepare_streaming: fn(_request, _events) {
    let stop_ready = process.new_subject()
    let owner =
      process.spawn_unlinked(fn() {
        let stop = process.new_subject()
        process.send(stop_ready, stop)
        let _stop = process.receive_forever(stop)
        Nil
      })
    let stop = process.receive_forever(stop_ready)
    Ok(
      http.PreparedRequest(
        running: http.RunningRequest(owner:, cancel: fn() {
          process.send(cancelled, Nil)
          process.send(stop, Nil)
        }),
        begin: fn() { Nil },
      ),
    )
  })
}

fn repeating_transport(
  cancelled: process.Subject(Nil),
  chunk: BitArray,
  every_ms every_ms: Int,
) -> http.Transport {
  http.Transport(prepare_streaming: fn(_request, events) {
    let ready = process.new_subject()
    let owner =
      process.spawn_unlinked(fn() {
        let begin = process.new_subject()
        let stop = process.new_subject()
        process.send(ready, #(begin, stop))
        let _begin = process.receive_forever(begin)
        process.send(events, http.ResponseStatus(status: 200, headers: []))
        repeat_chunks(events, stop, chunk, every_ms)
      })
    let #(begin, stop) = process.receive_forever(ready)
    Ok(
      http.PreparedRequest(
        running: http.RunningRequest(owner:, cancel: fn() {
          process.send(cancelled, Nil)
          process.send(stop, Nil)
        }),
        begin: fn() { process.send(begin, Nil) },
      ),
    )
  })
}

fn repeat_chunks(
  events: process.Subject(http.HttpEvent),
  stop: process.Subject(Nil),
  chunk: BitArray,
  every_ms: Int,
) -> Nil {
  process.send(events, http.ResponseChunk(chunk:))
  case process.receive(stop, within: every_ms) {
    Ok(Nil) -> Nil
    Error(Nil) -> repeat_chunks(events, stop, chunk, every_ms)
  }
}

pub fn drain_witness_retains_normal_reason_across_owner_exit_test() {
  let ready = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let stop = process.new_subject()
      process.send(ready, stop)
      let _stop = process.receive_forever(stop)
      Nil
    })
  let stop = process.receive_forever(ready)
  let handle =
    stream.owned(events: process.new_subject(), owner:, cancel: fn() {
      process.send(stop, Nil)
    })
  let witness = stream.watch_drain(handle)

  stream.cancel(handle)

  assert stream.await_drain_forever(witness) == stream.Drained
}

pub fn drain_witness_retains_abnormal_reason_across_owner_exit_test() {
  let owner =
    process.spawn_unlinked(fn() {
      process.receive_forever(process.new_subject())
    })
  let handle =
    stream.owned(events: process.new_subject(), owner:, cancel: fn() {
      process.kill(owner)
    })
  let witness = stream.watch_drain(handle)

  stream.cancel(handle)

  assert stream.await_drain_forever(witness) == stream.ProofLost
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
