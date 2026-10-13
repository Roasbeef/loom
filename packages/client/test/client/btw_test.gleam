//// Side inference uses production provider request encoding over scripted HTTP.
//// The real session store proves that auxiliary usage does not add transcript
//// entries. Controlled transports expose the request prefix and cancellation.

import client/btw
import core/clock
import core/json
import core/message
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import provider/adapter/openai
import provider/gateway
import provider/http
import provider/model
import provider/secret
import session/session
import session_view/btw as view
import storage/storage
import support/addresses
import support/provider
import weft/poll
import weft/registry as address
import weft/state_machine as sm

type HeldControl {
  BeginHeld

  CancelHeld
}

fn identity() {
  model.ResolvedModel(
    "fixture",
    "fixture-model",
    model.ThinkingOff,
    100_000,
    4096,
  )
}

fn request(text) {
  model.ProviderRequest(
    model.ForResolved(identity()),
    Some("Pinned system."),
    [message.UserMessage([message.UserText(text, None)], 0, None)],
    [
      model.ToolSpec(
        "dangerous",
        "An advertised tool with no side executor.",
        json.Object([]),
      ),
    ],
    None,
  )
}

fn fixture(response: String) {
  let assert Ok(opened) = session.open_memory(clock.fixed(1000))
    as "memory session opens"
  let observed = process.new_subject()
  let transport =
    provider.transport(fn(request, events) {
      process.send(observed, request)
      process.send(events, http.ResponseStatus(200, []))
      process.send(events, http.ResponseChunk(bit_array.from_string(response)))
      process.send(events, http.ResponseEnd)
    })
  let gateway =
    gateway.new(
      transport,
      secret.from_list([#("key", "dummy")]),
      clock.fixed(1000),
    )
    |> gateway.add_provider(gateway.OpenAiCompatibleProvider(
      "fixture",
      "https://fixture.invalid/v1",
      "key",
    ))
    |> gateway.route(model.Main, [identity()])
  let name = addresses.new()
  let assert Ok(started) = btw.start(name, gateway, opened)
    as "side service starts"
  #(name, opened, observed, started.pid)
}

fn text_response() {
  "data: {\"choices\":[{\"delta\":{\"content\":\"Side answer.\"},\"finish_reason\":null}]}\n\n"
  <> "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":3,\"prompt_tokens_details\":{\"cached_tokens\":80}}}\n\n"
  <> "data: [DONE]\n\n"
}

fn completed(name, owner) {
  let result =
    poll.until(within: 5000, every: 10, attempt: fn() {
      case
        btw.query(name, owner, "main", view.Read) |> result.try(view.decode)
      {
        Ok(board) if board.status != "running" -> poll.Done(board)
        Ok(_) -> poll.Retry
        Error(reason) -> poll.Fail(reason)
      }
    })
  let assert poll.Answered(board) = result
    as "side request reaches a terminal within five seconds"
  board
}

fn field(value, key) {
  let assert json.Object(fields) = value as "wire body is an object"
  let assert Ok(value) = list.key_find(fields, key) as "wire field is present"
  value
}

fn wire_body(observed: process.Subject(http.HttpRequest)) {
  let assert Ok(sent) = process.receive(observed, 1000)
    as "provider received a request"
  let assert Ok(body) = json.parse(sent.body) as "request is valid JSON"
  body
}

fn stop(pid) {
  process.unlink(pid)
  process.kill(pid)
}

pub fn frozen_followups_refresh_private_history_and_auxiliary_usage_test() {
  let #(name, opened, observed, pid) = fixture(text_response())
  let assert Ok(Nil) =
    address.send(
      name,
      btw.Capture("main", "snapshot-1", request("Original main context.")),
    )
    as "capture is admitted"
  let assert Ok(first) =
    btw.query(name, 1, "main", view.Ask("Why?")) |> result.try(view.decode)
    as "first question is admitted"
  assert first.snapshot == "snapshot-1"
  let done = completed(name, 1)
  assert done.status == "ready"
  assert done.exchanges == [view.Exchange("Why?", "Side answer.")]
  let first_wire = wire_body(observed)
  let assert json.Array(messages) = field(first_wire, "messages")
    as "wire has messages"
  let original =
    openai.build_request(
      "https://fixture.invalid/v1",
      "dummy",
      identity(),
      request("Original main context."),
    )
  let assert Ok(original) = json.parse(original.body)
    as "main request is valid JSON"
  assert field(original, "messages") == json.Array(list.take(messages, 2))
  assert field(original, "tools") == field(first_wire, "tools")
  assert field(original, "max_completion_tokens")
    == field(first_wire, "max_completion_tokens")

  let assert Ok(Nil) =
    address.send(
      name,
      btw.Capture(
        "main",
        "snapshot-2",
        request("Newer compacted main context."),
      ),
    )
    as "main advances independently"
  let assert Ok(_) = btw.query(name, 1, "main", view.Ask("Explain more."))
    as "follow-up is admitted"
  assert completed(name, 1).snapshot == "snapshot-1"
  let second_wire = wire_body(observed)
  assert field(first_wire, "tools") == field(second_wire, "tools")
  assert string.contains(json.to_string(second_wire), "Original main context.")
  assert !string.contains(json.to_string(second_wire), "Newer compacted")
  assert string.contains(json.to_string(second_wire), "Side answer.")
  let assert Ok(private) =
    btw.query(name, 2, "main", view.Read) |> result.try(view.decode)
    as "another attachment has its own board"
  assert private.exchanges == []
  let assert Ok(refreshed) =
    btw.query(name, 1, "main", view.Refresh) |> result.try(view.decode)
    as "explicit refresh captures newer context"
  assert refreshed.snapshot == "snapshot-2"
  assert refreshed.exchanges == []
  assert storage.scan_entries(opened.store, storage.entry_scan()) == Ok([])
  let assert Ok(usage) = storage.scan_usage(opened.store, storage.usage_scan())
    as "auxiliary usage is recorded"
  assert list.length(usage) == 2
  assert list.all(usage, fn(row) {
    row.entry_id == None && row.usage.cache_read == 80
  })
  stop(pid)
}

pub fn generated_tool_call_is_never_executed_or_replayed_test() {
  let response =
    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-1\",\"type\":\"function\",\"function\":{\"name\":\"dangerous\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]\n\n"
  let #(name, opened, observed, pid) = fixture(response)
  let assert Ok(Nil) =
    address.send(
      name,
      btw.Capture("main", "snapshot", request("Do main work.")),
    )
    as "capture exists"
  let assert Ok(_) =
    btw.query(name, 1, "main", view.Ask("Run the dangerous tool."))
    as "side question is admitted"
  let done = completed(name, 1)
  assert done.status == "failed"
  assert string.contains(done.notice, "nothing was executed")
  let _ = wire_body(observed)
  assert process.receive(observed, 20) == Error(Nil)
  assert storage.scan_entries(opened.store, storage.entry_scan()) == Ok([])
  assert result.is_error(btw.query(name, 1, "main", view.Ask("Continue.")))
  stop(pid)
}

pub fn question_history_and_snapshot_bounds_refuse_before_provider_dispatch_test() {
  let #(name, _, observed, pid) = fixture(text_response())
  assert result.is_error(btw.query(name, 1, "main", view.Ask("No base yet.")))
  let assert Ok(Nil) =
    address.send(name, btw.Capture("main", "snapshot", request("Base.")))
    as "capture exists"
  assert result.is_error(btw.query(
    name,
    1,
    "main",
    view.Ask(string.repeat("x", 8193)),
  ))
  list.each([1, 2, 3, 4, 5, 6, 7, 8], fn(_) {
    let assert Ok(_) = btw.query(name, 1, "main", view.Ask("Question."))
      as "bounded question admitted"
    assert completed(name, 1).status == "ready"
    let _ = wire_body(observed)
  })
  assert result.is_error(btw.query(name, 1, "main", view.Ask("Ninth question.")))
  assert process.receive(observed, 20) == Error(Nil)
  let assert Ok(_) = btw.query(name, 1, "main", view.Clear)
    as "clear releases history"
  let assert Ok(empty) =
    btw.query(name, 1, "main", view.Read) |> result.try(view.decode)
    as "clear is observable"
  assert empty.exchanges == []
  stop(pid)
}

pub fn gateway_incarnation_reset_and_disconnect_forget_private_content_test() {
  let #(name, _, observed, pid) = fixture(text_response())
  let assert Ok(Nil) =
    address.send(name, btw.Capture("main", "snapshot", request("Base.")))
    as "capture exists"
  let assert Ok(_) = btw.query(name, 1, "main", view.Ask("Private question."))
    as "question admitted"
  assert completed(name, 1).status == "ready"
  let _ = wire_body(observed)
  let assert Ok(Nil) = address.send(name, btw.Reset)
    as "gateway restart retires prior attachments"
  let assert Ok(empty) =
    btw.query(name, 1, "main", view.Read) |> result.try(view.decode)
    as "reused connection number cannot recover old content"
  assert empty.exchanges == []
  let assert Ok(_) = btw.query(name, 1, "main", view.Ask("Another question."))
    as "new incarnation can ask"
  assert completed(name, 1).status == "ready"
  let _ = wire_body(observed)
  let assert Ok(Nil) = address.send(name, btw.Forget(1))
    as "disconnect releases the conversation"
  let assert Ok(empty) =
    btw.query(name, 1, "main", view.Read) |> result.try(view.decode)
    as "forgotten conversation is empty"
  assert empty.exchanges == []
  stop(pid)
}

pub fn cancellation_holds_the_slot_until_drain_and_disconnect_cancels_test() {
  let assert Ok(opened) = session.open_memory(clock.fixed(1000))
    as "session opens"
  let observed = process.new_subject()
  let transport =
    http.Transport(prepare_streaming: fn(_request, events) {
      let assert Ok(owner) =
        sm.new(Nil, Nil)
        |> sm.on_event(fn(_, _, event) {
          case event {
            BeginHeld -> {
              process.send(observed, Nil)
              process.send(events, http.ResponseStatus(200, []))
              sm.keep(Nil)
            }
            CancelHeld -> {
              process.send(events, http.ResponseEnd)
              sm.stop()
            }
          }
        })
        |> sm.unlinked
        |> sm.start
        as "held transport starts parked"
      Ok(
        http.PreparedRequest(
          http.RunningRequest(owner.pid, fn() {
            process.send(owner.data, CancelHeld)
          }),
          fn() { process.send(owner.data, BeginHeld) },
        ),
      )
    })
  let gateway =
    gateway.new(
      transport,
      secret.from_list([#("key", "dummy")]),
      clock.fixed(1000),
    )
    |> gateway.add_provider(gateway.OpenAiCompatibleProvider(
      "fixture",
      "https://fixture.invalid",
      "key",
    ))
  let name = addresses.new()
  let assert Ok(started) = btw.start(name, gateway, opened)
    as "side service starts"
  let assert Ok(Nil) =
    address.send(name, btw.Capture("main", "base", request("Base")))
    as "base exists"
  let assert Ok(_) = btw.query(name, 1, "main", view.Ask("Held"))
    as "held side request admitted"
  let assert Ok(Nil) = process.receive(observed, 1000) as "request started"
  assert result.is_error(btw.query(name, 1, "main", view.Ask("Overlapping")))
  assert result.is_error(btw.query(name, 1, "main", view.Refresh))
  let assert Ok(_) = btw.query(name, 1, "main", view.Cancel)
    as "cancel is independent of main"
  assert completed(name, 1).status == "failed"
  let assert Ok(_) = btw.query(name, 1, "main", view.Clear)
    as "drained slot may be reused"
  let assert Ok(_) = btw.query(name, 1, "main", view.Ask("Held again"))
    as "new request admitted after drain"
  let assert Ok(Nil) = process.receive(observed, 1000) as "new request started"
  let assert Ok(Nil) = address.send(name, btw.Forget(1)) as "disconnect cancels"
  let ended =
    poll.until(within: 5000, every: 10, attempt: fn() {
      case storage.scan_usage(opened.store, storage.usage_scan()) {
        Ok(rows) ->
          case list.length(rows) == 2 {
            True -> poll.Done(Nil)
            False -> poll.Retry
          }
        Error(_) -> poll.Fail(Nil)
      }
    })
  assert ended == poll.Answered(Nil)
  let assert Ok(board) =
    btw.query(name, 1, "main", view.Read) |> result.try(view.decode)
    as "detached history remains forgotten"
  assert board.exchanges == []
  assert storage.scan_entries(opened.store, storage.entry_scan()) == Ok([])
  stop(started.pid)
}
