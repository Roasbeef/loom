//// Compatibility at the live actor boundary: a legacy actor never receives a
//// new closed-vocabulary constructor just because a caller connected to it.

import client/internal/ffi_remote
import client/remote/address
import client/remote/orchestrator_port
import client/remote/peer_client
import client/remote/peer_codec
import client/remote/peer_service
import client/remote/top_relay
import client/remote_mail
import client/remote_send
import client/remote_top
import core/json
import gleam/erlang/node
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None}
import gleam/string
import weft/actor

// This actor models an older port whose closed message vocabulary has only a
// health question. It is deliberately a real process, not a failure value.
type LegacyMessage {
  LegacyHealth(Subject(Nil))
}

pub fn a_legacy_port_survives_a_new_page_request_test() {
  let legacy_name: process.Name(LegacyMessage) =
    ffi_remote.fixed_name("loom_test_compat_legacy")
  let peer_name: process.Name(peer_service.Message) =
    ffi_remote.fixed_name("loom_test_compat_missing")
  let assert Ok(legacy) =
    actor.new(Nil)
    |> actor.on_message(fn(state, request: LegacyMessage) {
      case request {
        LegacyHealth(reply) -> {
          process.send(reply, Nil)
          actor.continue(state)
        }
      }
    })
    |> actor.named(legacy_name)
    |> actor.unlinked
    |> actor.start
  let watched = process.monitor(legacy.pid)
  let relay =
    top_relay.through(
      fn(_) { Ok(address.Address(node: node.self(), name: peer_name)) },
      top_relay.Timing(
        retry_window_ms: 100,
        create_ms: 100,
        call_ms: 100,
        first_pause_ms: 10,
        longest_pause_ms: 10,
      ),
    )
  assert top_relay.placements(relay, "box") == Error(top_relay.Unsupported)
  let died =
    process.new_selector()
    |> process.select_specific_monitor(watched, fn(_) { Nil })
    |> process.selector_receive(100)
  process.demonitor_process(watched)
  assert died == Error(Nil)
  assert process.call(
      process.named_subject(legacy_name),
      waiting: 1000,
      sending: LegacyHealth,
    )
    == Nil
}

// A live peer service using the same TopHost the legacy port serves.
fn peer(
  top: orchestrator_port.TopHost,
  epoch: String,
) -> address.Address(peer_service.Message) {
  let name = process.new_name("peer_service")
  let assert Ok(_) = peer_service.start(name, epoch, "build-test", top)
  address.Address(node: node.self(), name:)
}

fn call_peer(
  at: address.Address(peer_service.Message),
  payload: String,
) -> String {
  process.call(
    process.named_subject(at.name),
    waiting: 1000,
    sending: fn(reply) { peer_service.Exchange(payload, reply) },
  )
}

pub fn features_bind_correlation_version_and_bounded_revisions_test() {
  let at = peer(orchestrator_port.refusing_top(), "epoch-a")
  let answer = call_peer(at, peer_codec.features_request("request-a"))
  let assert Ok(peer_codec.FeaturesResponse("request-a", features)) =
    peer_codec.decode_response(
      answer,
      "request-a",
      peer_codec.feature_reply_bytes,
    )
  assert features.epoch == "epoch-a"
  assert features.build == "build-test"
  assert list.length(features.revisions) == 8
  assert list.contains(features.revisions, "094.stop.1")
  assert peer_codec.decode_response(
      answer,
      "another",
      peer_codec.feature_reply_bytes,
    )
    == Error("reply version or correlation does not match")
}

pub fn malformed_oversized_and_unknown_requests_never_dispatch_test() {
  let effects = process.new_subject()
  let at =
    peer(
      orchestrator_port.TopHost(
        ..orchestrator_port.refusing_top(),
        stop: fn(_, _) {
          process.send(effects, Nil)
          Ok(Nil)
        },
      ),
      "epoch-a",
    )
  let bad = call_peer(at, "{bad")
  assert peer_codec.decode_response(bad, "", peer_codec.feature_reply_bytes)
    == Error("invalid identifier")
  let future =
    call_peer(at, "{\"v\":2,\"op\":\"features\",\"request_id\":\"r\"}")
  assert peer_codec.decode_response(future, "r", peer_codec.feature_reply_bytes)
    == Ok(peer_codec.Unsupported("r"))
  let wrong =
    call_peer(
      at,
      peer_codec.operation_request(
        "r",
        "epoch-a",
        "094.stop.2",
        json.Array([json.String("s")]),
      ),
    )
  assert peer_codec.decode_response(wrong, "r", peer_codec.feature_reply_bytes)
    == Ok(peer_codec.Unsupported("r"))
  let invalid_body =
    call_peer(
      at,
      peer_codec.operation_request("r", "epoch-a", "094.stop.1", json.Array([])),
    )
  assert peer_codec.decode_response(
      invalid_body,
      "r",
      peer_codec.feature_reply_bytes,
    )
    == Ok(peer_codec.Malformed("r"))
  let stale =
    call_peer(
      at,
      peer_codec.operation_request(
        "r",
        "epoch-old",
        "094.stop.1",
        json.Array([json.String("s")]),
      ),
    )
  assert peer_codec.decode_response(stale, "r", peer_codec.feature_reply_bytes)
    == Ok(peer_codec.Stale("r"))
  let oversized =
    call_peer(at, string.repeat("x", peer_codec.operation_bytes + 1))
  assert string.contains(oversized, "oversized")
  assert process.receive(effects, 0) == Error(Nil)
}

pub fn an_oversized_request_never_reaches_the_host_test() {
  let effects = process.new_subject()
  let at =
    peer(
      orchestrator_port.TopHost(
        ..orchestrator_port.refusing_top(),
        send: fn(_, _, _, _) {
          process.send(effects, Nil)
          Ok(json.Null)
        },
      ),
      "epoch-a",
    )
  assert peer_client.call(
      at,
      "094.send.1",
      json.Array([
        json.String("s"),
        json.String("m"),
        json.String(string.repeat("x", peer_codec.operation_bytes)),
      ]),
      1000,
    )
    == Error(peer_client.RequestTooLarge)
  assert process.receive(effects, 0) == Error(Nil)
}

pub fn oversized_reply_after_a_send_remains_unknown_test() {
  let effects = process.new_subject()
  let at =
    peer(
      orchestrator_port.TopHost(
        ..orchestrator_port.refusing_top(),
        send: fn(_, _, _, _) {
          process.send(effects, Nil)
          Ok(json.String(string.repeat("x", peer_codec.operation_bytes)))
        },
      ),
      "epoch-a",
    )
  let relay =
    top_relay.through(
      fn(_) { Ok(at) },
      top_relay.Timing(
        retry_window_ms: 1000,
        create_ms: 500,
        call_ms: 500,
        first_pause_ms: 10,
        longest_pause_ms: 20,
      ),
    )
  let assert Error(top_relay.Unreadable(reason)) =
    top_relay.send(relay, "box", "s", "m", "hello")
  assert process.receive(effects, 1000) == Ok(Nil)
  assert string.contains(reason, "size limit")
  assert top_relay.outcome_unknown(top_relay.Unreadable(reason))
}

pub fn the_existing_send_text_bound_survives_json_escaping_test() {
  let received = process.new_subject()
  let at =
    peer(
      orchestrator_port.TopHost(
        ..orchestrator_port.refusing_top(),
        send: fn(_, _, _, text) {
          process.send(received, string.byte_size(text))
          Ok(remote_mail.encode_landing(remote_mail.Admitted))
        },
      ),
      "epoch-a",
    )
  let relay = top_relay.through(fn(_) { Ok(at) }, top_relay.production())
  assert top_relay.send(
      relay,
      "box",
      "s",
      "m",
      string.repeat("\n", remote_send.max_text_bytes),
    )
    == Ok(remote_mail.Admitted)
  assert process.receive(received, 1000) == Ok(remote_send.max_text_bytes)
}

// The intermediary returns a real old peer's features only after publishing a
// replacement at the selected name, making the race deterministic.
pub fn a_replacement_between_features_and_dispatch_rejects_the_old_epoch_test() {
  let effects = process.new_subject()
  let top =
    orchestrator_port.TopHost(
      ..orchestrator_port.refusing_top(),
      stop: fn(_, _) {
        process.send(effects, "stopped")
        Ok(Nil)
      },
    )
  let old = peer(top, "epoch-old")
  let name = process.new_name("replacement_peer")
  let assert Ok(_) =
    actor.new(Nil)
    |> actor.on_message(fn(state, message: peer_service.Message) {
      let peer_service.Exchange(payload, reply) = message
      let old_features = call_peer(old, payload)
      let assert Ok(Nil) = process.unregister(name)
      let assert Ok(_) = peer_service.start(name, "epoch-new", "build-new", top)
      process.send(reply, old_features)
      actor.continue(state)
    })
    |> actor.named(name)
    |> actor.start
  let at = address.Address(node: node.self(), name:)
  assert peer_client.call(
      at,
      "094.stop.1",
      json.Array([json.String("s")]),
      1000,
    )
    == Error(peer_client.Stale)
  assert process.receive(effects, 0) == Error(Nil)
}

pub fn mismatched_feature_correlation_never_dispatches_test() {
  let effects = process.new_subject()
  let name = process.new_name("wrong_features")
  let assert Ok(_) =
    actor.new(Nil)
    |> actor.on_message(fn(state, message: peer_service.Message) {
      let peer_service.Exchange(_payload, reply) = message
      process.send(effects, "feature request")
      process.send(
        reply,
        peer_codec.encode_response(peer_codec.FeaturesResponse(
          "wrong",
          peer_codec.Features(
            epoch: "epoch-a",
            build: "build",
            revisions: peer_codec.revisions,
          ),
        )),
      )
      actor.continue(state)
    })
    |> actor.named(name)
    |> actor.start
  let at = address.Address(node: node.self(), name:)
  assert peer_client.call(
      at,
      "094.stop.1",
      json.Array([json.String("s")]),
      1000,
    )
    == Error(peer_client.InvalidFeatures)
  assert process.receive(effects, 1000) == Ok("feature request")
  assert process.receive(effects, 0) == Error(Nil)
}

pub fn a_lost_mutation_stays_unknown_when_later_features_are_unsupported_test() {
  let sent = process.new_subject()
  let name = process.new_name("changing_features")
  let assert Ok(_) =
    actor.new(0)
    |> actor.on_message(fn(seen, message: peer_service.Message) {
      let peer_service.Exchange(payload, reply) = message
      case peer_codec.decode_request(payload) {
        Ok(peer_codec.FeaturesRequest(id)) if seen == 0 -> {
          process.send(
            reply,
            peer_codec.encode_response(peer_codec.FeaturesResponse(
              id,
              peer_codec.Features(
                epoch: "epoch-a",
                build: "build",
                revisions: peer_codec.revisions,
              ),
            )),
          )
          actor.continue(1)
        }
        Ok(peer_codec.FeaturesRequest(id)) -> {
          process.send(
            reply,
            peer_codec.encode_response(peer_codec.Unsupported(id)),
          )
          actor.continue(seen)
        }
        Ok(peer_codec.OperationRequest(..)) -> {
          process.send(sent, "created")
          actor.continue(seen)
        }
        Error(_) -> actor.continue(seen)
      }
    })
    |> actor.named(name)
    |> actor.start
  let at = address.Address(node: node.self(), name:)
  let relay =
    top_relay.through(
      fn(_) { Ok(at) },
      top_relay.Timing(
        retry_window_ms: 500,
        create_ms: 100,
        call_ms: 100,
        first_pause_ms: 10,
        longest_pause_ms: 20,
      ),
    )
  assert top_relay.create(
      relay,
      "box",
      "request",
      remote_top.Folder("/work"),
      "default",
      None,
    )
    == Error(top_relay.Silent)
  assert process.receive(sent, 1000) == Ok("created")
  assert process.receive(sent, 0) == Error(Nil)
}

pub fn the_feature_request_and_revision_list_have_their_own_bounds_test() {
  let at = peer(orchestrator_port.refusing_top(), "epoch-a")
  let request =
    json.to_string(
      json.Object([
        #("v", json.Int(1)),
        #("op", json.String("features")),
        #("request_id", json.String("r")),
        #(
          "padding",
          json.String(string.repeat("x", peer_codec.feature_request_bytes)),
        ),
      ]),
    )
  let response = call_peer(at, request)
  assert peer_codec.decode_response(
      response,
      "r",
      peer_codec.feature_reply_bytes,
    )
    == Ok(peer_codec.Oversized("r"))
  assert peer_codec.decode_response(
      string.repeat("x", peer_codec.feature_reply_bytes + 1),
      "r",
      peer_codec.feature_reply_bytes,
    )
    == Error("oversized")
  let too_many =
    peer_codec.encode_response(peer_codec.FeaturesResponse(
      "r",
      peer_codec.Features(
        epoch: "epoch-a",
        build: "build",
        revisions: list.repeat("094.stop.1", peer_codec.max_revisions + 1),
      ),
    ))
  assert peer_codec.decode_response(
      too_many,
      "r",
      peer_codec.feature_reply_bytes,
    )
    == Error("too many revisions")
}

pub fn an_old_caller_can_still_use_the_new_daemons_legacy_port_test() {
  let top =
    orchestrator_port.TopHost(
      ..orchestrator_port.refusing_top(),
      placements: fn(_) { Ok(remote_top.encode_offers(remote_top.no_offers())) },
    )
  let legacy_name = process.new_name("legacy_port")
  let assert Ok(_) =
    orchestrator_port.start_with_top(
      legacy_name,
      fn(_) { Ok(orchestrator_port.NotOwned) },
      fn(_, _) { Error(orchestrator_port.peer_unserved) },
      fn(_) { Error("not_found") },
      orchestrator_port.declining(),
      orchestrator_port.refusing_spawns(),
      orchestrator_port.refusing_children(),
      orchestrator_port.unheld,
      orchestrator_port.unreported(),
      top,
    )
  let at = address.Address(node: node.self(), name: legacy_name)
  let _stable = peer(top, "epoch-a")
  let assert Ok(Ok(offers)) = orchestrator_port.ask_placements(at, 1000)
  assert remote_top.decode_offers(offers) == Ok(remote_top.no_offers())
}

pub fn negotiation_and_dispatch_share_the_original_deadline_test() {
  let seen = process.new_subject()
  let replies = process.new_subject()
  let name = process.new_name("slow_peer")
  let assert Ok(_) =
    actor.new(Nil)
    |> actor.on_message(fn(state, message: peer_service.Message) {
      let peer_service.Exchange(payload, reply) = message
      case peer_codec.decode_request(payload) {
        Ok(peer_codec.FeaturesRequest(id)) -> {
          process.sleep(250)
          process.send(
            reply,
            peer_codec.encode_response(peer_codec.FeaturesResponse(
              id,
              peer_codec.Features(
                epoch: "epoch-a",
                build: "build",
                revisions: peer_codec.revisions,
              ),
            )),
          )
        }
        Ok(peer_codec.OperationRequest(id:, ..)) -> {
          process.send(seen, "operation")
          process.sleep(700)
          process.send(
            reply,
            peer_codec.encode_response(peer_codec.OperationResponse(
              id,
              json.Null,
            )),
          )
        }
        Error(_) -> Nil
      }
      actor.continue(state)
    })
    |> actor.named(name)
    |> actor.start
  let at = address.Address(node: node.self(), name:)
  process.spawn(fn() {
    process.send(
      replies,
      peer_client.call(at, "094.stop.1", json.Array([json.String("s")]), 400),
    )
  })
  assert process.receive(seen, 1000) == Ok("operation")
  assert process.receive(replies, 250) == Ok(Error(peer_client.ReplyLost))
}
