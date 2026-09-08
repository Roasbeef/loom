//// One hand-written daemon script, run twice, with the two runs compared.
////
//// The session runner draws a script and a fault schedule from a seed and
//// asks whether the faulted run ended where the fault-free one did. This is
//// the fault-free half of the same arrangement one layer up: no schedule, no
//// generator, one fixed script over two workspaces and two sessions, run
//// once and then again from a daemon that has never seen the first run's
//// files. What the comparison establishes is that the durable rows a script
//// produces are decided by the script, the logical clock and the seed, and
//// by nothing else the machine happened to be doing.
////
//// That is worth having on its own. A replay whose ids drifted would mean
//// the daemon's identities were not reproducible, and every later check
//// would be comparing noise. But its purpose is to be the baseline the
//// faulted runs are measured against: a fault is transparent when the run
//// under it lands on the rows recorded here.
////
//// The runner's own `Report` and `Verdict` are shaped for one conversation:
//// projected transcripts, ledger totals, per-strand terminal writes. None of
//// that has a daemon-level meaning, so this module carries its own verdict
//// rather than widening the session runner's. The named-check convention is
//// shared, and `runner.Failure` is reused unchanged so a printer that
//// already renders one renders the other.
////
//// This module is test infrastructure, so `let assert` appears in it under
//// the exemption `packages/conformance/CLAUDE.md` records.

import broker/token
import client/daemon/manager
import conformance/simulation/daemon/harness.{type Harness, type Snapshot}
import conformance/simulation/runner.{type Failure, Failure}
import conformance/simulation/vclock
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import storage/catalogue

/// The logical instant every run starts at. Nothing in a fault-free daemon
/// script advances the clock, so every id a run mints carries this timestamp
/// and a replay mints the same ones.
pub const origin_ms = 1_700_000_000_000

/// Runtime slots the script needs, with room for the sessions it opens.
const capacity = 4

/// The two workspaces the script creates sessions under. They are synthetic
/// absolute paths rather than real directories: the registry records a
/// workspace as owner-supplied metadata and never opens it, and a path that
/// did exist would make the rows depend on the machine's filesystem.
const workspace_a = "/simulation/workspace-a"

const workspace_b = "/simulation/workspace-b"

/// The verdict for one seed of the daemon script.
pub type Verdict {
  /// Every check held, in both runs and in the comparison between them.
  Passed

  /// A check failed. `reproduce` is the line to paste to run this seed
  /// alone.
  Failed(seed: Int, failure: Failure, reproduce: String)
}

/// What one run of the script converged to: every durable row the catalogue
/// held at the end, and the revision it held them at.
pub type Report =
  Snapshot

/// Runs the script twice from the given seed and reports the verdict.
///
/// The two runs use two temporary state roots, so the second is a daemon
/// that has never seen the first's catalogue, lock or conversation files.
/// Everything they are compared on is relative to that root.
///
/// ## Examples
///
/// ```gleam
/// // daemon_runner.run(seed: 12345)
/// ```
pub fn run(seed seed: Int) -> Verdict {
  case observe(seed) {
    Error(failure) -> failed(seed, failure)
    Ok(base) ->
      case observe(seed) {
        Error(failure) -> failed(seed, failure)
        Ok(replay) ->
          case compare(base, replay) {
            Ok(Nil) -> Passed
            Error(failure) -> failed(seed, failure)
          }
      }
  }
}

/// Runs the script once and reports the durable rows it left behind, or the
/// first named check that failed inside the run.
///
/// A caller that wants the two runs compared wants `run`; this is for a test
/// that has something to say about a single run's content.
///
/// ## Examples
///
/// ```gleam
/// // daemon_runner.observe(12345)
/// ```
pub fn observe(seed: Int) -> Result(Report, Failure) {
  let clock = vclock.start(from: origin_ms)
  let outcome = case harness.start(state_root(seed), clock:, capacity:) {
    Error(reason) -> Error(Failure("harness/start", reason))
    Ok(daemon) -> {
      let observed = script(daemon, seed)

      // A daemon that will not retire is a finding, not a footnote: a
      // leaked launch lock or a root blocked in recovery is exactly what a
      // faulted run is looking for, so a stop failure fails a run that
      // otherwise passed rather than being discarded.
      case harness.stop(daemon), observed {
        Error(reason), Ok(_) -> Error(Failure("harness/stop", reason))
        _stopped, observed -> observed
      }
    }
  }
  vclock.stop(clock)
  outcome
}

// One temporary state root per run. The seed names the run, and the entropy
// keeps a second run of the same seed from inheriting the first's catalogue
// and lock; nothing durable is derived from either, because everything the
// verdict reads has the root substituted out of it.
fn state_root(seed: Int) -> String {
  let suffix = bit_array.base16_encode(token.production_entropy()(8))
  "build/test_db/daemon-sim-" <> int.to_string(seed) <> "-" <> suffix
}

// The script itself. Two workspaces, two creation keys, both sessions read
// back through the catalogue under their canonical ids, and one retry of an
// existing key with a different generator seed. The retry is what makes the
// creation-key claim observable rather than assumed: a registry that minted
// on every call would answer it with a second identity.
fn script(daemon: Harness, seed: Int) -> Result(Report, Failure) {
  use alpha <- result.try(create(daemon, "alpha", workspace_a, "Alpha", seed))
  use beta <- result.try(create(daemon, "beta", workspace_b, "Beta", seed + 1))
  use Nil <- result.try(readable(daemon, alpha, workspace_a))
  use Nil <- result.try(readable(daemon, beta, workspace_b))

  // A different seed on the retry: the generator it builds must never be
  // consulted, because the key already names a durable reservation.
  use retried <- result.try(create(
    daemon,
    "alpha",
    workspace_a,
    "Alpha",
    seed + 9973,
  ))
  use Nil <- result.try(one_identity(alpha, retried))
  harness.snapshot(daemon)
  |> result.map_error(fn(reason) { Failure("catalogue/snapshot", reason) })
}

fn create(
  daemon: Harness,
  key: String,
  workspace: String,
  name: String,
  seed: Int,
) -> Result(catalogue.Registration, Failure) {
  harness.create(daemon, key:, workspace:, name:, seed:)
  |> result.map_error(fn(reason) {
    Failure("creation/accepted", key <> ": " <> reason)
  })
}

// `creation/readable-by-id`: a confirmed session is reachable through the
// catalogue under the identity the reservation minted, carrying the metadata
// the owner supplied. An open of the same id must agree that it is resident,
// so a row that reads back while the registry has lost the instance fails
// here rather than at the comparison.
fn readable(
  daemon: Harness,
  record: catalogue.Registration,
  workspace: String,
) -> Result(Nil, Failure) {
  let check = "creation/readable-by-id"
  use row <- result.try(
    harness.row(daemon, record.id)
    |> result.map_error(fn(reason) { Failure(check, reason) }),
  )
  use status <- result.try(
    harness.open(daemon, record.id)
    |> result.map_error(fn(reason) { Failure(check, reason) }),
  )

  // The creation time is pinned to the logical origin outright rather
  // than left to the cross-run comparison: two runs a few milliseconds
  // apart would only catch a real-time read that happened to straddle a
  // millisecond, and a coarser read would usually pass.
  case
    row.workspace == workspace
    && row.state == "Saved"
    && row.created_at == origin_ms
  {
    False ->
      Error(Failure(
        check,
        record.id
          <> " read back as "
          <> harness.describe_row(row)
          <> ", expecting workspace "
          <> workspace
          <> ", a confirmed row, and created_at at the logical origin "
          <> int.to_string(origin_ms),
      ))
    True -> resident(check, record.id, status)
  }
}

fn resident(
  check: String,
  id: String,
  status: manager.Status,
) -> Result(Nil, Failure) {
  case status {
    manager.Resident(_) -> Ok(Nil)
    manager.Reserved
    | manager.Saved
    | manager.Opening(_)
    | manager.Stopping(_)
    | manager.RecoveryBlocked(_) ->
      Error(Failure(
        check,
        id <> " opened as " <> string.inspect(status) <> ", not resident",
      ))
  }
}

// `creation/one-identity-per-key`: the whole point of the request key. A
// retry may not mint a second identity, a second database path, or a second
// creation time, however the caller seeded its generator.
//
// The confirmation state is deliberately excluded from the comparison. The
// first call returns while its builder still owns the operation, so its view
// reads `Reserved`, and the retry reads the same row after the builder
// confirmed it. That difference is the reservation making progress, not a
// second identity.
fn one_identity(
  first: catalogue.Registration,
  retried: catalogue.Registration,
) -> Result(Nil, Failure) {
  let identity = fn(record: catalogue.Registration) {
    #(record.id, record.path, record.request_key, record.created_at)
  }
  case identity(first) == identity(retried) {
    True -> Ok(Nil)
    False ->
      Error(Failure(
        "creation/one-identity-per-key",
        "key "
          <> first.request_key
          <> " reserved "
          <> first.id
          <> " at "
          <> first.path
          <> " but its retry answered "
          <> retried.id
          <> " at "
          <> retried.path,
      ))
  }
}

// `replay/equal-catalogue-rows`: the comparison the later faulted runs are
// measured against. Both the rows and the revision they were read at have to
// agree; a run that wrote a row twice would carry the same rows at a higher
// fence and would otherwise pass.
fn compare(base: Report, replay: Report) -> Result(Nil, Failure) {
  let check = "replay/equal-catalogue-rows"
  case base.fence == replay.fence {
    False ->
      Error(Failure(
        check,
        "catalogue fence "
          <> int.to_string(base.fence)
          <> " on the first run and "
          <> int.to_string(replay.fence)
          <> " on the replay",
      ))
    True ->
      case base.rows == replay.rows {
        True -> Ok(Nil)
        False -> Error(Failure(check, difference(base, replay)))
      }
  }
}

fn difference(base: Report, replay: Report) -> String {
  let render = fn(report: Report) {
    list.map(report.rows, harness.describe_row) |> string.join("\n  ")
  }
  "first run:\n  " <> render(base) <> "\nreplay:\n  " <> render(replay)
}

fn failed(seed: Int, failure: Failure) -> Verdict {
  Failed(
    seed:,
    failure:,
    reproduce: "daemon_runner.run(seed: " <> int.to_string(seed) <> ")",
  )
}
