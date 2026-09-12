//// Pins the Herdr pane contract this terminal speaks: the env gate, the
//// derivation from the terminal's own lifecycle signals, the change rule
//// that keeps the socket quiet, and the exact bytes of both wire calls.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import tui/approval
import tui/herdr
import tui/protocol.{type Strand, Strand}

fn config() -> herdr.Config {
  herdr.Config(
    pane_id: "pane-7",
    socket_path: "/tmp/herdr-client.sock",
    started_ms: 1_757_000_000_000,
  )
}

fn live_strand() -> Strand {
  Strand(id: "main", name: None, live_phase: Some("tool"))
}

fn idle_strand() -> Strand {
  Strand(id: "main", name: None, live_phase: None)
}

fn pending_review() -> approval.Review {
  approval.Review(
    id: "1",
    seq: 4,
    status: approval.Pending,
    tool: "bash",
    preview: "run it",
    origin: None,
    permission: approval.Unavailable(""),
  )
}

pub fn derive_blocked_beats_working_test() {
  herdr.state_for([live_strand()], [pending_review()])
  |> should.equal(herdr.Blocked)
}

pub fn derive_working_when_live_test() {
  herdr.state_for([live_strand()], [])
  |> should.equal(herdr.Working)
}

pub fn derive_idle_when_quiet_test() {
  herdr.state_for([idle_strand()], [])
  |> should.equal(herdr.Idle)
}

pub fn derive_idle_after_an_operation_settles_test() {
  // The reducer clears a strand's `live_phase` when its operation reaches
  // the `done` phase, so a settled operation is indistinguishable from one
  // that never ran, and the pane reports `idle` for both. That equality is
  // the whole of the settled case: Herdr is the side that turns an idle on
  // an unseen tab into its own `done`, and an agent that tried to report
  // `done` itself would fail the enum the daemon validates against.
  let settled = herdr.state_for([idle_strand()], [])
  let never_ran = herdr.state_for([], [])

  settled
  |> should.equal(herdr.Idle)

  settled
  |> should.equal(never_ran)
}

pub fn every_reported_state_is_one_herdr_accepts_test() {
  // Herdr's `PaneAgentState` is closed over idle, working and blocked —
  // `unknown` is Herdr's own marker for a pane it could not classify — and
  // the pane daemon rejects a `pane.report_agent` carrying anything else.
  // Pinning the encoding of every variant here is what keeps a reintroduced
  // `Done`, or a renamed arm, from reaching the wire unnoticed.
  [
    #(herdr.Idle, "idle"),
    #(herdr.Working, "working"),
    #(herdr.Blocked, "blocked"),
  ]
  |> list.each(fn(pair) {
    let #(state, name) = pair
    let line = herdr.encode_report(config(), 11, state, "sess-1", "")

    line
    |> string.contains("\"state\":\"" <> name <> "\"")
    |> should.be_true

    line
    |> string.contains("\"done\"")
    |> should.be_false
  })
}

pub fn changed_on_first_publish_test() {
  herdr.changed(None, herdr.Publication(herdr.Idle, "a"))
  |> should.be_true
}

pub fn unchanged_state_and_session_is_quiet_test() {
  herdr.changed(
    Some(herdr.Publication(herdr.Working, "a")),
    herdr.Publication(herdr.Working, "a"),
  )
  |> should.be_false
}

pub fn session_switch_at_same_state_changes_test() {
  // Resume keys on the session id, so an idle-to-idle switch is news.
  herdr.changed(
    Some(herdr.Publication(herdr.Idle, "a")),
    herdr.Publication(herdr.Idle, "b"),
  )
  |> should.be_true
}

pub fn encode_report_carries_the_pane_contract_test() {
  herdr.encode_report(config(), 42, herdr.Working, "sess-1", "")
  |> should.equal(
    "{\"id\":\"herdr:loom:42\",\"method\":\"pane.report_agent\","
    <> "\"params\":{\"pane_id\":\"pane-7\",\"source\":\"herdr:loom\","
    <> "\"agent\":\"loom\",\"seq\":42,\"state\":\"working\","
    <> "\"agent_session_id\":\"sess-1\",\"message\":null}}\n",
  )
}

pub fn encode_report_carries_a_message_test() {
  herdr.encode_report(config(), 1, herdr.Blocked, "s", "approval required")
  |> should.equal(
    "{\"id\":\"herdr:loom:1\",\"method\":\"pane.report_agent\","
    <> "\"params\":{\"pane_id\":\"pane-7\",\"source\":\"herdr:loom\","
    <> "\"agent\":\"loom\",\"seq\":1,\"state\":\"blocked\","
    <> "\"agent_session_id\":\"s\",\"message\":\"approval required\"}}\n",
  )
}

pub fn encode_announce_has_no_state_claim_test() {
  herdr.encode_announce(config(), 3, "sess-9")
  |> should.equal(
    "{\"id\":\"herdr:loom:3\",\"method\":\"pane.report_agent_session\","
    <> "\"params\":{\"pane_id\":\"pane-7\",\"source\":\"herdr:loom\","
    <> "\"agent\":\"loom\",\"seq\":3,\"agent_session_id\":\"sess-9\"}}\n",
  )
}

pub fn encode_escapes_untrusted_text_test() {
  // The message and ids are untrusted bytes on the wire; a quote in one
  // must not be able to break the request framing.
  herdr.encode_report(config(), 2, herdr.Idle, "se\"ss", "line\none")
  |> should.equal(
    "{\"id\":\"herdr:loom:2\",\"method\":\"pane.report_agent\","
    <> "\"params\":{\"pane_id\":\"pane-7\",\"source\":\"herdr:loom\","
    <> "\"agent\":\"loom\",\"seq\":2,\"state\":\"idle\","
    <> "\"agent_session_id\":\"se\\\"ss\",\"message\":\"line\\none\"}}\n",
  )
}
