//// The bounded reconnect an unexpected daemon death earns, and the resume
//// marker a reattachment is answered with.
////
//// Both halves are decided by functions this test can call: the reconnect
//// decision is read off `Model.reconnect`, which the operator's own status
//// line reads, and the resume marker is decoded from the same v2 frame the
//// daemon sends. No daemon is spawned — this jail cannot start one, and a
//// fixture that needed one would prove nothing about which branch was chosen.

import etui/widgets/textarea as text_area
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui
import tui/bootstrap
import tui/connection
import tui/inbound
import tui/model as tui_model
import tui/protocol
import tui/session_channel
import tui/session_control
import tui/snapshot
import tui/workspace
import weft

// A local launch, which is what makes a relaunch possible at all: it names the
// launcher state root a second start would use.
fn options() -> bootstrap.Options {
  bootstrap.Options(
    workspace: "/work",
    session_file: "/state/sessions.db",
    server: "",
    state_directory: "/state",
    config: "",
  )
}

// The state an unexpected daemon death leaves behind: an attached local
// session whose transport has closed and is now `Disconnected`.
fn disconnected() -> tui_model.Model {
  let base =
    tui.new_model_with_clock(
      connection.new_inbox(),
      workspace.Context("/work", None),
      fn() { 0 },
    )
  // `Disconnected` is the peer state just before an unexpected loss: the
  // terminal was attached and its transport has gone. A fresh model starts
  // in `Preview`, which is not a state a daemon death can reach.
  tui_model.Model(
    ..base,
    session: "s",
    local_options: Some(options()),
    peer: tui_model.Disconnected,
  )
}

// Drives the same public transition a closed conversation channel drives, so
// the decision under test is the one production reaches.
fn lose_the_channel(model: tui_model.Model) -> tui_model.Model {
  inbound.apply_channel_update(
    model,
    session_channel.Failed("the daemon exited"),
  )
}

pub fn an_unexpected_daemon_death_earns_one_attempt_test() {
  let idle = disconnected()
  assert idle.reconnect == tui_model.ReconnectIdle

  let attempted = lose_the_channel(idle)
  case attempted.reconnect {
    tui_model.ReconnectAttempting(..) -> Nil
    tui_model.ReconnectIdle | tui_model.ReconnectSpent ->
      panic as "a local attachment with a session earns one attempt"
  }

  // A second loss while the first attempt runs does not start another: the
  // attempt in flight is the same one.
  let again = lose_the_channel(attempted)
  case again.reconnect {
    tui_model.ReconnectAttempting(..) -> Nil
    tui_model.ReconnectIdle | tui_model.ReconnectSpent ->
      panic as "a reconnect already running is not restarted beside itself"
  }
}

pub fn an_operator_quit_and_a_remote_attachment_do_not_reconnect_test() {
  let quitting = lose_the_channel(tui_model.Model(..disconnected(), quit: True))
  assert quitting.reconnect == tui_model.ReconnectIdle

  let remote =
    lose_the_channel(tui_model.Model(..disconnected(), local_options: None))
  assert remote.reconnect == tui_model.ReconnectIdle

  let unattached =
    lose_the_channel(tui_model.Model(..disconnected(), session: ""))
  assert unattached.reconnect == tui_model.ReconnectIdle
}

pub fn a_failed_reconnect_is_reported_once_and_stays_disconnected_test() {
  let attempted = lose_the_channel(disconnected())
  let assert tui_model.ReconnectAttempting(replies:, ..) = attempted.reconnect

  let failed =
    session_control.accept_reconnect_event(
      attempted,
      session_control.ReconnectEvent(
        replies,
        weft.PulledOutcome(weft.Failed(index: 0, error: "loomd was not found")),
      ),
    )
  assert failed.reconnect == tui_model.ReconnectSpent
  assert failed.peer == tui_model.Disconnected
  assert list.any(failed.transcript, fn(line) {
    case line {
      tui_model.Line(speaker: tui_model.Failure, text:) ->
        string.contains(text, "reconnect failed")
      _other -> False
    }
  })
    as "the operator is told the reason, and how to get back"

  // A spent attempt is what stops a relaunch that cannot succeed from
  // becoming a loop: the same death cannot start another.
  let again = lose_the_channel(failed)
  assert again.reconnect == tui_model.ReconnectSpent
}

pub fn a_reconnect_event_from_another_attempt_is_ignored_test() {
  let attempted = lose_the_channel(disconnected())
  // A reply arriving on a mailbox this attempt does not own names some other
  // run, so it must not move this model.
  let elsewhere = process.new_subject()
  let ignored =
    session_control.accept_reconnect_event(
      attempted,
      session_control.ReconnectEvent(
        elsewhere,
        weft.PulledOutcome(weft.Failed(index: 0, error: "some other run")),
      ),
    )
  assert ignored.reconnect == attempted.reconnect
}

// --- the resume marker -----------------------------------------------------

pub fn a_resumed_subscription_names_the_cursor_it_holds_test() {
  // The subscribe a reattachment issues names the sequence the retained
  // transcript ends at, so the server continues rather than replaying from
  // zero.
  let frame = protocol.subscribe_from(1, "session-a", 42)
  assert string.contains(frame, "\"from_seq\":42")
  assert string.contains(frame, "\"session\":\"session-a\"")
}

pub fn a_resume_marker_decodes_to_the_resumed_event_test() {
  let text =
    "{\"v\":2,\"event\":\"snapshot\",\"body\":{\"mode\":\"resume\",\"next_seq\":40}}"
  assert protocol.decode_v2_presentation(text) == Ok(protocol.Resumed(40))
}

pub fn a_resumed_lane_requires_a_cursor_it_asked_for_test() {
  // A resume marker is the subscribe slot's own answer. A lane that issued
  // a subscription naming no cursor never asked to resume, so a marker
  // answering it is a lane this client did not build and must fail closed
  // rather than be read as a resume.
  let expected = snapshot.Expected("s", "epoch", "incarnation")
  let lane = session_channel.replay(expected)
  let marker =
    connection.Incoming(
      "{\"v\":2,\"reply_to\":1,\"event\":\"snapshot\",\"body\":{\"mode\":\"resume\",\"next_seq\":40}}",
    )
  let #(closed, updates) = session_channel.receive(lane, marker)
  let assert [session_channel.Failed(_)] = updates
  assert session_channel.in_flight(closed) == False
}

pub fn an_attempt_announces_itself_and_a_spent_one_does_not_test() {
  // The attempt is unattended, so the model's notice is the operator's only
  // signal that a relaunch is under way; once it is spent the failure line
  // replaces it, and the two must not be confusable.
  let attempted = lose_the_channel(disconnected())
  assert string.contains(attempted.notice, "reconnecting")

  let spent = lose_the_channel(attempted)
  case spent.reconnect {
    tui_model.ReconnectAttempting(..) -> Nil
    tui_model.ReconnectIdle | tui_model.ReconnectSpent ->
      panic as "the one attempt stays the one attempt"
  }
}

pub fn a_custody_return_decodes_to_the_held_input_event_test() {
  // The drain's custody return is pushed and uncorrelated, and its five
  // fields are the whole of what a restored draft needs — a missing one
  // fails the decode rather than restoring a partial draft.
  let text =
    "{\"v\":2,\"event\":\"held_input_returned\",\"body\":{\"strand\":\"main\",\"id\":\"h1\",\"kind\":\"queue\",\"text\":\"deploy when green\",\"attachment_count\":2}}"
  let assert Ok(event) = protocol.decode_v2_pushed(text)
  assert event
    == protocol.HeldInputReturned(
      strand: "main",
      id: "h1",
      kind: "queue",
      text: "deploy when green",
      attachment_count: 2,
    )

  let partial =
    "{\"v\":2,\"event\":\"held_input_returned\",\"body\":{\"strand\":\"main\",\"id\":\"h1\"}}"
  let assert Error(_) = protocol.decode_v2_pushed(partial)
}

pub fn a_custody_return_restores_the_draft_in_the_composer_test() {
  // The held queue is memory-only, so the pushed return is the prompt's
  // last copy: it must land in the composer, not in the bit bucket. An
  // empty composer takes the text outright.
  let model = disconnected()
  let returned =
    inbound.apply_channel_update(
      model,
      session_channel.Auxiliary(protocol.HeldInputReturned(
        strand: "main",
        id: "h1",
        kind: "queue",
        text: "held for the update",
        attachment_count: 0,
      )),
    )
  assert textarea_value(returned) == "held for the update"
  assert string.contains(returned.notice, "restored as a draft")
}

pub fn a_custody_return_never_overwrites_a_draft_in_progress_test() {
  // The operator is typing when the return arrives: both texts are theirs,
  // so the return is appended below the in-progress draft rather than
  // moved out from under the cursor.
  let model = disconnected()
  let typing =
    tui_model.Model(..model, input: text_area.state_from_string("half typed"))
  let returned =
    inbound.apply_channel_update(
      typing,
      session_channel.Auxiliary(protocol.HeldInputReturned(
        strand: "main",
        id: "h1",
        kind: "steer",
        text: "held for the update",
        attachment_count: 1,
      )),
    )
  assert textarea_value(returned) == "half typed\n\nheld for the update"

  // The count explains what the restored text cannot carry.
  assert string.contains(returned.notice, "1 attachment")
}

fn textarea_value(model: tui_model.Model) -> String {
  text_area.value(model.input)
}
