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
import client/remote_spawn.{Parent}
import client/spawners
import core/clock
import core/ids
import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import host/bootstrap
import simplifile
import sqlight
import storage/catalogue
import storage/domain
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
  agency.DelegateEndpoint(
    spawn: fn(_delegation, _site, _request) {
      Error(remote_spawn.StoreFailure(reason: "tag " <> int.to_string(tag)))
    },
    join: fn(_parent, _handles, _within_ms) { Ok([]) },
    run_ended: fn(_operation) { Ok(tag) },
    release: fn() { Ok(tag) },
  )
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
  let assert Error(remote_spawn.StoreFailure(reason:)) =
    resolve(laptop, parent(30))
  assert reason != ""
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
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
  let retain = fn(_spawner) { 100_000 }

  // Idle for 599_000 ms passes the 100_000 ms retention. Idle for exactly the
  // retention does not.
  assert manager.sweep_delegates(second, retain, 600_000, sessions) == Ok(1)
  assert catalogue.delegate_of(store, idle.session_id) == Ok(option.None)
  assert catalogue.get(store, idle.session_id) == Error(catalogue.Missing)
  assert catalogue.delegate_of(store, boundary.session_id)
    == Ok(option.Some(boundary))
  assert catalogue.delegates_held(store, "laptop") == Ok(1)

  // The slot the deleted session held is free again, and a repeat sweep finds
  // nothing more to delete.
  assert manager.sweep_delegates(second, retain, 600_000, sessions) == Ok(0)
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
  assert manager.sweep_delegates(registry, fn(_) { 10 }, 9_000_000, sessions)
    == Ok(0)
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
  // row and answers zero, without making a session.
  assert eventually(fn() {
    catalogue.delegate_of(store, recorded.session_id) == Ok(None)
  })
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
  assert manager.sweep_delegates(second, fn(_) { 1_000_000 }, 2000, sessions)
    == Ok(1)
  assert catalogue.delegate_of(store, failed.session_id) == Ok(None)
  assert catalogue.delegate_of(store, open.session_id) == Ok(Some(open))
  stop(second)
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
