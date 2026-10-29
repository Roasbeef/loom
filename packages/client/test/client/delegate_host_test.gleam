//// Finding the delegate session a subagent message is for
//// (protocol-change/084, slice S2): the registration a first message makes, the
//// cap on a spawner's sessions, and what a session that cannot open answers.
////
//// The registry is the real one over a real catalogue. Only the assembly is a
//// fake, and the instance it publishes is the delegate endpoint itself, which
//// tags each answer with the session that gave it so a test can tell which
//// session a message reached.

import client/agency
import client/daemon/domain as domain_service
import client/daemon/main as daemon_main
import client/daemon/manager
import client/delegate_host
import client/internal/ffi_os
import client/internal/instance_owner as custody
import client/peer_outbox_drain
import client/remote_child
import client/remote_escalation
import client/remote_reach
import client/remote_release
import client/remote_spawn.{Parent}
import client/spawners
import core/clock
import core/ids
import core/json
import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import simplifile
import sqlight
import storage/catalogue
import storage/domain
import support/fake_orchestrators
import support/remote_stubs
import telemetry/log
import tools/agent
import weft
import weft/poll

fn configuration(placement: String) -> String {
  "[distribution]
node = \"box@100.64.0.9\"
ca = \"/etc/loom/ca.pem\"
certificate = \"/etc/loom/cert.pem\"
key = \"/etc/loom/key.pem\"
cookie = \"/home/loom/.erlang.cookie\"

[[distribution.peers]]
node = \"laptop@100.64.0.5\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000001\"

[[distribution.peers]]
node = \"runner@100.64.0.7\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000003\"

[executors.runner]
node = \"runner@100.64.0.7\"

[pools.linux]
executors = [\"runner\"]

[profiles.cheap-review.roles]
main = [\"fast\"]

[spawners.laptop]
node = \"laptop@100.64.0.5\"
profile = \"cheap-review\"
max_sessions = 2
max_within_s = 7200
default_within_s = 900
tools = [\"bash\", \"agent_note\"]
" <> placement
}

fn spawner(placement: String) -> spawners.Spawner {
  let assert Ok([laptop]) = spawners.parse(configuration(placement))
    as "the configuration must parse"
  laptop
}

// The endpoint a resident session publishes, which answers a run end with the
// number of its session in the registry, so a test can tell sessions apart.
fn tagged(tag: Int) -> agency.DelegateEndpoint {
  tagged_with(tag, agency.Vacant)
}

// The same, answering the sweep's question about children with `occupancy`.
fn tagged_with(
  tag: Int,
  occupancy: agency.Occupancy,
) -> agency.DelegateEndpoint {
  agency.DelegateEndpoint(
    spawn: fn(_delegation, _site, _request) {
      Error(remote_spawn.StoreFailure(reason: "tag " <> int.to_string(tag)))
    },
    join: fn(_parent, _handles, _within_ms) { Ok([]) },
    run_ended: fn(_operation) { Ok(tag) },
    release: fn() { Ok(tag) },
    send: fn(_parent, _child, _message_id, _text) { Ok(json.Null) },
    history: fn(_parent, _child, _cursor, _limit) { Ok(json.Null) },
    occupancy: fn() { occupancy },
    resolve: fn(_parent, _child, _id, _decision, _seq, _decider) {
      Error(remote_spawn.StoreFailure(reason: "not under test"))
    },
  )
}

// A sweep whose spawner keeps a session for `retain_ms` and closes it when idle
// for `idle_close_ms`.
fn sweeping(
  retain_ms: Int,
  idle_close_ms: Int,
) -> manager.Sweep(agency.DelegateEndpoint) {
  manager.Sweep(
    standing: fn(_) { spawners.Configured(retain_ms:, idle_close_ms:) },
    activity: activity_of,
  )
}

// A sweep for which the spawner's table has been removed.
fn removed() -> manager.Sweep(agency.DelegateEndpoint) {
  manager.Sweep(standing: fn(_) { spawners.Removed }, activity: activity_of)
}

// The sweep's question, answered by the tagged endpoint.
fn activity_of(endpoint: agency.DelegateEndpoint) -> manager.Activity {
  case endpoint.occupancy() {
    agency.Vacant -> manager.Quiet
    agency.Occupied -> manager.Busy
  }
}

// Whether the registry holds the session open.
fn is_resident(
  registry: manager.Manager(agency.DelegateEndpoint),
  id: String,
) -> Bool {
  case manager.get(registry, id) {
    Ok(manager.View(status: manager.Resident(_), ..)) -> True
    _ -> False
  }
}

fn context(
  registry: manager.Manager(agency.DelegateEndpoint),
  directory: String,
) -> delegate_host.Context(agency.DelegateEndpoint) {
  context_at(registry, directory, 4242)
}

// The same, with the time a message is recorded as arriving, which becomes the
// pair's last contact.
fn context_at(
  registry: manager.Manager(agency.DelegateEndpoint),
  directory: String,
  now_ms: Int,
) -> delegate_host.Context(agency.DelegateEndpoint) {
  delegate_host.Context(
    registry:,
    sessions_directory: directory,
    domain_configuration: "",
    generator: fn() {
      ids.generator(
        clock.fixed(at: 1_700_000_000_000),
        ffi_os.unique_positive_integer(),
      )
    },
    now_ms: fn() { now_ms },
    endpoint: fn(instance) { instance },
  )
}

// A registry whose sessions open into a tagged endpoint, the tag being a number
// minted for each build, so a test can tell which session answered. `build` may
// refuse, to model a session that cannot open.
fn started(
  store: catalogue.Catalogue,
  build: fn(Int) -> Result(agency.DelegateEndpoint, String),
) -> manager.Manager(agency.DelegateEndpoint) {
  let assert Ok(registry) =
    manager.start(
      store,
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(_record, _domain, _services, _owner, _registry) {
          build(ffi_os.unique_positive_integer())
        },
        drain: fn(_, _) { Nil },
        fatal: fn(_) { [] },
      ),
      epoch: "delegate-host-test",
      limit: 4,
    )
    as "the registry starts"
  registry
}

// The registry is joined before its catalogue is closed, because a session that
// is still retiring reads the catalogue.
fn stop(registry: manager.Manager(instance)) -> Nil {
  let watch = process.monitor(manager.pid(registry))
  manager.shutdown(registry)
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(2000)
    as "shutdown joins all successful custody scopes"
  Nil
}

// The tag a resident session's endpoint answers a run end with.
fn tag_of(endpoint: agency.DelegateEndpoint) -> Int {
  let assert Ok(tag) = endpoint.run_ended(operation())
  tag
}

fn operation() -> ids.OpId {
  let #(operation, _) = ids.mint_op(ids.generator(clock.fixed(at: 5), seed: 9))
  operation
}

fn scratch(label: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the working directory is known"
  let directory =
    here
    <> "/build/test_db/delegate-host-"
    <> label
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())

  // The counter restarts with every VM, so a later run lands on the same name
  // and would open the earlier run's catalogue, damaged rows and all.
  let _ = simplifile.delete(directory)
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "the scratch directory is made"
  directory
}

fn parent(seed: Int) -> remote_spawn.Parent {
  let #(id, _) =
    ids.mint_session(ids.generator(clock.fixed(at: 1_700_000_000_000), seed:))
  Parent(session: ids.session_id_to_string(id), strand: "main")
}

pub fn the_terms_are_the_spawners_figures_in_milliseconds_test() {
  let laptop = spawner("directory = \"/srv/loom/scratch\"\n")
  assert delegate_host.terms_of(laptop)
    == remote_spawn.Terms(
      ceiling: ["bash", "agent_note"],
      max_depth: 1,
      max_within_ms: 7_200_000,
      default_within_ms: 900_000,
    )
}

pub fn an_executor_placement_creates_a_session_on_that_executor_test() {
  let laptop = spawner("executor = \"runner\"\nworkspace = \"loom\"\n")
  let remote = parent(1)
  let assert Ok(made) = delegate_host.creation(laptop, remote)
  assert made.request_key == "delegate:laptop:" <> remote.session
  assert made.executor == "runner"
  assert made.pool == ""
  assert made.workspace == "loom"
  assert made.profile == Some("cheap-review")
  assert made.model == None
  assert made.configuration == ""
}

pub fn a_pool_placement_creates_a_session_in_that_pool_test() {
  let laptop = spawner("pool = \"linux\"\nworkspace = \"loom\"\n")
  let assert Ok(made) = delegate_host.creation(laptop, parent(2))
  assert made.pool == "linux"
  assert made.executor == ""
  assert made.workspace == "loom"
}

pub fn a_directory_placement_names_the_canonical_directory_test() {
  let directory = scratch("canonical")
  let laptop = spawner("directory = \"" <> directory <> "\"\n")
  let assert Ok(made) = delegate_host.creation(laptop, parent(3))
  let assert Ok(canonical) = bootstrap.canonical_directory(directory)
  assert made.workspace == canonical
  assert made.executor == ""
  assert made.pool == ""

  // A directory that is not there is a refusal and not a crash.
  let missing = spawner("directory = \"/no/such/directory/anywhere\"\n")
  assert delegate_host.creation(missing, parent(3))
    == Error(remote_spawn.StoreFailure(
      reason: "the spawner's directory is unusable",
    ))
  let _removed = simplifile.delete_all([directory])
  Nil
}

pub fn the_first_message_for_a_pair_creates_its_session_and_a_return_finds_it_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let registry = started(store, fn(built) { Ok(tagged(built)) })
  let resolve =
    delegate_host.resolver(context(registry, "/delegate-host/sessions"))
  let laptop = spawner("executor = \"runner\"\nworkspace = \"loom\"\n")
  let remote = parent(10)

  // The first message creates the session with the spawner's placement and
  // profile and the session-only memory domain, and answers the Agency of the
  // session it opened.
  let assert Ok(first) = resolve(laptop, remote)
  let assert Ok(option.Some(recorded)) =
    catalogue.delegate_for(store, "laptop", remote.session)
  assert recorded.last_contact_ms == 4242
  let assert Ok(view) = manager.get(registry, recorded.session_id)
  assert view.registration.executor == "runner"
  assert view.registration.profile == Some("cheap-review")
  let assert Ok(selected) =
    manager.session_domain(registry, recorded.session_id)
  assert selected.scope == domain.SessionOnly

  // A second message for the pair reaches the same session and builds nothing.
  let assert Ok(again) = resolve(laptop, remote)
  assert tag_of(again) == tag_of(first)
  assert catalogue.delegates_held(store, "laptop") == Ok(1)

  // Another parent session gets a session of its own.
  let assert Ok(other) = resolve(laptop, parent(11))
  assert tag_of(other) != tag_of(first)
  assert catalogue.delegates_held(store, "laptop") == Ok(2)
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_spawner_is_refused_a_session_past_its_cap_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let registry = started(store, fn(built) { Ok(tagged(built)) })
  let resolve =
    delegate_host.resolver(context(registry, "/delegate-host/sessions"))
  let laptop = spawner("executor = \"runner\"\nworkspace = \"loom\"\n")
  let assert Ok(_) = resolve(laptop, parent(20))
  let assert Ok(_) = resolve(laptop, parent(21))

  // The third parent meets `max_sessions = 2`, and the refusal names the cap.
  // The parents that have sessions still reach them.
  let assert Error(refusal) = resolve(laptop, parent(22))
  assert refusal
    == remote_spawn.CapReached(cap: remote_spawn.MaxSessions, limit: 2)
  let assert Ok(_) = resolve(laptop, parent(20))
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_parent_that_is_not_a_session_identity_is_an_invalid_argument_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let registry = started(store, fn(built) { Ok(tagged(built)) })
  let resolve =
    delegate_host.resolver(context(registry, "/delegate-host/sessions"))
  let laptop = spawner("executor = \"runner\"\nworkspace = \"loom\"\n")
  assert resolve(laptop, Parent(session: "s1", strand: "main"))
    == Error(remote_spawn.InvalidArgument(
      reason: "the parent session is not a session identity",
    ))
  assert catalogue.delegates_held(store, "laptop") == Ok(0)

  // Nothing was created for the malformed pair, under the key it would have had.
  assert catalogue.by_request_key(store, "delegate:laptop:s1")
    == Error(catalogue.Missing)
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_session_that_cannot_open_ends_the_wait_with_a_refusal_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let registry = started(store, fn(_built) { Error("no executor answered") })
  let resolve =
    delegate_host.resolver(context(registry, "/delegate-host/sessions"))
  let laptop = spawner("executor = \"runner\"\nworkspace = \"loom\"\n")
  let remote = parent(30)
  let here = context(registry, "/delegate-host/sessions")
  let assert Ok(made) = delegate_host.creation(laptop, remote)
    as "the initial creation names its placement"
  let assert Ok(delegated) =
    manager.delegate_session(
      registry,
      manager.DelegateRequest(
        spawner: laptop.name,
        parent_session: remote.session,
        creation: made,
        directory: here.sessions_directory,
        generator: here.generator(),
        configuration: "",
        limit: laptop.max_sessions,
        now_ms: here.now_ms(),
      ),
    )
    as "the initial creation is admitted before its builder fails"

  // Once failed creation has drained, the uninitialized registration remains
  // reserved and carries why its start failed (protocol-change/093). This is a
  // definitive failure, unlike a saved delegate reopening.
  assert eventually(fn() {
    case manager.get(registry, delegated.session_id) {
      Ok(manager.View(status: manager.FailedStart(..), ..)) -> True
      Ok(_) | Error(_) -> False
    }
  })
  let assert Error(remote_spawn.StoreFailure(reason:)) = resolve(laptop, remote)
  assert reason != ""
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

// Opening a saved session may fail while the dead daemon's writer lease is
// still live. Custody retirement and the next admission are separate turns,
// so both an in-flight resolver and a later resolver can see Closing.
pub fn a_failed_reopen_keeps_retrying_until_original_custody_retires_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let builds = process.new_subject()
  let registry = gated_registry(store, builds)
  let here = context(registry, "/delegate-host/sessions")
  let laptop = spawner("executor = \"runner\"\nworkspace = \"loom\"\n")
  let remote = parent(31)
  let resolve = delegate_host.resolver(here)

  // Establish a saved identity before injecting the failed reopen. A failed
  // initial creation is deliberately still Reserved and has different rules.
  let initial = resolving(here, laptop, remote)
  let assert Ok(#(_owner, answer)) = process.receive(builds, 2000)
    as "the first build reaches its publication barrier"
  process.send(answer, Ok(tagged(1)))
  let assert Ok(first) = resolved(initial) as "initial delegate opens"
  assert tag_of(first) == 1
  let assert Ok(Some(row)) =
    catalogue.delegate_for(store, laptop.name, remote.session)
    as "the pair has exactly one durable identity"
  let assert Ok(_) = manager.stop_session(registry, row.session_id)
    as "the original resident begins its clean close"
  assert eventually(fn() {
    case manager.get(registry, row.session_id) {
      Ok(manager.View(status: manager.Saved, ..)) -> True
      Ok(_) | Error(_) -> False
    }
  })

  // Hold cleanup after a failed open rather than hoping the resolver samples
  // the short Closing interval. No replacement may start before this proof.
  let failing = resolving(here, laptop, remote)
  let assert Ok(#(owner, answer)) = process.receive(builds, 2000)
    as "the saved delegate begins reopening"
  let draining = process.new_subject()
  assert custody.publish(owner, custody.Storage, fn() {
      let release = process.new_subject()
      process.send(draining, release)
      process.receive_forever(release)
      Ok(Nil)
    })
    == Ok(Nil)
  process.send(answer, Error("another writer still holds the lease"))
  let assert Ok(release) = process.receive(draining, 2000)
    as "failed assembly has entered retained cleanup"
  let assert Error(remote_spawn.NotYetOpen(_)) = resolved(failing)
    as "a resolver already waiting does not permanently refuse Closing"
  let assert Error(remote_spawn.NotYetOpen(_)) = resolve(laptop, remote)
    as "a new resolver does not permanently refuse Closing admission"
  assert process.receive(builds, 0) == Error(Nil)
  assert catalogue.delegates_held(store, laptop.name) == Ok(1)

  // Releasing the original witness admits the same saved identity. The retry
  // publishes a new endpoint only after that retirement has completed.
  process.send(release, Nil)
  assert eventually(fn() {
    case manager.get(registry, row.session_id) {
      Ok(manager.View(status: manager.Saved, ..)) -> True
      Ok(_) | Error(_) -> False
    }
  })
  let retry = resolving(here, laptop, remote)
  let assert Ok(#(_owner, answer)) = process.receive(builds, 2000)
    as "the same delegate opens again after its custody retires"
  process.send(answer, Ok(tagged(2)))
  let assert Ok(reopened) = resolved(retry) as "retry reaches the new endpoint"
  assert tag_of(reopened) == 2
  let assert Ok(Some(reused)) =
    catalogue.delegate_for(store, laptop.name, remote.session)
    as "the successful retry retains the pair"
  assert reused.session_id == row.session_id
  assert catalogue.delegates_held(store, laptop.name) == Ok(1)
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

// A lost cleanup proof is permanent, unlike a cleanup that is still running.
// A release still wins over either state before a spawn can reach the Agency.
pub fn a_blocked_delegate_is_definitive_and_release_has_priority_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let builds = process.new_subject()
  let registry = gated_registry(store, builds)
  let here = context(registry, "/delegate-host/sessions")
  let laptop = spawner("executor = \"runner\"\nworkspace = \"loom\"\n")
  let remote = parent(32)
  let opening = resolving(here, laptop, remote)
  let assert Ok(#(owner, answer)) = process.receive(builds, 2000)
    as "the delegate reaches its publication barrier"
  assert custody.publish(owner, custody.Runtime, fn() {
      Error("original cleanup proof was lost")
    })
    == Ok(Nil)
  process.send(answer, Ok(tagged(3)))
  let assert Ok(_) = resolved(opening) as "the initial delegate is resident"
  let assert Ok(Some(row)) =
    catalogue.delegate_for(store, laptop.name, remote.session)
    as "the pair has one durable identity"
  let assert Ok(_) = manager.stop_session(registry, row.session_id)
    as "the failing cleanup begins"
  assert eventually(fn() {
    case manager.get(registry, row.session_id) {
      Ok(manager.View(status: manager.RecoveryBlocked(_), ..)) -> True
      Ok(_) | Error(_) -> False
    }
  })

  let resolve = delegate_host.resolver(here)
  let assert Error(remote_spawn.StoreFailure(reason)) = resolve(laptop, remote)
    as "an unconfirmed cleanup is never reported as retryable admission"
  assert string.contains(reason, "original cleanup proof was lost")
  assert process.receive(builds, 0) == Error(Nil)
  assert catalogue.delegates_held(store, laptop.name) == Ok(1)

  // Deletion fences admission before waiting on custody, so even an already
  // blocked session answers ParentRunEnded once its parent releases it.
  assert delegate_host.releaser(here)(laptop, remote) == Ok(0)
  assert resolve(laptop, remote) == Error(remote_spawn.ParentRunEnded)
  assert process.receive(builds, 0) == Error(Nil)
  manager.shutdown(registry)

  // The unresolved witness deliberately remains until this test VM exits;
  // replacing or killing it would erase the failed retirement proof.
  assert catalogue.close(store) == Ok(Nil)
}

// Each assembly waits for this test's answer on a subject it owns. Publishing
// cleanup while it is parked makes the tested retirement order deterministic.
fn gated_registry(
  store: catalogue.Catalogue,
  builds: process.Subject(
    #(custody.Owner, process.Subject(Result(agency.DelegateEndpoint, String))),
  ),
) -> manager.Manager(agency.DelegateEndpoint) {
  let assert Ok(registry) =
    manager.start(
      store,
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(_record, _domain, _services, owner, _registry) {
          let answer = process.new_subject()
          process.send(builds, #(owner, answer))
          process.receive_forever(answer)
        },
        drain: fn(_, _) { Nil },
        fatal: fn(_) { [] },
      ),
      epoch: "delegate-host-gated-test",
      limit: 4,
    )
    as "the gated registry starts"
  registry
}

fn resolving(
  here: delegate_host.Context(agency.DelegateEndpoint),
  laptop: spawners.Spawner,
  remote: remote_spawn.Parent,
) -> weft.Detached(
  Result(agency.DelegateEndpoint, remote_spawn.SpawnRefusal),
  Nil,
) {
  weft.new([fn() { Ok(delegate_host.resolver(here)(laptop, remote)) }])
  |> weft.deadline(5000)
  |> weft.start_detached
}

fn resolved(
  opening: weft.Detached(
    Result(agency.DelegateEndpoint, remote_spawn.SpawnRefusal),
    Nil,
  ),
) -> Result(agency.DelegateEndpoint, remote_spawn.SpawnRefusal) {
  let assert weft.PulledOutcome(weft.Completed(0, answer)) =
    weft.pull(opening, within: 5000)
    as "the bounded resolver completes"
  answer
}

// --- the retention sweep ------------------------------------------------------

pub fn the_boot_sweep_deletes_the_sessions_a_spawner_has_left_idle_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let laptop = spawner("executor = \"runner\"\nworkspace = \"loom\"\n")
  let sessions = "/delegate-host/sessions"
  let first = started(store, fn(built) { Ok(tagged(built)) })

  // Two parents made contact at different times.
  let assert Ok(_) =
    delegate_host.resolver(context_at(first, sessions, 1000))(
      laptop,
      parent(40),
    )
  let assert Ok(_) =
    delegate_host.resolver(context_at(first, sessions, 500_000))(
      laptop,
      parent(41),
    )
  assert catalogue.delegates_held(store, "laptop") == Ok(2)
  let assert Ok(option.Some(idle)) =
    catalogue.delegate_for(store, "laptop", parent(40).session)
  let assert Ok(option.Some(boundary)) =
    catalogue.delegate_for(store, "laptop", parent(41).session)

  // The daemon restarts: a new registry over the same catalogue has no session
  // resident, and the sweep judges every delegate by its last contact.
  stop(first)
  let second = started(store, fn(built) { Ok(tagged(built)) })
  let retain = sweeping(100_000, 100_000)

  // Idle for 599_000 ms passes the 100_000 ms retention. Idle for exactly the
  // retention does not.
  assert manager.sweep_delegates(second, retain, 600_000, sessions)
    == Ok(manager.Swept(deleted: 1, closed: 0))
  assert catalogue.delegate_of(store, idle.session_id) == Ok(option.None)
  assert catalogue.get(store, idle.session_id) == Error(catalogue.Missing)
  assert catalogue.delegate_of(store, boundary.session_id)
    == Ok(option.Some(boundary))
  assert catalogue.delegates_held(store, "laptop") == Ok(1)

  // The slot the deleted session held is free again, and a repeat sweep finds
  // nothing more to delete.
  assert manager.sweep_delegates(second, retain, 600_000, sessions)
    == Ok(manager.Swept(deleted: 0, closed: 0))
  let assert Ok(_) =
    delegate_host.resolver(context_at(second, sessions, 700_000))(
      laptop,
      parent(40),
    )
  assert catalogue.delegates_held(store, "laptop") == Ok(2)
  stop(second)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_resident_session_is_kept_by_the_sweep_whatever_its_age_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let laptop = spawner("executor = \"runner\"\nworkspace = \"loom\"\n")
  let sessions = "/delegate-host/sessions"
  let registry = started(store, fn(built) { Ok(tagged(built)) })
  let assert Ok(_) =
    delegate_host.resolver(context_at(registry, sessions, 1000))(
      laptop,
      parent(50),
    )

  // The session is open and its last contact is old, but something is using it.
  assert manager.sweep_delegates(
      registry,
      sweeping(10, 9_000_000_000),
      9_000_000,
      sessions,
    )
    == Ok(manager.Swept(deleted: 0, closed: 0))
  assert catalogue.delegates_held(store, "laptop") == Ok(1)
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_session_is_a_delegate_once_the_registry_has_recorded_its_pair_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let laptop = spawner("executor = \"runner\"\nworkspace = \"loom\"\n")
  let registry = started(store, fn(built) { Ok(tagged(built)) })
  let assert Ok(_) =
    delegate_host.resolver(context(registry, "/delegate-host/sessions"))(
      laptop,
      parent(60),
    )
  let assert Ok(option.Some(recorded)) =
    catalogue.delegate_for(store, "laptop", parent(60).session)
  assert manager.delegate_of(registry, recorded.session_id)
    == Ok(option.Some(recorded))

  // Only that session gets a deadline tick. Any other session has no pair, so
  // its Agency reaps on observation alone, as it always did.
  assert daemon_main.deadline_tick_of(registry, recorded.session_id)
    == Ok(option.Some(agency.delegate_deadline_tick_ms))
  assert daemon_main.deadline_tick_of(registry, parent(61).session)
    == Ok(option.None)

  // Its Agency judges spawns by the spawner's `max_depth`, and any other session
  // keeps the Agency's own default. A spawner whose table is gone gives none.
  let deeper = spawners.Spawner(..laptop, max_depth: 3)
  assert daemon_main.depth_cap_of(registry, [deeper], recorded.session_id)
    == option.Some(3)
  assert daemon_main.depth_cap_of(registry, [deeper], parent(61).session)
    == option.None
  assert daemon_main.depth_cap_of(registry, [], recorded.session_id)
    == option.None
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_session_whose_delegate_marker_is_unreadable_has_no_answer_test() {
  // A row that breaks its grammar makes the marker unreadable. The answer is an
  // error, which the build refuses, and not "no tick".
  let path = scratch("damaged") <> "/catalogue.db"
  let assert Ok(store) = catalogue.open(path) as "catalogue opens"
  let laptop = spawner("executor = \"runner\"\nworkspace = \"loom\"\n")
  let registry = started(store, fn(built) { Ok(tagged(built)) })
  let assert Ok(_) =
    delegate_host.resolver(context(registry, "/delegate-host/sessions"))(
      laptop,
      parent(70),
    )
  let assert Ok(option.Some(recorded)) =
    catalogue.delegate_for(store, "laptop", parent(70).session)
  let assert Ok(raw) = sqlight.open(path)
  let assert Ok(_) =
    sqlight.exec(
      "UPDATE catalogue_delegate_sessions SET parent_session = 'not-an-id'",
      on: raw,
    )
  let assert Error(_) =
    daemon_main.deadline_tick_of(registry, recorded.session_id)
  let assert Ok(Nil) = sqlight.close(raw)
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

// --- releasing a pair (protocol-change/084, phase 2) --------------------------
//
// A release says the parent session was deleted. Deleting the delegate session
// removes everything stored under it: its conversation, and with it the facts,
// the outbox rows and the remembered permissions kept there. These tests check
// the registry's half of that, and that a release never creates a session.

pub fn a_release_for_a_pair_with_no_row_answers_zero_and_creates_nothing_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let registry = started(store, fn(built) { Ok(tagged(built)) })
  let release =
    delegate_host.releaser(context(registry, "/delegate-host/sessions"))
  let laptop = spawner("executor = \"runner\"\nworkspace = \"loom\"\n")
  let remote = parent(80)

  // The release overtakes the spawn it concerns, or is simply sent twice: there
  // is no session, so nothing is stopped and nothing is made. The key a
  // creation would have used finds no registration.
  assert release(laptop, remote) == Ok(0)
  assert release(laptop, remote) == Ok(0)
  assert catalogue.delegates_held(store, "laptop") == Ok(0)
  assert catalogue.by_request_key(store, "delegate:laptop:" <> remote.session)
    == Error(catalogue.Missing)
  assert catalogue.delegate_for(store, "laptop", remote.session) == Ok(None)

  // The spawn that comes after is the first message for its pair and makes a
  // session of its own, which is the acceptable end of the ordering: the parent
  // still exists, as far as this orchestrator can know.
  let resolve =
    delegate_host.resolver(context(registry, "/delegate-host/sessions"))
  let assert Ok(_) = resolve(laptop, remote)
  assert catalogue.delegates_held(store, "laptop") == Ok(1)
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_release_stops_the_resident_session_and_deletes_it_and_its_row_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let registry = started(store, fn(built) { Ok(tagged(built)) })
  let here = context(registry, "/delegate-host/sessions")
  let laptop = spawner("executor = \"runner\"\nworkspace = \"loom\"\n")
  let remote = parent(81)
  let assert Ok(first) = delegate_host.resolver(here)(laptop, remote)
  let assert Ok(option.Some(recorded)) =
    catalogue.delegate_for(store, "laptop", remote.session)

  // The answer is the Agency's own count, here the session's tag, which shows
  // the release reached the resident session's endpoint.
  assert delegate_host.releaser(here)(laptop, remote) == Ok(tag_of(first))

  // The slot drains, and the session and its row go together. A repeat finds no
  // row and answers zero, without making a session. Observe through the owner
  // first: reading its connection directly could see the dependent row leave
  // inside a deletion transaction whose registration row has not left yet.
  assert eventually(fn() {
    manager.delegate_of(registry, recorded.session_id) == Ok(None)
  })
  assert catalogue.delegate_of(store, recorded.session_id) == Ok(None)
  assert catalogue.get(store, recorded.session_id) == Error(catalogue.Missing)
  assert catalogue.delegates_held(store, "laptop") == Ok(0)
  assert delegate_host.releaser(here)(laptop, remote) == Ok(0)
  assert catalogue.delegates_held(store, "laptop") == Ok(0)
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_release_of_a_closed_session_deletes_it_without_opening_it_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let laptop = spawner("executor = \"runner\"\nworkspace = \"loom\"\n")
  let sessions = "/delegate-host/sessions"
  let remote = parent(82)
  let first = started(store, fn(built) { Ok(tagged(built)) })
  let assert Ok(_) =
    delegate_host.resolver(context(first, sessions))(laptop, remote)
  let assert Ok(option.Some(recorded)) =
    catalogue.delegate_for(store, "laptop", remote.session)
  stop(first)

  // A new registry has no session resident. Nothing runs in a closed session, so
  // there is no child to stop, and the build is never asked to open it.
  let second = started(store, fn(_built) { Error("must not open") })
  assert delegate_host.releaser(context(second, sessions))(laptop, remote)
    == Ok(0)
  assert catalogue.delegate_of(store, recorded.session_id) == Ok(None)
  assert catalogue.get(store, recorded.session_id) == Error(catalogue.Missing)
  stop(second)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_spawn_for_a_released_pair_is_refused_and_opens_nothing_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let laptop = spawner("executor = \"runner\"\nworkspace = \"loom\"\n")
  let sessions = "/delegate-host/sessions"
  let remote = parent(83)
  let first = started(store, fn(built) { Ok(tagged(built)) })
  let assert Ok(_) =
    delegate_host.resolver(context(first, sessions))(laptop, remote)
  let assert Ok(option.Some(recorded)) =
    catalogue.delegate_for(store, "laptop", remote.session)
  stop(first)

  // The row says the release began and the deletion has not finished.
  let assert Ok(Nil) =
    catalogue.set_delegate_state(
      store,
      recorded.session_id,
      catalogue.Releasing,
    )
  let second = started(store, fn(_built) { Error("must not open") })
  assert delegate_host.resolver(context(second, sessions))(laptop, remote)
    == Error(remote_spawn.ParentRunEnded)

  // The refusal touched nothing: the row is as it was, and its contact time is
  // not moved by a message the session will not serve.
  assert catalogue.delegate_of(store, recorded.session_id)
    == Ok(Some(catalogue.Delegate(..recorded, state: catalogue.Releasing)))

  // A repeated release finishes the deletion the first began.
  assert delegate_host.releaser(context(second, sessions))(laptop, remote)
    == Ok(0)
  assert catalogue.delegate_of(store, recorded.session_id) == Ok(None)
  stop(second)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn the_sweep_deletes_a_released_session_whatever_its_age_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let laptop = spawner("executor = \"runner\"\nworkspace = \"loom\"\n")
  let sessions = "/delegate-host/sessions"
  let first = started(store, fn(built) { Ok(tagged(built)) })
  let assert Ok(_) =
    delegate_host.resolver(context_at(first, sessions, 1000))(
      laptop,
      parent(84),
    )
  let assert Ok(_) =
    delegate_host.resolver(context_at(first, sessions, 1000))(
      laptop,
      parent(85),
    )
  let assert Ok(option.Some(failed)) =
    catalogue.delegate_for(store, "laptop", parent(84).session)
  let assert Ok(option.Some(open)) =
    catalogue.delegate_for(store, "laptop", parent(85).session)
  stop(first)

  // A deletion that failed after the slot drained left its row released. The
  // sweep removes it though it is far inside the retention, and leaves the open
  // session that is equally recent.
  let assert Ok(Nil) =
    catalogue.set_delegate_state(store, failed.session_id, catalogue.Released)
  let second = started(store, fn(built) { Ok(tagged(built)) })
  assert manager.sweep_delegates(
      second,
      sweeping(1_000_000, 1_000_000),
      2000,
      sessions,
    )
    == Ok(manager.Swept(deleted: 1, closed: 0))
  assert catalogue.delegate_of(store, failed.session_id) == Ok(None)
  assert catalogue.delegate_of(store, open.session_id) == Ok(Some(open))
  stop(second)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn the_sweep_deletes_a_removed_spawners_session_at_once_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let laptop = spawner("executor = \"runner\"\nworkspace = \"loom\"\n")
  let sessions = "/delegate-host/sessions"
  let first = started(store, fn(built) { Ok(tagged(built)) })
  let assert Ok(_) =
    delegate_host.resolver(context_at(first, sessions, 1000))(
      laptop,
      parent(90),
    )
  let assert Ok(option.Some(row)) =
    catalogue.delegate_for(store, "laptop", parent(90).session)
  stop(first)

  // Contact was one millisecond ago and the retention is long, but the table
  // is gone, so nothing could ever send the session a message again.
  let second = started(store, fn(built) { Ok(tagged(built)) })
  assert manager.sweep_delegates(second, removed(), 1001, sessions)
    == Ok(manager.Swept(deleted: 1, closed: 0))
  assert catalogue.delegate_of(store, row.session_id) == Ok(None)
  assert catalogue.get(store, row.session_id) == Error(catalogue.Missing)
  stop(second)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_removed_spawners_idle_resident_session_is_closed_then_deleted_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let laptop = spawner("executor = \"runner\"\nworkspace = \"loom\"\n")
  let sessions = "/delegate-host/sessions"
  let registry = started(store, fn(built) { Ok(tagged(built)) })
  let assert Ok(_) =
    delegate_host.resolver(context_at(registry, sessions, 1000))(
      laptop,
      parent(94),
    )
  let assert Ok(option.Some(row)) =
    catalogue.delegate_for(store, "laptop", parent(94).session)

  // A slot holds the session, so the first sweep can only close it.
  assert manager.sweep_delegates(registry, removed(), 1001, sessions)
    == Ok(manager.Swept(deleted: 0, closed: 1))

  // Stopping is no longer resident but still holds the slot until the normal
  // custody witness exits. Only Saved proves that the next sweep can delete.
  assert eventually(fn() {
    case manager.get(registry, row.session_id) {
      Ok(manager.View(status: manager.Saved, ..)) -> True
      _ -> False
    }
  })

  // With the slot drained, the next sweep deletes it.
  assert manager.sweep_delegates(registry, removed(), 1002, sessions)
    == Ok(manager.Swept(deleted: 1, closed: 0))
  assert catalogue.delegate_of(store, row.session_id) == Ok(None)
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn the_sweep_closes_an_idle_resident_session_and_deletes_nothing_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let laptop = spawner("executor = \"runner\"\nworkspace = \"loom\"\n")
  let sessions = "/delegate-host/sessions"
  let registry = started(store, fn(built) { Ok(tagged(built)) })
  let assert Ok(_) =
    delegate_host.resolver(context_at(registry, sessions, 1000))(
      laptop,
      parent(91),
    )
  let assert Ok(option.Some(row)) =
    catalogue.delegate_for(store, "laptop", parent(91).session)
  assert is_resident(registry, row.session_id)

  // Silent for 5000 ms against a 2000 ms window, with no child running.
  assert manager.sweep_delegates(
      registry,
      sweeping(1_000_000, 2000),
      6000,
      sessions,
    )
    == Ok(manager.Swept(deleted: 0, closed: 1))
  assert eventually(fn() { !is_resident(registry, row.session_id) })

  // The row and the registration stay, and the next message reopens it.
  assert catalogue.delegate_of(store, row.session_id) == Ok(Some(row))
  let assert Ok(_) =
    delegate_host.resolver(context_at(registry, sessions, 7000))(
      laptop,
      parent(91),
    )
  assert eventually(fn() { is_resident(registry, row.session_id) })
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn the_sweep_keeps_a_session_with_a_live_child_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let laptop = spawner("executor = \"runner\"\nworkspace = \"loom\"\n")
  let sessions = "/delegate-host/sessions"
  let registry =
    started(store, fn(built) { Ok(tagged_with(built, agency.Occupied)) })
  let assert Ok(_) =
    delegate_host.resolver(context_at(registry, sessions, 1000))(
      laptop,
      parent(92),
    )
  let assert Ok(option.Some(row)) =
    catalogue.delegate_for(store, "laptop", parent(92).session)

  // Long past the idle window, but a child still has a run.
  assert manager.sweep_delegates(
      registry,
      sweeping(1_000_000_000, 2000),
      9_000_000,
      sessions,
    )
    == Ok(manager.Swept(deleted: 0, closed: 0))
  assert is_resident(registry, row.session_id)
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn the_sweep_keeps_a_session_younger_than_the_idle_window_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let laptop = spawner("executor = \"runner\"\nworkspace = \"loom\"\n")
  let sessions = "/delegate-host/sessions"
  let registry = started(store, fn(built) { Ok(tagged(built)) })
  let assert Ok(_) =
    delegate_host.resolver(context_at(registry, sessions, 1000))(
      laptop,
      parent(93),
    )
  let assert Ok(option.Some(row)) =
    catalogue.delegate_for(store, "laptop", parent(93).session)

  // Silent for exactly the window is not past it.
  assert manager.sweep_delegates(
      registry,
      sweeping(1_000_000, 2000),
      3000,
      sessions,
    )
    == Ok(manager.Swept(deleted: 0, closed: 0))
  assert is_resident(registry, row.session_id)
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

// Waits for something the registry does on its own turn, such as deleting a
// session once its slot drains.
fn eventually(done: fn() -> Bool) -> Bool {
  let waited =
    poll.until(within: 2000, every: 10, attempt: fn() {
      case done() {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
  case waited {
    poll.Answered(Nil) -> True
    poll.Failed(_) | poll.Expired -> False
  }
}

pub fn a_release_of_a_session_that_is_still_opening_does_not_wait_for_it_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let laptop = spawner("executor = \"runner\"\nworkspace = \"loom\"\n")
  let sessions = "/delegate-host/sessions"
  let remote = parent(86)

  // The build parks for a while, as an attach to a slow executor does.
  let registry =
    started(store, fn(_built) {
      process.sleep(800)
      Error("never reached")
    })
  let _opening =
    process.spawn_unlinked(fn() {
      let _ =
        delegate_host.resolver(context(registry, sessions))(laptop, remote)
      Nil
    })
  let assert Ok(recorded) = await_row(store, laptop, remote)

  // The release answers at once with zero, marks the row, and cancels the build,
  // so the session is deleted without ever serving a child.
  let began = ffi_os.system_time_ms()
  assert delegate_host.releaser(context(registry, sessions))(laptop, remote)
    == Ok(0)
  assert ffi_os.system_time_ms() - began < 3000
  assert eventually(fn() {
    catalogue.delegate_of(store, recorded.session_id) == Ok(None)
  })
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

// Waits for the pair's row, which the registry writes in the turn that admits
// the session.
fn await_row(
  store: catalogue.Catalogue,
  laptop: spawners.Spawner,
  remote: remote_spawn.Parent,
) -> Result(catalogue.Delegate, Nil) {
  let waited =
    poll.until(within: 2000, every: 10, attempt: fn() {
      case catalogue.delegate_for(store, laptop.name, remote.session) {
        Ok(Some(found)) -> poll.Done(found)
        Ok(None) | Error(_) -> poll.Retry
      }
    })
  case waited {
    poll.Answered(found) -> Ok(found)
    poll.Failed(_) | poll.Expired -> Error(Nil)
  }
}

// --- a spawner's rolling day (catalogue version 17) --------------------------
//
// The Agency's holder claims a spawn here for a child it is about to create, so
// these drive the registry's claim directly.

fn claim(
  registry: manager.Manager(agency.DelegateEndpoint),
  tokens: option.Option(Int),
  spawns: option.Option(Int),
  now_ms: Int,
) -> Result(Nil, remote_spawn.SpawnRefusal) {
  manager.claim_spawn(
    registry,
    "laptop",
    tokens,
    spawns,
    now_ms:,
    within_ms: 5000,
  )
  |> result.map_error(delegate_host.refused)
}

pub fn a_claim_past_max_per_day_is_refused_and_counts_nothing_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let registry = started(store, fn(built) { Ok(tagged(built)) })

  // Two claims pass and the third meets the cap, which the refusal names with
  // its own value. A refused claim is not counted.
  assert claim(registry, None, Some(2), 4242) == Ok(Nil)
  assert claim(registry, None, Some(2), 4242) == Ok(Nil)
  let refusal =
    Error(remote_spawn.CapReached(cap: remote_spawn.SpawnsPerDay, limit: 2))
  assert claim(registry, None, Some(2), 4242) == refusal
  assert claim(registry, None, Some(2), 4242) == refusal
  assert catalogue.spawner_spend(store, "laptop", now_ms: 4242)
    == Ok(catalogue.Spend(tokens: 0, spawns: 2))
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_claim_past_the_days_token_budget_is_refused_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let registry = started(store, fn(built) { Ok(tagged(built)) })
  assert manager.add_spend(registry, "laptop", now_ms: 4242, tokens: 999)
    == Ok(Nil)
  assert claim(registry, Some(1000), None, 4242) == Ok(Nil)
  assert manager.add_spend(registry, "laptop", now_ms: 4242, tokens: 1)
    == Ok(Nil)
  assert claim(registry, Some(1000), None, 4242)
    == Error(remote_spawn.CapReached(
      cap: remote_spawn.TokensPerDay,
      limit: 1000,
    ))
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn the_day_rolls_forward_with_the_clock_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let registry = started(store, fn(built) { Ok(tagged(built)) })
  let hour = catalogue.spend_bucket_ms
  assert manager.add_spend(registry, "laptop", now_ms: 0, tokens: 1000)
    == Ok(Nil)

  // Twenty-three hours later the spend is still inside the day. At the
  // twenty-fourth hour its bucket has left it and the claim passes.
  let assert Error(_) = claim(registry, Some(1000), None, 23 * hour + 5)
  assert claim(registry, Some(1000), None, 24 * hour) == Ok(Nil)
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_registry_that_does_not_answer_a_claim_is_a_store_failure_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let registry = started(store, fn(built) { Ok(tagged(built)) })
  stop(registry)

  // The claim is bounded and unanswered, and what it reports is a failure the
  // spawner retries. It is never a cap.
  let assert Error(remote_spawn.StoreFailure(_)) =
    claim(registry, None, Some(1), 4242)
  assert catalogue.close(store) == Ok(Nil)
}

// A message about a child that exists (a send into it, a decision about its
// request) is served by the pair's session if one is open, and never makes one.
// A stale card answered after the child finished and its session was deleted
// must not open a fresh session only to refuse the message. The refusal is also
// why a decision on a released child wakes nothing: it never reaches a session
// that could commit it, so `remote_decision` never tells a child about it.
pub fn a_send_or_a_decision_for_a_pair_with_no_session_creates_none_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let registry = started(store, fn(built) { Ok(tagged(built)) })
  let here = context(registry, "/delegate-host/sessions")
  let laptop = spawner("executor = \"runner\"\nworkspace = \"loom\"\n")
  let remote = parent(90)
  assert delegate_host.existing_endpoint(here)(laptop, remote) == Ok(None)

  let host =
    daemon_main.spawn_host(
      [laptop],
      delegate_host.resolver(here),
      delegate_host.releaser(here),
      delegate_host.existing_endpoint(here),
      log.discard(),
    )
  let origin = remote_spawn.Origin(node: "laptop@100.64.0.5", parent: remote)
  let child =
    agent.Handle(
      strand: "sub:^main/run-the-suite-1",
      operation: ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 5)).0,
    )
  let held =
    remote_spawn.InvalidArgument(
      reason: "this orchestrator holds no such child for that parent",
    )
  assert host.send(origin, child, "m1", "hello") == Error(held)
  assert host.resolve(
      origin,
      child,
      "policy-ab",
      remote_escalation.Deny,
      3,
      remote_escalation.Decider(principal: "ab12", name: "Ola"),
    )
    == Error(held)

  // Neither the registry nor the catalogue holds a row for the pair, and no
  // session was made.
  assert manager.delegate_pair(registry, "laptop", remote.session) == Ok(None)
  assert catalogue.delegates_held(store, "laptop") == Ok(0)
  assert catalogue.by_request_key(store, "delegate:laptop:" <> remote.session)
    == Error(catalogue.Missing)
}

// --- the release cascades (protocol-change/084, phase 4) ---------------------
//
// A delegate session's own children may have started children on a third
// orchestrator, and the session's stubs are the only record of them. The
// registry reads them from the closed file in the turn that deletes the drained
// session and writes a release row for each orchestrator they name. Until then
// the session may still resend a spawn, so a row written earlier could let a
// spawn reach the third orchestrator after its release.

// The release drainer's pass over `registry`, asking through `reach`.
fn cascade_pass(
  registry: manager.Manager(agency.DelegateEndpoint),
  reach: remote_reach.Reach,
) -> fn() -> peer_outbox_drain.Backlog {
  remote_release.pass(
    fn() {
      manager.remote_releases(registry) |> result.map_error(string.inspect)
    },
    fn(release) {
      manager.settle_remote_release(registry, release)
      |> result.map_error(string.inspect)
    },
    reach.release,
    log.discard(),
  )
}

// The stubs a delegate session's children wrote: one spawn on `third` still
// unanswered, and one that `fourth` refused, which made no child.
fn grandchild_stubs(path: String) -> Nil {
  remote_stubs.write(path, [
    remote_stubs.stub("third", 1, remote_child.Requested),
    remote_stubs.stub("fourth", 2, remote_child.Refused(reason: "no table")),
  ])
}

pub fn a_closed_session_owes_its_childrens_children_a_release_test() {
  let sessions = scratch("cascade-closed")
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let laptop = spawner("executor = \"runner\"\nworkspace = \"loom\"\n")
  let remote = parent(86)
  let first = started(store, fn(built) { Ok(tagged(built)) })
  let assert Ok(_) =
    delegate_host.resolver(context(first, sessions))(laptop, remote)
  let assert Ok(option.Some(recorded)) =
    catalogue.delegate_for(store, "laptop", remote.session)
  stop(first)
  let assert Ok(registration) = catalogue.get(store, recorded.session_id)
  grandchild_stubs(registration.path)

  // The session is closed, so the release deletes it in its own turn, and that
  // turn reads the file and owes `third` a release for the delegate session.
  // `fourth` refused its spawn and is owed nothing.
  let second = started(store, fn(_built) { Error("must not open") })
  assert delegate_host.releaser(context(second, sessions))(laptop, remote)
    == Ok(0)
  assert catalogue.get(store, recorded.session_id) == Error(catalogue.Missing)
  let assert Ok([row]) = catalogue.remote_releases(store)
  assert row.parent_session == recorded.session_id
  assert row.orchestrator == "third"

  // The drainer's pass tells `third`, naming the delegate session as the
  // parent, and settles the row on its answer.
  let third = fake_orchestrators.start("third", fake_orchestrators.Up)
  let pass =
    cascade_pass(second, fake_orchestrators.reach("", [third], fn() { True }))
  assert pass() == peer_outbox_drain.Clear
  assert fake_orchestrators.report(third).releases
    == [Parent(session: recorded.session_id, strand: "main")]
  assert catalogue.remote_releases(store) == Ok([])
  stop(second)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_resident_session_owes_the_release_only_once_its_slot_has_drained_test() {
  let sessions = scratch("cascade-resident")
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let rung = process.new_subject()
  let registry = started(store, fn(built) { Ok(tagged(built)) })
  manager.on_releases_owed(registry, fn() { process.send(rung, Nil) })
  let here = context(registry, sessions)
  let laptop = spawner("executor = \"runner\"\nworkspace = \"loom\"\n")
  let remote = parent(87)
  let assert Ok(first) = delegate_host.resolver(here)(laptop, remote)
  let assert Ok(option.Some(recorded)) =
    catalogue.delegate_for(store, "laptop", remote.session)
  let assert Ok(registration) = catalogue.get(store, recorded.session_id)
  grandchild_stubs(registration.path)
  assert delegate_host.releaser(here)(laptop, remote) == Ok(tag_of(first))

  // The row is written in the registry turn that deletes the session, after the
  // slot has drained and nothing of the session can resend a spawn. Asked
  // through the registry, which serializes with that turn, the row and the
  // session are never seen together.
  let assert Ok(Nil) = process.receive(rung, 5000)
    as "the release drainer is rung for the row"
  let assert Ok([row]) = manager.remote_releases(registry)
  assert row.orchestrator == "third"
  let assert Error(manager.Catalogue(catalogue.Missing)) =
    manager.get(registry, recorded.session_id)

  // A repeat finds no row for the pair, answers zero and owes nothing more.
  assert delegate_host.releaser(here)(laptop, remote) == Ok(0)
  let assert Ok([_still_one]) = catalogue.remote_releases(store)
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}
