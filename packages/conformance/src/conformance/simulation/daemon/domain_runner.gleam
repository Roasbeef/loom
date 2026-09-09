//// Seeded opens on both sides of a workspace domain's normal retirement.
////
//// The real daemon root, catalogue and custody owners run under the existing
//// harness. A cleanup callback holds the original domain after its last
//// session reaches Saved. The delayed run must acknowledge Opening during
//// that hold, preserve the operation across retries, and build replacement
//// services only after cleanup is released. The baseline waits for domain
//// retirement before opening. Both must leave identical durable rows and
//// catalogue revisions after their sessions retire again.
////
//// The seed chooses which saved session reopens and how many duplicate opens
//// arrive. The cleanup coordinate is the workspace's first retirement, not
//// a message count. Real waits are finite deadlock backstops; this runner
//// controls release order, not the BEAM scheduler or kernel enforcement.

import broker/token
import client/daemon/manager
import conformance/simulation/control
import conformance/simulation/daemon/harness
import conformance/simulation/runner.{type Failure, Failure}
import conformance/simulation/vclock
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import weft/poll

/// Which saved identity a seed reopens after the workspace becomes idle.
pub type Target {
  /// Reopen the session whose final retirement started domain cleanup.
  LastSession

  /// Open the peer that retired while the last session remained resident.
  SavedPeer
}

/// The finite workload drawn from a seed, shared by the baseline and delay.
pub type Script {
  Script(
    /// Which canonical session receives the explicit open.
    target: Target,
    /// How many duplicates must recover that accepted operation.
    retries: Int,
  )
}

/// Where the explicit open lands relative to the original domain retirement.
pub type Schedule {
  /// Domain retirement completes before the open is submitted.
  AfterRetirement

  /// Cleanup remains held until the open and its duplicates are acknowledged.
  DuringRetirement
}

type Barrier {
  Barrier(control: control.Control, arrived: Subject(Subject(Nil)))
}

const workspace = "/simulation/domain-retirement"

const origin_ms = 1_700_000_000_000

const settle_ms = 20_000

const retirement_key = "retire-domain@/simulation/domain-retirement"

const release_key = "release-domain@/simulation/domain-retirement"

const held_key = "held-domain@/simulation/domain-retirement"

const released_key = "released-domain@/simulation/domain-retirement"

const builds_key = "build-domain@/simulation/domain-retirement"

const overlap_key = "overlapping-domain@/simulation/domain-retirement"

/// Draws the target and one or two retry calls without coupling either draw.
///
/// ## Examples
///
/// ```gleam
/// domain_runner.plan(0) == Script(LastSession, 1)
/// ```
pub fn plan(seed: Int) -> Script {
  let target = case int.bitwise_and(seed, 1) {
    0 -> LastSession
    _ -> SavedPeer
  }
  Script(
    target:,
    retries: 1 + int.bitwise_and(int.bitwise_shift_right(seed, 1), 1),
  )
}

/// Runs a baseline and a held-retirement schedule and compares durable state.
///
/// ## Examples
///
/// ```gleam
/// // domain_runner.run(seed: 20_260_912)
/// ```
pub fn run(seed seed: Int) -> Result(Nil, Failure) {
  use baseline <- result.try(observe(seed, AfterRetirement))
  use delayed <- result.try(observe(seed, DuringRetirement))
  require(
    fn() { baseline == delayed },
    "domain/converges-with-baseline",
    "baseline "
      <> string.inspect(baseline)
      <> "; delayed "
      <> string.inspect(delayed),
  )
}

/// Drives one schedule and reports the catalogue only after complete cleanup.
///
/// ## Examples
///
/// ```gleam
/// // domain_runner.observe(7, DuringRetirement)
/// ```
pub fn observe(
  seed: Int,
  schedule: Schedule,
) -> Result(harness.Snapshot, Failure) {
  let clock = vclock.start(from: origin_ms)
  let barrier = Barrier(control.start(), process.new_subject())
  let suffix = bit_array.base16_encode(token.production_entropy()(8))
  let path =
    "build/test_db/domain-retirement-" <> int.to_string(seed) <> "-" <> suffix

  // The clock and barrier outlive the daemon so every outcome can release
  // held custody before stopping those two simulation services.
  let started =
    harness.start(harness.Boot(
      state_root: path,
      clock:,
      capacity: 2,
      incarnation: 0,
      arrest: harness.HoldDomainRetirement(
        workspace,
        cleanup(barrier),
        built(barrier),
      ),
    ))
  let outcome = case started {
    Error(reason) -> Error(Failure("domain/start", reason))
    Ok(daemon) -> {
      let observed = body(daemon, barrier, seed, schedule)

      // Disarm a hold not reached by an early failure, or release the one
      // already waiting. Cleanup runs even when admission is the failed check.
      let released = release(barrier)
      let stopped = harness.stop(daemon)
      case released, stopped, observed {
        Error(reason), _, _ -> Error(Failure("domain/release", reason))
        Ok(Nil), Error(reason), _ -> Error(Failure("domain/stop", reason))
        Ok(Nil), Ok(Nil), observed -> observed
      }
    }
  }
  control.stop(barrier.control)
  vclock.stop(clock)
  outcome
}

// One claim chooses the named first retirement. Later replacement cleanup is
// ordinary cleanup, so finalization never needs an unbounded release loop.
fn cleanup(barrier: Barrier) -> fn() -> Result(Nil, String) {
  fn() {
    case control.claim(barrier.control, retirement_key) {
      False -> Ok(Nil)
      True -> {
        let reply = process.new_subject()
        process.send(barrier.arrived, reply)
        let _ = control.bump(barrier.control, held_key)
        use Nil <- result.try(
          process.receive(reply, settle_ms)
          |> result.map_error(fn(_) {
            "[timing] domain cleanup release expired"
          }),
        )
        let _ = control.bump(barrier.control, released_key)
        Ok(Nil)
      }
    }
  }
}

// This records an overlap at the actual build boundary, so the final check
// cannot miss a premature build that happened between two registry reads.
fn built(barrier: Barrier) -> fn() -> Nil {
  fn() {
    // Capture release before publishing the build observation. Reading it
    // afterwards could let an intervening release hide a premature build.
    let released = control.read(barrier.control, released_key)
    let count = control.bump(barrier.control, builds_key)
    case count > 1 && released == 0 {
      True -> {
        let _ = control.bump(barrier.control, overlap_key)
        Nil
      }
      False -> Nil
    }
  }
}

// Taking retirement_key first disarms cleanup if an earlier setup step failed.
// If cleanup already owns that key, it must publish exactly one release subject.
// release_key makes the normal path and the unconditional finalizer idempotent.
fn release(barrier: Barrier) -> Result(Nil, String) {
  case control.claim(barrier.control, release_key) {
    False -> Ok(Nil)
    True ->
      case control.claim(barrier.control, retirement_key) {
        True -> Ok(Nil)
        False -> {
          use reply <- result.try(
            process.receive(barrier.arrived, settle_ms)
            |> result.map_error(fn(_) {
              "[timing] held domain was never reported"
            }),
          )
          process.send(reply, Nil)
          Ok(Nil)
        }
      }
  }
}

fn body(
  daemon: harness.Harness,
  barrier: Barrier,
  seed: Int,
  schedule: Schedule,
) {
  let script = plan(seed)
  use last <- result.try(created(daemon, "last", seed))
  use peer <- result.try(created(daemon, "peer", seed + 1))
  use Nil <- result.try(stop_saved(daemon, peer.id))
  use Nil <- result.try(stop_saved(daemon, last.id))
  use Nil <- result.try(
    await("domain/cleanup-held", fn() {
      Ok(control.read(barrier.control, held_key) == 1)
    }),
  )
  let id = case script.target {
    LastSession -> last.id
    SavedPeer -> peer.id
  }

  // Only the baseline may poll the domain census before admission. The delayed
  // schedule submits its open while the original cleanup callback is held.
  use Nil <- result.try(before_open(daemon, barrier, schedule))
  use operation <- result.try(opened(daemon, id))
  use Nil <- result.try(retries(daemon, id, operation, script.retries))
  use Nil <- result.try(waiting(daemon, barrier, id, operation, schedule))
  use Nil <- result.try(
    release(barrier) |> result.map_error(Failure("domain/release", _)),
  )
  use Nil <- result.try(
    await("domain/resident", fn() {
      harness.status(daemon, id)
      |> result.map(fn(status) { status == manager.Resident(operation) })
    }),
  )

  // A held callback cannot be mistaken for a zero-length closing interval:
  // replacement count and the permanent overlap record cover its full lifetime.
  use Nil <- result.try(require(
    fn() {
      control.read(barrier.control, builds_key) == 2
      && control.read(barrier.control, overlap_key) == 0
    },
    "domain/no-overlapping-cleanup",
    "replacement was missing, duplicated, or started before cleanup release",
  ))
  use Nil <- result.try(stop_saved(daemon, id))
  use Nil <- result.try(empty(daemon))
  harness.snapshot(daemon) |> result.map_error(Failure("domain/snapshot", _))
}

fn created(daemon: harness.Harness, key: String, seed: Int) {
  harness.create(daemon, key:, workspace:, name: key, seed:)
  |> result.map_error(Failure("domain/create", _))
}

fn stop_saved(daemon: harness.Harness, id: String) {
  use _ <- result.try(
    manager.stop_session(harness.registry(daemon), id)
    |> result.map_error(fn(error) {
      Failure("domain/stop-session", string.inspect(error))
    }),
  )
  await("domain/saved", fn() {
    harness.status(daemon, id)
    |> result.map(fn(status) { status == manager.Saved })
  })
}

fn before_open(daemon, barrier, schedule) {
  case schedule {
    DuringRetirement -> Ok(Nil)
    AfterRetirement -> {
      use Nil <- result.try(
        release(barrier) |> result.map_error(Failure("domain/release", _)),
      )
      empty(daemon)
    }
  }
}

fn opened(daemon, id) {
  case harness.admission(daemon, id) {
    Ok(manager.Opening(operation)) -> Ok(operation)
    answer ->
      Error(Failure(
        "domain/admission",
        "expected Opening, received " <> string.inspect(answer),
      ))
  }
}

fn retries(daemon, id, operation, remaining) {
  list.try_each(list.repeat(Nil, remaining), fn(_) {
    let answer = harness.admission(daemon, id)
    require(
      fn() {
        answer == Ok(manager.Opening(operation))
        || answer == Ok(manager.Resident(operation))
      },
      "domain/same-operation",
      "duplicate open changed the operation: " <> string.inspect(answer),
    )
  })
}

fn waiting(
  daemon: harness.Harness,
  barrier: Barrier,
  id: String,
  operation: String,
  schedule: Schedule,
) {
  case schedule {
    AfterRetirement -> Ok(Nil)
    DuringRetirement -> {
      use status <- result.try(
        harness.status(daemon, id)
        |> result.map_error(Failure("domain/status", _)),
      )
      use summary <- result.try(
        manager.summary(harness.registry(daemon))
        |> result.map_error(fn(error) {
          Failure("domain/census", string.inspect(error))
        }),
      )
      require(
        fn() {
          status == manager.Opening(operation)
          && summary.occupied == 1
          && summary.domain_occupied == 1
          && control.read(barrier.control, builds_key) == 1
        },
        "domain/waits-for-cleanup",
        "accepted open must stay parked and consume one session and one domain reservation",
      )
    }
  }
}

fn empty(daemon) {
  await("domain/retirement", fn() {
    manager.summary(harness.registry(daemon))
    |> result.map_error(string.inspect)
    |> result.map(fn(summary) {
      summary.occupied == 0 && summary.domain_occupied == 0
    })
  })
}

// These are observation backstops over real actors, not simulated deadlines.
fn await(check: String, observe: fn() -> Result(Bool, String)) {
  case
    poll.until(within: settle_ms, every: 1, attempt: fn() {
      case observe() {
        Ok(True) -> poll.Done(Nil)
        Ok(False) -> poll.Retry
        Error(reason) -> poll.Fail(reason)
      }
    })
  {
    poll.Answered(Nil) -> Ok(Nil)
    poll.Failed(reason) -> Error(Failure(check, reason))
    poll.Expired -> Error(Failure(check, "[timing] observation expired"))
  }
}

fn require(
  holds: fn() -> Bool,
  check: String,
  detail: String,
) -> Result(Nil, Failure) {
  case holds() {
    True -> Ok(Nil)
    False -> Error(Failure(check, detail))
  }
}
