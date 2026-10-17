//// The daemon's release drainer, end to end over the real registry
//// (protocol-change/084, phase 2): deleting a parent session that started a
//// child elsewhere leaves a row, the registry's bell wakes the drainer, the
//// drainer tells the other orchestrator, and the row is settled only when that
//// orchestrator answers.
////
//// The drainer's timer is a fake wheel the test steps by hand, so the fixed
//// five second retry costs the test nothing and the number of passes is exactly
//// the number of steps.

import client/daemon/domain as domain_service
import client/daemon/manager
import client/internal/ffi_os
import client/peer_outbox_drain
import client/remote_child
import client/remote_release
import core/clock
import core/ids
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import gleam/string
import simplifile
import storage/access
import storage/catalogue
import support/fake_orchestrators.{Down, Up}
import support/remote_stubs
import telemetry/log
import weft/registry as names

fn registered(
  store: catalogue.Catalogue,
  seed: Int,
) -> #(catalogue.Registration, String, access.Digest) {
  let assert Ok(cwd) = simplifile.current_directory()
    as "the catalogue accepts only absolute paths"
  let sessions =
    cwd
    <> "/build/test_db/release-drain-"
    <> int.to_string(ffi_os.unique_positive_integer())
    <> "/sessions"
  let _removed = simplifile.delete_all([sessions])
  let assert Ok(Nil) = simplifile.create_directory_all(sessions)
    as "the sessions directory exists"
  let #(id, _) =
    ids.mint_session(ids.generator(clock.fixed(at: 1_700_000_000_000), seed:))
  let id = ids.session_id_to_string(id)
  let record =
    catalogue.Registration(
      id:,
      path: sessions <> "/" <> id <> ".db",
      workspace: "/workspace/project",
      name: "parent",
      configuration: "",
      created_at: 1_700_000_000_000,
      request_key: "request-" <> int.to_string(seed),
      state: catalogue.Reserved,
      profile: option.None,
      model: option.None,
      executor: "",
      pool: "",
      subtitle: option.None,
    )
  assert catalogue.reserve(store, record) == Ok(record)
  let assert Ok(record) = catalogue.confirm(store, record.id)
    as "the parent is an ordinary saved registration"
  let assert Ok(owner) = access.credential_digest(string.repeat("a", 64))
    as "owner digest"
  let assert Ok(_) = access.bootstrap_owner(store, "owner", "Owner", owner)
    as "owner exists"
  #(record, sessions, owner)
}

fn start_registry(store: catalogue.Catalogue) -> manager.Manager(String) {
  let assert Ok(registry) =
    manager.start(
      store,
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(record, _domain, _services, _owner, _registry) {
          Ok(record.id)
        },
        drain: fn(_, _) { Nil },
        fatal: fn(_) { [] },
      ),
      epoch: "release-drain-test",
      limit: 1,
    )
    as "the registry starts"
  registry
}

// Waits for something another process does, polling at a short interval.
fn eventually(done: fn() -> Bool) -> Bool {
  eventually_within(done, 200)
}

fn eventually_within(done: fn() -> Bool, attempts: Int) -> Bool {
  case done(), attempts {
    True, _ -> True
    False, 0 -> False
    False, _ -> {
      process.sleep(10)
      eventually_within(done, attempts - 1)
    }
  }
}

pub fn a_deleted_parent_is_released_once_its_orchestrator_answers_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let #(record, sessions, owner) = registered(store, 5201)
  let registry = start_registry(store)
  let box = fake_orchestrators.start("box", Down)
  let reach = fake_orchestrators.reach(record.id, [box], fn() { True })

  // The drainer is the daemon's: one instance over the registry's rows and the
  // reach's release call. Its timer is a wheel this test turns.
  let wheel = process.new_subject()
  let options =
    peer_outbox_drain.over(
      remote_release.pass(
        fn() {
          manager.remote_releases(registry)
          |> result_text
        },
        fn(row) { manager.settle_remote_release(registry, row) |> result_text },
        reach.release,
        log.discard(),
      ),
      fn(delay, wake) { process.send(wheel, #(delay, wake)) },
    )
  let assert Ok(namespace) = names.start()
  let name = names.new_address(namespace)
  let assert Ok(_) = peer_outbox_drain.start(options, name)
  manager.on_releases_owed(registry, fn() { peer_outbox_drain.poke(name) })

  // The pass at start finds nothing owed, and the drainer goes idle with no
  // timer: a daemon that never deletes such a parent costs nothing.
  let assert Ok(#(0, first_pass)) = process.receive(wheel, 1000)
  first_pass()
  assert process.receive(wheel, 100) == Error(Nil)

  // The parent started a child on the box, and the owner deletes the parent.
  remote_stubs.write(record.path, [
    remote_stubs.stub("box", 1, remote_child.Requested),
  ])
  let assert Ok(_) =
    manager.delete_session(
      registry,
      owner,
      "release-drain-test",
      record.id,
      sessions,
    )
  assert catalogue.get(store, record.id) == Error(catalogue.Missing)

  // The bell wakes the drainer, which arms the retry interval. The box is down:
  // the release is sent, nobody answers, and the row stays.
  let assert Ok(#(5000, second_pass)) = process.receive(wheel, 1000)
  second_pass()
  assert eventually(fn() {
    list.length(fake_orchestrators.report(box).releases) == 1
  })
  let assert Ok(#(5000, third_pass)) = process.receive(wheel, 1000)
  assert list.length(owed(registry)) == 1

  // The box returns. The next pass is answered, the row is settled, and the
  // drainer goes idle again.
  fake_orchestrators.set_mode(box, Up)
  third_pass()
  assert eventually(fn() { owed(registry) == [] })
  let releases = fake_orchestrators.report(box).releases
  assert list.map(releases, fn(parent) { parent.session })
    == [record.id, record.id]
  assert process.receive(wheel, 100) == Error(Nil)
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

fn owed(registry: manager.Manager(String)) -> List(catalogue.RemoteRelease) {
  let assert Ok(rows) = manager.remote_releases(registry)
  rows
}

fn result_text(outcome: Result(a, manager.Error)) -> Result(a, String) {
  case outcome {
    Ok(value) -> Ok(value)
    Error(error) -> Error(string.inspect(error))
  }
}

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
