//// Pins the Herdr pane contract this terminal speaks: the launch gate and
//// the sequence seed it admits, the derivation from the terminal's own
//// lifecycle signals, the change and announcement rules that decide what
//// reaches the socket, and the exact bytes of all three wire calls.

import etui/backend
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import session_view/approval
import session_view/protocol.{type Strand, Strand}
import tui
import tui/connection
import tui/effect
import tui/herdr
import tui/model as tui_model
import tui/view_set
import tui/workspace
import tui_test/stepping

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
    strand: None,
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

pub fn blocked_message_names_the_pending_approval_test() {
  // The pane's `message` field is what Herdr shows beside a blocked pane,
  // and the pending approval's tool and preview are the same words the
  // approval surface is showing the operator.
  herdr.message_for([pending_review()])
  |> should.equal("bash: run it")
}

pub fn blocked_message_names_a_toolless_approval_test() {
  let review =
    approval.Review(
      id: "1",
      seq: 4,
      status: approval.Pending,
      tool: "",
      preview: "",
      origin: None,
      permission: approval.Unavailable(""),
      strand: None,
    )

  herdr.message_for([review])
  |> should.equal("pending approval")
}

pub fn a_toolless_head_of_a_queue_names_it_too_test() {
  // The toolless guard belongs to the head of the queue, not only to a
  // single approval: a pane reading `: write it (1 more)` for a review
  // with no tool is a dangling colon on the operator's screen.
  let toolless =
    approval.Review(
      id: "1",
      seq: 4,
      status: approval.Pending,
      tool: "",
      preview: "write it",
      origin: None,
      permission: approval.Unavailable(""),
      strand: None,
    )
  let other =
    approval.Review(
      id: "2",
      seq: 5,
      status: approval.Pending,
      tool: "fs_write",
      preview: "later",
      origin: None,
      permission: approval.Unavailable(""),
      strand: None,
    )

  herdr.message_for([toolless])
  |> should.equal("pending approval")

  herdr.message_for([toolless, other])
  |> should.equal("pending approval (1 more)")
}

pub fn blocked_message_counts_a_queue_test() {
  let other =
    approval.Review(
      id: "2",
      seq: 5,
      status: approval.Pending,
      tool: "fs_write",
      preview: "write it",
      origin: None,
      permission: approval.Unavailable(""),
      strand: None,
    )

  herdr.message_for([pending_review(), other])
  |> should.equal("bash: run it (1 more)")
}

pub fn no_message_when_nothing_is_pending_test() {
  herdr.message_for([])
  |> should.equal("")

  let decided =
    approval.Review(
      id: "1",
      seq: 4,
      status: approval.Approved,
      tool: "bash",
      preview: "run it",
      origin: None,
      permission: approval.Unavailable(""),
      strand: None,
    )

  herdr.message_for([decided])
  |> should.equal("")
}

pub fn changed_on_first_publish_test() {
  herdr.changed(None, herdr.Publication(herdr.Idle, "a", ""))
  |> should.be_true
}

pub fn unchanged_state_and_session_is_quiet_test() {
  herdr.changed(
    Some(herdr.Publication(herdr.Working, "a", "")),
    herdr.Publication(herdr.Working, "a", ""),
  )
  |> should.be_false
}

pub fn session_switch_at_same_state_changes_test() {
  // The resume command follows the session id, so an idle-to-idle switch
  // is news.
  herdr.changed(
    Some(herdr.Publication(herdr.Idle, "a", "")),
    herdr.Publication(herdr.Idle, "b", ""),
  )
  |> should.be_true
}

pub fn a_message_change_alone_republishes_test() {
  // A second approval queuing behind the first leaves the pane blocked on
  // the same session; only the message moves, and a pane still showing the
  // first approval's words after the second arrived is the pane
  // disagreeing with the operator's own screen.
  herdr.changed(
    Some(herdr.Publication(herdr.Blocked, "s1", "bash: run it")),
    herdr.Publication(herdr.Blocked, "s1", "bash: run it (1 more)"),
  )
  |> should.be_true
}

pub fn an_identical_message_adds_nothing_test() {
  // The third field does not turn every publish into a send: an unchanged
  // state, session and message is still quiet.
  herdr.changed(
    Some(herdr.Publication(herdr.Blocked, "s1", "bash: run it")),
    herdr.Publication(herdr.Blocked, "s1", "bash: run it"),
  )
  |> should.be_false
}

pub fn source_leaves_the_reserved_prefix_alone_test() {
  // Herdr reserves the `herdr:` source prefix for the integrations it
  // ships itself; a third-party agent that reports under it is claiming
  // an identity Herdr's own routing keys on. The pane contract is pinned
  // through the encoded request, so this holds for every call.
  [
    herdr.encode_report(config(), 1, herdr.Idle, "s", ""),
    herdr.encode_announce(config(), 2, "s"),
    herdr.encode_release(config(), 3),
  ]
  |> list.each(fn(line) {
    line
    |> string.contains("\"source\":\"herdr:")
    |> should.be_false

    line
    |> string.contains("\"source\":\"loom:terminal\"")
    |> should.be_true
  })
}

pub fn encode_report_carries_the_pane_contract_test() {
  herdr.encode_report(config(), 42, herdr.Working, "sess-1", "")
  |> should.equal(
    "{\"id\":\"loom:terminal:42\",\"method\":\"pane.report_agent\","
    <> "\"params\":{\"pane_id\":\"pane-7\",\"source\":\"loom:terminal\","
    <> "\"agent\":\"loom\",\"seq\":42,\"state\":\"working\","
    <> "\"agent_session_id\":\"sess-1\",\"message\":null,"
    <> "\"resume_argv\":[\"loom\",\"--session\",\"sess-1\"]}}\n",
  )
}

pub fn encode_report_carries_a_message_test() {
  herdr.encode_report(config(), 1, herdr.Blocked, "s", "approval required")
  |> should.equal(
    "{\"id\":\"loom:terminal:1\",\"method\":\"pane.report_agent\","
    <> "\"params\":{\"pane_id\":\"pane-7\",\"source\":\"loom:terminal\","
    <> "\"agent\":\"loom\",\"seq\":1,\"state\":\"blocked\","
    <> "\"agent_session_id\":\"s\",\"message\":\"approval required\","
    <> "\"resume_argv\":[\"loom\",\"--session\",\"s\"]}}\n",
  )
}

pub fn the_resume_command_reopens_the_reported_session_test() {
  // `resume_argv` is the only restart mechanism Herdr gives a source it
  // does not ship an integration for: the daemon replays the command in
  // the pane's directory after a server restart. Its first word has to be
  // a plain command name on the operator's PATH — a path there would fail
  // `invalid_resume_argv` — and `loom --session <id>` is exactly the
  // launch that reopens the same conversation.
  herdr.resume_argv("sess-1")
  |> should.equal(["loom", "--session", "sess-1"])
}

pub fn encode_announce_has_no_state_claim_test() {
  herdr.encode_announce(config(), 3, "sess-9")
  |> should.equal(
    "{\"id\":\"loom:terminal:3\",\"method\":\"pane.report_agent_session\","
    <> "\"params\":{\"pane_id\":\"pane-7\",\"source\":\"loom:terminal\","
    <> "\"agent\":\"loom\",\"seq\":3,\"agent_session_id\":\"sess-9\"}}\n",
  )
}

pub fn encode_release_clears_the_pane_test() {
  // Release is the request that clears this terminal's label, state and
  // resume command from the pane at quit, rather than waiting for Herdr's
  // own safety net to notice the pane went back to a shell prompt.
  herdr.encode_release(config(), 4)
  |> should.equal(
    "{\"id\":\"loom:terminal:4\",\"method\":\"pane.release_agent\","
    <> "\"params\":{\"pane_id\":\"pane-7\",\"source\":\"loom:terminal\","
    <> "\"agent\":\"loom\",\"seq\":4}}\n",
  )
}

pub fn encode_escapes_untrusted_text_test() {
  // The message and ids are untrusted bytes on the wire; a quote in one
  // must not be able to break the request framing.
  herdr.encode_report(config(), 2, herdr.Idle, "se\"ss", "line\none")
  |> should.equal(
    "{\"id\":\"loom:terminal:2\",\"method\":\"pane.report_agent\","
    <> "\"params\":{\"pane_id\":\"pane-7\",\"source\":\"loom:terminal\","
    <> "\"agent\":\"loom\",\"seq\":2,\"state\":\"idle\","
    <> "\"agent_session_id\":\"se\\\"ss\",\"message\":\"line\\none\","
    <> "\"resume_argv\":[\"loom\",\"--session\",\"se\\\"ss\"]}}\n",
  )
}

pub fn a_negative_seed_is_not_a_herdr_pane_test() {
  // The environment values are present, so this is the gate on the seed
  // alone. A negative `started_ms` is the BEAM monotonic clock reaching a
  // parameter that wants the wall clock; Herdr types `seq` as an unsigned
  // integer, so a config seeded from it could only ever produce reports the
  // pane's daemon rejects, and there is nothing to report from.
  herdr.config_for(
    pane_id: "pane-7",
    socket_path: "/tmp/herdr-client.sock",
    started_ms: -576_460_751_285,
  )
  |> should.equal(None)

  herdr.config_for(
    pane_id: "pane-7",
    socket_path: "/tmp/herdr-client.sock",
    started_ms: 1_789_193_617_870,
  )
  |> should.equal(
    Some(herdr.Config(
      pane_id: "pane-7",
      socket_path: "/tmp/herdr-client.sock",
      started_ms: 1_789_193_617_870,
    )),
  )
}

pub fn every_report_carries_a_non_negative_seq_test() {
  // `start` seeds the reporter's counter from `started_ms` and `handle`
  // advances it before each attempt, so the first report on the wire is
  // seed + 1. Both calls put that number in `params.seq`, which Herdr's
  // request schema types as a uint64 with a minimum of zero.
  let started_ms = 1_789_193_617_870
  let assert Some(config) =
    herdr.config_for(
      pane_id: "pane-7",
      socket_path: "/tmp/herdr-client.sock",
      started_ms:,
    )
    as "a wall-clock seed is a valid pane config"

  let first = started_ms + 1

  { first >= 0 }
  |> should.be_true

  [
    herdr.encode_announce(config, first, "sess-1"),
    herdr.encode_report(config, first, herdr.Working, "sess-1", ""),
    herdr.encode_release(config, first),
  ]
  |> list.each(fn(line) {
    line
    |> string.contains("\"seq\":" <> int.to_string(first))
    |> should.be_true

    line
    |> string.contains("\"seq\":-")
    |> should.be_false
  })
}

pub fn nothing_is_announced_without_a_session_test() {
  // The first publish happens at the session picker, where no session is
  // attached yet; an empty `agent_session_id` names nothing to announce.
  herdr.announces(None, herdr.Publication(herdr.Idle, "", ""))
  |> should.be_false
}

pub fn announced_when_the_session_becomes_known_test() {
  herdr.announces(None, herdr.Publication(herdr.Idle, "s1", ""))
  |> should.be_true
}

pub fn a_state_change_alone_does_not_announce_test() {
  herdr.announces(
    Some(herdr.Publication(herdr.Idle, "s1", "")),
    herdr.Publication(herdr.Working, "s1", ""),
  )
  |> should.be_false
}

pub fn a_session_switch_announces_again_test() {
  // The identity that moved has to be announced again rather than ridden
  // along on the state report.
  herdr.announces(
    Some(herdr.Publication(herdr.Idle, "s1", "")),
    herdr.Publication(herdr.Idle, "s2", ""),
  )
  |> should.be_true
}

// The release must be the last word on the pane. The quit step drains the
// connection before it interprets Ctrl-C, so a state transition observed
// alongside the quit would otherwise be published AFTER the release queued
// by submit.quit in the same outbox, re-marking a pane the release just
// cleared. The publish gate on `shared.quit` is what keeps the goodbye
// last.
pub fn a_quitting_step_publishes_nothing_after_the_release_test() {
  let assert Ok(reporter) = herdr.start(config())
    as "the pane reporter starts outside Herdr too; it just never sends"

  // A model whose demo strands are live, so a publish would emit `working`
  // (the base publication is None, making this the first publish).
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  let model =
    tui_model.Model(
      ..base,
      view: view_set.herdr_reporter(base.view, Some(reporter)),
    )

  let #(_quit, effects) = stepping.step(backend.KeyPress("ctrl+c"), model)

  // The release is on the outbox and nothing follows it.
  assert list.any(effects, fn(requested) {
    case requested {
      effect.ReleaseHerdr(_) -> True
      _ -> False
    }
  })
    as "the quit queues the pane release"

  assert !list.any(effects, fn(requested) {
    case requested {
      effect.ReportHerdr(..) | effect.AnnounceHerdr(..) -> True
      _ -> False
    }
  })
    as "no state report or announcement lands after the release"
}
