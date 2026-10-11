//// The native transport parks operations before begin and retains native owners
//// when their leaf worker disappears. Delayed resource fixtures make the drain
//// witness observable rather than inferring cleanup from a cancellation call.

import client/codex/oauth
import client/codex/profile
import client/codex/transport
import core/accounting
import gleam/bit_array
import gleam/crypto
import gleam/erlang/process
import gleam/option.{None}
import host/bootstrap
import provider/adapter/responses
import provider/http
import provider/model
import provider/stream
import support/provider_http as peer
import weft

pub fn codex_prepared_cancel_before_begin_runs_no_operation_test() {
  let events = process.new_subject()
  let calls = process.new_subject()
  let assert Ok(prepared) =
    transport.prepare_with(events, fn(_) {
      process.send(calls, Nil)
      Ok(Nil)
    })
    as "The operation parks before publication."
  let watch = process.monitor(prepared.running.owner)
  prepared.running.cancel()
  assert down(watch, 1000) == Ok(process.Normal)
  prepared.begin()
  assert process.receive(calls, 20) == Error(Nil)
}

pub fn codex_prepared_begin_runs_operation_once_test() {
  let calls = process.new_subject()
  let assert Ok(prepared) =
    transport.prepare_with(process.new_subject(), fn(_) {
      process.send(calls, Nil)
      Ok(Nil)
    })
    as "The worker owns the begin permit."
  let watch = process.monitor(prepared.running.owner)
  prepared.begin()
  prepared.begin()
  assert process.receive(calls, 1000) == Ok(Nil)
  assert down(watch, 1000) == Ok(process.Normal)
  assert process.receive(calls, 20) == Error(Nil)
}

pub fn codex_worker_loss_waits_for_adopted_resource_drain_test() {
  let resource_ready = process.new_subject()
  let cancel_seen = process.new_subject()
  let native_owner =
    weft.new_prepared([
      weft.managed(fn(_) {
        let cancel = process.new_subject()
        let release = process.new_subject()
        process.send(resource_ready, #(cancel, release))
        process.receive_forever(cancel)
        process.send(cancel_seen, Nil)
        process.receive_forever(release)
        Ok(Nil)
      }),
    ])
    |> weft.start_witnessed
  let assert Ok(#(cancel, release)) = process.receive(resource_ready, 1000)
    as "The resource publishes its own control subjects."
  let adopted = process.new_subject()
  let assert Ok(prepared) =
    transport.prepare_with(process.new_subject(), fn(ledger) {
      let assert weft.Adopted =
        weft.adopt(ledger, weft.witness_pid(native_owner), fn() {
          process.send(cancel, Nil)
        })
        as "The resource enters surviving custody before publication."
      process.send(adopted, process.self())
      process.receive_forever(process.new_subject())
      Ok(Nil)
    })
    as "The operation is prepared."
  let watch = process.monitor(prepared.running.owner)
  prepared.begin()
  let assert Ok(worker) = process.receive(adopted, 1000)
    as "The worker publishes only after adoption."
  process.kill(worker)
  assert process.receive(cancel_seen, 1000) == Ok(Nil)
  assert down(watch, 20) == Error(Nil)
  process.send(release, Nil)
  assert down(watch, 1000) == Ok(process.Normal)
}

pub fn codex_consumer_loss_cancels_and_drains_native_resources_test() {
  let publication = process.new_subject()
  let consumer =
    weft.new_prepared([
      weft.managed(fn(_) {
        let events = process.new_subject()
        process.send(publication, #(events, process.self()))
        process.receive_forever(process.new_subject())
        Ok(Nil)
      }),
    ])
    |> weft.start_witnessed
  let assert Ok(#(events, consumer_worker)) = process.receive(publication, 1000)
    as "The consumer publishes its event subject."
  let resource_ready = process.new_subject()
  let cancelled = process.new_subject()
  let native_owner =
    weft.new_prepared([
      weft.managed(fn(_) {
        let cancel = process.new_subject()
        let release = process.new_subject()
        process.send(resource_ready, #(cancel, release))
        process.receive_forever(cancel)
        process.send(cancelled, Nil)
        process.receive_forever(release)
        Ok(Nil)
      }),
    ])
    |> weft.start_witnessed
  let assert Ok(#(cancel, release)) = process.receive(resource_ready, 1000)
    as "The native resource is prepared."
  let adopted = process.new_subject()
  let assert Ok(prepared) =
    transport.prepare_with(events, fn(ledger) {
      let assert weft.Adopted =
        weft.adopt(ledger, weft.witness_pid(native_owner), fn() {
          process.send(cancel, Nil)
        })
        as "The resource is adopted before admission."
      process.send(adopted, Nil)
      process.receive_forever(process.new_subject())
      Ok(Nil)
    })
    as "The operation is prepared."
  let watch = process.monitor(prepared.running.owner)
  prepared.begin()
  assert process.receive(adopted, 1000) == Ok(Nil)
  process.kill(consumer_worker)
  assert process.receive(cancelled, 1000) == Ok(Nil)
  assert down(watch, 20) == Error(Nil)
  process.send(release, Nil)
  assert down(watch, 1000) == Ok(process.Normal)
  weft.cancel_witnessed(consumer)
}

pub fn codex_logged_out_refusal_has_no_inference_attempt_and_drains_test() {
  let directory =
    "/var/tmp/loom-codex-native-"
    <> bit_array.base16_encode(crypto.strong_random_bytes(8))
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
    as "The test owns an empty credential directory."
  let authorization = process.new_subject()
  let inference_calls = process.new_subject()
  let inference =
    http.Transport(prepare_streaming: fn(_request, events) {
      process.send(inference_calls, "prepare")
      transport.prepare_with(events, fn(_) {
        process.send(inference_calls, "begin")
        Ok(Nil)
      })
    })
  let native =
    http.Transport(prepare_streaming: fn(request, events) {
      transport.prepare_streaming_with(
        fn(name, ledger) {
          process.send(authorization, name)
          profile.auth_at(directory, name, oauth.services_on(ledger))
        },
        inference,
        "work",
        request,
        events,
      )
    })
  let request =
    http.HttpRequest(
      "POST",
      "/responses",
      [#("content-type", "application/json"), #("accept", "text/event-stream")],
      "{}",
    )
  let owners = process.new_subject()
  let outcome =
    stream.run_tracked(
      native,
      request,
      responses.subscription_response_machine(
        model.ResolvedModel(
          "codex-subscription",
          "gpt-6-sol",
          model.ThinkingOff,
          200_000,
          8192,
        ),
        now: 1000,
      ),
      fn(_) { panic as "A local credential refusal emits no delta." },
      fn(running) {
        assert process.receive(authorization, 0) == Error(Nil)
        process.send(owners, process.monitor(running.owner))
      },
      control: process.new_subject(),
      consumer: process.self(),
      within: 1000,
    )
  let assert stream.AttemptTerminal(stream.Failed(error, report)) = outcome
    as "The real Responses fold retains the local authentication refusal."
  assert stream.underlying_error(error)
    == stream.HttpError(
      401,
      "responses_error",
      "Responses provider reported failure",
      None,
    )
  assert report == accounting.empty()
  assert accounting.attempts(report) == 0
  assert process.receive(authorization, 0) == Ok("work")
  assert process.receive(authorization, 0) == Error(Nil)
  assert process.receive(inference_calls, 0) == Error(Nil)
  let assert Ok(watch) = process.receive(owners, 0)
    as "Custody was published before authorization began."
  assert down(watch, 1000) == Ok(process.Normal)
}

pub fn codex_authorized_stream_retains_native_creator_until_response_end_test() {
  let #(_, report) =
    peer.with_server(
      [peer.PacedExchange("native bridge", "native answer", peer.Paced(20))],
      fn(url) {
        let events = process.new_subject()
        let native = http.httpc_transport()
        let inference =
          http.Transport(prepare_streaming: fn(request, events) {
            assert request.url == "https://api.openai.com/v1/responses"
            assert request.headers
              == [
                #("authorization", "Bearer fixture-bearer"),
                #("content-type", "application/json"),
                #("accept", "text/event-stream"),
              ]
            native.prepare_streaming(
              http.HttpRequest(..request, url: url <> "/v1/messages", headers: [
                #("content-type", "application/json"),
                #("x-api-key", peer.dummy_key),
              ]),
              events,
            )
          })
        let assert Ok(prepared) =
          transport.prepare_streaming_with(
            fn(_, _) { Ok("fixture-bearer") },
            inference,
            "work",
            http.HttpRequest(
              "POST",
              "/responses",
              [
                #("content-type", "application/json"),
                #("accept", "text/event-stream"),
              ],
              "{\"model\":\"fixture\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"native bridge\"}]}]}",
            ),
            events,
          )
          as "The authorized bridge parks the real native HTTP owner."
        let watch = process.monitor(prepared.running.owner)
        prepared.begin()
        let assert Ok(http.ResponseStatus(200, _)) =
          process.receive(events, 2000)
          as "The authorized request reaches the loopback provider."
        assert await_response_end(events) > 0
        assert down(watch, 2000) == Ok(process.Normal)
      },
    )
  let assert Ok([observed]) = report
    as "The peer observes exactly one authorized native request."
  assert observed.latest == peer.UserPrompt("native bridge")
}

// A paced peer keeps the response open beyond the bridge's begin call. Only
// a complete native response may satisfy this test; cancellation is not EOF.
fn await_response_end(events: process.Subject(http.HttpEvent)) -> Int {
  let assert Ok(event) = process.receive(events, 2000)
    as "The creator survives until the native response ends."
  case event {
    http.ResponseChunk(chunk) ->
      bit_array.byte_size(chunk) + await_response_end(events)
    http.ResponseEnd -> 0
    _ -> panic as "The authorized response terminates without transport failure."
  }
}

fn down(watch: process.Monitor, timeout: Int) {
  process.new_selector()
  |> process.select_specific_monitor(watch, fn(event) { event.reason })
  |> process.selector_receive(timeout)
}
