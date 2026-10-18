//// A spawner's operator's decision about a child's request, judged on the box
//// (protocol-change/089).
////
//// The runtime is a real one on a private SQLite file, and the record it holds is
//// raised through the same door `client/escalate` raises through, so the cases
//// meet the record shape the shipped daemon does: scoped to a child's call,
//// bound to an action, and carrying the broker's wanted diff. What is not here is
//// the broker's refusal and the parked call, which the shipped fixture covers.

import broker/escalation as broker_escalation
import broker/policy.{type Grant}
import client/approval_ceiling
import client/delegate_outbox
import client/grants
import client/internal/ffi_os
import client/permissions
import client/remote_decision
import client/remote_escalation.{
  Approve, Decided, Decider, Deny, Forget, Forgotten, Once, Refused, Session,
  Stale,
}
import client/remote_spawn
import core/clock
import core/ids
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import runtime/api
import runtime/escalation as durable
import runtime/lineage
import simplifile
import support/notes_session

const spawner_name = "laptop"

const child_strand = "sub:^main/build-0123456789abcdef"

const action = "digest-of-the-call"

fn an_op(seed: Int) -> ids.OpId {
  let #(op, _generator) = ids.mint_op(ids.generator(clock.fixed(at: 0), seed:))
  op
}

// A private directory that exists, so a remembered path resolves.
fn workspace(label: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "locate the test workspace"
  let root =
    here
    <> "/build/remote-decision-"
    <> label
    <> "-"
    <> int.to_string(
      ffi_os.system_time_ms() * 1000 + ffi_os.unique_positive_integer(),
    )
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/work")
    as "create the workspace"
  root
}

fn session(root: String) -> api.Runtime {
  notes_session.open(root <> "/session.db", clock.fixed(1000)).runtime
}

fn link(
  ceiling: option.Option(approval_ceiling.Ceiling),
) -> delegate_outbox.SpawnerLink {
  delegate_outbox.SpawnerLink(
    parent_session: "0198c0de-0000-7000-8000-000000000001",
    spawner: spawner_name,
    node: "laptop@100.64.0.5",
    ceiling:,
  )
}

fn ceiling_over(root: String) -> approval_ceiling.Ceiling {
  approval_ceiling.Ceiling(..approval_ceiling.nothing(), writable_roots: [
    root <> "/work",
  ])
}

fn parent() -> remote_spawn.Parent {
  remote_spawn.Parent(
    session: "0198c0de-0000-7000-8000-000000000001",
    strand: "main",
  )
}

fn decider() -> remote_escalation.Decider {
  Decider(principal: "ab12cd", name: "Ola")
}

// The child's lineage cell, which is what makes it a descendant of `^main`.
fn child_of(runtime: api.Runtime, parent_reference: String) -> Nil {
  let assert Ok(Nil) =
    api.put_reserved_fact(
      runtime,
      lineage.register_key(child_strand),
      lineage.encode(lineage.Lineage(
        strand: child_strand,
        parent: parent_reference,
        depth: 1,
        minted_by: lineage.CallSite(
          operation: an_op(1),
          step_id: "step",
          source_index: 0,
        ),
        brief: an_op(2),
        tools: [],
        default_within_ms: None,
        deadline: None,
        detached: True,
        reaped: False,
        orchestrator: None,
      )),
    )
  Nil
}

// Raises a request the way `client/escalate` does and answers its `seq`.
fn raise(runtime: api.Runtime, id: String, wanted: List(Grant)) -> Int {
  let denial =
    grants.encode_denial(
      reason: "tool requirements exceed the session policy",
      source: broker_escalation.PolicyDenial,
      wanted:,
    )
  let assert Ok(durable.Claimed(_)) =
    api.claim_escalation(
      runtime,
      id,
      denial,
      action: durable.Action(tool: "bash", digest: action, preview: "make"),
      scope: durable.CallScope(
        operation: an_op(3),
        strand: child_strand,
        step_id: "step",
        source_index: 0,
        call_id: "call-1",
      ),
      max_asks: 3,
    )
    as "the test's raise takes the claim"
  seq_of(runtime, id)
}

fn seq_of(runtime: api.Runtime, id: String) -> Int {
  let assert Ok(cell) = api.escalation_cell(runtime, id)
    as "the record is readable"
  cell.seq
}

fn status_of(runtime: api.Runtime, id: String) -> durable.Status {
  let assert Ok(cell) = api.escalation_cell(runtime, id)
    as "the record is readable"
  cell.record.status
}

fn admit(
  runtime: api.Runtime,
  ceiling: option.Option(approval_ceiling.Ceiling),
  id: String,
  decision: remote_escalation.Decision,
  seq: Int,
) -> remote_escalation.Answer {
  remote_decision.admit(
    runtime,
    link(ceiling),
    parent(),
    id,
    decision,
    seq,
    decider(),
    1000,
  )
}

pub fn an_approval_inside_the_ceiling_commits_once_test() {
  let root = workspace("once")
  let runtime = session(root)
  child_of(runtime, "^main")
  let wanted = [policy.GrantWritableRoot(root <> "/work/out")]
  let seq = raise(runtime, "policy-1", wanted)
  let answer =
    admit(
      runtime,
      Some(ceiling_over(root)),
      "policy-1",
      Approve(grants: wanted, action:, scope: Once),
      seq,
    )
  let assert Decided(record) = answer
  assert record.status == "approved"
  assert status_of(runtime, "policy-1") == durable.Approved

  // The decider is kept as the record's origin, as plain data.
  let assert Ok(cell) = api.escalation_cell(runtime, "policy-1")
  assert cell.record.origin == Some(remote_escalation.origin_of(decider()))

  // A once approval remembers nothing.
  let assert Ok(listing) = permissions.listing(runtime)
  assert listing.grants == []
  let assert Ok(Nil) = api.close(runtime)
}

pub fn an_approval_outside_the_ceiling_is_refused_and_stays_pending_test() {
  let root = workspace("outside")
  let runtime = session(root)
  child_of(runtime, "^main")
  let wanted = [policy.GrantWritableRoot("/etc")]
  let seq = raise(runtime, "policy-1", wanted)
  assert admit(
      runtime,
      Some(ceiling_over(root)),
      "policy-1",
      Approve(grants: wanted, action:, scope: Once),
      seq,
    )
    == Refused(reason: remote_escalation.outside_the_ceiling)

  // The record is untouched, so the box's owner can still answer it.
  assert status_of(runtime, "policy-1") == durable.Pending
  assert seq_of(runtime, "policy-1") == seq
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_spawner_with_no_ceiling_takes_no_decision_test() {
  let root = workspace("none")
  let runtime = session(root)
  child_of(runtime, "^main")
  let wanted = [policy.GrantWritableRoot(root <> "/work")]
  let seq = raise(runtime, "policy-1", wanted)
  assert admit(runtime, None, "policy-1", Deny, seq)
    == Refused(reason: remote_escalation.outside_the_ceiling)
  assert status_of(runtime, "policy-1") == durable.Pending
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_decision_about_a_moved_question_is_stale_with_the_current_record_test() {
  let root = workspace("stale")
  let runtime = session(root)
  child_of(runtime, "^main")
  let wanted = [policy.GrantWritableRoot(root <> "/work")]
  let seq = raise(runtime, "policy-1", wanted)
  let answer =
    admit(
      runtime,
      Some(ceiling_over(root)),
      "policy-1",
      Approve(grants: wanted, action:, scope: Once),
      seq - 1,
    )
  let assert Stale(record:, ..) = answer
  assert record.seq == seq
  assert record.status == "pending"
  assert status_of(runtime, "policy-1") == durable.Pending
  let assert Ok(Nil) = api.close(runtime)
}

pub fn an_echo_that_names_another_action_or_wider_grants_is_stale_test() {
  let root = workspace("echo")
  let runtime = session(root)
  child_of(runtime, "^main")
  let wanted = [policy.GrantWritableRoot(root <> "/work")]
  let seq = raise(runtime, "policy-1", wanted)
  let ceiling = Some(ceiling_over(root))
  let assert Stale(..) =
    admit(
      runtime,
      ceiling,
      "policy-1",
      Approve(grants: wanted, action: "another", scope: Once),
      seq,
    )
  let assert Stale(..) =
    admit(
      runtime,
      ceiling,
      "policy-1",
      Approve(
        grants: [policy.GrantWritableRoot(root <> "/work/more")],
        action:,
        scope: Once,
      ),
      seq,
    )
  assert status_of(runtime, "policy-1") == durable.Pending
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_request_from_another_parents_child_is_refused_test() {
  let root = workspace("parent")
  let runtime = session(root)
  child_of(runtime, "^other")
  let wanted = [policy.GrantWritableRoot(root <> "/work")]
  let seq = raise(runtime, "policy-1", wanted)
  let assert Refused(..) =
    admit(runtime, Some(ceiling_over(root)), "policy-1", Deny, seq)
  assert status_of(runtime, "policy-1") == durable.Pending
  let assert Ok(Nil) = api.close(runtime)
}

pub fn an_unknown_request_is_refused_test() {
  let root = workspace("unknown")
  let runtime = session(root)
  let assert Refused(..) =
    admit(runtime, Some(ceiling_over(root)), "policy-9", Deny, 1)
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_denial_rejects_the_question_test() {
  let root = workspace("deny")
  let runtime = session(root)
  child_of(runtime, "^main")
  let seq =
    raise(runtime, "policy-1", [policy.GrantWritableRoot(root <> "/work")])
  let assert Decided(record) =
    admit(runtime, Some(ceiling_over(root)), "policy-1", Deny, seq)
  assert record.status == "rejected"
  assert status_of(runtime, "policy-1") == durable.Rejected

  // The question is closed, so a second answer is stale with the decided record.
  let assert Stale(record: closed, ..) =
    admit(runtime, Some(ceiling_over(root)), "policy-1", Deny, seq)
  assert closed.status == "rejected"
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_session_approval_is_remembered_with_the_spawners_provenance_test() {
  let root = workspace("session")
  let runtime = session(root)
  child_of(runtime, "^main")
  let granted = policy.GrantWritableRoot(root <> "/work")
  let seq = raise(runtime, "policy-1", [granted])
  let assert Decided(_) =
    admit(
      runtime,
      Some(ceiling_over(root)),
      "policy-1",
      Approve(grants: [granted], action:, scope: Session),
      seq,
    )

  // Dispatch reads the grant for every later call of the session, whichever
  // child makes it, because the fact is the session's.
  let assert Ok(standing) = permissions.read_stored(runtime.session)
  assert standing == [granted]

  // It is attributed to the spawner and its operator as plain data.
  let assert Ok(listing) = permissions.listing(runtime)
  assert list.map(listing.grants, fn(row) { row.provenance })
    == [
      permissions.Spawner(
        spawner: spawner_name,
        principal: remote_escalation.origin_of(decider()),
        at_ms: 1000,
      ),
    ]
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_session_grant_does_not_reach_another_delegate_session_test() {
  let root = workspace("sessions")
  let first = session(root)
  let second = session(workspace("sessions-other"))
  child_of(first, "^main")
  let granted = policy.GrantWritableRoot(root <> "/work")
  let seq = raise(first, "policy-1", [granted])
  let assert Decided(_) =
    admit(
      first,
      Some(ceiling_over(root)),
      "policy-1",
      Approve(grants: [granted], action:, scope: Session),
      seq,
    )
  assert permissions.read_stored(first.session) == Ok([granted])
  assert permissions.read_stored(second.session) == Ok([])
  let assert Ok(Nil) = api.close(first)
  let assert Ok(Nil) = api.close(second)
}

pub fn opening_withdraws_the_grants_a_narrowed_ceiling_no_longer_admits_test() {
  let root = workspace("narrowed")
  let runtime = session(root)
  child_of(runtime, "^main")
  let granted = policy.GrantWritableRoot(root <> "/work")
  let seq = raise(runtime, "policy-1", [granted])
  let assert Decided(_) =
    admit(
      runtime,
      Some(ceiling_over(root)),
      "policy-1",
      Approve(grants: [granted], action:, scope: Session),
      seq,
    )

  // The same ceiling keeps it.
  assert permissions.withdraw_spawner_grants(
      runtime,
      spawner_name,
      approval_ceiling.admits(ceiling_over(root), _),
    )
    == Ok([])
  assert permissions.read_stored(runtime.session) == Ok([granted])

  // A narrowed ceiling withdraws it, and a ceiling that is gone withdraws it too.
  let narrowed =
    approval_ceiling.Ceiling(..approval_ceiling.nothing(), writable_roots: [
      root <> "/work/sub",
    ])
  assert permissions.withdraw_spawner_grants(
      runtime,
      spawner_name,
      approval_ceiling.admits(narrowed, _),
    )
    == Ok([granted])
  assert permissions.read_stored(runtime.session) == Ok([])
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_grant_the_owner_remembered_is_never_withdrawn_by_the_ceiling_test() {
  let root = workspace("owner")
  let runtime = session(root)
  let granted = policy.GrantWritableRoot(root <> "/work")
  let assert Ok(change) =
    permissions.remembering(runtime, [granted], permissions.Unknown)
  let assert Ok(Nil) =
    api.edit_reserved_facts(runtime, [api.ReservedFactSet(change)])
  assert permissions.withdraw_spawner_grants(runtime, spawner_name, fn(_) {
      False
    })
    == Ok([])
  assert permissions.read_stored(runtime.session) == Ok([granted])
  let assert Ok(Nil) = api.close(runtime)
}

pub fn forget_withdraws_only_a_grant_this_spawner_approved_test() {
  let root = workspace("forget")
  let runtime = session(root)
  child_of(runtime, "^main")
  let from_spawner = policy.GrantWritableRoot(root <> "/work")
  let by_owner = policy.GrantReadableRoot(root)
  let seq = raise(runtime, "policy-1", [from_spawner])
  let assert Decided(_) =
    admit(
      runtime,
      Some(ceiling_over(root)),
      "policy-1",
      Approve(grants: [from_spawner], action:, scope: Session),
      seq,
    )
  let assert Ok(change) =
    permissions.remembering(runtime, [by_owner], permissions.Unknown)
  let assert Ok(Nil) =
    api.edit_reserved_facts(runtime, [api.ReservedFactSet(change)])

  // The owner's grant is not the spawner's to withdraw.
  let assert Refused(..) =
    admit(runtime, Some(ceiling_over(root)), "", Forget(by_owner), 0)
  let assert Ok(standing) = permissions.read_stored(runtime.session)
  assert list.contains(standing, by_owner)

  // Its own is.
  assert admit(runtime, Some(ceiling_over(root)), "", Forget(from_spawner), 0)
    == Forgotten
  let assert Ok(after) = permissions.read_stored(runtime.session)
  assert after == [by_owner]

  // And a second forget finds nothing to withdraw.
  let assert Refused(..) =
    admit(runtime, Some(ceiling_over(root)), "", Forget(from_spawner), 0)
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_symlink_under_the_ceiling_that_leads_outside_it_is_refused_test() {
  let root = workspace("symlink")
  let runtime = session(root)
  child_of(runtime, "^main")
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/outside")
    as "the target outside the ceiling exists"
  let assert Ok(Nil) =
    simplifile.create_symlink(root <> "/outside", root <> "/work/link")
    as "a symlink under the ceiling leads outside it"

  // The text is under the ceiling's root, and the place it names is not.
  let wanted = [policy.GrantWritableRoot(root <> "/work/link")]
  assert approval_ceiling.admits_all(ceiling_over(root), wanted)
  let seq = raise(runtime, "policy-1", wanted)
  assert admit(
      runtime,
      Some(ceiling_over(root)),
      "policy-1",
      Approve(grants: wanted, action:, scope: Once),
      seq,
    )
    == Refused(reason: remote_escalation.outside_the_ceiling)
  assert status_of(runtime, "policy-1") == durable.Pending

  // A real directory under the ceiling is still approved.
  let real = [policy.GrantWritableRoot(root <> "/work")]
  let other = raise(runtime, "policy-2", real)
  let assert Decided(_) =
    admit(
      runtime,
      Some(ceiling_over(root)),
      "policy-2",
      Approve(grants: real, action:, scope: Once),
      other,
    )
  let assert Ok(Nil) = api.close(runtime)
}
