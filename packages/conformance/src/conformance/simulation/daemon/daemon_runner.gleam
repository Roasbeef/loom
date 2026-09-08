//// One generated daemon script, run fault-free and then run again under a
//// schedule that kills the daemon partway through a creation.
////
//// The session runner draws a script and a fault schedule from a seed and
//// asks whether the faulted run ended where the fault-free one did. This is
//// the same arrangement one layer up. The script is what the run is asked to
//// do: workspaces, creation keys, and which keys are retried. The schedule is
//// where the daemon dies, and it must be transparent, so the two runs have to
//// converge on the same catalogue rows at the same revision.
////
//// A kill here is the whole daemon and then a `start` over the same state
//// root. The root answers a dead registry by blocking recovery rather than
//// restarting it in place, so a registry restarted underneath a live root is
//// a state production never reaches; the durable shape is the root going away
//// and the next start rebuilding from what was committed.
////
//// Four checks, each reporting its own name:
////
//// - `creation/one-identity-per-key` — every observation of a request key,
////   before the kill and after it, answers the same id, path and creation
////   time.
//// - `creation/no-orphan-file` — at the end of a run, every confirmed row
////   has its conversation database and every database in the sessions
////   directory has a confirmed row naming it.
//// - `publication/before-execute` — a reservation is never resident and
////   never admitted for an explicit open before its row is confirmed, and a
////   session that did become resident carries its reserved identity in its
////   own database.
//// - `replay/equal-catalogue-rows` — the fault-free run and the faulted run
////   end on the same rows at the same catalogue revision.
////
//// The domain services are not opened under this harness, so a domain row's
//// memory and search databases never exist and no check may expect them. The
//// only files a run produces are the catalogue and the conversation
//// databases.
////
//// This module is test infrastructure, so `let assert` appears in it under
//// the exemption `packages/conformance/CLAUDE.md` records.

import broker/token
import client/daemon/manager
import conformance/simulation/daemon/daemon_fault.{
  type Schedule, type Step, AfterConfirm, AfterCustodyPublish, AfterDomainBind,
  AfterReservation, KillDaemonAt,
}
import conformance/simulation/daemon/daemon_script.{type Creation, type Script}
import conformance/simulation/daemon/harness.{type Harness, type Snapshot}
import conformance/simulation/random
import conformance/simulation/runner.{type Failure, Failure}
import conformance/simulation/vclock.{type Clockwork}
import gleam/bit_array
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import storage/catalogue
import storage/sqlite

/// The logical instant every run starts at. Nothing inside one incarnation
/// advances the clock, so every id a run mints carries this timestamp and a
/// replay mints the same ones.
pub const origin_ms = 1_700_000_000_000

/// Runtime slots the script needs. Sessions and domains are counted against
/// the same limit in the registry, so this covers three sessions and the two
/// workspaces they can be spread over, with room to spare.
const capacity = 6

/// How long the run waits for a parked builder to report that its step was
/// reached. It is a real millisecond backstop against a schedule whose fault
/// the run never gets to, not part of the simulated schedule.
const arrival_ms = 20_000

/// The verdict for one seed of the daemon script.
pub type Verdict {
  /// Every check held, in both runs and in the comparison between them.
  Passed

  /// A check failed. `reproduce` is the line to paste to run this seed
  /// alone, and `detail` names the script and the schedule it was drawn
  /// with, because neither is recoverable from the seed by eye.
  Failed(seed: Int, failure: Failure, reproduce: String, detail: String)
}

/// What one run of the script converged to: every durable row the catalogue
/// held at the end, and the revision it held them at.
pub type Report =
  Snapshot

// Every observation of one request key's identity. Two observations of one
// key that disagree on any component are two identities, whatever the
// catalogue's row count says.
type Identity =
  #(String, String, String, Int)

/// Runs the seed's script fault-free, then again under the seed's schedule,
/// and reports the verdict.
///
/// The two runs use two temporary state roots, so the faulted run's restart
/// rebuilds from its own crash rather than from the fault-free run's files.
///
/// ## Examples
///
/// ```gleam
/// // daemon_runner.run(seed: 12345)
/// ```
pub fn run(seed seed: Int) -> Verdict {
  let #(script, schedule) = plan(seed)
  case execute(seed, script, daemon_fault.none()) {
    Error(failure) -> failed(seed, script, schedule, failure)
    Ok(base) ->
      case execute(seed, script, schedule) {
        Error(failure) -> failed(seed, script, schedule, failure)
        Ok(faulted) ->
          case compare(base, faulted) {
            Ok(Nil) -> Passed
            Error(failure) -> failed(seed, script, schedule, failure)
          }
      }
  }
}

/// Draws the script and the schedule a seed stands for, without running
/// anything. A failing seed prints both, and a test that pins a seed can
/// state what it pinned.
///
/// ## Examples
///
/// ```gleam
/// // let #(script, schedule) = daemon_runner.plan(12345)
/// ```
pub fn plan(seed: Int) -> #(Script, Schedule) {
  let #(scripts, rest) = random.split(random.from_seed(seed))
  let #(schedules, _rest) = random.split(rest)
  let #(script, _) = daemon_script.generate(scripts)
  let #(schedule, _) =
    daemon_fault.generate(schedules, daemon_script.coordinates(script))
  #(script, schedule)
}

/// Runs the seed's script once under the given schedule and reports the
/// durable rows it left behind, or the first named check that failed inside
/// the run.
///
/// A caller that wants the two runs compared wants `run`; this is for a test
/// with something to say about a single run's content.
///
/// ## Examples
///
/// ```gleam
/// // daemon_runner.observe(12345, daemon_fault.none())
/// ```
pub fn observe(seed: Int, schedule: Schedule) -> Result(Report, Failure) {
  let #(script, _) = plan(seed)
  execute(seed, script, schedule)
}

/// A one-line rendering of what a seed stands for.
///
/// ## Examples
///
/// ```gleam
/// // daemon_runner.describe(12345)
/// ```
pub fn describe(seed: Int) -> String {
  let #(script, schedule) = plan(seed)
  daemon_script.describe(script) <> " | " <> daemon_fault.describe(schedule)
}

fn execute(
  seed: Int,
  script: Script,
  schedule: Schedule,
) -> Result(Report, Failure) {
  let clock = vclock.start(from: origin_ms)
  let outcome = drive(state_root(seed), clock, script, schedule)
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

// The shape of a run. A fault-free run is one incarnation; a faulted run is
// two, over the same state root, with the kill between them. Everything after
// the restart is identical in both, which is what makes the comparison a
// statement about the fault rather than about the script.
fn drive(
  state_root: String,
  clock: Clockwork,
  script: Script,
  schedule: Schedule,
) -> Result(Report, Failure) {
  let arrived = process.new_subject()
  use daemon <- result.try(boot(state_root, clock, 0, arrest(schedule, arrived)))
  case schedule.faults {
    [] -> finish(daemon, complete(daemon, script, schedule, []))

    [KillDaemonAt(key:, workspace: _, step:)] ->
      case interrupt(daemon, script, key, step, arrived) {
        Error(failure) -> finish(daemon, Error(failure))
        Ok(observed) -> {
          use restarted <- result.try(resumed(state_root, clock))
          let carried = {
            use Nil <- result.try(recovered(restarted, key, step))
            complete(restarted, script, schedule, observed)
          }
          finish(restarted, carried)
        }
      }

    [_, _, ..] ->
      finish(
        daemon,
        Error(Failure(
          "schedule/one-kill",
          "a daemon schedule carries at most one kill, and this one carries "
            <> int.to_string(list.length(schedule.faults)),
        )),
      )
  }
}

fn boot(
  state_root: String,
  clock: Clockwork,
  incarnation: Int,
  arrest: harness.Arrest,
) -> Result(Harness, Failure) {
  harness.start(harness.Boot(
    state_root:,
    clock:,
    capacity:,
    incarnation:,
    arrest:,
  ))
  |> result.map_error(fn(reason) {
    Failure(
      "harness/start",
      "incarnation " <> int.to_string(incarnation) <> ": " <> reason,
    )
  })
}

// The second incarnation of a faulted run. It goes through `resume` rather
// than `start` because the killed root's launch lock is released by the
// operating system after the process is already gone, so a single start races
// a lock the crash has not finished dropping. A `resume` that runs out of
// patience still reports the refusal it ended on, which fails the run.
fn resumed(state_root: String, clock: Clockwork) -> Result(Harness, Failure) {
  harness.resume(harness.Boot(
    state_root:,
    clock:,
    capacity:,
    incarnation: 1,
    arrest: harness.Unimpeded,
  ))
  |> result.map_error(fn(reason) {
    Failure("harness/start", "incarnation 1: " <> reason)
  })
}

// A daemon that will not retire is a finding, not a footnote: a leaked launch
// lock or a root blocked in recovery is exactly what a faulted run is looking
// for, so a stop failure fails a run that otherwise passed rather than being
// discarded.
fn finish(
  daemon: Harness,
  observed: Result(Report, Failure),
) -> Result(Report, Failure) {
  case harness.stop(daemon), observed {
    Error(reason), Ok(_) -> Error(Failure("harness/stop", reason))
    _stopped, observed -> observed
  }
}

// The arrest the schedule arms before the daemon starts. `AfterConfirm` needs
// none: the run drives to residency on its own and kills a daemon that is
// doing nothing, which is exactly what that step means.
fn arrest(schedule: Schedule, arrived: Subject(Pid)) -> harness.Arrest {
  case schedule.faults {
    [KillDaemonAt(key:, workspace:, step:)] ->
      case step {
        AfterConfirm -> harness.Unimpeded
        AfterReservation ->
          harness.ParkAt(step:, coordinate: workspace, arrived:)
        AfterDomainBind | AfterCustodyPublish ->
          harness.ParkAt(step:, coordinate: key, arrived:)
      }
    [] | [_, _, ..] -> harness.Unimpeded
  }
}

// The first incarnation of a faulted run: create in script order up to the
// killed key, take the run to that key's step, check what may be observed
// while it is stopped there, and kill the daemon. Creations after the killed
// one are left to the second incarnation, because the daemon they would have
// run against is gone.
fn interrupt(
  daemon: Harness,
  script: Script,
  key: String,
  step: Step,
  arrived: Subject(Pid),
) -> Result(List(#(String, Identity)), Failure) {
  let before =
    list.take_while(script.creations, fn(one: Creation) { one.key != key })
  use observed <- result.try(
    list.try_fold(before, [], fn(seen, one) {
      use record <- result.map(created(daemon, one, seen))
      [#(one.key, identity(record)), ..seen]
    }),
  )
  use #(record, parked) <- result.try(reach(
    daemon,
    script,
    key,
    step,
    arrived,
    observed,
  ))
  use Nil <- result.map(unpublished(daemon, record, step))
  harness.kill(daemon, parked:)
  [#(key, identity(record)), ..observed]
}

// Reaching the step, and reporting the builder parked at it so the kill can
// take that process down too. Three of the four steps are inside a builder
// that parks and announces itself, so the run reserves without waiting for a
// residency that will never come. The fourth is after confirmation, which is
// an ordinary completed creation with nobody parked.
fn reach(
  daemon: Harness,
  script: Script,
  key: String,
  step: Step,
  arrived: Subject(Pid),
  observed: List(#(String, Identity)),
) -> Result(#(catalogue.Registration, Option(Pid)), Failure) {
  let assert Ok(target) =
    list.find(script.creations, fn(one: Creation) { one.key == key })
    as "a schedule names a key its script creates"
  case step {
    AfterConfirm ->
      created(daemon, target, observed)
      |> result.map(fn(record) { #(record, None) })
    AfterReservation | AfterDomainBind | AfterCustodyPublish -> {
      use record <- result.try(
        harness.reserve(
          daemon,
          key: target.key,
          workspace: target.workspace,
          name: target.name,
          seed: target.seed,
        )
        |> result.map_error(fn(reason) {
          Failure("creation/accepted", key <> ": " <> reason)
        }),
      )
      case process.receive(arrived, arrival_ms) {
        Ok(builder) -> Ok(#(record, Some(builder)))
        Error(Nil) ->
          Error(Failure(
            "schedule/unreachable",
            "no builder reached the scheduled step for " <> key,
          ))
      }
    }
  }
}

// `publication/before-execute`, observed at the crash point itself. A parked
// builder holds a reservation the registry has not confirmed, so the row must
// still read `Reserved` and no open may answer that the session is resident.
// A creation killed after confirmation is the opposite case and is checked
// for the opposite answer.
fn unpublished(
  daemon: Harness,
  record: catalogue.Registration,
  step: Step,
) -> Result(Nil, Failure) {
  let check = "publication/before-execute"
  use row <- result.try(
    harness.row(daemon, record.id)
    |> result.map_error(fn(reason) { Failure(check, reason) }),
  )
  let admitted = harness.admission(daemon, record.id)
  let resident = case admitted {
    Ok(manager.Resident(_)) -> True
    Ok(_) | Error(_) -> False
  }
  case step, row.state, resident {
    AfterConfirm, "Saved", True -> Ok(Nil)
    AfterConfirm, _, _ ->
      Error(Failure(
        check,
        record.id
          <> " was killed after confirmation but reads "
          <> harness.describe_row(row),
      ))
    _parked, "Reserved", False -> Ok(Nil)
    _parked, _, _ ->
      Error(Failure(
        check,
        record.id
          <> " is parked before confirmation but reads "
          <> harness.describe_row(row)
          <> " and answered "
          <> string.inspect(admitted)
          <> " to an open",
      ))
  }
}

// `publication/before-execute` again, one incarnation later. An interrupted
// reservation owns no slot after the restart, so its durable state is the
// whole answer: the registry must refuse to open it, because opening it would
// let a session run against a row nothing has confirmed.
fn recovered(daemon: Harness, key: String, step: Step) -> Result(Nil, Failure) {
  let check = "publication/before-execute"
  use snapshot <- result.try(
    harness.snapshot(daemon)
    |> result.map_error(fn(reason) { Failure(check, reason) }),
  )
  use row <- result.try(
    case
      list.find(snapshot.rows, fn(row: harness.Row) { row.request_key == key })
    {
      Ok(row) -> Ok(row)
      Error(Nil) ->
        Error(Failure(
          check,
          "the reservation for " <> key <> " did not survive the restart",
        ))
    },
  )
  case step, row.state, harness.admission(daemon, row.id) {
    AfterConfirm, "Saved", _admitted -> Ok(Nil)
    _parked, "Reserved", Error(manager.NotInitialized) -> Ok(Nil)
    _step, _state, admitted ->
      Error(Failure(
        check,
        "after the restart "
          <> key
          <> " reads "
          <> harness.describe_row(row)
          <> " and answered "
          <> string.inspect(admitted)
          <> " to an open",
      ))
  }
}

// Everything the run still owes, performed identically whether or not a kill
// happened: every creation the script names, then every retry, then the three
// end-of-run checks.
fn complete(
  daemon: Harness,
  script: Script,
  schedule: Schedule,
  observed: List(#(String, Identity)),
) -> Result(Report, Failure) {
  use observed <- result.try(
    list.try_fold(script.creations, observed, fn(seen, one) {
      use record <- result.map(created(daemon, one, seen))
      [#(one.key, identity(record)), ..seen]
    }),
  )

  // A retry seeds its generator differently on purpose. The generator must
  // never be consulted, because the key already names a durable reservation,
  // and a registry that minted on every call would answer with a second id.
  use observed <- result.try(
    list.try_fold(
      daemon_script.retries(script, schedule),
      observed,
      fn(seen, key) {
        let assert Ok(one) =
          list.find(script.creations, fn(one: Creation) { one.key == key })
          as "a retry names a key the script creates"
        let retry = daemon_script.Creation(..one, seed: one.seed + 9973)
        use record <- result.map(created(daemon, retry, seen))
        [#(key, identity(record)), ..seen]
      },
    ),
  )
  use Nil <- result.try(one_identity_per_key(observed))
  use snapshot <- result.try(
    harness.snapshot(daemon)
    |> result.map_error(fn(reason) { Failure("catalogue/snapshot", reason) }),
  )
  use Nil <- result.try(published(daemon, snapshot))
  use Nil <- result.map(no_orphan_file(daemon, snapshot))
  snapshot
}

// A refusal is attributed to whichever claim it breaks. The first creation
// under a key can only fail `creation/accepted`, because no identity exists
// yet to be inconsistent with. Every later creation under that key is a
// retry, and a retry the registry refuses has lost the identity the key
// reserved just as surely as one that answers a second id, which is what
// makes the refusal a `creation/one-identity-per-key` failure rather than an
// acceptance failure.
//
// The one refusal that would not belong to that claim is a writer lease the
// previous incarnation left unexpired, and it cannot arrive here. Logical time
// advances by a full lease lifetime per incarnation, so the restarted builder
// finds every lease of the dead incarnation expired and steals it with a
// bumped fence. A restart inside the lease TTL is a different scenario, and
// `harness.Boot`'s documentation says where it is checked.
fn created(
  daemon: Harness,
  one: Creation,
  observed: List(#(String, Identity)),
) -> Result(catalogue.Registration, Failure) {
  let check = case list.key_find(observed, one.key) {
    Ok(_reserved) -> "creation/one-identity-per-key"
    Error(Nil) -> "creation/accepted"
  }
  harness.create(
    daemon,
    key: one.key,
    workspace: one.workspace,
    name: one.name,
    seed: one.seed,
  )
  |> result.map_error(fn(reason) { Failure(check, one.key <> ": " <> reason) })
}

fn identity(record: catalogue.Registration) -> Identity {
  #(record.id, record.path, record.request_key, record.created_at)
}

// `creation/one-identity-per-key`: the whole point of the request key. Every
// observation of one key across the run, on either side of a crash and under
// whatever generator seed, answers the same identity.
//
// The confirmation state is deliberately not part of an `Identity`. A
// reservation observed while its builder still owns the operation reads
// `Reserved` and the same row observed later reads `Saved`; that is the
// reservation making progress, not a second identity.
fn one_identity_per_key(
  observed: List(#(String, Identity)),
) -> Result(Nil, Failure) {
  let check = "creation/one-identity-per-key"
  let keys = list.unique(list.map(observed, fn(seen) { seen.0 }))
  list.try_each(keys, fn(key) {
    let answers =
      list.filter_map(observed, fn(seen) {
        case seen.0 == key {
          True -> Ok(seen.1)
          False -> Error(Nil)
        }
      })
    case list.unique(answers) {
      [_one] -> Ok(Nil)
      several ->
        Error(Failure(
          check,
          "key "
            <> key
            <> " answered "
            <> int.to_string(list.length(several))
            <> " identities: "
            <> string.inspect(several),
        ))
    }
  })
}

// `publication/before-execute`, the durable half. A session that became
// resident published an identity into its own database before the registry
// was allowed to confirm its row, so at the end of the run every confirmed
// row's database carries its own canonical id. A confirmation that overtook
// that write leaves a row nothing in the file agrees with.
fn published(daemon: Harness, snapshot: Snapshot) -> Result(Nil, Failure) {
  let check = "publication/before-execute"
  list.try_each(snapshot.rows, fn(row: harness.Row) {
    let path = absolute(daemon, row.path)
    case row.state, sqlite.identity(path) {
      "Saved", Ok(#(Some(id), _)) if id == row.id -> Ok(Nil)
      _state, read ->
        Error(Failure(
          check,
          row.id
            <> " ended as "
            <> harness.describe_row(row)
            <> " with its database reporting "
            <> string.inspect(read),
        ))
    }
  })
}

// `creation/no-orphan-file`: the two directions of the same claim. No
// confirmed row without its database, and no database without a confirmed row
// naming it. Only conversation databases are counted, because the domain
// services are never opened under this harness and their memory and search
// files therefore do not exist.
fn no_orphan_file(daemon: Harness, snapshot: Snapshot) -> Result(Nil, Failure) {
  let check = "creation/no-orphan-file"
  let expected =
    list.map(snapshot.rows, fn(row: harness.Row) { absolute(daemon, row.path) })
  use Nil <- result.try(
    list.try_each(expected, fn(path) {
      case simplifile.is_file(path) {
        Ok(True) -> Ok(Nil)
        _missing ->
          Error(Failure(check, "confirmed row has no database at " <> path))
      }
    }),
  )
  let directory = harness.sessions_directory(daemon)
  use entries <- result.try(
    simplifile.read_directory(directory)
    |> result.map_error(fn(error) {
      Failure(check, directory <> ": " <> string.inspect(error))
    }),
  )
  let present =
    entries
    |> list.filter(fn(entry) { string.ends_with(entry, ".db") })
    |> list.map(fn(entry) { directory <> "/" <> entry })
  list.try_each(present, fn(path) {
    case list.contains(expected, path) {
      True -> Ok(Nil)
      False -> Error(Failure(check, "no confirmed row names " <> path))
    }
  })
}

// A `Row` carries the state root substituted out, so a check that touches the
// filesystem has to put it back.
fn absolute(daemon: Harness, path: String) -> String {
  string.replace(path, harness.root_marker, harness.state_root(daemon))
}

// `replay/equal-catalogue-rows`: the transparency claim. Both the rows and
// the revision they were read at have to agree; a run that wrote a row twice
// would carry the same rows at a higher fence and would otherwise pass.
fn compare(base: Report, faulted: Report) -> Result(Nil, Failure) {
  let check = "replay/equal-catalogue-rows"
  case base.fence == faulted.fence {
    False ->
      Error(Failure(
        check,
        "catalogue fence "
          <> int.to_string(base.fence)
          <> " on the fault-free run and "
          <> int.to_string(faulted.fence)
          <> " under the schedule",
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
  "fault-free run:\n  "
  <> render(base)
  <> "\nfaulted run:\n  "
  <> render(faulted)
}

fn failed(
  seed: Int,
  script: Script,
  schedule: Schedule,
  failure: Failure,
) -> Verdict {
  Failed(
    seed:,
    failure:,
    reproduce: "daemon_runner.run(seed: " <> int.to_string(seed) <> ")",
    detail: daemon_script.describe(script)
      <> " | "
      <> daemon_fault.describe(schedule),
  )
}
