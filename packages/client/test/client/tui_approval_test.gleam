//// The TUI translates actual storage grants into the server's exact wire codec.
//// These tests deliberately cross package boundaries so duplicated wire words
//// cannot agree with a hand-written fixture while disagreeing with production.

import broker/escalation as broker_escalation
import broker/policy
import client/grants
import client/protocol
import core/message
import core/register
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import runtime/escalation
import tui/approval
import tui/snapshot_view

pub fn tui_approval_translates_every_current_grant_without_widening_test() {
  let limits = [
    policy.CpuSeconds,
    policy.WallSeconds,
    policy.MemBytes,
    policy.Pids,
    policy.FsizeBytes,
    policy.OutputBytes,
  ]
  let values = [
    policy.GrantReadableRoot("/read"),
    policy.GrantWritableRoot("/write"),
    policy.GrantEnv("PATH"),
    policy.GrantNetwork(policy.NetworkOff),
    policy.GrantNetwork(policy.NetworkFull),
    policy.GrantNetwork(policy.NetworkProxy(["example.test"], "127.0.0.1:8080")),
    policy.GrantScratch(policy.ScratchTmpfs),
    policy.GrantScratch(policy.ScratchPath("/scratch")),
    ..list.map(limits, fn(field) { policy.GrantLimit(field, 17) })
  ]
  list.each(values, fn(grant) {
    let assert Ok(wire) = approval.wire_grant(grants.encode(grant))
      as "every current storage grant has an exact TUI translation"
    assert wire == protocol.encode_grant(grant)
    assert protocol.decode_grant(wire) == Ok(grant)
  })
}

fn review(id, seq) {
  let row =
    escalation.raised(
      id,
      grants.encode_denial("timeout refused", broker_escalation.PolicyDenial, [
        policy.GrantLimit(policy.WallSeconds, 60),
      ]),
      action: Some(escalation.Action("bash", "exact-action", "sleep 60")),
      scope: None,
    )
  let assert Ok(review) =
    approval.decode(snapshot_view.Cell(
      register.FactCustom,
      escalation.register_key(id),
      seq,
      escalation.encode(row),
    ))
    as "the UI decodes the actual runtime durable record"
  review
}

pub fn tui_approval_echoes_same_captured_action_grants_and_sequence_test() {
  let captured = review("esc-1", 47)
  let assert Ok(wire) = approval.approve(19, captured)
    as "a displayed pending action can be answered"
  let assert Ok(envelope) = protocol.decode_command(wire)
    as "the current server accepts the exact TUI command shape"
  assert envelope.command
    == protocol.Approve(
      "esc-1",
      [policy.GrantLimit(policy.WallSeconds, 60)],
      "exact-action",
      47,
    )
  let assert Ok(wire) = approval.deny(20, captured)
    as "denial uses the same captured sequence"
  let assert Ok(envelope) = protocol.decode_command(wire)
    as "the denial is a total server command"
  assert envelope.command == protocol.Deny("esc-1", 47)
}

pub fn tui_approval_resolved_summaries_are_bounded_and_do_not_replace_newer_questions_test() {
  let rows =
    int.range(from: 1, to: 21, with: [], run: list.prepend)
    |> list.map(fn(index) {
      approval.Review(
        ..review("esc-" <> int.to_string(index), index),
        status: approval.Rejected,
        origin: Some(message.Origin("bob", "Bob")),
        preview: string.repeat("x", 2048),
      )
    })
  let summaries = approval.decisions([], rows, [])
  assert list.length(summaries) == 16
  assert list.all(summaries, fn(row) {
    string.length(row.preview) <= 512
    && row.permission
    == approval.Unavailable("this decision is already resolved")
  })
  let reopened = review("esc-1", 99)
  assert approval.decisions(
      [reopened],
      [approval.Review(..reopened, seq: 47, status: approval.Rejected)],
      [],
    )
    == [reopened]
  assert approval.project(summaries, [reopened]) |> list.contains(reopened)
}
