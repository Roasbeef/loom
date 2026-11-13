//// A box for the live feed's laptop-side tests: a real registry over a real
//// catalogue, a real `TopHost` and the real stable endpoint, with a real gateway
//// for one relayed session, as `feed_host_test` builds them for the box's half
//// (protocol-change/108). The laptop's feed client, `top_relay` and
//// `peer_client.call_at` are then tested against the box's own code and not a
//// restatement of it.

import client/daemon/domain as domain_service
import client/daemon/manager
import client/deployment
import client/gateway
import client/gateway_test
import client/internal/ffi_os
import client/relayed_session.{type Endpoint}
import client/remote/address.{type Address}
import client/remote/peer_service
import client/remote_feed
import client/remote_top
import client/spawners
import client/top_host
import core/clock
import core/entry as core_entry
import core/ids
import core/message
import gleam/erlang/atom
import gleam/erlang/node
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import simplifile
import storage/access
import storage/catalogue
import storage/storage
import support/addresses

pub const configuration =
  "
[distribution]
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

[executors.exec]
node = \"runner@100.64.0.7\"

[models.base]
dialect = \"anthropic\"
api_key_env = \"UNUSED_TEST_KEY\"
model_id = \"base-model\"
context_window = 1000
max_output_tokens = 100

[roles]
main = [\"base\"]

[profiles.alt.roles]
main = [\"base\"]

[spawners.laptop]
node = \"laptop@100.64.0.5\"
directory = \"/srv/loom/scratch\"
profile = \"alt\"
"

// A table whose ceiling admits the environment variable `TOKEN` and nothing else.
pub const deciding =
  "
[spawners.laptop.top_level]
executors = [\"exec\"]
profiles = [\"alt\"]
max_sessions = 3

[spawners.laptop.top_level.approval_ceiling]
env = [\"TOKEN\"]
network = \"any\"
"

// The same table with no ceiling: its page can watch and decides nothing.
pub const watching =
  "
[spawners.laptop.top_level]
executors = [\"exec\"]
profiles = [\"alt\"]
max_sessions = 3
"

// The same table that serves the transcript page of 094 only.
pub const paged =
  "
[spawners.laptop.top_level]
executors = [\"exec\"]
profiles = [\"alt\"]
max_sessions = 3
page = \"paged\"
"

// The daemon epoch the box serves and its feeds are bound under.
pub const epoch = "feed-host-test"

// --- the rig ------------------------------------------------------------------

pub type Rig {
  Rig(
    registry: manager.Manager(Endpoint),
    harness: gateway_test.Harness,
    peer: Address(peer_service.Message),
    session: String,
    spawner: spawners.Spawner,
    /// What the gateway counts before any feed attaches: its fixture's own sink.
    baseline: Int,
  )
}

pub fn own_node() -> String {
  atom.to_string(node.name(node.self()))
}

pub fn scratch(label: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the working directory is known"
  let directory =
    here
    <> "/build/test_db/feed-host-"
    <> label
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let _ = simplifile.delete(directory)
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "the scratch directory is made"
  directory
}

pub fn box_owner() -> access.Principal {
  access.Principal(
    id: "owner-1",
    display_name: "Owner",
    kind: access.OwnerPrincipal,
  )
}

pub fn context(
  registry: manager.Manager(Endpoint),
  spawner: spawners.Spawner,
  directory: String,
  configuration_path: String,
  hub: gateway.Gateway,
  lease_ms: Int,
) -> top_host.Context(Endpoint) {
  top_host.Context(
    spawners: [spawner],
    registry:,
    endpoint: fn(endpoint) { endpoint },
    sessions_directory: directory,
    domain_configuration: configuration_path,
    generator: fn() {
      ids.generator(
        clock.fixed(at: 1_700_000_000_000),
        ffi_os.unique_positive_integer(),
      )
    },
    now_ms: fn() { 1_700_000_000_000 },
    has_executor: fn(name) { name == "exec" },
    has_pool: fn(_) { False },
    survey: fn() { deployment.Placements(executors: [], pools: []) },
    check_folder: fn(path) { Ok(path) },
    record: fn(_) { Ok(Nil) },
    covered: fn() { Nil },
    epoch:,
    gateway: fn(_) { hub },
    owner: box_owner(),
    admit: fn() { Ok(fn() { Ok(Nil) }) },
    feed_lease_ms: lease_ms,
  )
}

/// A rig whose spawner table is `table`, over a registry that holds one relayed
/// session and a real gateway for it. `lease_ms` is the feed lease.
pub fn rig(label: String, table: String, lease_ms: Int) -> Rig {
  let directory = scratch(label)
  let text = configuration <> table
  let configuration_path = directory <> "/loom.toml"
  let assert Ok(Nil) = simplifile.write(configuration_path, text)
    as "the configuration is written"
  let assert Ok(configured) = spawners.parse(text) as "the spawner table parses"
  let assert [spawner] = configured
  let spawner = spawners.Spawner(..spawner, node: own_node())
  let assert Ok(store) = catalogue.open(directory <> "/catalogue.db")
    as "the catalogue opens"
  let assert Ok(registry) =
    manager.start(
      store,
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(_record, _domain, _services, _owner, _registry) {
          Ok(relayed_session.refusing())
        },
        drain: fn(_, _) { Nil },
        fatal: fn(_) { [] },
      ),
      epoch:,
      limit: 32,
    )
    as "the registry starts"

  // The session is made by the page of the spawner, as 094 makes it, and then
  // gets a gateway whose session identity is its own.
  let creating =
    top_host.host(context(
      registry,
      spawner,
      directory,
      configuration_path,
      gateway.Gateway(name: addresses.new()),
      remote_feed.lease_ms,
    ))
  let assert Ok(session) =
    creating.create(
      own_node(),
      "0198c0de-0000-7000-8000-100000000001",
      remote_top.Workspace(executor: "exec", name: "repo"),
      "alt",
      None,
    )
    as "the relayed session is created"
  let assert Ok(id) = ids.parse_session_id(session)
    as "the registry's session identity parses"
  let harness = gateway_test.reserved_fixture(id)
  let baseline = gateway.attached(harness.hub)
  let name = process.new_name("peer_service")
  let assert Ok(_) =
    peer_service.start(
      name,
      epoch,
      "build-test",
      top_host.host(context(
        registry,
        spawner,
        directory,
        configuration_path,
        harness.hub,
        lease_ms,
      )),
    )
    as "the stable endpoint starts"
  Rig(
    registry:,
    harness:,
    peer: address.Address(node: node.self(), name:),
    session:,
    spawner:,
    baseline:,
  )
}

/// The texts of the user messages the session's transcript holds.
pub fn prompts(rig: Rig) -> List(String) {
  let assert Ok(rows) =
    storage.scan_entries(
      rig.harness.runtime.session.store,
      storage.entry_scan() |> storage.entry_seq_range(Some(1), None),
    )
    as "the transcript is readable"
  list.filter_map(rows, fn(row) {
    case row {
      core_entry.MessageEntry(
        message: message.UserMessage(content: [message.UserText(text:, ..)], ..),
        ..,
      ) -> Ok(text)
      _ -> Error(Nil)
    }
  })
}
