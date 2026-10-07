//// The registered channel is exercised through the real client actor.
//// The local peer holds physical input credits and publishes output only through
//// the original opaque sink. These tests claim local consumption, not retirement.

import core/json
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lsp/client
import lsp/framing
import lsp/internal/consumed_channel as consumed
import lsp/jsonrpc
import lsp/protocol
import lsp/query
import lsp/range
import support/consumed_server as peer
import support/fake_server
import weft
import weft/poll

const root = "/work"

const path = "/work/a.gleam"

const uri = "file:///work/a.gleam"

pub fn an_output_grant_is_owned_once_by_the_original_consumer_test() {
  let events = process.new_subject()
  let attached = process.new_subject()
  let assert Ok(connection) =
    consumed.open(
      fn(sink) {
        process.send(attached, sink)
        Ok(
          consumed.Session(fn(_) { Ok(Nil) }, fn() {
            consumed.closed(sink, "closed original")
          }),
        )
      },
      events,
    )
    as "The original window starts."
  let assert Ok(sink) = process.receive(attached, 1000)
    as "The sink is installed before output."
  let published =
    weft.new([
      fn() {
        consumed.publish(sink, consumed.Stdout, <<1, 2, 3>>, consumed.Intact)
      },
    ])
    |> weft.deadline(2000)
    |> weft.start_detached
  let assert Ok(consumed.Output(consumed.Stdout, <<1, 2, 3>>, grant)) =
    process.receive(events, 1000)
    as "Exact output carries its original grant."
  assert weft.pull(published, 0) == weft.NotYet

  // Moving the opaque value to another process transfers no consuming authority.
  let stranger = weft.new([fn() { consumed.consume(grant) }]) |> weft.start
  let assert [weft.Failed(0, _)] = stranger
    as "Only the original client owner can consume its output."
  assert consumed.consume(grant) == Ok(Nil)
  assert weft.pull(published, 1000)
    == weft.PulledOutcome(weft.Completed(0, Nil))
  assert weft.pull(published, 1000) == weft.AllDelivered
  let assert Error(_) = consumed.consume(grant)
    as "A drained original grant cannot be reused."
  connection.close()
  let assert Ok(consumed.Failed(_)) = process.receive(events, 1000)
    as "Closing fences input before the original close witness."
  let assert Ok(consumed.Closed("closed original")) =
    process.receive(events, 1000)
    as "Close retains the original attachment's witness."
}

pub fn a_blocked_input_holds_the_full_writer_byte_reservation_test() {
  let #(connection, events, feeds) = blocked_window()
  assert connection.send(string.repeat("x", 20_000)) == Ok(Nil)
  assert process.receive(feeds, 1000) == Ok(consumed.feed_bytes)
  assert connection.send(string.repeat("y", consumed.writer_bytes - 20_000))
    == Ok(Nil)
  assert process.receive(feeds, 0) == Error(Nil)
  assert connection.send("z") == Error(Nil)
  let assert Ok(consumed.Failed(_)) = process.receive(events, 1000)
    as "Admission exhaustion fences before another physical feed."
  let assert Ok(consumed.Closed(_)) = process.receive(events, 1000)
    as "The original blocked attachment closes."
}

pub fn the_writer_message_window_admits_128_then_fences_test() {
  let #(connection, events, feeds) = blocked_window()
  list.each(numbers(128), fn(_) {
    assert connection.send("x") == Ok(Nil)
  })
  assert process.receive(feeds, 1000) == Ok(1)
  assert process.receive(feeds, 0) == Error(Nil)
  assert connection.send("x") == Error(Nil)
  let assert Ok(consumed.Failed(_)) = process.receive(events, 1000)
    as "The 129th logical message never owns input credit."
  let assert Ok(consumed.Closed(_)) = process.receive(events, 1000)
    as "Exhaustion closes the original attachment."
}

pub fn the_original_8192_frame_allowance_includes_eof_and_never_renews_test() {
  let events = process.new_subject()
  let physical = process.new_subject()
  let assert Ok(connection) =
    consumed.open(
      fn(sink) {
        Ok(
          consumed.Session(
            fn(bytes) {
              process.send(physical, bit_array.byte_size(bytes))
              Ok(Nil)
            },
            fn() { consumed.closed(sink, "original lifetime exhausted") },
          ),
        )
      },
      events,
    )
    as "The finite original lifetime is installed once."
  let full = string.repeat("x", 16_777_216)
  let marker = string.repeat("y", 8192)

  // A marker fits beside the prior whole-frame reservation. Seeing its physical
  // feed proves the preceding frame's matching task drained before the next one.
  list.each(numbers(3), fn(_) {
    assert connection.send(full) == Ok(Nil)
    physical_feeds(physical, 2048)
    assert connection.send(marker) == Ok(Nil)
    physical_feeds(physical, 1)
  })
  assert connection.send(string.repeat("z", 2044 * 8192)) == Ok(Nil)
  physical_feeds(physical, 2044)
  assert 3 * { 2048 + 1 } + 2044 == 8191
  assert 8191 * 8192 == 67_100_672
  assert connection.send("x") == Error(Nil)
  let assert Ok(consumed.Failed(_)) = process.receive(events, 1000)
    as "EOF's reserved frame prevents a renewed original allowance."
  let assert Ok(consumed.Closed(_)) = process.receive(events, 1000)
    as "Cumulative exhaustion closes the original session."
  assert process.receive(physical, 0) == Error(Nil)
}

pub fn the_pending_input_credit_uses_the_fixed_30_second_deadline_test() {
  let #(connection, events, feeds) = blocked_window()
  assert connection.send("x") == Ok(Nil)
  assert process.receive(feeds, 1000) == Ok(1)
  let assert Ok(consumed.Failed(reason)) = process.receive(events, 31_500)
    as "The fixed weft credit deadline ends a blocked feed."
  assert string.contains(reason, "expired")
  let assert Ok(consumed.Closed(_)) = process.receive(events, 1000)
    as "Expiry requests closure from the original attachment."
}

pub fn blocked_input_does_not_block_output_or_request_cancellation_test() {
  let #(started, server) = start_client()
  await_method(server, "initialized", 1)
  peer.mode(server, peer.Blocked)
  assert client.sync(started, [
      client.Open(path, "gleam", string.repeat("a", 20_000)),
    ])
    == Ok(Nil)
  await_feeds(server, 3)
  assert peer.emit(server, progress("loading", "Loading", "begin")) == Ok(Nil)
  assert client.ready(started, 0, 20) == Ok(client.StillBusy(["Loading"]))
  assert client.definition(started, path, range.Position(0, 0), 25)
    == Error(client.TimedOut(25))
  assert peer.emit(server, progress("loading", "Loading", "end")) == Ok(Nil)
  assert client.ready(started, 0, 1000) == Ok(client.Quiet)
  assert client.stop(started, 1) == client.Forced
}

pub fn fragmented_stdout_is_acknowledged_after_exact_state_updates_test() {
  let #(started, server) = start_client()
  let title = string.repeat("t", 40_000)
  let framed = framing.frame(progress("loading", title, "begin"))
  let bytes = bit_array.from_string(framed)
  let assert Ok(first) = bit_array.slice(bytes, 0, 17)
    as "The first chunk leaves an incomplete header."
  let assert Ok(rest) =
    bit_array.slice(bytes, 17, bit_array.byte_size(bytes) - 17)
    as "The remaining stream retains every byte."
  assert peer.raw(server, first) == Ok(Nil)
  assert client.ready(started, 0, 1000) == Ok(client.Quiet)
  assert peer.raw(server, rest) == Ok(Nil)
  assert client.ready(started, 0, 20) == Ok(client.StillBusy([title]))
  assert peer.stderr(server, bit_array.from_string(string.repeat("e", 32_768)))
    == Ok(Nil)
  assert peer.emit(server, progress("loading", title, "end")) == Ok(Nil)
  assert client.stop(started, 1000) == client.Graceful
}

pub fn truncation_and_bad_json_close_the_original_attachment_test() {
  let #(started, server) = start_client()
  let monitor = process.monitor(client.pid(started))
  let assert Error(_) = peer.truncate(server)
    as "Native truncation cannot be acknowledged as consumed."
  assert_failed(monitor)

  let #(started, server) = start_client()
  let monitor = process.monitor(client.pid(started))
  let bad = "Content-Length: 1\r\n\r\n{"
  let assert Error(_) = peer.raw(server, bit_array.from_string(bad))
    as "Malformed complete JSON withholds the physical output credit."
  assert_failed(monitor)
}

pub fn combined_document_text_is_exactly_bounded_before_the_next_effect_test() {
  let #(started, server) = start_client()
  let text = string.repeat("a", 2_097_152)
  assert client.sync(started, [client.Open(path, "gleam", text)]) == Ok(Nil)
  assert client.sync(started, [client.Open("/work/b.gleam", "gleam", text)])
    == Ok(Nil)
  await_method(server, "textDocument/didOpen", 2)
  assert client.synced_text(started, path) == Ok(Some(text))
  let monitor = process.monitor(client.pid(started))
  let assert Error(client.Unavailable(_)) =
    client.sync(started, [client.Change(path, text <> "x")])
    as "One extra retained byte is refused before a didChange is written."
  assert_failed(monitor)
}

pub fn the_registered_document_count_refuses_the_65th_without_lru_eviction_test() {
  let #(started, _server) = start_client()
  list.each(numbers(64), fn(n) {
    assert client.sync(started, [
        client.Open("/work/" <> int.to_string(n) <> ".gleam", "gleam", "x"),
      ])
      == Ok(Nil)
  })
  let assert Ok(paths) = client.open_paths(started)
    as "All 64 registered documents remain held."
  assert list.length(paths) == 64
  let monitor = process.monitor(client.pid(started))
  let assert Error(client.Unavailable(_)) =
    client.sync(started, [client.Open("/work/65.gleam", "gleam", "x")])
    as "Registered custody fails instead of evicting an earlier document."
  assert_failed(monitor)
}

pub fn diagnostic_and_progress_count_exhaustion_is_transport_fatal_test() {
  let #(started, server) = start_client()
  let diagnostic = diagnostic("broken")
  assert peer.emit(server, publication(list.repeat(diagnostic, 200))) == Ok(Nil)
  let assert Ok([#(_, diagnostics)]) = client.diagnostics(started, Some(path))
    as "The exact diagnostic count remains readable."
  assert list.length(diagnostics) == 200
  let monitor = process.monitor(client.pid(started))
  let assert Error(_) =
    peer.emit(server, publication(list.repeat(diagnostic, 201)))
    as "Registered publications are refused instead of silently truncated."
  assert_failed(monitor)

  let #(started, server) = start_client()
  list.each(numbers(64), fn(n) {
    let token = int.to_string(n)
    assert peer.emit(server, progress(token, token, "begin")) == Ok(Nil)
  })
  let assert Ok(client.StillBusy(titles)) = client.ready(started, 0, 20)
    as "All original progress entries remain active."
  assert list.length(titles) == 64
  let monitor = process.monitor(client.pid(started))
  let assert Error(_) = peer.emit(server, progress("65", "65", "begin"))
    as "The 65th entry cannot evict original registered progress."
  assert_failed(monitor)
}

pub fn diagnostic_and_metadata_bytes_are_bounded_before_acknowledgement_test() {
  let #(started, server) = start_client()
  let message = string.repeat("x", 4_194_304)
  let monitor = process.monitor(client.pid(started))
  let assert Error(_) = peer.emit(server, publication([diagnostic(message)]))
    as "The diagnostic budget includes its retained sites and strings."
  assert_failed(monitor)
  let #(started, server) = start_client()
  let monitor = process.monitor(client.pid(started))
  let assert Error(_) = peer.emit(server, progress("load", message, "begin"))
    as "Progress shares the bounded metadata category."
  assert_failed(monitor)
}

pub fn exact_diagnostic_and_metadata_byte_edges_retain_original_evidence_test() {
  let #(started, server) = start_client()
  let site_charge = string.byte_size(uri) + string.byte_size(path) + 256
  let message = string.repeat("d", 4_194_304 - site_charge)
  assert peer.emit(server, publication([diagnostic(message)])) == Ok(Nil)
  let assert Ok([#(_, [kept])]) = client.diagnostics(started, Some(path))
    as "The exact diagnostic budget remains readable."
  assert kept.message == message
  let monitor = process.monitor(client.pid(started))
  let assert Error(_) =
    peer.emit(server, publication([diagnostic(message <> "x")]))
    as "One additional diagnostic byte cannot be acknowledged."
  assert_failed(monitor)

  let #(started, server) = start_client()
  let base =
    string.byte_size("fixture")
    + string.byte_size("gleam")
    + 2
    * string.byte_size("file:///work")
    + string.byte_size("work")
    + 64
  let title =
    string.repeat("m", 4_194_304 - base - string.byte_size("load") - 128)
  assert peer.emit(server, progress("load", title, "begin")) == Ok(Nil)
  let assert Ok(observed) = client.observation_state(started, 1000)
    as "An atomic read adds no retained waiter or authority."
  assert observed.busy == [title]
  let monitor = process.monitor(client.pid(started))
  let assert Error(_) =
    peer.emit(server, progress("load", title <> "x", "begin"))
    as "One additional metadata byte fails before any clean readiness result."
  assert_failed(monitor)
}

pub fn the_registered_uri_store_refuses_513_instead_of_evicting_test() {
  let #(started, server) = start_client()
  list.each(numbers(512), fn(n) {
    let published_uri = "file:///work/" <> int.to_string(n) <> ".gleam"
    assert peer.emit(
        server,
        jsonrpc.notification(
          "textDocument/publishDiagnostics",
          Some(
            json.Object([
              #("uri", json.String(published_uri)),
              #("diagnostics", json.Array([])),
            ]),
          ),
        ),
      )
      == Ok(Nil)
  })
  let assert Ok(stored) = client.diagnostics(started, None)
    as "All 512 original publications remain held."
  assert list.length(stored) == 512
  let monitor = process.monitor(client.pid(started))
  let assert Error(_) = peer.emit(server, publication([]))
    as "A new 513th URI cannot evict earlier registered evidence."
  assert_failed(monitor)
}

pub fn aggregate_json_nodes_are_bounded_in_the_real_registered_actor_test() {
  let #(started, server) = start_client()
  let values = string.join(list.repeat("null", 200_000), ",")
  let body =
    "{\"jsonrpc\":\"2.0\",\"method\":\"custom\",\"params\":[" <> values <> "]}"
  let frame =
    "Content-Length: "
    <> int.to_string(string.byte_size(body))
    <> "\r\n\r\n"
    <> body
  let monitor = process.monitor(client.pid(started))
  let assert Error(_) = peer.raw(server, bit_array.from_string(frame))
    as "The JSON profile counts the complete body including keys and values."
  assert_failed(monitor)
}

pub fn the_128_outstanding_requests_are_admitted_and_the_129th_closes_test() {
  let #(started, server) = start_client()
  let reports = process.new_subject()
  let calls =
    list.map(numbers(128), fn(_) {
      fn() { client.definition(started, path, range.Position(0, 0), 10_000) }
    })
  let _ =
    weft.new([
      fn() {
        Ok(
          weft.new(calls)
          |> weft.limit(128)
          |> weft.deadline(12_000)
          |> weft.start,
        )
      },
    ])
    |> weft.deadline(15_000)
    |> weft.start_relayed(to: reports)
  await_method(server, "textDocument/definition", 128)
  let monitor = process.monitor(client.pid(started))
  let assert Error(client.Unavailable(_)) =
    client.definition(started, path, range.Position(0, 0), 10_000)
    as "The 129th request is refused before physical dispatch."
  assert_failed(monitor)
  let assert Ok(weft.PulledOutcome(weft.Completed(0, outcomes))) =
    process.receive(reports, 2000)
    as "Every previously accepted caller is answered."
  assert list.length(outcomes) == 128
  list.each(outcomes, fn(outcome) {
    let assert weft.Failed(_, client.Unavailable(_)) = outcome
      as "State exhaustion answers all original pending requests."
  })
  assert process.receive(reports, 1000) == Ok(weft.AllDelivered)
}

pub fn registered_diagnostic_positions_and_versions_admit_protocol_boundaries_test() {
  let #(started, server) = start_client()
  let diagnostic =
    protocol.ServerDiagnostic(
      range.Range(
        range.Position(0, 2_147_483_647),
        range.Position(2_147_483_647, 0),
      ),
      query.SeverityError,
      "bounded site",
      None,
    )
  list.each([None, Some(-2_147_483_648), Some(2_147_483_647)], fn(version) {
    let published = protocol.PublishDiagnostics(uri, version, [diagnostic])
    assert peer.emit(server, typed_publication(published)) == Ok(Nil)
    assert client.diagnostics(started, Some(path))
      == Ok([#(path, [diagnostic])])
  })
  assert client.stop(started, 1000) == client.Graceful
}

pub fn every_registered_diagnostic_coordinate_refuses_one_above_uinteger_test() {
  let outside = 2_147_483_648
  let ranges = [
    range.Range(range.Position(outside, 0), range.Position(0, 0)),
    range.Range(range.Position(0, outside), range.Position(0, 0)),
    range.Range(range.Position(0, 0), range.Position(outside, 0)),
    range.Range(range.Position(0, 0), range.Position(0, outside)),
    range.Range(
      range.Position(9_223_372_036_854_775_808, 0),
      range.Position(0, 0),
    ),
  ]
  list.each(ranges, fn(site) {
    let #(started, server) = start_client()
    let diagnostic =
      protocol.ServerDiagnostic(site, query.SeverityError, "d", None)
    let monitor = process.monitor(client.pid(started))
    let assert Error(_) =
      peer.emit(
        server,
        typed_publication(protocol.PublishDiagnostics(uri, None, [diagnostic])),
      )
      as "An out-of-protocol site never receives a consumption acknowledgment."
    let assert Error(client.Unavailable(_)) =
      client.diagnostics(started, Some(path))
      as "Invalid retained numbers cannot become clean diagnostics."
    assert_failed(monitor)
  })
}

pub fn registered_diagnostic_publication_versions_refuse_both_signed_overflows_test() {
  list.each(
    [-2_147_483_649, 2_147_483_648, 9_223_372_036_854_775_808],
    fn(version) {
      let #(started, server) = start_client()
      let monitor = process.monitor(client.pid(started))
      let assert Error(_) =
        peer.emit(
          server,
          typed_publication(protocol.PublishDiagnostics(uri, Some(version), [])),
        )
        as "An empty publication cannot clear retained evidence with an oversized version."
      let assert Error(client.Unavailable(_)) =
        client.diagnostics(started, Some(path))
        as "A refused empty publication cannot be read as clean."
      assert_failed(monitor)
    },
  )
}

pub fn ordinary_channels_keep_their_existing_diagnostic_integer_admission_test() {
  let diagnostic =
    protocol.ServerDiagnostic(
      range.Range(
        range.Position(9_223_372_036_854_775_808, 2_147_483_648),
        range.Position(0, 0),
      ),
      query.SeverityError,
      "ordinary site",
      None,
    )
  let published =
    protocol.PublishDiagnostics(uri, Some(-2_147_483_649), [diagnostic])
  let server =
    fake_server.start(
      json.Object([#("definitionProvider", json.Bool(True))]),
      Nil,
      fn(state, message) {
        case message {
          jsonrpc.ServerRequest(id, "emit", _) -> #(state, [
            fake_server.Reply(typed_publication(published)),
            fake_server.Reply(jsonrpc.response(id, json.Null)),
          ])
          jsonrpc.ServerRequest(id, "shutdown", _) -> #(state, [
            fake_server.Reply(jsonrpc.response(id, json.Null)),
          ])
          jsonrpc.ServerRequest(..)
          | jsonrpc.Notification(..)
          | jsonrpc.Response(..) -> #(state, [])
        }
      },
    )
  let assert Ok(started) =
    client.start(
      fake_server.seam(server),
      client.options("ordinary", root, "gleam"),
    )
    as "The ordinary actor retains its existing profile."

  // The publication precedes the fake's barrier reply, which precedes this read.
  assert client.request(started, protocol.DefinitionFeature, "emit", None, 1000)
    == Ok(json.Null)
  assert client.diagnostics(started, Some(path)) == Ok([#(path, [diagnostic])])
  assert client.stop(started, 1000) == client.Graceful
}

fn start_client() -> #(client.Client, peer.Peer) {
  let server = peer.start()
  let options =
    client.Options(
      ..client.options("fixture", root, "gleam"),
      initialize_ms: 2000,
    )
  let assert Ok(started) = client.start(peer.seam(server), options)
    as "The production actor completes its consumed handshake."
  #(started, server)
}

fn blocked_window() -> #(
  consumed.Connection,
  process.Subject(consumed.Event),
  process.Subject(Int),
) {
  let events = process.new_subject()
  let feeds = process.new_subject()
  let assert Ok(connection) =
    consumed.open(
      fn(sink) {
        Ok(
          consumed.Session(
            fn(bytes) {
              process.send(feeds, bit_array.byte_size(bytes))
              process.receive_forever(process.new_subject())
            },
            fn() { consumed.closed(sink, "closed original blocked attachment") },
          ),
        )
      },
      events,
    )
    as "The fixture owns one original blocked input credit."
  #(connection, events, feeds)
}

fn progress(token: String, title: String, kind: String) -> json.JsonValue {
  jsonrpc.notification(
    "$/progress",
    Some(
      json.Object([
        #("token", json.String(token)),
        #(
          "value",
          json.Object([
            #("kind", json.String(kind)),
            #("title", json.String(title)),
          ]),
        ),
      ]),
    ),
  )
}

fn diagnostic(message: String) -> json.JsonValue {
  let position =
    json.Object([#("line", json.Int(0)), #("character", json.Int(0))])
  json.Object([
    #("range", json.Object([#("start", position), #("end", position)])),
    #("message", json.String(message)),
  ])
}

fn publication(diagnostics: List(json.JsonValue)) -> json.JsonValue {
  jsonrpc.notification(
    "textDocument/publishDiagnostics",
    Some(
      json.Object([
        #("uri", json.String(uri)),
        #("diagnostics", json.Array(diagnostics)),
      ]),
    ),
  )
}

fn await_method(server: peer.Peer, method: String, count: Int) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(5000, 1, fn() {
      let seen = peer.inspect(server).2
      case
        list.length(list.filter(seen, fn(seen) { seen == method })) >= count
      {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "The original physical peer observes exactly the admitted requests."
  Nil
}

fn await_feeds(server: peer.Peer, count: Int) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(1000, 1, fn() {
      case list.length(peer.inspect(server).1) >= count {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "The writer owns a blocked physical feed."
  Nil
}

fn down(monitor: process.Monitor) -> process.ExitReason {
  let assert Ok(reason) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(message) { message.reason })
    |> process.selector_receive(2000)
    as "The original client exits after its attachment close witness."
  reason
}

fn numbers(n: Int) -> List(Int) {
  int.range(from: n, to: 0, with: [], run: list.prepend)
}

fn assert_failed(monitor: process.Monitor) -> Nil {
  let assert process.Abnormal(_) = down(monitor)
    as "Protocol/state exhaustion retains its failure instead of inventing clean shutdown."
  Nil
}

fn physical_feeds(feeds: process.Subject(Int), count: Int) -> Nil {
  case count {
    0 -> Nil
    _ -> {
      assert process.receive(feeds, 1000) == Ok(8192)
      physical_feeds(feeds, count - 1)
    }
  }
}

fn typed_publication(published: protocol.PublishDiagnostics) -> json.JsonValue {
  let fields = [
    #("uri", json.String(published.uri)),
    #(
      "diagnostics",
      json.Array(
        list.map(published.diagnostics, fn(diagnostic) {
          let position = fn(position: range.Position) {
            json.Object([
              #("line", json.Int(position.line)),
              #("character", json.Int(position.character)),
            ])
          }
          json.Object([
            #(
              "range",
              json.Object([
                #("start", position(diagnostic.range.start)),
                #("end", position(diagnostic.range.end)),
              ]),
            ),
            #("message", json.String(diagnostic.message)),
          ])
        }),
      ),
    ),
  ]
  let fields = case published.version {
    None -> fields
    Some(version) -> [#("version", json.Int(version)), ..fields]
  }
  jsonrpc.notification(
    "textDocument/publishDiagnostics",
    Some(json.Object(fields)),
  )
}
