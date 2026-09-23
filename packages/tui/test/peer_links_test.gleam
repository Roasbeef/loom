import core/json
import etui/keys
import gleam/option.{Some}
import tui/daemon/protocol
import tui/peer_links

const inspection = "{\"outgoing\":[{\"session\":\"target-id\",\"target_strand\":\"reviewer\",\"wake\":\"busy_only\",\"metadata\":{\"status\":\"resident\"}}],\"incoming\":[{\"source_session\":\"sender-id\",\"source_strand\":\"builder\",\"target_strand\":\"main\",\"wake\":\"may_wake\",\"metadata\":{\"status\":\"saved\"}}]}"

pub fn inspection_keeps_exact_directions_and_wake_permissions_test() {
  let assert Ok(document) = json.parse(inspection)
  let assert Ok(value) =
    peer_links.decode_inspection(document, "local-id", "main")
  assert value.outgoing
    == [
      peer_links.Grant(
        "local-id",
        "main",
        "target-id",
        "reviewer",
        Some(protocol.BusyOnly),
        peer_links.Available,
      ),
    ]
  assert value.incoming
    == [
      peer_links.Grant(
        "sender-id",
        "builder",
        "local-id",
        "main",
        Some(protocol.MayWake),
        peer_links.Unavailable("saved"),
      ),
    ]
}

pub fn create_link_reviews_exact_pair_and_defaults_to_busy_only_test() {
  let session =
    protocol.Session(
      "target-id",
      "/workspace/review",
      "Review",
      0,
      protocol.Resident("incarnation"),
    )
  let state = peer_links.new("local-id", "main")
  let state = peer_links.loaded(state, [session], peer_links.Inspection([], []))
  let assert peer_links.Continue(state) =
    peer_links.update(keys.Char("l"), state)
    as "expected a local peer-link state transition"
  let assert peer_links.Continue(state) = peer_links.update(keys.Enter, state)
    as "expected a local peer-link state transition"
  let assert peer_links.Continue(state) =
    peer_links.update(keys.Char("r"), state)
    as "expected a local peer-link state transition"
  let assert peer_links.Continue(state) =
    peer_links.update(keys.Char("e"), state)
    as "expected a local peer-link state transition"
  let assert peer_links.Continue(state) =
    peer_links.update(keys.Char("v"), state)
    as "expected a local peer-link state transition"
  let assert peer_links.Continue(state) =
    peer_links.update(keys.Char("i"), state)
    as "expected a local peer-link state transition"
  let assert peer_links.Continue(state) =
    peer_links.update(keys.Char("e"), state)
    as "expected a local peer-link state transition"
  let assert peer_links.Continue(state) =
    peer_links.update(keys.Char("w"), state)
    as "expected a local peer-link state transition"
  let assert peer_links.Continue(state) = peer_links.update(keys.Enter, state)
    as "expected a local peer-link state transition"
  assert peer_links.update(keys.Enter, state)
    == peer_links.Link(peer_links.Proposal(
      "local-id",
      "main",
      "target-id",
      "review",
      protocol.BusyOnly,
    ))
}

pub fn wake_permission_requires_an_explicit_confirmation_choice_test() {
  let session =
    protocol.Session(
      "target-id",
      "/workspace/review",
      "Review",
      0,
      protocol.Resident("incarnation"),
    )
  let state =
    peer_links.loaded(
      peer_links.new("local-id", "main"),
      [session],
      peer_links.Inspection([], []),
    )
  let assert peer_links.Continue(state) =
    peer_links.update(keys.Char("l"), state)
    as "expected a local peer-link state transition"
  let assert peer_links.Continue(state) = peer_links.update(keys.Enter, state)
    as "expected a local peer-link state transition"
  let assert peer_links.Continue(state) =
    peer_links.update(keys.Char("r"), state)
    as "expected a local peer-link state transition"
  let assert peer_links.Continue(state) = peer_links.update(keys.Enter, state)
    as "expected a local peer-link state transition"
  let assert peer_links.Continue(state) = peer_links.update(keys.Tab, state)
    as "expected a local peer-link state transition"
  let assert peer_links.Continue(state) =
    peer_links.update(keys.Char("x"), state)
    as "expected a local peer-link state transition"
  assert peer_links.update(keys.Enter, state)
    == peer_links.Link(peer_links.Proposal(
      "local-id",
      "main",
      "target-id",
      "r",
      protocol.MayWake,
    ))
}

pub fn saved_target_is_not_admitted_or_opened_test() {
  let saved =
    protocol.Session("saved-id", "/workspace/saved", "Saved", 0, protocol.Saved)
  let state =
    peer_links.loaded(
      peer_links.new("local-id", "main"),
      [saved],
      peer_links.Inspection([], []),
    )
  let assert peer_links.Continue(state) =
    peer_links.update(keys.Char("l"), state)
    as "expected a local peer-link state transition"
  let assert peer_links.Continue(state) = peer_links.update(keys.Enter, state)
    as "expected a local peer-link state transition"
  assert state.notice
    == "saved session cannot receive links; open it explicitly first"
  assert state.prompt == peer_links.ChoosingSession
}

pub fn reverse_requires_a_separate_confirmed_link_action_test() {
  let assert Ok(document) = json.parse(inspection)
  let assert Ok(current) =
    peer_links.decode_inspection(document, "local-id", "main")
  let state = peer_links.loaded(peer_links.new("local-id", "main"), [], current)
  let assert peer_links.Continue(confirming) =
    peer_links.update(keys.Char("v"), state)
    as "expected a local peer-link state transition"
  assert confirming.prompt
    == peer_links.Confirming(peer_links.Proposal(
      "target-id",
      "reviewer",
      "local-id",
      "main",
      protocol.BusyOnly,
    ))
  assert peer_links.update(keys.Enter, confirming)
    == peer_links.Link(peer_links.Proposal(
      "target-id",
      "reviewer",
      "local-id",
      "main",
      protocol.BusyOnly,
    ))
}

pub fn malformed_or_oversized_inspection_is_refused_test() {
  assert peer_links.decode_inspection(json.Null, "local-id", "main")
    == Error("expected peer inspection object")
  let assert Ok(document) = json.parse("{\"outgoing\":[],\"incoming\":[]}")
  assert peer_links.decode_inspection(document, "local-id", "main")
    == Ok(peer_links.Inspection([], []))
}
