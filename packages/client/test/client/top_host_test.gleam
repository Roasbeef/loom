//// This orchestrator's answer to the page of a spawner that wants to start and
//// drive sessions here (protocol-change/094), end to end below the sessions
//// themselves: a message goes through the orchestrator port to `top_host`,
//// which judges it against the `top_level` table and serves it from the real
//// registry over a real catalogue.
////
//// Only the sessions are fakes. The registry's assembly publishes a recording
//// `relayed_session.Endpoint` as each session's instance, so the tests can say
//// which session a message reached and what it was told. The real endpoint over
//// a real runtime is pinned in `relayed_session_test`, and the real judgement of
//// a decision in `remote_decision_test` and `gateway_test`.

import client/daemon/domain as domain_service
import client/daemon/manager
import client/deployment
import client/executors
import client/internal/ffi_os
import client/peer_mail
import client/protocol
import client/relayed_session.{type Endpoint, Endpoint, Overview}
import client/remote/address.{type Address}
import client/remote/orchestrator_port.{type Message}
import client/remote_escalation
import client/remote_top
import client/spawners
import client/top_host
import core/clock
import core/ids
import core/json
import gleam/dict.{type Dict}
import gleam/erlang/atom
import gleam/erlang/node
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import simplifile
import storage/catalogue
import storage/domain
import weft/actor
import weft/poll

const answers_within_ms = 5000

const configuration =
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

[pools.linux]
executors = [\"exec\"]

[models.base]
dialect = \"anthropic\"
api_key_env = \"UNUSED_TEST_KEY\"
model_id = \"base-model\"
context_window = 1000
max_output_tokens = 100

[models.fast]
dialect = \"openai\"
api_key_env = \"UNUSED_TEST_KEY\"
model_id = \"fast-model\"
context_window = 2000
max_output_tokens = 200

[roles]
main = [\"base\"]

[profiles.alt.roles]
main = [\"fast\"]

[profiles.other.roles]
main = [\"base\"]

[spawners.laptop]
node = \"laptop@100.64.0.5\"
directory = \"/srv/loom/scratch\"
profile = \"alt\"
"

// The default table: both placements, folders, the `alt` profile, small caps
// that a test can reach, and a ceiling that admits one root.
const table =
  "
[spawners.laptop.top_level]
executors = [\"exec\"]
pools = [\"linux\"]
folders = \"recent\"
profiles = [\"alt\"]
max_sessions = 3
max_per_hour = 100

[spawners.laptop.top_level.approval_ceiling]
writable_roots = [\"/srv/work\"]
"

// --- the world the fake sessions share --------------------------------------------------

type World {
  Put(session: String, overview: relayed_session.Overview)
  Note(line: String)
  ReadOverview(
    session: String,
    reply: Subject(Option(relayed_session.Overview)),
  )
  Lines(reply: Subject(List(String)))
}

type Book {
  Book(overviews: Dict(String, relayed_session.Overview), lines: List(String))
}

fn start_world() -> Subject(World) {
  let assert Ok(started) =
    actor.new(Book(overviews: dict.new(), lines: []))
    |> actor.on_message(fn(book, message) {
      case message {
        Put(session:, overview:) ->
          actor.continue(
            Book(
              ..book,
              overviews: dict.insert(book.overviews, session, overview),
            ),
          )
        Note(line:) -> actor.continue(Book(..book, lines: [line, ..book.lines]))
        ReadOverview(session:, reply:) -> {
          process.send(
            reply,
            option.from_result(dict.get(book.overviews, session)),
          )
          actor.continue(book)
        }
        Lines(reply:) -> {
          process.send(reply, list.reverse(book.lines))
          actor.continue(book)
        }
      }
    })
    |> actor.start
    as "the world starts"
  started.data
}

fn lines(world: Subject(World)) -> List(String) {
  process.call(world, waiting: 1000, sending: Lines)
}

fn resting() -> relayed_session.Overview {
  Overview(
    doing: peer_mail.Resting,
    updated_at: None,
    pending: [],
    children: [],
  )
}

// The endpoint a resident session publishes. Each answer is recorded with the
// session it came from, and the overview is whatever the test put for it.
fn endpoint_for(world: Subject(World), id: String) -> Endpoint {
  Endpoint(
    overview: fn(ceiling) {
      process.send(
        world,
        Note(
          "overview "
          <> id
          <> " ceiling "
          <> string.inspect(option.is_some(ceiling)),
        ),
      )
      case
        process.call(world, waiting: 1000, sending: fn(reply) {
          ReadOverview(id, reply)
        })
      {
        Some(found) -> Ok(found)
        None -> Ok(resting())
      }
    },
    send: fn(message_id, text) {
      process.send(
        world,
        Note("send " <> id <> " " <> message_id <> " " <> text),
      )
      Ok(json.String("landed " <> message_id))
    },
    history: fn(cursor, limit) {
      process.send(
        world,
        Note(
          "history "
          <> id
          <> " "
          <> int.to_string(cursor)
          <> " "
          <> int.to_string(limit),
        ),
      )
      Ok(json.Int(cursor))
    },
    stop: fn() {
      process.send(world, Note("stop " <> id))
      Ok(Nil)
    },
    resolve: fn(terms, escalation_id, _decision, seq, _decider) {
      process.send(
        world,
        Note(
          "resolve "
          <> id
          <> " "
          <> terms.spawner
          <> " "
          <> escalation_id
          <> " "
          <> int.to_string(seq)
          <> " ceiling "
          <> string.inspect(option.is_some(terms.ceiling)),
        ),
      )
      Ok(remote_escalation.Forgotten)
    },
  )
}

// --- the rig ----------------------------------------------------------------------------

type Rig {
  Rig(
    store: catalogue.Catalogue,
    registry: manager.Manager(Endpoint),
    world: Subject(World),
    port: Address(Message),
    directory: String,
    configuration_path: String,
    spawner: spawners.Spawner,
  )
}

fn own_node() -> String {
  atom.to_string(node.name(node.self()))
}

fn scratch(label: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the working directory is known"
  let directory =
    here
    <> "/build/test_db/top-host-"
    <> label
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let _ = simplifile.delete(directory)
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "the scratch directory is made"
  directory
}

// A rig with this `top_level` table text, starting from now `now`.
fn rig_with(label: String, spawner_text: String, now: Int) -> Rig {
  let directory = scratch(label)
  let text = configuration <> spawner_text
  let configuration_path = directory <> "/loom.toml"
  let assert Ok(Nil) = simplifile.write(configuration_path, text)
    as "the configuration is written"
  let assert Ok(configured) = spawners.parse(text) as "the spawner table parses"
  let assert [spawner] = configured
  let spawner = spawners.Spawner(..spawner, node: own_node())
  let assert Ok(store) = catalogue.open(directory <> "/catalogue.db")
    as "catalogue opens"
  let world = start_world()
  let assert Ok(registry) =
    manager.start(
      store,
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(record, _domain, _services, _owner, _registry) {
          Ok(endpoint_for(world, record.id))
        },
        drain: fn(_, _) { Nil },
        fatal: fn(_) { [] },
      ),
      epoch: "top-host-test",
      limit: 32,
    )
    as "the registry starts"
  let rig =
    Rig(
      store:,
      registry:,
      world:,
      port: address.Address(node: node.self(), name: process.new_name("unused")),
      directory:,
      configuration_path:,
      spawner:,
    )
  Rig(..rig, port: port_at(rig, now))
}

fn rig(label: String) -> Rig {
  rig_with(label, table, 1_700_000_000_000)
}

// A second port over the same registry, with its own clock, which is how a test
// moves the rolling hour.
fn port_at(rig: Rig, now: Int) -> Address(Message) {
  let context =
    top_host.Context(
      spawners: [rig.spawner],
      registry: rig.registry,
      endpoint: fn(endpoint) { endpoint },
      sessions_directory: rig.directory,
      domain_configuration: rig.configuration_path,
      generator: fn() {
        ids.generator(clock.fixed(at: now), ffi_os.unique_positive_integer())
      },
      now_ms: fn() { now },
      has_executor: fn(name) { name == "exec" },
      has_pool: fn(name) { name == "linux" },
      survey: fn() {
        deployment.Placements(
          executors: [
            deployment.ExecutorEntry(
              executor: executors.plain("exec", "runner@100.64.0.7"),
              health: deployment.Reachable,
              report: None,
            ),
          ],
          pools: [
            deployment.PoolEntry(name: "linux", executors: ["exec"], eligible: [
              "exec",
            ]),
          ],
        )
      },
      check_folder: fn(path) {
        case path {
          "/srv/work" -> Ok("/srv/work")
          "/srv/old" -> Ok("/srv/old")
          other ->
            case string.starts_with(other, "/long/") {
              True -> Ok(other)
              False -> Error("That is not a folder you can use.")
            }
        }
      },
      record: fn(session) {
        process.send(rig.world, Note("record " <> session))
        Ok(Nil)
      },
      covered: fn() { process.send(rig.world, Note("covered")) },
    )
  let name = process.new_name("orchestrator_port")
  let assert Ok(_) =
    orchestrator_port.start_with_top(
      name,
      fn(_session) { Ok(orchestrator_port.NotOwned) },
      fn(_session, _command) { Error(orchestrator_port.peer_unserved) },
      fn(_session) { Error("not_found") },
      orchestrator_port.declining(),
      orchestrator_port.refusing_spawns(),
      orchestrator_port.refusing_children(),
      orchestrator_port.unheld,
      orchestrator_port.unreported(),
      top_host.host(context),
    )
    as "the port starts"
  address.Address(node: node.self(), name:)
}

fn unknown() -> Result(a, remote_top.Refusal) {
  Error(remote_top.UnknownSpawner(own_node()))
}

fn off() -> Result(a, remote_top.Refusal) {
  Error(remote_top.TopLevelOff)
}

fn not_relayed() -> Result(a, remote_top.Refusal) {
  Error(remote_top.NotRelayed)
}

fn request(n: Int) -> String {
  "0198c0de-0000-7000-8000-" <> int.to_string(100_000_000_000 + n)
}

fn on_exec() -> remote_top.Placement {
  remote_top.Workspace(executor: "exec", name: "repo")
}

fn create(
  rig: Rig,
  n: Int,
) -> Result(Result(String, remote_top.Refusal), orchestrator_port.Silence) {
  orchestrator_port.ask_top_create(
    rig.port,
    request(n),
    on_exec(),
    "alt",
    None,
    answers_within_ms,
  )
}

fn made(rig: Rig, n: Int) -> String {
  let assert Ok(Ok(session)) = create(rig, n)
    as "the create is answered with a session"
  session
}

fn resident(rig: Rig, session: String) -> Nil {
  let assert poll.Answered(_) =
    poll.until(within: 5000, every: 20, attempt: fn() {
      case manager.get(rig.registry, session) {
        Ok(manager.View(status: manager.Resident(_), ..)) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "the session becomes resident"
  Nil
}

fn stopped(rig: Rig, session: String) -> Nil {
  let assert Ok(_) = manager.stop_session(rig.registry, session)
  let assert poll.Answered(_) =
    poll.until(within: 5000, every: 20, attempt: fn() {
      case manager.get(rig.registry, session) {
        Ok(manager.View(status: manager.Saved, ..)) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "the session drains to saved"
  Nil
}

fn rows(rig: Rig, after: String, limit: Int) -> List(remote_top.Row) {
  let assert Ok(Ok(json)) =
    orchestrator_port.ask_top_sessions(
      rig.port,
      after,
      limit,
      answers_within_ms,
    )
  let assert Ok(page) = remote_top.decode_page(json)
  page.rows
}

// --- judging the sender -------------------------------------------------------------------

pub fn a_node_no_spawner_names_is_refused_everything_naming_the_node_test() {
  let rig = rig("unknown")
  let elsewhere =
    top_host.host(
      top_host.Context(
        spawners: [spawners.Spawner(..rig.spawner, node: "someone@else")],
        registry: rig.registry,
        endpoint: fn(endpoint) { endpoint },
        sessions_directory: rig.directory,
        domain_configuration: rig.configuration_path,
        generator: fn() { ids.generator(clock.fixed(at: 1), 1) },
        now_ms: fn() { 1 },
        has_executor: fn(_) { True },
        has_pool: fn(_) { True },
        survey: fn() { deployment.Placements([], []) },
        check_folder: fn(path) { Ok(path) },
        record: fn(_) { Ok(Nil) },
        covered: fn() { Nil },
      ),
    )
  assert elsewhere.placements(own_node()) == unknown()
  assert elsewhere.stop(own_node(), "s") == unknown()
  assert elsewhere.archive(own_node(), "s") == unknown()
  assert elsewhere.sessions(own_node(), "", 10) == unknown()
  assert elsewhere.history(own_node(), "s", 0, 10) == unknown()
  assert elsewhere.send(own_node(), "s", "m", "hi") == unknown()
}

pub fn a_spawner_with_no_top_level_table_is_refused_all_eight_messages_test() {
  let rig = rig_with("off", "", 1_700_000_000_000)
  assert orchestrator_port.ask_placements(rig.port, answers_within_ms)
    == Ok(off())
  assert orchestrator_port.ask_top_create(
      rig.port,
      request(1),
      on_exec(),
      "alt",
      None,
      answers_within_ms,
    )
    == Ok(Error(remote_top.TopLevelOff))
  assert orchestrator_port.ask_top_sessions(rig.port, "", 10, answers_within_ms)
    == Ok(off())
  assert orchestrator_port.ask_top_history(
      rig.port,
      "s",
      0,
      10,
      answers_within_ms,
    )
    == Ok(off())
  assert orchestrator_port.ask_top_send(
      rig.port,
      "s",
      "m",
      "hi",
      answers_within_ms,
    )
    == Ok(off())
  assert orchestrator_port.ask_top_stop(rig.port, "s", answers_within_ms)
    == Ok(Error(remote_top.TopLevelOff))
  assert orchestrator_port.ask_top_archive(rig.port, "s", answers_within_ms)
    == Ok(Error(remote_top.TopLevelOff))
  assert orchestrator_port.ask_top_resolve(
      rig.port,
      "s",
      "policy-1",
      remote_escalation.Deny,
      1,
      remote_escalation.Decider(principal: "ab", name: "Ola"),
      answers_within_ms,
    )
    == Ok(Error(remote_top.TopLevelOff))

  // Nothing was reserved.
  assert catalogue.relayed_held(rig.store, "laptop") == Ok(0)
}

// --- what the page may pick --------------------------------------------------------------

// A remembered folder this daemon's own check refuses, such as one a terminal made
// outside the home directory, is not offered, because a create in it would be
// refused by the same check.
pub fn a_remembered_folder_the_check_refuses_is_not_offered_test() {
  let rig = rig("offers-checked")
  manager.remember_folder(rig.registry, "/outside/home")
  manager.remember_folder(rig.registry, "/srv/work")
  let assert poll.Answered(_) =
    poll.until(within: 3000, every: 20, attempt: fn() {
      case manager.recent_folders(rig.registry) {
        Ok([_, _, ..]) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
  let assert Ok(Ok(json)) =
    orchestrator_port.ask_placements(rig.port, answers_within_ms)
  let assert Ok(offers) = remote_top.decode_offers(json)

  assert offers.folders
    == [remote_top.FolderOffer(path: "/srv/work", label: "work")]
}

pub fn the_offers_are_what_the_table_lists_and_this_daemon_remembers_test() {
  let rig = rig("offers")
  manager.remember_folder(rig.registry, "/srv/work")
  let assert poll.Answered(_) =
    poll.until(within: 3000, every: 20, attempt: fn() {
      case manager.recent_folders(rig.registry) {
        Ok([_, ..]) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
  let assert Ok(Ok(json)) =
    orchestrator_port.ask_placements(rig.port, answers_within_ms)
  let assert Ok(offers) = remote_top.decode_offers(json)
  assert offers.folders
    == [remote_top.FolderOffer(path: "/srv/work", label: "work")]
  assert list.map(offers.executors, fn(offer) { #(offer.name, offer.state) })
    == [#("exec", remote_top.Ready)]
  assert list.map(offers.pools, fn(offer) { #(offer.name, offer.ready) })
    == [#("linux", 1)]

  // The table lists one profile, and the daemon has two.
  assert offers.profiles == ["alt"]
  assert offers.models == ["base", "fast"]
}

pub fn a_table_with_no_profiles_key_offers_every_profile_and_no_folders_test() {
  let rig =
    rig_with(
      "all-profiles",
      "
[spawners.laptop.top_level]
executors = [\"exec\"]
folders = \"none\"
",
      1_700_000_000_000,
    )
  manager.remember_folder(rig.registry, "/srv/work")
  let assert Ok(Ok(json)) =
    orchestrator_port.ask_placements(rig.port, answers_within_ms)
  let assert Ok(offers) = remote_top.decode_offers(json)
  assert offers.folders == []
  assert offers.profiles == ["alt", "other"]
  assert offers.pools == []
}

// --- a create judged against the table ------------------------------------------------------

fn refused_create(
  rig: Rig,
  placement: remote_top.Placement,
  profile: String,
  model: Option(String),
) -> Result(String, remote_top.Refusal) {
  let assert Ok(answer) =
    orchestrator_port.ask_top_create(
      rig.port,
      request(90),
      placement,
      profile,
      model,
      answers_within_ms,
    )
  answer
}

pub fn every_key_of_the_table_refuses_a_request_outside_it_and_reserves_nothing_test() {
  let rig = rig("refusals")
  manager.remember_folder(rig.registry, "/srv/work")
  let assert poll.Answered(_) =
    poll.until(within: 3000, every: 20, attempt: fn() {
      case manager.recent_folders(rig.registry) {
        Ok([_, ..]) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })

  // executors, pools: a name the table does not list, or this daemon lacks.
  assert refused_create(
      rig,
      remote_top.Workspace(executor: "other", name: "repo"),
      "alt",
      None,
    )
    == Error(remote_top.NotOffered(remote_top.OfferedExecutor, "other"))
  assert refused_create(
      rig,
      remote_top.Pooled(pool: "mac", name: "repo"),
      "alt",
      None,
    )
    == Error(remote_top.NotOffered(remote_top.OfferedPool, "mac"))

  // folders: one this daemon does not remember, and one it remembers but the
  // folder checks refuse.
  assert refused_create(rig, remote_top.Folder("/srv/never"), "alt", None)
    == Error(remote_top.NotOffered(remote_top.OfferedFolder, "/srv/never"))
  manager.remember_folder(rig.registry, "/srv/gone")
  let assert poll.Answered(_) =
    poll.until(within: 3000, every: 20, attempt: fn() {
      case manager.recent_folders(rig.registry) {
        Ok([_, _, ..]) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
  assert refused_create(rig, remote_top.Folder("/srv/gone"), "alt", None)
    == Error(remote_top.InvalidArgument(
      reason: "That is not a folder you can use.",
    ))

  // profiles, models: outside the table's list, or unknown to the catalogue.
  assert refused_create(rig, on_exec(), "other", None)
    == Error(remote_top.NotOffered(remote_top.OfferedProfile, "other"))
  assert refused_create(rig, on_exec(), "alt", Some("slow"))
    == Error(remote_top.NotOffered(remote_top.OfferedModel, "slow"))

  // A workspace name and a request id outside their grammars.
  let assert Error(remote_top.InvalidArgument(..)) =
    refused_create(
      rig,
      remote_top.Workspace(executor: "exec", name: "a/b"),
      "alt",
      None,
    )
  let assert Ok(Error(remote_top.InvalidArgument(..))) =
    orchestrator_port.ask_top_create(
      rig.port,
      "not a request id",
      on_exec(),
      "alt",
      None,
      answers_within_ms,
    )

  // Nothing was reserved, and no cap was charged.
  assert catalogue.relayed_held(rig.store, "laptop") == Ok(0)
  assert catalogue.relayed_since(rig.store, "laptop", 0) == Ok(0)
  assert list.filter(lines(rig.world), string.starts_with(_, "record")) == []
}

pub fn a_table_with_folders_none_refuses_every_folder_test() {
  let rig =
    rig_with(
      "no-folders",
      "
[spawners.laptop.top_level]
executors = [\"exec\"]
folders = \"none\"
profiles = [\"alt\"]
",
      1_700_000_000_000,
    )
  manager.remember_folder(rig.registry, "/srv/work")
  assert refused_create(rig, remote_top.Folder("/srv/work"), "alt", None)
    == Error(remote_top.NotOffered(remote_top.OfferedFolder, "/srv/work"))
}

// --- a create that is allowed --------------------------------------------------------------------

pub fn a_create_reserves_makes_the_session_and_records_it_test() {
  let rig = rig("create")
  let session = made(rig, 1)
  resident(rig, session)

  // The registry holds the registration the table's placement describes, and
  // the relayed row names the session for the spawner and the request.
  let assert Ok(manager.View(registration:, ..)) =
    manager.get(rig.registry, session)
  assert registration.executor == "exec"
  assert registration.workspace == "repo"
  assert registration.profile == Some("alt")
  assert registration.state == catalogue.Saved
  let assert Ok(Some(row)) = manager.relayed_of(rig.registry, session)
  assert row.spawner == "laptop"
  assert row.request_id == request(1)

  // A registered workspace is recorded in the session directory before it is
  // served, and a folder is not.
  assert lines(rig.world)
    |> list.filter(string.starts_with(_, "record"))
    == ["record " <> session]
}

pub fn a_folder_create_remembers_the_folder_and_tells_the_movers_test() {
  let rig = rig("folder")
  manager.remember_folder(rig.registry, "/srv/work")
  let assert poll.Answered(_) =
    poll.until(within: 3000, every: 20, attempt: fn() {
      case manager.recent_folders(rig.registry) {
        Ok([_, ..]) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
  let assert Ok(Ok(session)) =
    orchestrator_port.ask_top_create(
      rig.port,
      request(2),
      remote_top.Folder("/srv/work"),
      "alt",
      Some("fast"),
      answers_within_ms,
    )
  resident(rig, session)
  let assert Ok(manager.View(registration:, ..)) =
    manager.get(rig.registry, session)
  assert registration.workspace == "/srv/work"
  assert registration.executor == ""
  assert registration.model == Some("fast")
  assert lines(rig.world) |> list.contains("covered")
  assert lines(rig.world)
    |> list.filter(string.starts_with(_, "record"))
    == []
}

pub fn a_pooled_create_names_the_pool_and_no_executor_test() {
  let rig = rig("pooled")
  let assert Ok(Ok(session)) =
    orchestrator_port.ask_top_create(
      rig.port,
      request(3),
      remote_top.Pooled(pool: "linux", name: "repo"),
      "alt",
      None,
      answers_within_ms,
    )
  resident(rig, session)
  let assert Ok(manager.View(registration:, ..)) =
    manager.get(rig.registry, session)
  assert registration.pool == "linux"
  assert registration.workspace == "repo"
}

pub fn a_resent_create_answers_the_same_session_and_makes_no_other_test() {
  let rig = rig("resend")
  let first = made(rig, 1)
  resident(rig, first)
  let assert Ok(Ok(again)) = create(rig, 1)
  assert again == first
  assert catalogue.relayed_held(rig.store, "laptop") == Ok(1)

  // Even after the session was stopped, the resend answers it.
  stopped(rig, first)
  let assert Ok(Ok(later)) = create(rig, 1)
  assert later == first
  assert catalogue.relayed_held(rig.store, "laptop") == Ok(1)
  assert catalogue.relayed_since(rig.store, "laptop", 0) == Ok(1)
}

pub fn a_create_resent_after_the_transaction_and_before_the_store_finishes_it_test() {
  let rig = rig("finish")

  // The transaction commits and the daemon goes no further, as it would if it
  // crashed between the reservation and the store.
  let creation =
    manager.Creation(
      request_key: catalogue.relayed_key("laptop", request(7)),
      workspace: "repo",
      name: "laptop session",
      configuration: "",
      profile: Some("alt"),
      model: None,
      executor: "exec",
      pool: "",
    )
  let assert Ok(manager.Relaying(session_id:, state:)) =
    manager.reserve_relayed(
      rig.registry,
      manager.RelayRequest(
        spawner: "laptop",
        request_id: request(7),
        creation:,
        directory: rig.directory,
        generator: ids.generator(clock.fixed(at: 5), 7),
        configuration: rig.configuration_path,
        limits: catalogue.RelayedLimits(
          max_sessions: 3,
          max_per_hour: 100,
          now_ms: 1_700_000_000_000,
        ),
      ),
    )
  assert state == catalogue.Reserved
  let assert Ok(manager.View(status: manager.Reserved, ..)) =
    manager.get(rig.registry, session_id)

  // The listing shows the unfinished session, idle, and it counts against the
  // cap.
  let assert [unfinished] = rows(rig, "", 10)
  assert unfinished.session_id == session_id
  assert unfinished.request_id == request(7)
  assert unfinished.activity == remote_top.Idle
  assert catalogue.relayed_held(rig.store, "laptop") == Ok(1)

  // A message to it is told to send the create again, and opens nothing.
  let assert Ok(Error(remote_top.NotYetOpen(..))) =
    orchestrator_port.ask_top_send(
      rig.port,
      session_id,
      "m1",
      "hello",
      answers_within_ms,
    )

  // The resent create answers the same session and finishes it.
  let assert Ok(Ok(answered)) = create(rig, 7)
  assert answered == session_id
  resident(rig, session_id)
  assert catalogue.relayed_held(rig.store, "laptop") == Ok(1)
}

// --- the two caps ---------------------------------------------------------------------------------

fn collect(results: Subject(a), count: Int) -> List(a) {
  list.map(list.repeat(0, count), fn(_) {
    let assert Ok(one) = process.receive(results, 20_000)
    one
  })
}

pub fn concurrent_creates_at_the_cap_let_exactly_the_cap_through_test() {
  let rig = rig("cap")
  let results = process.new_subject()
  let attempts = [1, 2, 3, 4, 5, 6, 7, 8]
  list.each(attempts, fn(n) {
    process.spawn(fn() { process.send(results, create(rig, n)) })
  })
  let outcomes = collect(results, 8)
  let made =
    list.filter(outcomes, fn(outcome) {
      case outcome {
        Ok(Ok(_)) -> True
        _ -> False
      }
    })
  let capped =
    list.filter(outcomes, fn(outcome) {
      outcome
      == Ok(Error(remote_top.CapReached(cap: remote_top.MaxSessions, limit: 3)))
    })
  assert list.length(made) == 3
  assert list.length(capped) == 5
  assert catalogue.relayed_held(rig.store, "laptop") == Ok(3)
}

pub fn archiving_frees_a_place_and_a_resent_capped_create_is_not_made_twice_test() {
  let rig = rig("archive-frees")
  let first = made(rig, 1)
  let _second = made(rig, 2)
  let _third = made(rig, 3)
  assert create(rig, 4)
    == Ok(Error(remote_top.CapReached(cap: remote_top.MaxSessions, limit: 3)))
  resident(rig, first)

  assert orchestrator_port.ask_top_archive(rig.port, first, answers_within_ms)
    == Ok(Ok(Nil))
  assert catalogue.relayed_held(rig.store, "laptop") == Ok(2)
  let fourth = made(rig, 4)
  assert fourth != first

  // The archive is idempotent: the same message again is the same answer.
  assert orchestrator_port.ask_top_archive(rig.port, first, answers_within_ms)
    == Ok(Ok(Nil))
}

pub fn the_hourly_cap_counts_the_rolling_hour_on_the_box_test() {
  let rig =
    rig_with(
      "hourly",
      "
[spawners.laptop.top_level]
executors = [\"exec\"]
profiles = [\"alt\"]
max_sessions = 50
max_per_hour = 2
",
      1_700_000_000_000,
    )
  let _ = made(rig, 1)
  let _ = made(rig, 2)
  assert create(rig, 3)
    == Ok(Error(remote_top.CapReached(cap: remote_top.MaxPerHour, limit: 2)))

  // An hour and a millisecond later the window has passed.
  let later = Rig(..rig, port: port_at(rig, 1_700_000_000_000 + 3_600_001))
  let assert Ok(Ok(_)) = create(later, 3)
}

// --- listing ----------------------------------------------------------------------------------------

pub fn a_page_lists_newest_first_with_the_request_id_and_continues_after_a_row_test() {
  let rig =
    rig_with(
      "page",
      "
[spawners.laptop.top_level]
executors = [\"exec\"]
profiles = [\"alt\"]
max_sessions = 10
",
      1_700_000_000_000,
    )
  let sessions = list.map([1, 2, 3, 4, 5], fn(n) { #(n, made(rig, n)) })
  let newest_first = list.sort(sessions, fn(a, b) { string.compare(b.1, a.1) })
  let first = rows(rig, "", 2)
  assert list.map(first, fn(row) { row.session_id })
    == list.map(list.take(newest_first, 2), fn(pair) { pair.1 })
  assert list.map(first, fn(row) { row.request_id })
    == list.map(list.take(newest_first, 2), fn(pair) { request(pair.0) })
  let assert Ok(last) = list.last(first)
  let rest = rows(rig, last.session_id, 10)
  assert list.map(rest, fn(row) { row.session_id })
    == list.map(list.drop(newest_first, 2), fn(pair) { pair.1 })

  // The page says whether more may follow.
  let assert Ok(Ok(json)) =
    orchestrator_port.ask_top_sessions(rig.port, "", 2, answers_within_ms)
  let assert Ok(page) = remote_top.decode_page(json)
  assert page.more == remote_top.Further
  let assert Ok(Ok(json)) =
    orchestrator_port.ask_top_sessions(rig.port, "", 50, answers_within_ms)
  let assert Ok(all) = remote_top.decode_page(json)
  assert all.more == remote_top.Last
  assert list.length(all.rows) == 5
}

fn record(seq: Int, preview: String) -> protocol.EscalationRecord {
  protocol.EscalationRecord(
    escalation_id: "policy-" <> int.to_string(seq),
    op: "op",
    strand: "main",
    status: "pending",
    tool: "bash",
    action: "digest",
    preview:,
    asked: 1,
    denial: None,
    seq:,
    origin: None,
    placement: None,
    admitted: Some([]),
  )
}

pub fn a_row_carries_the_oldest_eight_requests_by_seq_and_counts_the_rest_test() {
  let rig = rig("requests")
  let session = made(rig, 1)
  resident(rig, session)
  process.send(
    rig.world,
    Put(
      session,
      Overview(
        doing: peer_mail.NeedsAnswer,
        updated_at: Some(1234),
        pending: list.map([9, 3, 12, 1, 7, 5, 11, 2, 8, 4, 10, 6], fn(seq) {
          record(seq, "x")
        }),
        children: [],
      ),
    ),
  )
  let assert [row] = rows(rig, "", 10)
  assert row.activity == remote_top.NeedsYou
  assert row.updated_at == 1234
  assert list.map(row.requests, fn(r) { r.seq }) == [1, 2, 3, 4, 5, 6, 7, 8]
  assert row.more == 4
  assert row.placement == remote_top.Workspace(executor: "exec", name: "repo")
}

pub fn a_page_is_cut_at_the_byte_bound_and_a_row_is_whole_or_absent_test() {
  let rig =
    rig_with(
      "bytes",
      "
[spawners.laptop.top_level]
executors = [\"exec\"]
profiles = [\"alt\"]
max_sessions = 40
max_per_hour = 100
",
      1_700_000_000_000,
    )
  let large = string.repeat("p", 4000)
  let sessions =
    list.index_map(list.repeat(0, 20), fn(_, index) { made(rig, index + 1) })
  list.each(sessions, fn(session) {
    process.send(
      rig.world,
      Put(
        session,
        Overview(
          doing: peer_mail.NeedsAnswer,
          updated_at: None,
          pending: list.map([1, 2, 3, 4, 5, 6, 7, 8, 9], fn(seq) {
            record(seq, large)
          }),
          children: [],
        ),
      ),
    )
  })
  list.each(sessions, fn(session) { resident(rig, session) })
  let assert Ok(Ok(wire)) =
    orchestrator_port.ask_top_sessions(rig.port, "", 64, answers_within_ms)
  assert string.byte_size(json.to_string(wire)) <= remote_top.max_page_bytes
  let assert Ok(page) = remote_top.decode_page(wire)
  assert page.more == remote_top.Further
  assert list.length(page.rows) < 20
  assert page.rows != []

  // Every row on the page is whole: its requests and its count account for
  // all nine, and none was cut in half.
  list.each(page.rows, fn(row) {
    assert list.length(row.requests) + row.more == 9
  })

  // The next page continues after the last row and no row is lost or repeated.
  let assert Ok(last) = list.last(page.rows)
  let next = rows(rig, last.session_id, 64)
  assert list.all(next, fn(row) {
    string.compare(row.session_id, last.session_id) == order.Lt
  })
  assert list.length(page.rows) + list.length(next) <= 20
}

pub fn a_saved_session_is_listed_idle_with_no_requests_and_is_not_opened_test() {
  let rig = rig("saved")
  let session = made(rig, 1)
  resident(rig, session)
  process.send(
    rig.world,
    Put(
      session,
      Overview(
        doing: peer_mail.NeedsAnswer,
        updated_at: None,
        pending: [record(1, "x")],
        children: [],
      ),
    ),
  )
  let assert [live] = rows(rig, "", 10)
  assert live.activity == remote_top.NeedsYou
  stopped(rig, session)
  let assert [saved] = rows(rig, "", 10)
  assert saved.activity == remote_top.Idle
  assert saved.requests == []
  let assert Ok(manager.View(status: manager.Saved, ..)) =
    manager.get(rig.registry, session)
}

pub fn an_archived_session_is_listed_archived_and_the_first_prompt_names_it_test() {
  let rig = rig("named")
  let session = made(rig, 1)
  resident(rig, session)
  let assert Ok(Ok(_)) =
    orchestrator_port.ask_top_send(
      rig.port,
      session,
      "m1",
      "fix the flaky test in the scheduler",
      answers_within_ms,
    )
  let assert poll.Answered(_) =
    poll.until(within: 3000, every: 20, attempt: fn() {
      case rows(rig, "", 10) {
        [row] if row.name != "laptop session" -> poll.Done(row.name)
        _ -> poll.Retry
      }
    })
    as "the first prompt becomes the name"
  assert orchestrator_port.ask_top_archive(rig.port, session, answers_within_ms)
    == Ok(Ok(Nil))

  // The laptop never shows an archived session, so the box does not list it.
  assert rows(rig, "", 10) == []
}

// --- messages about a session -----------------------------------------------------------------------

pub fn a_session_that_is_not_relayed_for_the_spawner_is_not_relayed_test() {
  let rig = rig("not-relayed")

  // A session the owner started, and one another spawner started.
  let owners = owner_session(rig)
  let other = other_spawner_session(rig)
  list.each([owners, other, "0198c0de-0000-7000-8000-ffffffffffff"], fn(id) {
    assert orchestrator_port.ask_top_stop(rig.port, id, answers_within_ms)
      == Ok(not_relayed())
    assert orchestrator_port.ask_top_archive(rig.port, id, answers_within_ms)
      == Ok(not_relayed())
    assert orchestrator_port.ask_top_history(
        rig.port,
        id,
        0,
        10,
        answers_within_ms,
      )
      == Ok(Error(remote_top.NotRelayed))
    assert orchestrator_port.ask_top_send(
        rig.port,
        id,
        "m",
        "hi",
        answers_within_ms,
      )
      == Ok(Error(remote_top.NotRelayed))
    assert orchestrator_port.ask_top_resolve(
        rig.port,
        id,
        "policy-1",
        remote_escalation.Deny,
        1,
        remote_escalation.Decider(principal: "ab", name: "Ola"),
        answers_within_ms,
      )
      == Ok(not_relayed())
  })

  // The owner's session and the other spawner's are not in this spawner's list,
  // and neither was opened.
  assert rows(rig, "", 10) == []
  assert list.filter(lines(rig.world), string.starts_with(_, "send")) == []
}

fn owner_session(rig: Rig) -> String {
  let assert Ok(view) =
    manager.create_scoped(
      rig.registry,
      manager.Creation(
        request_key: "owner-key",
        workspace: "repo",
        name: "owner",
        configuration: "",
        profile: None,
        model: None,
        executor: "exec",
        pool: "",
      ),
      directory: rig.directory,
      generator: ids.generator(clock.fixed(at: 9), 9),
      scope: domain.SessionOnly,
      configuration: "",
    )
  view.registration.id
}

fn other_spawner_session(rig: Rig) -> String {
  let creation =
    manager.Creation(
      request_key: catalogue.relayed_key("desk", request(40)),
      workspace: "repo",
      name: "desk session",
      configuration: "",
      profile: None,
      model: None,
      executor: "exec",
      pool: "",
    )
  let assert Ok(manager.Relaying(session_id:, ..)) =
    manager.reserve_relayed(
      rig.registry,
      manager.RelayRequest(
        spawner: "desk",
        request_id: request(40),
        creation:,
        directory: rig.directory,
        generator: ids.generator(clock.fixed(at: 8), 8),
        configuration: rig.configuration_path,
        limits: catalogue.RelayedLimits(
          max_sessions: 5,
          max_per_hour: 5,
          now_ms: 1,
        ),
      ),
    )
  session_id
}

pub fn a_message_reaches_the_sessions_endpoint_and_a_saved_session_is_opened_first_test() {
  let rig = rig("drive")
  let session = made(rig, 1)
  resident(rig, session)

  assert orchestrator_port.ask_top_send(
      rig.port,
      session,
      "m1",
      "hello",
      answers_within_ms,
    )
    == Ok(Ok(json.String("landed m1")))
  assert orchestrator_port.ask_top_history(
      rig.port,
      session,
      41,
      20,
      answers_within_ms,
    )
    == Ok(Ok(json.Int(41)))
  assert orchestrator_port.ask_top_stop(rig.port, session, answers_within_ms)
    == Ok(Ok(Nil))

  // A stop of a session that is saved has nothing to stop and opens nothing.
  stopped(rig, session)
  assert orchestrator_port.ask_top_stop(rig.port, session, answers_within_ms)
    == Ok(Ok(Nil))
  let assert Ok(manager.View(status: manager.Saved, ..)) =
    manager.get(rig.registry, session)

  // A send to it opens it first, and reaches the endpoint of the new
  // incarnation.
  assert orchestrator_port.ask_top_send(
      rig.port,
      session,
      "m2",
      "again",
      answers_within_ms,
    )
    == Ok(Ok(json.String("landed m2")))
  let assert Ok(manager.View(status: manager.Resident(_), ..)) =
    manager.get(rig.registry, session)
  assert lines(rig.world)
    |> list.filter(string.starts_with(_, "send"))
    == ["send " <> session <> " m1 hello", "send " <> session <> " m2 again"]
}

pub fn a_decision_reaches_the_endpoint_with_the_spawner_and_its_ceiling_test() {
  let rig = rig("resolve")
  let session = made(rig, 1)
  resident(rig, session)
  assert orchestrator_port.ask_top_resolve(
      rig.port,
      session,
      "policy-1",
      remote_escalation.Deny,
      4,
      remote_escalation.Decider(principal: "ab", name: "Ola"),
      answers_within_ms,
    )
    == Ok(Ok(remote_escalation.Forgotten))
  assert lines(rig.world)
    |> list.filter(string.starts_with(_, "resolve"))
    == ["resolve " <> session <> " laptop policy-1 4 ceiling True"]

  // A saved session is opened to be judged in its hub's turn.
  stopped(rig, session)
  let assert Ok(Ok(_)) =
    orchestrator_port.ask_top_resolve(
      rig.port,
      session,
      "policy-2",
      remote_escalation.Deny,
      5,
      remote_escalation.Decider(principal: "ab", name: "Ola"),
      answers_within_ms,
    )
  let assert Ok(manager.View(status: manager.Resident(_), ..)) =
    manager.get(rig.registry, session)
}

pub fn a_table_with_no_ceiling_hands_the_hub_no_ceiling_test() {
  let rig =
    rig_with(
      "no-ceiling",
      "
[spawners.laptop.top_level]
executors = [\"exec\"]
profiles = [\"alt\"]
",
      1_700_000_000_000,
    )
  let session = made(rig, 1)
  resident(rig, session)
  let assert Ok(Ok(_)) =
    orchestrator_port.ask_top_resolve(
      rig.port,
      session,
      "policy-1",
      remote_escalation.Deny,
      4,
      remote_escalation.Decider(principal: "ab", name: "Ola"),
      answers_within_ms,
    )
  assert lines(rig.world)
    |> list.filter(string.starts_with(_, "resolve"))
    == ["resolve " <> session <> " laptop policy-1 4 ceiling False"]
}

pub fn a_message_to_an_archived_session_is_refused_not_opened_test() {
  let rig = rig("archived")
  let session = made(rig, 1)
  resident(rig, session)
  assert orchestrator_port.ask_top_archive(rig.port, session, answers_within_ms)
    == Ok(Ok(Nil))
  let assert Ok(Error(remote_top.InvalidArgument(..))) =
    orchestrator_port.ask_top_send(
      rig.port,
      session,
      "m1",
      "hello",
      answers_within_ms,
    )
  assert list.filter(lines(rig.world), string.starts_with(_, "send")) == []
}

pub fn deleting_a_session_removes_its_row_and_frees_the_place_test() {
  let rig = rig("deleted")
  let first = made(rig, 1)
  let _ = made(rig, 2)
  let _ = made(rig, 3)
  stopped(rig, first)

  // An external deletion owns a connection of its own. The registry may still
  // be confirming the other creations on its connection after this one stops.
  let assert Ok(external) = catalogue.open(rig.directory <> "/catalogue.db")
    as "the external deleter opens its own catalogue connection"
  let deleted = catalogue.delete(external, first)
  assert catalogue.close(external) == Ok(Nil)
    as "the external connection closes before the deletion result is asserted"
  let assert Ok(_) = deleted
  assert manager.relayed_of(rig.registry, first) == Ok(None)
  let _fourth = made(rig, 4)
}

pub fn an_over_long_remembered_folder_is_not_offered_or_started_in_and_breaks_no_page_test() {
  let rig = rig("long-folder")
  let long = "/long/" <> string.repeat("d", 600)
  manager.remember_folder(rig.registry, long)
  manager.remember_folder(rig.registry, "/srv/work")
  let assert poll.Answered(_) =
    poll.until(within: 3000, every: 20, attempt: fn() {
      case manager.recent_folders(rig.registry) {
        Ok([_, _, ..]) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })

  // The offers leave it out and still decode.
  let assert Ok(Ok(json)) =
    orchestrator_port.ask_placements(rig.port, answers_within_ms)
  let assert Ok(offers) = remote_top.decode_offers(json)
  assert offers.folders
    == [remote_top.FolderOffer(path: "/srv/work", label: "work")]

  // A create there is refused, and nothing is reserved.
  let assert Error(remote_top.InvalidArgument(..)) =
    refused_create(rig, remote_top.Folder(long), "alt", None)
  assert catalogue.relayed_held(rig.store, "laptop") == Ok(0)
}

pub fn a_session_listing_is_active_only_and_old_active_ones_stay_on_the_page_test() {
  let rig =
    rig_with(
      "active-only",
      "
[spawners.laptop.top_level]
executors = [\"exec\"]
profiles = [\"alt\"]
max_sessions = 3
max_per_hour = 100
",
      1_700_000_000_000,
    )
  let oldest = made(rig, 1)
  resident(rig, oldest)
  list.each([2, 3, 4, 5], fn(n) {
    let session = made(rig, n)
    resident(rig, session)
    assert orchestrator_port.ask_top_archive(
        rig.port,
        session,
        answers_within_ms,
      )
      == Ok(Ok(Nil))
  })
  let listed = rows(rig, "", 64)
  assert list.map(listed, fn(row) { row.session_id }) == [oldest]
}
