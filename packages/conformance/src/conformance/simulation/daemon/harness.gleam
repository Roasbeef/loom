//// A daemon assembled for simulation: the real root, the real registry, the
//// real catalogue, and no listener.
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
import conformance/simulation/vclock.{type Clockwork}
import core/ids
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import session/session
import storage/catalogue
import storage/domain
import weft/poll

/// The instance a simulated assembly publishes. The registry only stores it
/// and hands it back, so the canonical session id carries everything the
/// harness needs and nothing the effect plane would have to supply.
pub type Instance =
  String

/// How long a lease taken by a simulated builder runs before it expires.
/// Nothing in this harness advances the logical clock, so the lease is held
/// for the life of the run and this bound is never reached.
const lease_ttl_ms = 60_000

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
/// // let assert Ok(daemon) = harness.start("build/test_db/sim-1", clock, 4)
/// ```
pub fn start(
  state_root state_root: String,
  clock clock: Clockwork,
  capacity capacity: Int,
) -> Result(Harness, String) {
  let config =
    root.Config(state_root:, owner_display_name: "simulation-owner", capacity:)
  use started <- result.try(root.start(config, assembly(clock)))

  // Readiness is a query, not a command: a root that refuses still owns
  // whatever it acquired, so the handle is discarded only by `stop`.
  case root.ready(started, within: settle_ms) {
    Ok(ready) -> Ok(Harness(root: started, ready:, clock:))
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
  let request = manager.Creation(key, workspace, name, "")
  let generator = ids.generator(vclock.clock(harness.clock), seed:)
  let outcome =
    manager.create(
      harness.ready.registry,
      request,
      directory: harness.ready.sessions_directory,
      generator:,
    )
  use view <- result.try(result.map_error(outcome, describe))
  use Nil <- result.map(await_resident(harness, view.registration.id))
  view.registration
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
fn assembly(clock: Clockwork) -> manager.Assembly(Instance) {
  manager.Assembly(
    domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
    build: fn(record, _, _, owner) { initialize(record, owner, clock) },
    fatal: fn(_) { [] },
  )
}

fn initialize(
  record: catalogue.Registration,
  owner: custody.Owner,
  clock: Clockwork,
) -> Result(Instance, String) {
  let assert Ok(#(opened, retire, transfer)) =
    session.open_sqlite_custody(
      path: record.path,
      owner: "simulation-writer-" <> record.id,
      lease_ttl_ms:,
      clock: vclock.clock(clock),
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
  let assert Ok(id) = ids.parse_session_id(record.id)
    as "the catalogue reservation supplies a canonical identity"
  let assert Ok(_) = session.ensure_reserved_id(opened, id)
    as "the conversation persists that identity before confirmation"
  Ok(record.id)
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
