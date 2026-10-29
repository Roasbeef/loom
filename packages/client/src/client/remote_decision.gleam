//// The box's door for the decision of a spawner's operator (protocol-change/089).
////
//// A child in a delegate session is refused by its sandbox, and the refusal is
//// an escalation record there like any other. When the spawner sets an approval
//// ceiling the operator on the spawning orchestrator is shown the record and
//// answers it (`Resolve`). This module is where that answer is judged and
//// committed, in the delegate session, against the same record a local operator
//// would have answered. It is the gateway's `approve` door (`docs/architecture/approvals.md`,
//// "Deciding") with the connection taken out and a ceiling put in: the same
//// question, the same echoed action, the same subset of the wanted diff, the same
//// compare-and-set commit, and one added test, that every grant is inside the
//// ceiling.
////
//// ## What is checked, in order
////
//// 1. The spawner has a ceiling. A spawner with none is unattended, and a
////    decision from it is refused as outside the ceiling.
//// 2. The record exists and was raised by a descendant of the parent the message
////    names. The message arrives on a connection that proves only that it came
////    from the spawner's node, and the delegate session serves the children of
////    one parent. Otherwise the answer is `Refused`.
//// 3. The record is at the `seq` the operator was shown, and is pending.
////    Otherwise the answer is `Stale` with the record as it is now, so the
////    operator sees the current question and not an error.
//// 4. For an approval: the echoed action is the record's, and every grant is in
////    the record's wanted list (`Stale` otherwise, as for a local operator), and
////    every grant names a canonical path that is inside the ceiling (`Refused`,
////    and the record stays pending for the owner of this machine). A path is
////    canonical when resolving it on this machine gives the same path, so a
////    symlink under the ceiling that leads outside it is not inside it.
//// 5. The commit is one compare-and-set at the `seq` read in step 3. A session
////    approval commits the remembered grant in the same transaction, with the
////    spawner's provenance.
////
//// The deciding principal arrives as plain text and is kept as provenance. It is
//// not a principal of this machine and nothing here resolves it to one.
////
//// ## A session the spawner's page started
////
//// A relayed session (protocol-change/094) is not a delegate session, and no
//// parent's descendants raise its requests: the person who decides is the
//// spawner's, and the session is theirs because the registry's relayed row says
//// so, which the box's host has already checked. `admit_relayed` is the same
//// judgement with the descent test taken out. Every other check, the ceiling,
//// the echoed action, the subset of the wanted list, the canonical paths and the
//// compare-and-set, is the one function, so a decision from a page and a
//// decision about a child cannot drift apart.
////
//// ## Flow
////
//// `admit` → `admit_relayed` → `forget` → `decide` → `approve` → `answered`
////
//// 1. `admit` applies the ceiling check and routes by decision, and
////    `admit_relayed` does the same for a session the spawner's page started.
//// 2. `forget` withdraws a remembered grant this spawner approved.
//// 3. `decide` reads the record and applies steps 2 and 3 above, and `canonical`
////    is the path test of step 4.
//// 4. `approve` and `deny` commit the two decisions on the record that `decide`
////    read, and `answered` tells the child and reads the record back as the box
////    now has it.
////
//// ## Telling the child
////
//// A child's refused call parks only for a short grace, so the decision usually
//// arrives after the call settled in band and often after the child's run ended.
//// `answered` hands a committed decision to `escalate.notify_spawner_decision`,
//// which steers a child that is still running and opens a run on one that is
//// idle, bounded by the child's deadline as a parent's `agent_send` would be.
//// The child is told after the commit, never before, so the run it is woken
//// into finds the grant already in the store.

import broker/policy.{type Grant}
import client/approval_ceiling.{type Ceiling}
import client/delegate_outbox.{type SpawnerLink}
import client/escalate
import client/escalation_view
import client/grants
import client/permissions
import client/remote_escalation.{
  type Answer, type Decider, type Decision, Approve, Decided, Deny, Forget,
  Forgotten, Once, Refused, Session, Stale,
}
import client/remote_spawn.{type Parent}
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import runtime/api
import runtime/escalation as durable
import runtime/lineage
import tools/fs

/// The longest chain of lineage cells the descent test follows. A child's chain
/// ends at a reference after a few hops, and the bound only keeps a damaged
/// ledger from looping.
const lineage_limit = 32

/// Judges and commits a decision. See the module doc for the order of the checks.
///
/// `now_ms` stamps the provenance of a remembered grant, on the session's clock.
/// `Error` means the decision committed but its current record could not be
/// read back; validation and rejected commits remain answers in `Ok`.
///
/// ## Examples
///
/// ```gleam
/// // remote_decision.admit(runtime, link, parent, "policy-ab", escalation.Deny, 3, decider, now)
/// ```
pub fn admit(
  runtime: api.Runtime,
  link: SpawnerLink,
  parent: Parent,
  escalation_id: String,
  decision: Decision,
  expected_seq: Int,
  decider: Decider,
  now_ms: Int,
) -> Result(Answer, String) {
  judge(
    runtime,
    link.spawner,
    link.ceiling,
    fn(record) { raised_under(runtime, record, parent) },
    "that request is not from a child of this parent",
    escalation_id,
    decision,
    expected_seq,
    decider,
    now_ms,
  )
}

/// Judges and commits a decision from the page of the spawner that started the
/// session (protocol-change/094). It is `admit` with the descendant test taken
/// out: the caller has already checked that the registry's relayed row names
/// this session for `spawner`, and the record needs no ancestry because every
/// request of the session is the spawner's to answer. A committed decision
/// whose record cannot be read back returns `Error` for the transport to report.
///
/// ## Examples
///
/// ```gleam
/// // remote_decision.admit_relayed(runtime, "laptop", Some(ceiling), "policy-ab", escalation.Deny, 3, decider, now)
/// ```
pub fn admit_relayed(
  runtime: api.Runtime,
  spawner: String,
  ceiling: Option(Ceiling),
  escalation_id: String,
  decision: Decision,
  expected_seq: Int,
  decider: Decider,
  now_ms: Int,
) -> Result(Answer, String) {
  judge(
    runtime,
    spawner,
    ceiling,
    fn(_record) { True },
    "that request is not this session's",
    escalation_id,
    decision,
    expected_seq,
    decider,
    now_ms,
  )
}

// The judgement both doors share. `within` says whether the record is one the
// decider may answer, and `outside` is the refusal when it is not.
/// Judge keeps this client operation’s decoding or state decision in one place.
fn judge(
  runtime: api.Runtime,
  spawner: String,
  ceiling: Option(Ceiling),
  within: fn(durable.Escalation) -> Bool,
  outside: String,
  escalation_id: String,
  decision: Decision,
  expected_seq: Int,
  decider: Decider,
  now_ms: Int,
) -> Result(Answer, String) {
  // This match resolves ceiling before the surrounding protocol step continues.
  // This match resolves ceiling before the enclosing validation continues.
  case ceiling {
    None -> Ok(Refused(reason: remote_escalation.outside_the_ceiling))
    Some(ceiling) ->
      // This match resolves decision before the surrounding protocol step continues.
      case decision {
        Forget(grant:) -> Ok(forget(runtime, spawner, grant))
        Deny ->
          decide(
            runtime,
            within,
            outside,
            escalation_id,
            expected_seq,
            fn(cell) { deny(runtime, cell, decider) },
          )
        Approve(grants: approved, action:, scope:) ->
          decide(
            runtime,
            within,
            outside,
            escalation_id,
            expected_seq,
            fn(cell) {
              approve(
                runtime,
                spawner,
                ceiling,
                cell,
                approved,
                action,
                scope,
                decider,
                now_ms,
              )
            },
          )
      }
  }
}

// Withdraws a grant this spawner's operator approved for the session. A grant
// that is not remembered, or that was approved by anyone else, is not theirs to
// withdraw.
/// Forget keeps this client operation’s decoding or state decision in one place.
fn forget(runtime: api.Runtime, spawner: String, grant: Grant) -> Answer {
  // This match resolves permissions.forgetting_for_spawner(runtime, spawner, grant) before the surrounding protocol step continues.
  // This match resolves permissions.forgetting_for_spawner(runtime, spawner, grant) before the enclosing validation continues.
  case permissions.forgetting_for_spawner(runtime, spawner, grant) {
    Error(permissions.Stale) ->
      Refused(reason: "that permission is no longer remembered")
    Error(permissions.Failed(reason:)) -> Refused(reason:)
    Ok(edits) ->
      // This match resolves api.edit_reserved_facts(runtime, edits) before the surrounding protocol step continues.
      case api.edit_reserved_facts(runtime, edits) {
        Ok(Nil) -> Forgotten
        Error(_) ->
          Refused(reason: "the remembered permissions changed; try again")
      }
  }
}

// Reads the record once, with the register sequence it was written at, and
// checks it is the question the operator answered and a child of this parent's.
// The commit that follows asserts the same sequence, so a claim that lands
// between the check and the commit loses the commit and the operator is shown
// the new question.
/// Decide keeps this client operation’s decoding or state decision in one place.
fn decide(
  runtime: api.Runtime,
  within: fn(durable.Escalation) -> Bool,
  outside: String,
  escalation_id: String,
  expected_seq: Int,
  commit: fn(api.EscalationCell) -> Result(Answer, String),
) -> Result(Answer, String) {
  // This match resolves api.escalation_cell(runtime, escalation_id) before the surrounding protocol step continues.
  // This match resolves api.escalation_cell(runtime, escalation_id) before the enclosing validation continues.
  case api.escalation_cell(runtime, escalation_id) {
    Error(_) -> Ok(Refused(reason: "unknown escalation: " <> escalation_id))
    Ok(cell) -> {
      use <- bool.lazy_guard(when: !within(cell.record), return: fn() {
        Ok(Refused(reason: outside))
      })
      use <- bool.lazy_guard(when: cell.seq != expected_seq, return: fn() {
        Ok(stale(cell, "the displayed question has changed"))
      })
      use <- bool.lazy_guard(
        when: cell.record.status != durable.Pending,
        return: fn() {
          Ok(stale(
            cell,
            "the request is " <> escalation_view.status_name(cell.record.status),
          ))
        },
      )
      commit(cell)
    }
  }
}

// Whether the call that raised the record ran in a descendant of the parent. A
// record with no scope names no call and is nobody's.
/// Raised under keeps this client operation’s decoding or state decision in one place.
fn raised_under(
  runtime: api.Runtime,
  record: durable.Escalation,
  parent: Parent,
) -> Bool {
  // This match resolves record.scope before the surrounding protocol step continues.
  // This match resolves record.scope before the enclosing validation continues.
  case record.scope {
    None -> False
    Some(scope) ->
      lineage.is_descendant(
        of: api.parent_reference_prefix <> parent.strand,
        strand: scope.strand,
        cells: fn(name) {
          // This match resolves api.fact(runtime, lineage.register_key(name)) before the surrounding protocol step continues.
          case api.fact(runtime, lineage.register_key(name)) {
            Ok(Some(value)) -> lineage.decode(value) |> option.from_result
            Ok(None) | Error(_) -> None
          }
        },
        limit: lineage_limit,
      )
  }
}

/// Stale keeps this client operation’s decoding or state decision in one place.
fn stale(cell: api.EscalationCell, reason: String) -> Answer {
  Stale(record: escalation_view.view(cell.record, cell.seq), reason:)
}

/// Deny keeps this client operation’s decoding or state decision in one place.
fn deny(
  runtime: api.Runtime,
  cell: api.EscalationCell,
  decider: Decider,
) -> Result(Answer, String) {
  api.deny_escalation_at(
    runtime,
    cell,
    Some(remote_escalation.origin_of(decider)),
  )
  |> answered(runtime, cell, escalate.Denied)
}

// An approval is the local operator's approval with the ceiling put in. The
// ceiling is checked after the echoes, so a stale approval is told it is stale
// whatever it asked for, and before the commit, so that nothing outside the
// ceiling is ever written.
/// Approve keeps this client operation’s decoding or state decision in one place.
fn approve(
  runtime: api.Runtime,
  spawner: String,
  ceiling: Ceiling,
  cell: api.EscalationCell,
  approved: List(Grant),
  action: String,
  scope: remote_escalation.Scope,
  decider: Decider,
  now_ms: Int,
) -> Result(Answer, String) {
  let record = cell.record
  use wanted <- or_refuse(wanted_of(record))
  use <- bool.lazy_guard(
    when: option.unwrap(record.action, "") != action,
    return: fn() {
      Ok(stale(
        cell,
        "the action this approval names is not the one the request now "
          <> "carries",
      ))
    },
  )
  use <- bool.lazy_guard(
    when: option.is_some(grants.first_unwanted(approved, wanted:)),
    return: fn() {
      Ok(stale(
        cell,
        "the approved grants are not a subset of what was asked for",
      ))
    },
  )
  use <- bool.lazy_guard(
    when: approved == []
      || !canonical(approved)
      || !approval_ceiling.admits_all(ceiling, approved),
    return: fn() { Ok(Refused(reason: remote_escalation.outside_the_ceiling)) },
  )
  let origin = Some(remote_escalation.origin_of(decider))
  let payloads = list.map(approved, grants.encode)

  // This match resolves scope before the surrounding protocol step continues.
  // This match resolves scope before the enclosing validation continues.
  case scope {
    Once -> api.approve_escalation_at(runtime, cell, payloads, origin)
    Session ->
      case
        permissions.remembering_action(
          runtime,
          record,
          approved,
          permissions.Spawner(
            spawner:,
            principal: remote_escalation.origin_of(decider),
            at_ms: now_ms,
          ),
        )
      {
        Error(reason) -> Error(api.ReadFailed(reason))
        Ok(change) ->
          api.approve_escalation_with_fact_at(
            runtime,
            cell,
            payloads,
            origin,
            change,
          )
      }
  }
  // This match resolves scope before the enclosing validation continues.
  |> answered(runtime, cell, case scope {
    Once -> escalate.ApprovedOnce
    Session -> escalate.ApprovedForSession
  })
}

// Whether every path a grant names is already its own canonical path on this
// machine. The ceiling compares text, and a path under the ceiling can be a
// symlink whose target is outside it, so a grant that is not canonical is not
// judged inside the ceiling. This is the rule `permissions.revalidate` applies
// to a remembered grant. A path that cannot be resolved is not canonical.
/// Canonical keeps this client operation’s decoding or state decision in one place.
fn canonical(approved: List(Grant)) -> Bool {
  let filesystem = fs.real_filesystem()
  list.all(approved, fn(grant) {
    // This match resolves grant before the surrounding protocol step continues.
    // This match resolves grant before the enclosing validation continues.
    case grant {
      policy.GrantWritableRoot(path:)
      | policy.GrantReadableRoot(path:)
      | policy.GrantScratch(policy.ScratchPath(path:)) ->
        fs.resolve_real(filesystem, "/", path) == Ok(path)
      policy.GrantNetwork(_)
      | policy.GrantEnv(_)
      | policy.GrantLimit(..)
      | policy.GrantScratch(policy.ScratchTmpfs) -> True
    }
  })
}

/// Wanted of keeps this client operation’s decoding or state decision in one place.
fn wanted_of(record: durable.Escalation) -> Result(List(Grant), String) {
  grants.decode_denial(record.denial)
  |> result.map(fn(decoded) { decoded.wanted })
  |> result.map_error(fn(_) { "the stored denial is unreadable" })
}

/// Keeps validation refusals conclusive while a committed read-back can fail.
fn or_refuse(
  found: Result(a, String),
  then: fn(a) -> Result(Answer, String),
) -> Result(Answer, String) {
  // This match resolves found before the surrounding protocol step continues.
  // This match resolves found before the enclosing validation continues.
  case found {
    Ok(value) -> then(value)
    Error(reason) -> Ok(Refused(reason:))
  }
}

// The answer to a commit. A lost compare-and-set is the question having moved,
// and the operator is shown it as it now is. The storage contract guarantees
// a returned commit error applied nothing; a successful commit whose record
// cannot be read back is carried separately to the transport.
/// Distinguishes rejected commits from unavailable post-commit records.
fn answered(
  committed: Result(durable.Escalation, api.ApiError),
  runtime: api.Runtime,
  cell: api.EscalationCell,
  decision: escalate.OperatorDecision,
) -> Result(Answer, String) {
  // This match resolves committed before the surrounding protocol step continues.
  // This match resolves committed before the enclosing validation continues.
  case committed {
    // The decision, and for a session approval the remembered grant, are
    // durable in the commit that answered `Ok`, and only then is the child told.
    // The notice may open a run on an idle child, and that run's retry re-checks
    // the call against the store, so it is admitted after the grant it spends
    // and cannot race it. A decision that lost its compare-and-set, or a second
    // decision on a record no longer pending, never reaches this arm, so a child
    // is woken at most once for a record's `seq`.
    Ok(_) -> {
      let _ = escalate.notify_spawner_decision(runtime, cell, decision)
      read_back(runtime, cell)
    }
    Error(api.RaceLost) ->
      // This match resolves api.escalation_cell(runtime, cell.record.id) before the surrounding protocol step continues.
      case api.escalation_cell(runtime, cell.record.id) {
        Ok(fresh) ->
          Ok(stale(fresh, "the request changed while it was decided"))
        Error(_) ->
          Ok(Refused(reason: "the request changed while it was decided"))
      }
    Error(_) -> Ok(Refused(reason: "the decision could not be committed"))
  }
}

// The record after the commit, as the box has it.
/// Reads the committed record without treating a failed read as a rejection.
fn read_back(
  runtime: api.Runtime,
  cell: api.EscalationCell,
) -> Result(Answer, String) {
  // This match resolves api.escalation_cell(runtime, cell.record.id) before the surrounding protocol step continues.
  // This match resolves api.escalation_cell(runtime, cell.record.id) before the enclosing validation continues.
  case api.escalation_cell(runtime, cell.record.id) {
    Ok(fresh) ->
      Ok(Decided(record: escalation_view.view(fresh.record, fresh.seq)))
    Error(_) -> Error("the decision committed but the record is unreadable")
  }
}
