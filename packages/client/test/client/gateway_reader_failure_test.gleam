//// A stalled original SQLite actor poisons its gateway and closes admission.
//// This uses real instance custody: a reader timeout is not cancellation, and
//// the registry cannot reopen until the original storage actor resumes/drains.

import client/daemon/domain as domain_service
import client/daemon/lifetime
import client/daemon/manager
import client/gateway
import client/owned_assembly_test
import client/protocol
import client/serve
import core/clock
import core/ids
import filepath
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import simplifile
import storage/access
import storage/catalogue
import telemetry/log
import weft/poll

pub fn sqlite_read_timeout_poison_stops_original_incarnation_without_self_wait_test() {
  process.trap_exits(True)
  let settings = owned_assembly_test.settings()
  let directory = filepath.directory_name(settings.session_path)
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "the catalogue directory exists"
  let assert Ok(store) = catalogue.open(directory <> "/catalogue.db")
    as "the real catalogue opens"
  let assert Ok(lifetime) =
    lifetime.start(
      store,
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(record, _domain, _services, owner) {
          let assert Ok(id) = ids.parse_session_id(record.id)
            as "the manager reserved a canonical ID"
          serve.assemble_owned(
            serve.Settings(
              ..settings,
              session_path: record.path,
              session_id: record.id,
            ),
            id,
            log.discard(),
            owner,
          )
        },
        fatal: serve.instance_children,
      ),
      epoch: "reader-failure",
      limit: 1,
    )
    as "the custody lifetime starts"
  let registry = lifetime.registry(lifetime)
  let assert Ok(view) =
    manager.create(
      registry,
      manager.Creation("reader-timeout", settings.workspace, "reader", ""),
      directory: directory <> "/sessions",
      generator: ids.generator(clock.fixed(1), 414),
    )
    as "creation starts real assembly"
  let assert poll.Answered(instance) =
    poll.until(within: 10_000, every: 5, attempt: fn() {
      case manager.resolve(registry, view.registration.id) {
        Ok(instance) -> poll.Done(instance)
        Error(_) -> poll.Retry
      }
    })
    as "the real SQLite instance becomes resident"
  let assert Ok(manager.View(status: manager.Resident(incarnation), ..)) =
    manager.get(registry, view.registration.id)
    as "the original incarnation is current"
  let principal = access.Principal("reader", "Reader", access.MemberPrincipal)
  let assert Ok(digest) = access.credential_digest(string.repeat("b", 64))
    as "the fixture digest is valid"
  let stopped = process.new_subject()
  let assert Ok(connection) =
    gateway.attach_authenticated(
      instance.gateway,
      gateway.Binding(
        view.registration.id,
        "reader-failure",
        incarnation,
        "reader-connection",
        principal,
        access.Owner,
        digest,
      ),
      fn() { Ok(#(principal, access.Owner)) },
      fn(_) { Nil },
      fn() { Nil },
      fn() {
        let outcome =
          manager.stop_if_incarnation(
            registry,
            view.registration.id,
            incarnation,
          )
        process.send(stopped, outcome)
      },
      process.self(),
    )
    as "the attachment captures its exact-instance stop capability"
  let assert Ok(storage_pid) =
    list.key_find(serve.instance_children(instance), "the session storage")
    as "the original storage owner is inventoried"
  let assert True = suspend_process(storage_pid)
    as "stall the original SQLite actor"

  // The one capture remains queued after timeout. The callback returns only
  // Stopping, so it cannot deadlock waiting for its own gateway to retire.
  let first =
    gateway.connection_request(
      connection,
      protocol.encode_command(protocol.CommandEnvelope(
        1,
        protocol.Subscribe(view.registration.id, None),
      )),
    )
  let admitted_stop = process.receive(stopped, within: 1000)
  let queued_before = snapshot_requests(storage_pid)
  let second =
    gateway.connection_request(
      connection,
      protocol.encode_command(protocol.CommandEnvelope(2, protocol.CatchUp(0))),
    )
  let queued_after = snapshot_requests(storage_pid)
  let resolved = manager.resolve(registry, view.registration.id)
  let reopened = manager.open(registry, view.registration.id)
  let assert True = resume_process(storage_pid)
    as "release the original backend before asserting"

  assert result.is_error(first)
  let assert Ok(Ok(manager.Stopping(found))) = admitted_stop
    as "the stop callback acknowledges admission without waiting for itself"
  assert found == incarnation
  assert queued_before == 1
  assert queued_after == queued_before
  assert result.is_error(second)
  assert result.is_error(resolved)
  assert result.is_error(reopened)
  assert process.receive(stopped, within: 50) == Error(Nil)

  let assert poll.Answered(Nil) =
    poll.until(within: 10_000, every: 5, attempt: fn() {
      case manager.get(registry, view.registration.id) {
        Ok(manager.View(status: manager.Saved, ..)) -> poll.Done(Nil)
        Ok(manager.View(status: manager.RecoveryBlocked(reason), ..)) ->
          poll.Fail(reason)
        Ok(_) -> poll.Retry
        Error(_) -> poll.Fail("registry disappeared")
      }
    })
    as "normal original custody drain releases the reservation"
  let watch = process.monitor(lifetime.witness(lifetime))
  lifetime.shutdown(lifetime)
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(5000)
    as "the original lifetime confirms drain"
  assert catalogue.close(store) == Ok(Nil)
}

fn snapshot_requests(pid) {
  let assert Ok(messages) =
    decode.run(
      process_info(pid, atom.create("messages")),
      decode.at([1], decode.list(decode.dynamic)),
    )
    as "the stalled SQLite mailbox is inspectable"
  list.count(messages, fn(message) {
    decode.run(message, decode.at([1, 0], decode.dynamic))
    == Ok(atom.to_dynamic(atom.create("snapshot_capture")))
  })
}

@external(erlang, "erlang", "process_info")
fn process_info(pid: process.Pid, item: atom.Atom) -> Dynamic

@external(erlang, "erlang", "suspend_process")
fn suspend_process(pid: process.Pid) -> Bool

@external(erlang, "erlang", "resume_process")
fn resume_process(pid: process.Pid) -> Bool
