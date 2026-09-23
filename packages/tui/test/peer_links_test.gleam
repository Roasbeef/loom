import core/json
import etui/buffer
import etui/geometry.{Position}
import etui/keys
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui/daemon/protocol
import tui/peer_links
import tui/selection

const inspection = "{\"outgoing\":[{\"session\":\"target-id\",\"target_strand\":\"reviewer\",\"wake\":\"busy_only\",\"metadata\":{\"status\":\"resident\"}}],\"incoming\":[{\"source_session\":\"sender-id\",\"source_strand\":\"builder\",\"target_strand\":\"main\",\"wake\":\"may_wake\",\"metadata\":{\"status\":\"saved\"}}],\"next\":null}"

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

pub fn inspection_pages_continue_and_replace_duplicate_coordinates_test() {
  let first_text =
    "{\"outgoing\":[{\"session\":\"target-id\",\"target_strand\":\"reviewer\",\"wake\":\"busy_only\",\"metadata\":{\"status\":\"resident\"}}],\"incoming\":[],\"next\":\"cursor-2\"}"
  let second_text =
    "{\"outgoing\":[{\"session\":\"target-id\",\"target_strand\":\"reviewer\",\"wake\":\"may_wake\",\"metadata\":{\"status\":\"resident\"}},{\"session\":\"other-id\",\"target_strand\":\"main\",\"wake\":\"busy_only\",\"metadata\":{\"status\":\"resident\"}}],\"incoming\":[],\"next\":null}"
  let assert Ok(first_document) = json.parse(first_text)
  let assert Ok(first) =
    peer_links.decode_inspection_page(first_document, "local-id", "main")
  let state =
    peer_links.loaded(
      peer_links.new("local-id", "main"),
      [],
      first.inspection,
      first.next,
    )
  assert state.notice == "more grants available · press n to continue"
  assert peer_links.update(keys.Char("n"), state)
    == peer_links.NextPage("cursor-2")

  let assert Ok(second_document) = json.parse(second_text)
  let assert Ok(second) =
    peer_links.decode_inspection_page(second_document, "local-id", "main")
  let completed = peer_links.append_page(state, second)
  let assert Some(peer_links.Inspection(outgoing:, incoming: [])) =
    completed.inspection
    as "all fetched pages stay available to the grant selector"
  assert list.length(outgoing) == 2
  assert list.first(outgoing)
    == Ok(peer_links.Grant(
      "local-id",
      "main",
      "target-id",
      "reviewer",
      Some(protocol.MayWake),
      peer_links.Available,
    ))
  assert completed.next_cursor == None
  assert completed.notice == "peer inspection complete"
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
  let state =
    peer_links.loaded(state, [session], peer_links.Inspection([], []), None)
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
      None,
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
      None,
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
  let state =
    peer_links.loaded(peer_links.new("local-id", "main"), [], current, None)
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
  let assert Ok(document) =
    json.parse("{\"outgoing\":[],\"incoming\":[],\"next\":null}")
  assert peer_links.decode_inspection(document, "local-id", "main")
    == Ok(peer_links.Inspection([], []))
}

pub fn mutation_acknowledgement_survives_refresh_and_enter_cannot_repeat_test() {
  let state = peer_links.new("local-id", "main")
  let state =
    peer_links.State(
      ..state,
      prompt: peer_links.Confirming(peer_links.Proposal(
        "local-id",
        "main",
        "target-id",
        "review",
        protocol.BusyOnly,
      )),
    )
  let assert Ok(document) = json.parse("{\"status\":\"partial\"}")
  let completed = peer_links.completed(state, document)
  assert completed.prompt == peer_links.Browsing
  assert peer_links.update(keys.Enter, completed)
    == peer_links.Continue(completed)
  let refreshed =
    peer_links.loaded(completed, [], peer_links.Inspection([], []), None)
  assert refreshed.operation_result
    == Some("server result: {\"status\":\"partial\"}")
  assert string.contains(view_text(refreshed), "server result:")
}

pub fn chooser_pages_past_the_first_hundred_authorized_sessions_test() {
  let first =
    list.repeat(Nil, 100)
    |> list.index_map(fn(_, number) {
      protocol.Session(
        "session-" <> int.to_string(number),
        "/workspace",
        "Session",
        0,
        protocol.Resident("incarnation"),
      )
    })
  let state =
    peer_links.catalogue(
      peer_links.new("local-id", "main"),
      protocol.Page(7, first, Some("cursor-100")),
    )
  let assert peer_links.Continue(choosing) =
    peer_links.update(keys.Char("l"), state)
  assert peer_links.update(keys.Char("n"), choosing)
    == peer_links.NextSessions("cursor-100", 7)
  let next =
    peer_links.append_sessions(
      choosing,
      protocol.Page(
        7,
        [
          protocol.Session(
            "session-100",
            "/workspace",
            "Last target",
            0,
            protocol.Resident("incarnation"),
          ),
        ],
        None,
      ),
    )
  assert next.selected_session == 100
  assert string.contains(view_text(next), "Last target")
  let assert peer_links.Continue(editing) = peer_links.update(keys.Enter, next)
  assert editing.prompt == peer_links.EditingTargetStrand
  assert peer_links.update(keys.Char("n"), choosing)
    == peer_links.NextSessions("cursor-100", 7)
}

pub fn selected_grant_and_footer_follow_the_viewport_test() {
  let outgoing =
    list.repeat(Nil, 51)
    |> list.index_map(fn(_, number) {
      peer_links.Grant(
        "local-id",
        "main",
        "target-" <> int.to_string(number),
        "review",
        Some(protocol.BusyOnly),
        peer_links.Available,
      )
    })
  let state =
    peer_links.loaded(
      peer_links.new("local-id", "main"),
      [],
      peer_links.Inspection(outgoing, []),
      None,
    )
  let state = peer_links.State(..state, selected_grant: 45)
  let visible = view_text(state)
  assert string.contains(visible, "target-45")
  assert !string.contains(visible, "target-0")
  assert string.contains(visible, "peer inspection current")
  assert string.contains(visible, "Esc close")
}

fn view_text(state: peer_links.State) -> String {
  let screen = geometry.rect_new(0, 0, 100, 12)
  let rendered = peer_links.render(buffer.buffer_new(screen), screen, state)
  let selected =
    selection.start(screen, Position(0, 0))
    |> selection.extend(Position(99, 11))
  selection.text(rendered, selected)
}
