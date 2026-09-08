//// A daemon assembled for simulation: the real root, the real registry, the
//// real catalogue, and no listener.
////
//// A fault that kills the daemon is a root restart over the same state
//// root, never a registry restart in place: the root answers a killed
//// registry by blocking recovery, so the durable shape (the persisted
//// reservation rebuilt by the next `start`) is the only one a faulted run
//// can take, and the harness accepts a caller-supplied `state_root` for
//// exactly that reason.
////
//// The session runner drives one conversation tree. The claims the daemon
//// owns are about several sessions at once: a creation key that must mint
//// one identity however often it is retried, a workspace whose domain record
//// two sessions share. None of them can be observed from inside a single
//// session, so this module builds the layer above: `client/daemon/root`
//// started against a temporary state root, advanced to `Serving`, and read
//// back through the registry it publishes.
////
//// Three things make that construction possible without a socket. The root
//// starts its listener only when a caller sends `StartListener`, so a root
//// that is never asked for one serves its registry with no network surface
//// at all. Creation takes the id generator from its caller rather than from
//// a global, so the simulation's logical clock and a seed decide every
//// minted session id, and a second run of the same script mints the same
//// ones. And assembly is a record of callbacks the caller supplies, so the
//// harness can perform the production storage acquisition without the
//// runtime, the provider, or the effect plane.
////
//// What the harness does not simulate is the BEAM scheduler. Creation
//// returns while a builder is still working, and `await_resident` waits for
//// the registry to publish it. That wait is real milliseconds, because the
//// registry is a real process; the logical clock governs what is *minted*,
//// which is what a replay has to agree on.
////
//// Every coordinate a caller names here is durable: a creation request key
//// or a canonical session id, never the order in which something happened.
//// `docs/architecture/simulation.md` gives the reason under "Keying, and why
//// it is not a counter".
////
//// This module is test infrastructure, so `let assert` appears in it under
//// the exemption `packages/conformance/CLAUDE.md` records.

import client/daemon/domain as domain_service
import client/daemon/manager
import client/daemon/root
import client/internal/instance_owner as custody
import conformance/simulation/daemon/daemon_fault.{
  type Step, AfterCustodyPublish, AfterDomainBind, AfterReservation,
}
import conformance/simulation/vclock.{type Clockwork}
import core/clock
import core/ids
import gleam/bit_array
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session/session
import storage/access
import storage/catalogue
import storage/domain
import tools/blob
import weft/poll

/// The instance a simulated assembly publishes. The registry only stores it
/// and hands it back, so the canonical session id carries everything the
/// harness needs and nothing the effect plane would have to supply.
pub type Instance =
  String

/// How long a lease taken by a simulated builder runs before it expires.
/// Nothing inside one incarnation advances the logical clock, so a lease is
/// held for the life of that incarnation and this bound is never reached
/// while the daemon is alive.
const lease_ttl_ms = 60_000

/// How far logical time moves between incarnations. It is longer than a lease
/// so the previous incarnation's lease is expired rather than merely stale,
/// which is what lets a restarted builder steal it with a bumped fence
/// instead of refusing its own reservation.
const lease_step_ms = 60_001

/// How long the harness waits for the root to reach `Serving`, and for a
/// created session to become resident. Both are real milliseconds spent
/// waiting on real processes, so they are deadlock backstops rather than
/// part of the simulated schedule.
const settle_ms = 20_000

/// The text substituted for the run's temporary state root, so that two runs
/// under different directories still produce comparable rows.
pub const root_marker = "<state-root>"

/// A serving daemon and the logical clock every identity it mints reads.
pub opaque type Harness {
  Harness(
    root: root.Root(Instance),
    ready: root.Ready(Instance),
    clock: Clockwork,
  )
}

/// Where a simulated builder stops and waits to be killed.
///
/// A fault schedule cannot reach inside `manager` to suspend it, and adding a
/// seam there for a test would put a pause in production code. The assembly
/// callbacks are already caller-supplied, so the harness parks in its own
/// callback instead: the run learns the step was reached, and the daemon dies
/// with exactly that much committed.
pub type Arrest {
  /// No callback pauses; every builder runs to completion.
  Unimpeded

  /// The builder reaching `step` reports its own pid on `arrived` and then
  /// blocks until it is killed. `coordinate` is the workspace for
  /// `AfterReservation`, which is reached inside the domain build and sees no
  /// request key, and the request key for the two later steps.
  ///
  /// The pid is what the report carries because a parked builder has to be
  /// killed by name. It is neither linked to the registry nor able to notice
  /// the registry's death while it is blocked, so nothing else in the daemon's
  /// collapse reaches it.
  ParkAt(step: Step, coordinate: String, arrived: Subject(Pid))
}

/// Everything one daemon incarnation is started from.
///
/// `incarnation` counts restarts over the same `state_root`, and its only
/// effect is on the clock the conversation's writer lease is read against: a
/// killed daemon leaves an unexpired lease in the file it was writing, held
/// by an owner that no longer exists, and a restart that read the same instant
/// would refuse its own reservation with `LeaseHeld` forever. Logical time
/// therefore advances by one lease lifetime per incarnation, which is the only
/// place a crash makes stale-lease recovery observable. The identity generator
/// keeps reading the unadvanced clock, so a restart does not shift the
/// timestamps a later creation mints.
///
/// The advance is deliberate even though `kill` leaves no live lease holder
/// behind. A writer lease is time-based rather than owner-liveness-based, so a
/// restart inside the previous lease's TTL is refused with `LeaseHeld` until it
/// expires however dead the owner is, and whether the dead incarnation's
/// custody got as far as releasing the lease is a race this scenario must not
/// depend on. A restart inside the TTL is therefore out of scope here; the
/// claim about it lives in `daemon_shipped_identity_recovery_test`, which
/// drives a real daemon over a real lease it does not step past.
pub type Boot {
  Boot(
    state_root: String,
    clock: Clockwork,
    capacity: Int,
    incarnation: Int,
    arrest: Arrest,
  )
}

/// One session's durable coordinates, with the temporary state root replaced
/// by `root_marker`. This is the unit two runs of a script are compared on.
pub type Row {
  Row(
    /// The canonical session id, minted from the logical clock and a seed.
    id: String,
    /// The immutable creation request key that reserved this identity.
    request_key: String,
    /// The conversation database path, relative to the state root.
    path: String,
    /// The workspace the owner named at creation.
    workspace: String,
    /// The display label.
    name: String,
    /// Whether initialization has been confirmed.
    state: String,
    /// Creation time in logical Unix milliseconds.
    created_at: Int,
    /// The session's domain record, rendered with its paths relativized.
    domain: String,
  )
}

/// Every registration the catalogue holds, together with the revision it was
/// read at. The revision is the durable fence a page continuation is checked
/// against, and it moves whenever a registration does.
pub type Snapshot {
  Snapshot(fence: Int, rows: List(Row))
}

/// Starts a daemon over `state_root`, which may be relative to the working
/// directory and need not exist. The caller owns the directory afterwards.
///
/// The returned handle is serving: its catalogue is open, its owner identity
/// is established, and its registry is empty because restoration opens no
/// sessions.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(daemon) = harness.start(harness.Boot(root, clock, 4, 0, harness.Unimpeded))
/// ```
pub fn start(boot: Boot) -> Result(Harness, String) {
  let Boot(state_root:, clock: clockwork, capacity:, incarnation:, arrest:) =
    boot
  let config =
    root.Config(state_root:, owner_display_name: "simulation-owner", capacity:)
  let lease_clock =
    clock.fixed(vclock.now(clockwork) + incarnation * lease_step_ms)
  use started <- result.try(root.start(config, assembly(lease_clock, arrest)))

  // Readiness is a query, not a command: a root that refuses still owns
  // whatever it acquired, so the handle is discarded only by `stop`.
  case root.ready(started, within: settle_ms) {
    Ok(ready) -> Ok(Harness(root: started, ready:, clock: clockwork))
    Error(reason) -> {
      let _ = root.shutdown(started, within: settle_ms)
      Error(reason)
    }
  }
}

/// Asks the daemon to retire and waits for its lifetime owner to confirm.
///
/// ## Examples
///
/// ```gleam
/// // harness.stop(daemon)
/// ```
pub fn stop(harness: Harness) -> Result(Nil, String) {
  root.shutdown(harness.root, within: settle_ms)
}

/// Kills the daemon untrappably and waits for every process holding its
/// durable resources to be gone. `parked` is the builder `park` reported, and
/// is `None` for a schedule that parks nobody.
///
/// This is the fault, and it is deliberately not a drain. An orderly `stop`
/// retires the writer lease, closes the catalogue and releases the launch
/// lock; a crashed daemon does none of those, so what the next `start` over
/// the same state root finds is the durable shape a crash leaves behind. The
/// root is unlinked from its caller, so the run driver survives all of this
/// and can perform that restart.
///
/// Killing the root is enough to take the registry down: the lifetime scope
/// is linked to the root, so the root's death cancels the scope, and the
/// registry it owns dies with it. What that cascade does not give is a moment
/// at which the caller knows it has finished, and it does not reach a builder
/// parked in an assembly callback, which is linked to nothing the cascade
/// travels along. This therefore kills the registry and the parked builder by
/// name as well, and waits for a monitor on each. Killing a process the
/// cascade has already taken down costs nothing, because a monitor on a dead
/// pid delivers DOWN immediately, so the order the three die in carries no
/// meaning and the harness does not depend on the cascade's timing. A `start`
/// that overlapped a live predecessor would be measuring the harness rather
/// than the daemon.
///
/// What the session tree does in response is asynchronous and unordered
/// against the restart: it retires the dead lease in its own time. The
/// restart does not wait for that, which is why `Boot.incarnation` moves the
/// lease clock past the dead lease instead.
///
/// Waiting for the monitors says the processes are gone, not that everything
/// they held has been released. The launch lock in particular is released by
/// the operating system when the dead root's port closes, which is not ordered
/// against the monitor, and that is why a restart goes through `resume`.
///
/// ## Examples
///
/// ```gleam
/// // harness.kill(daemon, parked: Some(builder))
/// ```
pub fn kill(harness: Harness, parked parked: Option(Pid)) -> Nil {
  destroy(root.pid(harness.root))
  destroy(manager.pid(harness.ready.registry))
  case parked {
    None -> Nil
    Some(builder) -> destroy(builder)
  }
}

// A kill is untrappable, so the monitor's DOWN reports that the process is
// gone rather than that it chose to acknowledge anything. Monitoring a pid
// that has already died delivers DOWN immediately, so a process that the
// previous kill took down with it costs this nothing and the order the three
// die in carries no meaning.
fn destroy(pid: Pid) -> Nil {
  let monitor = process.monitor(pid)
  process.kill(pid)
  let _ =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_down) { Nil })
    |> process.selector_receive(settle_ms)
  process.demonitor_process(monitor)
}

/// Starts a daemon over a state root a killed daemon has not finished letting
/// go of, retrying until the launch lock is free.
///
/// A killed root's launch lock is released by the operating system when its
/// port closes, and that is not ordered against the monitor `kill` waited on.
/// Starting once would therefore fail on a race that says nothing about the
/// invariant under test. The retry is bounded by the same deadlock backstop
/// the rest of the harness uses, and an expiry is reported as the refusal it
/// ended on rather than swallowed, so a state root that never frees up fails
/// the run.
///
/// ## Examples
///
/// ```gleam
/// // harness.resume(harness.Boot(root, clock, 4, 1, harness.Unimpeded))
/// ```
pub fn resume(boot: Boot) -> Result(Harness, String) {
  let answer =
    poll.until(within: settle_ms, every: 5, attempt: fn() {
      case start(boot) {
        Ok(daemon) -> poll.Done(daemon)
        Error(_busy) -> poll.Retry
      }
    })
  case answer {
    poll.Answered(daemon) -> Ok(daemon)
    poll.Failed(reason) -> Error(reason)

    // The deadline is a backstop, so the attempt that ran out of time is not
    // the one whose reason a reader needs. One more start outside the loop
    // reports what the state root is actually refusing.
    poll.Expired -> start(boot)
  }
}

/// Reserves and initializes a session under `key`, then waits for the
/// registry to publish it.
///
/// `seed` decides the identity only when the key is new. A retry with a key
/// the catalogue already knows resumes the original reservation and ignores
/// the generator entirely, which is the property this harness exists to make
/// observable: pass a different seed on a retry and the same id must come
/// back.
///
/// ## Examples
///
/// ```gleam
/// // harness.create(daemon, "alpha", "/sim/ws-a", "Alpha", seed: 7)
/// ```
pub fn create(
  harness: Harness,
  key key: String,
  workspace workspace: String,
  name name: String,
  seed seed: Int,
) -> Result(catalogue.Registration, String) {
  use record <- result.try(reserve(harness, key:, workspace:, name:, seed:))
  use Nil <- result.map(await_resident(harness, record.id))
  record
}

/// Reserves and starts a creation without waiting for the registry to publish
/// it.
///
/// A run whose schedule parks this creation's builder must not wait for a
/// residency that will never arrive, and it still needs the durable
/// reservation the call committed before the builder started. That is the only
/// difference from `create`.
///
/// ## Examples
///
/// ```gleam
/// // harness.reserve(daemon, key: "alpha", workspace: "/sim/ws-a", name: "Alpha", seed: 7)
/// ```
pub fn reserve(
  harness: Harness,
  key key: String,
  workspace workspace: String,
  name name: String,
  seed seed: Int,
) -> Result(catalogue.Registration, String) {
  let request = manager.Creation(key, workspace, name, "")
  let generator = ids.generator(vclock.clock(harness.clock), seed:)
  manager.create(
    harness.ready.registry,
    request,
    directory: harness.ready.sessions_directory,
    generator:,
  )
  |> result.map_error(describe)
  |> result.map(fn(view: manager.View) { view.registration })
}

/// Asks the registry to admit an explicit open and reports its own answer,
/// refusal included.
///
/// `open` renders a refusal as text, which is what a passing caller wants.
/// A check that has to distinguish "the registry refused an unconfirmed
/// reservation" from "the registry admitted one" needs the refusal itself, so
/// it reads this instead.
///
/// ## Examples
///
/// ```gleam
/// // harness.admission(daemon, id)
/// ```
pub fn admission(
  harness: Harness,
  id id: String,
) -> Result(manager.Status, manager.Error) {
  manager.open(harness.ready.registry, id)
}

/// Requests an explicit open of an already initialized session and reports
/// the lifecycle state the registry answered with.
///
/// ## Examples
///
/// ```gleam
/// // harness.open(daemon, id)
/// ```
pub fn open(harness: Harness, id id: String) -> Result(manager.Status, String) {
  manager.open(harness.ready.registry, id)
  |> result.map_error(describe)
}

/// Reads one session's durable coordinates back through the catalogue,
/// keyed by its canonical id.
///
/// ## Examples
///
/// ```gleam
/// // harness.row(daemon, id)
/// ```
pub fn row(harness: Harness, id id: String) -> Result(Row, String) {
  use view <- result.try(
    manager.get(harness.ready.registry, id) |> result.map_error(describe),
  )
  use selected <- result.map(
    manager.session_domain(harness.ready.registry, id)
    |> result.map_error(describe),
  )
  render(harness, view.registration, selected)
}

/// Reads every registration the catalogue holds, with the revision it was
/// read at, sorted by canonical id so the result does not depend on the
/// order the sessions were created in.
///
/// ## Examples
///
/// ```gleam
/// // harness.snapshot(daemon).rows
/// ```
pub fn snapshot(harness: Harness) -> Result(Snapshot, String) {
  use page <- result.try(
    manager.page(harness.ready.registry, after: "")
    |> result.map_error(describe),
  )
  let #(fence, views) = page
  use rows <- result.map(
    list.try_map(views, fn(view) { row(harness, view.registration.id) }),
  )
  Snapshot(
    fence:,
    rows: list.sort(rows, fn(a, b) { string.compare(a.id, b.id) }),
  )
}

/// The canonical state root this harness acquired, after the daemon
/// resolved and canonicalized the path the caller gave it.
///
/// ## Examples
///
/// ```gleam
/// // harness.state_root(daemon)
/// ```
pub fn state_root(harness: Harness) -> String {
  harness.ready.state_root
}

/// The directory every conversation database this daemon creates lives in.
/// A check for a file with no confirmed row behind it enumerates this.
///
/// ## Examples
///
/// ```gleam
/// // harness.sessions_directory(daemon)
/// ```
pub fn sessions_directory(harness: Harness) -> String {
  harness.ready.sessions_directory
}

// Creation returns as soon as a builder owns the operation, so the durable
// row is still `Reserved` at that point and a read-back would see a session
// that has no database behind it. Waiting for the published incarnation is
// what makes the row the caller then reads the confirmed one.
fn await_resident(harness: Harness, id: String) -> Result(Nil, String) {
  let answer =
    poll.until(within: settle_ms, every: 1, attempt: fn() {
      case manager.get(harness.ready.registry, id) {
        Ok(manager.View(status: manager.Resident(_), ..)) -> poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(describe(error))
      }
    })
  case answer {
    poll.Answered(Nil) -> Ok(Nil)
    poll.Failed(reason) -> Error(reason)
    poll.Expired -> Error("session " <> id <> " never became resident")
  }
}

// Two runs of one script use two temporary directories, so every absolute
// path the daemon derived from its state root differs between them by
// construction. Substituting the root is what leaves a difference in the
// *shape* of a path visible while hiding the difference in its prefix.
fn render(
  harness: Harness,
  record: catalogue.Registration,
  selected: domain.Domain,
) -> Row {
  let relative = fn(path) {
    string.replace(path, harness.ready.state_root, root_marker)
  }
  let rendered =
    string.join(
      [
        selected.id,
        string.inspect(selected.scope),
        selected.workspace,
        selected.configuration,
        relative(selected.memory_path),
        relative(selected.index_path),
      ],
      "|",
    )
  Row(
    id: record.id,
    request_key: record.request_key,
    path: relative(record.path),
    workspace: record.workspace,
    name: record.name,
    state: string.inspect(record.state),
    created_at: record.created_at,
    domain: rendered,
  )
}

// The registry reports refusals as a domain type rather than as text. The
// harness reports them as text because a failing check's job is to name what
// happened, and every caller here already has a `Result(_, String)`.
fn describe(error: manager.Error) -> String {
  "registry refused: " <> string.inspect(error)
}

// The effect plane is out of scope for a daemon script, so no domain service
// is opened and the published instance is the session id. What is *not*
// simplified is the storage sequence: acquiring the writer lease, publishing
// its retirement under custody, and persisting the reserved identity before
// the registry may confirm the reservation. That order is the invariant a
// creation-key claim rests on, so a harness that skipped it would confirm
// rows no production path could have produced.
fn assembly(
  lease_clock: clock.Clock,
  arrest: Arrest,
) -> manager.Assembly(Instance) {
  manager.Assembly(
    domain_build: fn(selected: domain.Domain, _, _) {
      park(arrest, AfterReservation, selected.workspace)
      Ok(domain_service.inert())
    },
    build: fn(record: catalogue.Registration, _, _, owner) {
      park(arrest, AfterDomainBind, record.request_key)
      initialize(record, owner, lease_clock, arrest)
    },
    fatal: fn(_) { [] },
  )
}

fn initialize(
  record: catalogue.Registration,
  owner: custody.Owner,
  lease_clock: clock.Clock,
  arrest: Arrest,
) -> Result(Instance, String) {
  let assert Ok(#(opened, retire, transfer)) =
    session.open_sqlite_custody(
      path: record.path,
      owner: "simulation-writer-" <> record.id,
      lease_ttl_ms:,
      clock: lease_clock,
    )
    as "one simulated builder acquires the real writer lease"

  // Custody is published before the identity is written, so a builder that
  // dies between the two still leaves a retirable connection behind rather
  // than an orphaned lease no owner will release.
  let assert Ok(Nil) =
    custody.publish(owner, custody.Storage, fn() {
      retire() |> result.map_error(string.inspect)
    })
    as "the simulated builder publishes its storage retirement"
  let assert Ok(_) = transfer()
    as "published custody owns storage independently of its builder"

  // The interesting crash point: a database file exists, a live lease is
  // recorded in it, and the reservation it belongs to is still unconfirmed.
  park(arrest, AfterCustodyPublish, record.request_key)
  let assert Ok(id) = ids.parse_session_id(record.id)
    as "the catalogue reservation supplies a canonical identity"
  let assert Ok(_) = session.ensure_reserved_id(opened, id)
    as "the conversation persists that identity before confirmation"
  Ok(record.id)
}

// A parked builder never returns. It announces its own pid, so that the kill
// can reach a process no link and no readable monitor would take down, and
// then waits out the deadline. The deadline is a backstop for a schedule whose
// kill never arrives, which would otherwise hang the suite.
fn park(arrest: Arrest, step: Step, coordinate: String) -> Nil {
  case arrest {
    Unimpeded -> Nil
    ParkAt(step: on, coordinate: at, arrived:) ->
      case on == step && at == coordinate {
        False -> Nil
        True -> {
          process.send(arrived, process.self())
          let _ = process.receive(process.new_subject(), settle_ms)
          Nil
        }
      }
  }
}

/// Renders a row as one line, for a failure that has to say which of two
/// snapshots disagreed and where.
///
/// ## Examples
///
/// ```gleam
/// // harness.describe_row(row)
/// ```
pub fn describe_row(row: Row) -> String {
  string.join(
    [
      row.id,
      row.request_key,
      row.path,
      row.workspace,
      row.name,
      row.state,
      int.to_string(row.created_at),
      row.domain,
    ],
    "|",
  )
}

/// The registry this daemon publishes, for a check that drives the manager's
/// own admission and administration surface rather than the harness's
/// convenience wrappers.
///
/// ## Examples
///
/// ```gleam
/// // manager.session_authority(harness.registry(daemon), digest, id)
/// ```
pub fn registry(harness: Harness) -> manager.Manager(Instance) {
  harness.ready.registry
}

/// The random identity of this daemon lifetime. Every authority question the
/// manager answers is fenced on it, and a restart mints a new one, so a check
/// that reuses a previous lifetime's epoch is asking about a daemon that no
/// longer exists.
///
/// ## Examples
///
/// ```gleam
/// // harness.epoch(daemon)
/// ```
pub fn epoch(harness: Harness) -> String {
  harness.ready.epoch
}

/// The digest of the durable owner credential, which is what every
/// administration is authorized against.
///
/// The credential itself leaves the root through one door only, and this is
/// the only reason the harness opens it: an invitation and a revocation are
/// owner-only mutations, so a revocation check cannot be written without it.
///
/// The digest is the lowercase hex SHA-256 of the credential, which is what
/// the root itself stored when it bootstrapped the owner. The hash comes from
/// `tools/blob`, whose content address is that same construction behind a
/// prefix, because the daemon's own hashing lives in `host` and this package
/// does not depend on it. A harness that hashed differently would authenticate
/// as nobody and every administration would refuse.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(owner) = harness.owner_digest(daemon)
/// ```
pub fn owner_digest(harness: Harness) -> Result(access.Digest, String) {
  use credential <- result.try(root.listener_credential(harness.root))
  let hashed =
    string.drop_start(blob.ref_for(bit_array.from_string(credential)), 7)
  access.credential_digest(hashed)
  |> result.replace_error("the durable owner credential is not a digest")
}

/// Reserves and initializes a session whose aggregate is scoped to itself,
/// then waits for the registry to publish it.
///
/// A workspace-private session refuses invitation outright, because sharing a
/// workspace aggregate needs an explicit stopped isolation first. A check
/// about the admission boundary is not a check about that refusal, so it
/// creates its session already isolated and reaches the boundary directly.
///
/// ## Examples
///
/// ```gleam
/// // harness.create_isolated(daemon, "shared", "/sim/ws-a", "Shared", seed: 3)
/// ```
pub fn create_isolated(
  harness: Harness,
  key key: String,
  workspace workspace: String,
  name name: String,
  seed seed: Int,
) -> Result(catalogue.Registration, String) {
  let request = manager.Creation(key, workspace, name, "")
  let generator = ids.generator(vclock.clock(harness.clock), seed:)
  let outcome =
    manager.create_scoped(
      harness.ready.registry,
      request,
      directory: harness.ready.sessions_directory,
      generator:,
      scope: domain.SessionOnly,
      configuration: "",
    )
  use view <- result.try(result.map_error(outcome, describe))
  use Nil <- result.map(await_resident(harness, view.registration.id))
  view.registration
}

/// Reads one session's live lifecycle status without waiting for it to
/// settle.
///
/// ## Examples
///
/// ```gleam
/// // harness.status(daemon, id)
/// ```
pub fn status(
  harness: Harness,
  id id: String,
) -> Result(manager.Status, String) {
  manager.get(harness.ready.registry, id)
  |> result.map(fn(view: manager.View) { view.status })
  |> result.map_error(describe)
}
