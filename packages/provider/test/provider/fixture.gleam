//// Shared test fixtures: recorded-style SSE transcripts, fixture
//// transports, and a pure driver for response machines. No live network
//// anywhere — transports replay scripted `HttpEvent`s.

import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import provider/http.{
  type HttpEvent, type HttpRequest, type Transport, ResponseChunk, ResponseEnd,
  ResponseStatus, Transport,
}
import provider/model.{
  type ProviderRequest, type ResolvedModel, ProviderRequest, ResolvedModel,
  ThinkingOff,
}
import provider/stream.{type ResponseMachine, type StreamEvent}

type ScriptControl {
  BeginScript
  CancelScript
  CreatorExited
}

/// A resolved identity used across the adapter tests.
pub fn resolved(
  provider provider: String,
  model_id model_id: String,
) -> ResolvedModel {
  ResolvedModel(
    provider:,
    model_id:,
    thinking: ThinkingOff,
    context_window: 200_000,
    max_output_tokens: 8192,
  )
}

/// A minimal provider request targeting a pre-resolved identity.
pub fn request_for(target: ResolvedModel) -> ProviderRequest {
  ProviderRequest(
    target: model.ForResolved(target),
    system: Some("You are a helpful assistant."),
    messages: [],
    tools: [],
    max_output_tokens: None,
  )
}

/// One SSE event as wire text: `event:` line, `data:` line, blank line.
pub fn sse_event(name: String, data: String) -> String {
  "event: " <> name <> "\ndata: " <> data <> "\n\n"
}

/// A bare `data:` SSE event (the chat-completions dialect).
pub fn sse_data(data: String) -> String {
  "data: " <> data <> "\n\n"
}

/// The response-event script for a 200 SSE body sent as one chunk.
pub fn ok_response(body: String) -> List(HttpEvent) {
  [
    ResponseStatus(status: 200, headers: []),
    ResponseChunk(chunk: bit_array.from_string(body)),
    ResponseEnd,
  ]
}

/// The response-event script for an error status with a JSON body.
pub fn error_response(
  status: Int,
  headers: List(#(String, String)),
  body: String,
) -> List(HttpEvent) {
  [
    ResponseStatus(status:, headers:),
    ResponseChunk(chunk: bit_array.from_string(body)),
    ResponseEnd,
  ]
}

/// A transport that replays the same scripted events for every request.
pub fn transport(events: List(HttpEvent)) -> Transport {
  Transport(prepare_streaming: fn(_request, subject) {
    Ok(
      scripted_request(fn() {
        list.each(events, fn(event) { process.send(subject, event) })
      }),
    )
  })
}

/// A transport that chooses its script per request, for fallback-chain
/// tests and request-inspection tests.
pub fn routing_transport(
  script: fn(HttpRequest) -> List(HttpEvent),
) -> Transport {
  Transport(prepare_streaming: fn(request, subject) {
    Ok(
      scripted_request(fn() {
        list.each(script(request), fn(event) { process.send(subject, event) })
      }),
    )
  })
}

fn scripted_request(run: fn() -> Nil) -> http.PreparedRequest {
  scripted_request_before_return(run, fn(_owner) { Nil })
}

fn scripted_request_before_return(
  run: fn() -> Nil,
  before_return: fn(process.Pid) -> Nil,
) -> http.PreparedRequest {
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
        |> process.selector_receive_forever()
      process.demonitor_process(creator_monitor)
      case command {
        BeginScript -> run()
        CancelScript | CreatorExited -> Nil
      }
    })
  let control = process.receive_forever(ready)
  before_return(owner)
  http.PreparedRequest(
    running: http.RunningRequest(owner:, cancel: fn() {
      process.send(control, CancelScript)
    }),
    begin: fn() { process.send(control, BeginScript) },
  )
}

pub fn parked_owner_reaps_if_prepare_dies_before_return_test() {
  let owners = process.new_subject()
  let creator =
    process.spawn_unlinked(fn() {
      let _request =
        scripted_request_before_return(fn() { Nil }, fn(owner) {
          process.send(owners, owner)
          process.receive_forever(process.new_subject())
        })
      Nil
    })
  let assert Ok(owner) = process.receive(owners, within: 1000)
    as "the parked owner must exist while prepare is still blocked"
  let owner_monitor = process.monitor(owner)

  process.kill(creator)

  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(owner_monitor, fn(down) { down })
    |> process.selector_receive(1000)
    as "creator death must retire the unpublished owner normally"
}

/// Drives a response machine purely — no processes — over one response:
/// status, then body chunks, then end-of-body. Returns every emitted
/// stream event in order.
pub fn drive(
  machine: ResponseMachine(state),
  status status: Int,
  headers headers: List(#(String, String)),
  chunks chunks: List(BitArray),
) -> List(StreamEvent) {
  let state = machine.on_status(machine.init, status, headers)
  let #(state, events) =
    list.fold(chunks, #(state, []), fn(folded, chunk) {
      let #(state, events) = folded
      let #(state, new_events) = machine.on_chunk(state, chunk)
      #(state, list.append(events, new_events))
    })
  list.append(events, machine.on_end(state))
}

/// Drives a machine over a 200 SSE body delivered as one chunk.
pub fn drive_ok(
  machine: ResponseMachine(state),
  body: String,
) -> List(StreamEvent) {
  drive(machine, status: 200, headers: [], chunks: [bit_array.from_string(body)])
}

/// Splits bytes into fixed-size chunks.
pub fn chunked(bytes: BitArray, size: Int) -> List(BitArray) {
  case bit_array.byte_size(bytes) <= size {
    True -> [bytes]
    False -> {
      let head = case bit_array.slice(bytes, 0, size) {
        Ok(head) -> head
        Error(Nil) -> <<>>
      }
      let rest = case
        bit_array.slice(bytes, size, bit_array.byte_size(bytes) - size)
      {
        Ok(rest) -> rest
        Error(Nil) -> <<>>
      }
      [head, ..chunked(rest, size)]
    }
  }
}

/// Renders any value for the secret-leak scan.
pub fn rendered(value: anything) -> String {
  string.inspect(value)
}
