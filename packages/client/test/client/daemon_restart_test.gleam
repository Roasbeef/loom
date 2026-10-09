//// A profile switch restarts a resident session through a real registry and a
//// real catalogue, with only the assembly of a runtime faked. The saved profile
//// must be what the next open's builder is handed, and each failed step must
//// leave the session where `client/daemon/restart` says it does.

import broker/token
import client/daemon/domain as domain_service
import client/daemon/manager
import client/daemon/restart
import client/internal/instance_owner as custody
import core/clock
import core/ids
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import simplifile
import storage/catalogue
import storage/domain
import weft/poll

const epoch = "daemon-test"

fn saved(store: catalogue.Catalogue, seed: Int) -> catalogue.Registration {
  let generator = ids.generator(clock.fixed(at: 1_700_000_000_000), seed:)
  let #(id, _) = ids.mint_session(generator)
  let id = ids.session_id_to_string(id)
  let record =
    catalogue.Registration(
      id:,
      path: "/unopened-restart-test/" <> id <> ".db",
      workspace: "/workspace/project",
      name: "session " <> int.to_string(seed),
      configuration: "",
      created_at: 1_700_000_000_000,
      request_key: "request-" <> int.to_string(seed),
      state: catalogue.Reserved,
      profile: None,
      model: None,
      subtitle: None,
    )
  assert catalogue.reserve(store, record) == Ok(record)
  let assert Ok(record) = catalogue.confirm(store, record.id)
    as "the fixture represents initialized metadata"
  let selected =
    domain.Domain(
      domain.key(domain.SessionOnly, record.workspace, record.id),
      domain.SessionOnly,
      record.workspace,
      "",
      "/owner/aggregate/memory.db",
      "/owner/aggregate/search.db",
    )
  assert domain.bind(store, record.id, selected) == Ok(selected)
  record
}

// A registry whose `build` is told the number of the open (the first is 1) and
// the registration it was handed. The builder runs in the registry's own
// process, so the count is kept in a directory each open adds a file to.
fn started(
  store: catalogue.Catalogue,
  build: fn(Int, catalogue.Registration, custody.Owner) ->
    Result(String, String),
) -> manager.Manager(String) {
  let directory =
    "build/test_db/restart-"
    <> bit_array.base16_encode(token.production_entropy()(8))
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "the open counter's directory exists"
  let assert Ok(registry) =
    manager.start(
      store,
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(record, _domain, _services, owner, _directory) {
          let assert Ok(opened) = simplifile.read_directory(directory)
            as "the open counter reads"
          let number = list.length(opened) + 1
          let assert Ok(Nil) =
            simplifile.create_file(directory <> "/" <> int.to_string(number))
            as "the open counter counts"
          build(number, record, owner)
        },
        drain: fn(_, _) { Nil },
        fatal: fn(_) { [] },
      ),
      epoch:,
      limit: 2,
    )
    as "registry starts without invoking assembly"
  registry
}

fn await(
  registry: manager.Manager(String),
  id: String,
  expected: fn(manager.Status) -> Bool,
) -> Nil {
  let outcome =
    poll.until(within: 3000, every: 1, attempt: fn() {
      case manager.get(registry, id) {
        Ok(manager.View(status:, ..)) ->
          case expected(status) {
            True -> poll.Done(Nil)
            False -> poll.Retry
          }
        Error(error) -> poll.Fail(string.inspect(error))
      }
    })
  assert outcome == poll.Answered(Nil)
}

fn is_resident(status: manager.Status) -> Bool {
  case status {
    manager.Resident(_) -> True
    manager.Reserved
    | manager.Saved
    | manager.Opening(_)
    | manager.Stopping(_)
    | manager.RecoveryBlocked(_) -> False
  }
}

fn is_saved(status: manager.Status) -> Bool {
  case status {
    manager.Saved -> True
    manager.Reserved
    | manager.Opening(_)
    | manager.Resident(_)
    | manager.Stopping(_)
    | manager.RecoveryBlocked(_) -> False
  }
}

fn running(registry: manager.Manager(String), id: String) -> Nil {
  let assert Ok(manager.Opening(_)) = manager.open(registry, id)
    as "the session opens"
  await(registry, id, is_resident)
}

fn finish(
  registry: manager.Manager(String),
  store: catalogue.Catalogue,
) -> Nil {
  let watch = process.monitor(manager.pid(registry))
  manager.shutdown(registry)
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(2000)
    as "shutdown joins every custody scope"
  assert catalogue.close(store) == Ok(Nil)
  Nil
}

// The profile a builder was handed, reported on a subject the test reads.
fn recording(
  reported: process.Subject(#(Int, Option(String))),
) -> fn(Int, catalogue.Registration, custody.Owner) -> Result(String, String) {
  fn(number, record: catalogue.Registration, _owner) {
    process.send(reported, #(number, record.profile))
    Ok(record.id)
  }
}

// The switch's whole path at the registry: the profile is saved while the
// session runs, the restart stops and opens it again, and the second open's
// builder is handed the saved profile, which is what a resume reads.
pub fn a_saved_profile_is_what_the_restarted_session_opens_under_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record = saved(store, 1401)
  let reported = process.new_subject()
  let registry = started(store, recording(reported))
  running(registry, record.id)
  assert process.receive(reported, within: 1000) == Ok(#(1, None))

  assert manager.set_profile(registry, record.id, Some("codex")) == Ok(Nil)
  assert restart.restart(registry, record.id) == Ok(Nil)
  assert process.receive(reported, within: 1000) == Ok(#(2, Some("codex")))
  await(registry, record.id, is_resident)

  // And back to the default roles: the clear is saved the same way.
  assert manager.set_profile(registry, record.id, None) == Ok(Nil)
  assert restart.restart(registry, record.id) == Ok(Nil)
  assert process.receive(reported, within: 1000) == Ok(#(3, None))
  finish(registry, store)
}

// Saving a profile does not touch a running session: the choice is read by the
// next open, so the registry write alone leaves the incarnation in place.
pub fn saving_a_profile_leaves_the_running_session_alone_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record = saved(store, 1402)
  let reported = process.new_subject()
  let registry = started(store, recording(reported))
  running(registry, record.id)
  let assert Ok(manager.View(status: before, ..)) =
    manager.get(registry, record.id)
  assert manager.set_profile(registry, record.id, Some("codex")) == Ok(Nil)
  let assert Ok(manager.View(status: after, ..)) =
    manager.get(registry, record.id)
  assert after == before
  assert process.receive(reported, within: 100) == Ok(#(1, None))
  assert process.receive(reported, within: 100) == Error(Nil)
  finish(registry, store)
}

pub fn a_malformed_or_missing_registration_is_refused_by_the_registry_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record = saved(store, 1403)
  let registry =
    started(store, fn(_, _, _) { panic as "a refused write opens nothing" })
  let assert Error(manager.Catalogue(catalogue.Invalid(_))) =
    manager.set_profile(registry, record.id, Some("Not A Name"))
  assert manager.set_profile(registry, "absent", Some("codex"))
    == Error(manager.Catalogue(catalogue.Missing))
  finish(registry, store)
}

// A session whose reopen fails stays stopped and saved, with the profile kept
// for the next open from any client.
pub fn a_failed_reopen_leaves_the_session_saved_with_the_profile_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record = saved(store, 1404)
  let registry =
    started(store, fn(number, record, _) {
      case number {
        1 -> Ok(record.id)
        _ -> Error("assembly refused")
      }
    })
  running(registry, record.id)
  assert manager.set_profile(registry, record.id, Some("codex")) == Ok(Nil)
  assert restart.restart(registry, record.id) == Error(restart.NotReopened)
  await(registry, record.id, is_saved)
  let assert Ok(stored) = catalogue.get(store, record.id)
  assert stored.profile == Some("codex")
  finish(registry, store)
}

// The detached form reports a failure from its own process, which is how the
// daemon's log learns that a switch saved its profile and did not apply it.
pub fn begin_reports_a_failure_from_the_detached_process_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record = saved(store, 1405)
  let registry =
    started(store, fn(number, record, _) {
      case number {
        1 -> Ok(record.id)
        _ -> Error("assembly refused")
      }
    })
  running(registry, record.id)
  let failures = process.new_subject()
  restart.begin(registry, record.id, fn(failure) {
    process.send(failures, failure)
  })
  assert process.receive(failures, within: 5000) == Ok(restart.NotReopened)
  finish(registry, store)
}
