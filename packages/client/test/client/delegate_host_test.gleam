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
import storage/catalogue
import storage/domain

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
  )
}

fn context(
  registry: manager.Manager(agency.DelegateEndpoint),
  directory: String,
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
    now_ms: fn() { 4242 },
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
