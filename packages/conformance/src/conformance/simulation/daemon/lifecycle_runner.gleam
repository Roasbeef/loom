//// Two faulted daemon scripts: a restart with a lifecycle request still in
//// flight, and a revocation landing on a command already through admission.
////
//// The fault-free baseline in `daemon_runner` establishes that a script's
//// durable rows are decided by the script, the logical clock and the seed.
//// This module spends that baseline. Each script here runs twice, once with
//// nothing going wrong and once under a fault, and the claim is that the two
//// runs converge: the same catalogue rows at the same revision, whichever
//// way the run got there. A fault that moved a row would be a durability
//// finding, and a check that had to be relaxed to accommodate one would be
//// the same finding written down as an exception.
////
//// **What "pending" means here.** The harness has no listener, so a lifecycle
//// request is one the registry itself accepted: `manager.open` answering
//// `Opening`, or `manager.stop_session` answering `Stopping`. Both return
//// while the work behind them is still running, so a root killed at that
//// moment leaves a request whose outcome nobody learned. That is the
//// ambiguity `lifecycle/no-resend` is about, and it does not need a socket to
//// exist.
////
//// **What "principal" means here.** Also without a listener, so not a
//// connection. A principal is an identity the registry knows: an invited
//// member with a credential digest and a session grant. The boundary it
//// crosses is `manager.frame_authority`, which the transport asks once when a
//// command is admitted and again when the reply is delivered. A command in
//// flight is therefore exactly a pair of those answers with a gap between
//// them, and a revocation lands in the gap. What this cannot reach is the
//// socket itself: that no frame is written to a closed connection is a
//// gateway claim, and `tui_shipped_multiplayer_test` is what proves it. What
//// is checked here is the decision the gateway acts on.
////
//// This module is test infrastructure, so `let assert` appears in it under
//// the exemption `packages/conformance/CLAUDE.md` records.

import broker/token
import client/daemon/manager
import conformance/simulation/daemon/harness.{type Harness, type Snapshot}
import conformance/simulation/daemon/lifecycle_faults.{
  type Coordinate, type Fault, type Pending, BeforeAdmission,
  BetweenAdmissionAndDelivery, FaultFree, KillDaemonWithPending, PendingOpen,
  PendingStop, RevokeAt,
}
import conformance/simulation/runner.{type Failure, Failure}
import conformance/simulation/vclock.{type Clockwork}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import storage/access
import storage/catalogue
import weft/poll

/// The logical instant every run starts at, shared with the fault-free
/// baseline so a row minted here is comparable with one minted there.
pub const origin_ms = 1_700_000_000_000

/// Runtime slots the scripts need. One session each, plus room for the
/// reopened incarnation a restart could ask for.
const capacity = 2

/// The workspace both scripts create their session under. It is a synthetic
/// absolute path: the registry records a workspace as owner-supplied metadata
/// and never opens it.
const workspace = "/simulation/lifecycle"

/// The creation request key the restart script reserves its session under.
const restart_key = "lifecycle"

/// The creation request key the revocation script reserves its session under.
const revocation_key = "revocation"

/// The member id the revocation script invites and then revokes.
const member_id = "operator"

/// The verdict for one seed of the lifecycle and revocation scripts.
pub type Verdict {
  /// Every named check held, in the fault-free run, in the faulted run, and
  /// in the comparison between them.
  Passed

  /// A check failed. `reproduce` is the line to paste to run this seed
  /// alone.
  Failed(seed: Int, failure: Failure, reproduce: String)
}

/// What one run converged to: every durable row the catalogue held at the
/// end, and the revision it held them at.
pub type Report =
  Snapshot

/// Runs both scripts under both schedules the seed draws and reports the
/// verdict.
///
/// ## Examples
///
/// ```gleam
/// // lifecycle_runner.run(seed: 20_260_908)
/// ```
pub fn run(seed seed: Int) -> Verdict {
  case restart_converges(seed) {
    Error(failure) -> failed(seed, failure)
    Ok(Nil) ->
      case revocation_converges(seed) {
        Error(failure) -> failed(seed, failure)
        Ok(Nil) -> Passed
      }
  }
}

/// Runs the restart script fault-free and then under the kill the seed drew,
/// and compares the two.
///
/// ## Examples
///
/// ```gleam
/// // lifecycle_runner.restart_converges(4471)
/// ```
pub fn restart_converges(seed: Int) -> Result(Nil, Failure) {
  let pending = lifecycle_faults.pending_for(seed)
  let kill = KillDaemonWithPending(session: restart_key, request: pending)
  use base <- result.try(restart_script(seed, FaultFree, pending))
  use faulted <- result.try(restart_script(seed, kill, pending))
  compare("lifecycle/converges-with-baseline", base, faulted)
}

/// Runs the revocation script fault-free and then under the revocation the
/// seed drew, and compares the two.
///
/// ## Examples
///
/// ```gleam
/// // lifecycle_runner.revocation_converges(4471)
/// ```
pub fn revocation_converges(seed: Int) -> Result(Nil, Failure) {
  let at = lifecycle_faults.coordinate_for(seed)
  let revoke = RevokeAt(principal: member_id, at:)
  use base <- result.try(revocation_script(seed, FaultFree))
  use faulted <- result.try(revocation_script(seed, revoke))
  compare("revocation/converges-with-baseline", base, faulted)
}

/// Runs the restart script once under the named schedule and reports the
/// durable rows it left behind.
///
/// A caller that wants the two runs compared wants `restart_converges`; this
/// is for a test with something to say about a single run's content.
///
/// ## Examples
///
/// ```gleam
/// // lifecycle_runner.restart_script(4471, FaultFree, PendingOpen)
/// ```
pub fn restart_script(
  seed: Int,
  fault: Fault,
  pending: Pending,
) -> Result(Report, Failure) {
  let clock = vclock.start(from: origin_ms)
  let path = state_root(seed, "restart-" <> lifecycle_faults.label(fault))
  let outcome = restart_over(path, clock, seed, fault, pending)
  vclock.stop(clock)
  outcome
}

/// Runs the revocation script once under the named schedule and reports the
/// durable rows it left behind.
///
/// ## Examples
///
/// ```gleam
/// // lifecycle_runner.revocation_script(4471, FaultFree)
/// ```
pub fn revocation_script(seed: Int, fault: Fault) -> Result(Report, Failure) {
  let clock = vclock.start(from: origin_ms)
  let path = state_root(seed, "revocation-" <> lifecycle_faults.label(fault))
  let outcome = {
    use daemon <- result.try(started(path, clock))
    let observed = revocation_body(daemon, seed, fault)
    retire(daemon, observed)
  }
  vclock.stop(clock)
  outcome
}

// One temporary state root per run. The seed and the schedule name the run,
// and the entropy keeps a rerun from inheriting a previous one's catalogue and
// lock. Nothing durable is derived from any of them, because every path the
// verdict reads has the root substituted out of it.
fn state_root(seed: Int, label: String) -> String {
  let suffix = bit_array.base16_encode(token.production_entropy()(8))
  "build/test_db/daemon-lifecycle-"
  <> int.to_string(seed)
  <> "-"
  <> label
  <> "-"
  <> suffix
}

// The restart script proper. Two daemons over one state root: the first
// creates a session and leaves a lifecycle request unsettled, and the second
// is what a crash actually restarts into.
//
// The first daemon is retired inside this function rather than by the caller,
// because how it ends is the schedule. Under the fault it is killed while the
// request is in flight; fault-free it settles the request and drains. Both
// hand the same state root to the second daemon, and the second daemon's
// answer is what the two runs are compared on.
fn restart_over(
  path: String,
  clock: Clockwork,
  seed: Int,
  fault: Fault,
  pending: Pending,
) -> Result(Report, Failure) {
  use first <- result.try(started(path, clock))
  let interrupted = {
    use record <- result.try(create(first, restart_key, seed))
    use Nil <- result.try(request(first, record.id, pending))
    Ok(#(record, harness.epoch(first)))
  }

  // A failure before the fault still has to leave the first daemon retired,
  // or the second could not take the launch lock and the run would report a
  // startup failure in place of the real one.
  case interrupted, fault {
    Error(failure), _any -> {
      let _ = harness.stop(first)
      Error(failure)
    }
    Ok(#(record, epoch)), KillDaemonWithPending(..) ->
      case harness.kill(first, parked: None) {
        Error(reason) -> Error(Failure("harness/kill", reason))
        Ok(Nil) -> restarted(path, clock, seed, record, epoch, pending)
      }
    Ok(#(record, epoch)), FaultFree | Ok(#(record, epoch)), RevokeAt(..) -> {
      let settled = settle(first, record.id, pending)
      case retire(first, settled) {
        Error(failure) -> Error(failure)
        Ok(Nil) -> restarted(path, clock, seed, record, epoch, pending)
      }
    }
  }
}

// The second daemon: the one a crash restarts into, or the one an orderly
// stop is followed by. Both take the same checks, which is the point.
fn restarted(
  path: String,
  clock: Clockwork,
  seed: Int,
  record: catalogue.Registration,
  epoch: String,
  pending: Pending,
) -> Result(Report, Failure) {
  use second <- result.try(
    harness.resume(boot(path, clock, 1))
    |> result.map_error(fn(reason) { Failure("harness/resume", reason) }),
  )
  let observed = {
    use Nil <- result.try(reopen_policy(second, record))
    use Nil <- result.try(no_resend(second, seed, record, epoch, pending))
    snapshot(second)
  }
  case retire(second, observed) {
    Error(failure) -> Error(failure)
    Ok(report) -> Ok(report)
  }
}

// `lifecycle/reopen-policy`: restoration restores metadata and opens nothing.
//
// The registration comes back byte for byte, including the identity the
// reservation minted and the creation time the logical clock supplied, and
// every session the catalogue holds reads back as saved. A daemon that
// resumed an interrupted request on the owner's behalf would have a resident
// or opening session here, and a daemon that lost the record would have no
// row at all.
fn reopen_policy(
  daemon: Harness,
  record: catalogue.Registration,
) -> Result(Nil, Failure) {
  let check = "lifecycle/reopen-policy"
  use snapshot <- result.try(snapshot(daemon))
  use restored <- result.try(
    list.find(snapshot.rows, fn(row: harness.Row) { row.id == record.id })
    |> result.map_error(fn(_) {
      Failure(
        check,
        record.id <> " is absent from the restarted daemon's catalogue",
      )
    }),
  )
  case
    restored.request_key == record.request_key
    && restored.workspace == record.workspace
    && restored.name == record.name
    && restored.created_at == record.created_at
  {
    False ->
      Error(Failure(
        check,
        record.id
          <> " was restored as "
          <> harness.describe_row(restored)
          <> ", which is not the metadata the reservation committed",
      ))
    True -> saved_only(check, snapshot.rows)
  }
}

// Every row a restoration produced must read as saved. `Reserved` would mean
// an unconfirmed reservation was published as a session, and anything live
// would mean restoration opened something.
fn saved_only(check: String, rows: List(harness.Row)) -> Result(Nil, Failure) {
  case list.filter(rows, fn(row: harness.Row) { row.state != "Saved" }) {
    [] -> Ok(Nil)
    [row, ..] ->
      Error(Failure(
        check,
        "restoration published "
          <> harness.describe_row(row)
          <> ", not a saved row",
      ))
  }
}

// `lifecycle/no-resend`: the ambiguous request is not re-issued, and it cannot
// settle against the daemon that replaced the one that accepted it.
//
// Two separate things, and only the second holds for both requests. That
// nothing is running is read from the session's live status, and a status of
// `Saved` only discriminates under `PendingOpen`: an interrupted open that was
// re-driven would leave the session `Opening` or `Resident`, which the status
// names. An interrupted stop is not observable that way, because a stop that
// was re-driven and a stop that was dropped both leave the session `Saved` with
// no slot, so the status check would accept the resend it is meant to catch.
// `PendingStop` is therefore held to `lifecycle/reopen-policy` and to the
// convergence comparison instead, which is where a re-driven stop would show
// up as a moved row.
//
// The second thing holds under both. Every lifetime mints a fresh epoch, and
// the authority boundary checks the epoch before it looks at anything else, so
// a caller still holding the previous lifetime's coordinates is refused
// `StaleEpoch` rather than resolved. That refusal is what makes the absence of
// a resend a property of the daemon rather than of the script's timing.
fn no_resend(
  daemon: Harness,
  seed: Int,
  record: catalogue.Registration,
  epoch: String,
  pending: Pending,
) -> Result(Nil, Failure) {
  let check = "lifecycle/no-resend"
  use Nil <- result.try(case pending {
    PendingStop -> Ok(Nil)
    PendingOpen -> nothing_reopened(daemon, record)
  })

  // Any well-formed digest asks the question, because the epoch is checked
  // before the credential is looked at, and the member digest costs the check
  // nothing beyond the seed it already has. Naming the owner's digest here
  // would tie this check to how the harness reconstructs that digest, so a
  // change to the credential hashing would fail two checks instead of the one
  // that is about it.
  use member <- result.try(member_digest(seed))
  let stale =
    manager.frame_authority(
      harness.registry(daemon),
      epoch:,
      id: record.id,
      incarnation: "the-interrupted-operation",
      digest: member,
    )
  case stale {
    Error(manager.StaleEpoch) -> Ok(Nil)
    _other ->
      Error(Failure(
        check,
        "the previous lifetime's epoch answered "
          <> string.inspect(stale)
          <> " rather than a stale-epoch refusal, so an interrupted request could still settle",
      ))
  }
}

// The half of `lifecycle/no-resend` that only an interrupted open can be held
// to. The session was saved when the open was accepted, so anything but
// `Saved` here is an operation the restarted daemon started on the owner's
// behalf to finish what the dead lifetime began.
fn nothing_reopened(
  daemon: Harness,
  record: catalogue.Registration,
) -> Result(Nil, Failure) {
  let check = "lifecycle/no-resend"
  use status <- result.try(
    harness.status(daemon, record.id)
    |> result.map_error(fn(reason) { Failure(check, reason) }),
  )
  case status {
    manager.Saved -> Ok(Nil)
    manager.Reserved
    | manager.Opening(_)
    | manager.Stopping(_)
    | manager.Resident(_)
    | manager.RecoveryBlocked(_) ->
      Error(Failure(
        check,
        record.id
          <> " came back as "
          <> string.inspect(status)
          <> " after a pending open was left in flight, so the request was resumed rather than dropped",
      ))
  }
}

// Issues the lifecycle request the schedule is going to interrupt, and checks
// that the registry accepted it without settling it.
//
// A pending open needs a saved session to open, and creation leaves one
// resident, so the open is preceded by an ordered stop that is allowed to
// complete. That preparation runs identically under both schedules; only the
// request after it is interrupted.
fn request(
  daemon: Harness,
  id: String,
  pending: Pending,
) -> Result(Nil, Failure) {
  let check = "lifecycle/request-accepted"
  case pending {
    PendingStop ->
      accepted(check, id, manager.stop_session(harness.registry(daemon), id))
    PendingOpen -> {
      use Nil <- result.try(accepted(
        check,
        id,
        manager.stop_session(harness.registry(daemon), id),
      ))
      use Nil <- result.try(await(daemon, id, is_saved))
      accepted(check, id, manager.open(harness.registry(daemon), id))
    }
  }
}

// Both requests answer with the operation they accepted rather than with the
// state the session has reached, which is exactly what makes the outcome
// ambiguous when the daemon then dies.
fn accepted(
  check: String,
  id: String,
  answer: Result(manager.Status, manager.Error),
) -> Result(Nil, Failure) {
  case answer {
    Ok(manager.Opening(_)) | Ok(manager.Stopping(_)) -> Ok(Nil)
    Ok(status) ->
      Error(Failure(
        check,
        id
          <> " answered "
          <> string.inspect(status)
          <> ", not an accepted operation",
      ))
    Error(error) -> Error(Failure(check, id <> ": " <> string.inspect(error)))
  }
}

// The fault-free half of the same moment: let the request finish, so the
// orderly run reaches the same durable place the crashed one is restarted
// into.
fn settle(
  daemon: Harness,
  id: String,
  pending: Pending,
) -> Result(Nil, Failure) {
  case pending {
    PendingStop -> await(daemon, id, is_saved)
    PendingOpen -> await(daemon, id, is_resident)
  }
}

fn is_saved(status: manager.Status) -> Bool {
  status == manager.Saved
}

fn is_resident(status: manager.Status) -> Bool {
  case status {
    manager.Resident(_) -> True
    manager.Reserved
    | manager.Saved
    | manager.Opening(_)
    | manager.Stopping(_)
    | manager.RecoveryBlocked(_) -> False
  }
}

// The revocation script proper. One session, one invited principal, and a
// command that straddles the authority boundary twice.
//
// The fault-free run never revokes, so its principal is admitted at both
// coordinates. The faulted run revokes at the coordinate the seed drew. Both
// end with the same durable rows, because a membership is not a registration:
// a revocation that moved a session's catalogue row would be a finding, and
// the comparison the caller runs afterwards is what says so.
fn revocation_body(
  daemon: Harness,
  seed: Int,
  fault: Fault,
) -> Result(Report, Failure) {
  use record <- result.try(create_shared(daemon, revocation_key, seed))
  use incarnation <- result.try(incarnation_of(daemon, record.id))
  use owner <- result.try(
    harness.owner_digest(daemon)
    |> result.map_error(fn(reason) { Failure("revocation/owner", reason) }),
  )
  use member <- result.try(member_digest(seed))
  use Nil <- result.try(invite(daemon, owner, member, record.id))
  use Nil <- result.try(case fault {
    FaultFree -> fault_free_command(daemon, record.id, incarnation, member)
    RevokeAt(at:, ..) ->
      revoked_command(daemon, owner, member, record.id, incarnation, at)

    // The restart fault names a lifecycle request rather than a coordinate in
    // a command, so there is no schedule for this script to run under it.
    // Reporting that is what keeps the two scripts' faults from being silently
    // interchangeable.
    KillDaemonWithPending(..) ->
      Error(Failure(
        "revocation/schedule",
        "the revocation script was handed "
          <> lifecycle_faults.describe(fault)
          <> ", which names no revocation coordinate",
      ))
  })
  snapshot(daemon)
}

// With nothing revoked, the principal is admitted throughout. This is the
// "before it, its admissions succeed" half of the claim, and it is what makes
// the refusal under the fault mean something.
//
// The first pair is the same warm-up the `BetweenAdmissionAndDelivery` arm
// runs, so that the two schedules differ only in the revocation itself. It is
// a pair rather than a single call because the registry remembers a resolved
// grant for the lifetime of the session's slot: a check that only ever asked
// once would never read the remembered answer, and a mutation that kept a
// remembered grant alive across an administration would pass unnoticed. The
// second pair is the command's own two authority answers, at admission and at
// delivery.
fn fault_free_command(
  daemon: Harness,
  id: String,
  incarnation: String,
  member: access.Digest,
) -> Result(Nil, Failure) {
  use Nil <- result.try(admitted(daemon, id, incarnation, member))
  use Nil <- result.try(admitted(daemon, id, incarnation, member))
  use Nil <- result.try(admitted(daemon, id, incarnation, member))
  admitted(daemon, id, incarnation, member)
}

// `revocation/silence-after-close`: once the owner has revoked a principal,
// the boundary refuses it, and it refuses the command the principal already
// had in flight.
//
// The two coordinates are the two places a revocation can land relative to a
// command, and they are two different schedules rather than one schedule run
// twice. `BeforeAdmission` revokes before the boundary has answered anything
// at all, so the command is refused outright and nothing is ever queued.
// `BetweenAdmissionAndDelivery` first admits the principal, which both fills
// the registry's remembered grant and gets the command through admission, and
// only then revokes: the command was admitted under a grant that was live at
// the time, and the delivery check must still refuse, so what the principal
// queued is never delivered. That difference is what makes a memo the
// administration fails to clear observable under one coordinate and not the
// other. Both then check that the principal stays refused, which is the
// silence the name is about.
fn revoked_command(
  daemon: Harness,
  owner: access.Digest,
  member: access.Digest,
  id: String,
  incarnation: String,
  at: Coordinate,
) -> Result(Nil, Failure) {
  use Nil <- result.try(case at {
    BeforeAdmission -> Ok(Nil)
    BetweenAdmissionAndDelivery -> {
      use Nil <- result.try(admitted(daemon, id, incarnation, member))
      use Nil <- result.try(admitted(daemon, id, incarnation, member))
      admitted(daemon, id, incarnation, member)
    }
  })
  use Nil <- result.try(revoke(daemon, owner))
  use Nil <- result.try(refused(daemon, id, incarnation, member))

  // A second refusal, because one refusal could be a transient read. The
  // claim is that the principal stays out, not that it was out once.
  use Nil <- result.try(refused(daemon, id, incarnation, member))
  let check = "revocation/silence-after-close"
  case manager.session_authority(harness.registry(daemon), member, id) {
    Error(_refused) -> Ok(Nil)
    Ok(answer) ->
      Error(Failure(
        check,
        "a revoked principal still resolves session authority as "
          <> string.inspect(answer),
      ))
  }
}

fn admitted(
  daemon: Harness,
  id: String,
  incarnation: String,
  member: access.Digest,
) -> Result(Nil, Failure) {
  let check = "revocation/admitted-before-close"
  let answer =
    manager.frame_authority(
      harness.registry(daemon),
      epoch: harness.epoch(daemon),
      id:,
      incarnation:,
      digest: member,
    )
  case answer {
    Ok(#(_principal, access.Participant(access.Operator))) -> Ok(Nil)
    _other ->
      Error(Failure(
        check,
        "an invited operator was answered "
          <> string.inspect(answer)
          <> " at the admission boundary of "
          <> id,
      ))
  }
}

fn refused(
  daemon: Harness,
  id: String,
  incarnation: String,
  member: access.Digest,
) -> Result(Nil, Failure) {
  let check = "revocation/silence-after-close"
  let answer =
    manager.frame_authority(
      harness.registry(daemon),
      epoch: harness.epoch(daemon),
      id:,
      incarnation:,
      digest: member,
    )
  case answer {
    Error(manager.Unauthorized) -> Ok(Nil)
    _other ->
      Error(Failure(
        check,
        "a revoked principal was answered "
          <> string.inspect(answer)
          <> " at the admission boundary of "
          <> id
          <> ", so a command it queued would still be delivered",
      ))
  }
}

fn invite(
  daemon: Harness,
  owner: access.Digest,
  member: access.Digest,
  id: String,
) -> Result(Nil, Failure) {
  let action =
    manager.Invite(member_id, "Operator", member, id, access.Operator)
  case
    manager.administer(
      harness.registry(daemon),
      owner,
      harness.epoch(daemon),
      action,
    )
  {
    Ok(_principal) -> Ok(Nil)
    Error(error) ->
      Error(Failure(
        "revocation/invited",
        "the owner could not invite a principal to "
          <> id
          <> ": "
          <> string.inspect(error),
      ))
  }
}

// Revoking every credential rather than one session grant. The narrower
// mutation would leave the principal authenticated, and the claim under test
// is about the boundary refusing it, not about which of the two admin actions
// reached it.
fn revoke(daemon: Harness, owner: access.Digest) -> Result(Nil, Failure) {
  case
    manager.administer(
      harness.registry(daemon),
      owner,
      harness.epoch(daemon),
      manager.RevokeMember(member_id),
    )
  {
    Ok(_principal) -> Ok(Nil)
    Error(error) ->
      Error(Failure(
        "revocation/administered",
        "the owner could not revoke "
          <> member_id
          <> ": "
          <> string.inspect(error),
      ))
  }
}

// A session an owner may invite anyone to has to have an aggregate of its
// own; sharing a workspace-private one requires an explicit stopped isolation
// first, which is a different claim with its own fixture.
fn create_shared(
  daemon: Harness,
  key: String,
  seed: Int,
) -> Result(catalogue.Registration, Failure) {
  harness.create_isolated(daemon, key:, workspace:, name: "Shared", seed:)
  |> result.map_error(fn(reason) {
    Failure("creation/accepted", key <> ": " <> reason)
  })
}

fn create(
  daemon: Harness,
  key: String,
  seed: Int,
) -> Result(catalogue.Registration, Failure) {
  harness.create(daemon, key:, workspace:, name: "Lifecycle", seed:)
  |> result.map_error(fn(reason) {
    Failure("creation/accepted", key <> ": " <> reason)
  })
}

// The incarnation the authority boundary is fenced on. It is a durable
// coordinate of the admission, and every frame check the script makes names
// it, so a session that were silently restarted underneath the script would
// fail the admission check rather than pass under a new instance.
fn incarnation_of(daemon: Harness, id: String) -> Result(String, Failure) {
  let check = "revocation/resident"
  use status <- result.try(
    harness.status(daemon, id)
    |> result.map_error(fn(reason) { Failure(check, reason) }),
  )
  case status {
    manager.Resident(operation) -> Ok(operation)
    manager.Reserved
    | manager.Saved
    | manager.Opening(_)
    | manager.Stopping(_)
    | manager.RecoveryBlocked(_) ->
      Error(Failure(
        check,
        id
          <> " is "
          <> string.inspect(status)
          <> ", so it has no admitted incarnation",
      ))
  }
}

// The member's credential is derived from the seed rather than fixed, so two
// seeds do not invite the same digest into two catalogues, and a single seed
// derives the same one on both of its runs.
fn member_digest(seed: Int) -> Result(access.Digest, Failure) {
  let hex = string.lowercase(int.to_base16(seed))
  let padded = string.slice(hex <> string.repeat("b", 64), 0, 64)
  access.credential_digest(padded)
  |> result.map_error(fn(_) {
    Failure(
      "revocation/credential",
      "the seed did not derive a canonical credential digest: " <> padded,
    )
  })
}

// The first incarnation over a state root. Incarnation zero is the one no
// crash precedes, so the lease clock it reads is the unadvanced one.
fn started(path: String, clock: Clockwork) -> Result(Harness, Failure) {
  harness.start(boot(path, clock, 0))
  |> result.map_error(fn(reason) { Failure("harness/start", reason) })
}

// Everything one incarnation is started from. Only the incarnation number
// differs between the two daemons a restart script runs, and it is what moves
// the writer lease clock past the lease the killed incarnation left behind.
fn boot(path: String, clock: Clockwork, incarnation: Int) -> harness.Boot {
  harness.Boot(
    state_root: path,
    clock:,
    capacity:,
    incarnation:,
    arrest: harness.Unimpeded,
  )
}

// A daemon that will not retire is a finding rather than a footnote: a leaked
// launch lock or a root blocked in recovery is exactly what a faulted run is
// looking for, so a stop failure fails a run that otherwise passed.
fn retire(daemon: Harness, observed: Result(a, Failure)) -> Result(a, Failure) {
  case harness.stop(daemon), observed {
    Error(reason), Ok(_) -> Error(Failure("harness/stop", reason))
    _stopped, observed -> observed
  }
}

fn snapshot(daemon: Harness) -> Result(Report, Failure) {
  harness.snapshot(daemon)
  |> result.map_error(fn(reason) { Failure("catalogue/snapshot", reason) })
}

// Waits for a session to reach a settled state, on real milliseconds. The
// logical clock governs what a run mints, not how long a real registry takes
// to publish it, so this is a deadlock backstop rather than part of the
// schedule.
fn await(
  daemon: Harness,
  id: String,
  settled: fn(manager.Status) -> Bool,
) -> Result(Nil, Failure) {
  let check = "lifecycle/settles"
  let answer =
    poll.until(within: 20_000, every: 1, attempt: fn() {
      case harness.status(daemon, id) {
        Error(reason) -> poll.Fail(reason)
        Ok(status) ->
          case settled(status) {
            True -> poll.Done(Nil)
            False -> poll.Retry
          }
      }
    })
  case answer {
    poll.Answered(Nil) -> Ok(Nil)
    poll.Failed(reason) -> Error(Failure(check, reason))
    poll.Expired -> Error(Failure(check, id <> " never settled"))
  }
}

// The convergence check. Both the rows and the revision they were read at have
// to agree: a run that rewrote a row would carry the same rows at a higher
// revision and would otherwise pass.
fn compare(
  check: String,
  base: Report,
  faulted: Report,
) -> Result(Nil, Failure) {
  case base.fence == faulted.fence {
    False ->
      Error(Failure(
        check,
        "catalogue revision "
          <> int.to_string(base.fence)
          <> " fault-free and "
          <> int.to_string(faulted.fence)
          <> " under the fault",
      ))
    True ->
      case base.rows == faulted.rows {
        True -> Ok(Nil)
        False -> Error(Failure(check, difference(base, faulted)))
      }
  }
}

fn difference(base: Report, faulted: Report) -> String {
  let render = fn(report: Report) {
    list.map(report.rows, harness.describe_row) |> string.join("\n  ")
  }
  "fault-free:\n  "
  <> render(base)
  <> "\nunder the fault:\n  "
  <> render(faulted)
}

fn failed(seed: Int, failure: Failure) -> Verdict {
  Failed(
    seed:,
    failure:,
    reproduce: "lifecycle_runner.run(seed: " <> int.to_string(seed) <> ")",
  )
}
