//// What a stalled SQLite actor costs, and what it must not.
////
//// Both tests here run real instance custody against a real backend and stop
//// that backend mid-flight; they differ only in who was waiting on it. A
//// capture is the server's own question, funded with the reader's whole
//// budget, so exhausting it fences the gateway and stops the exact
//// incarnation. A snapshot continuation is funded from what is left of a
//// client's retention window and of that client's own request, so exhausting
//// one is the caller's wait running out: it must cost that caller its
//// transfer and cost nobody else anything at all.

import client/daemon/domain as domain_service
import client/daemon/lifetime
import client/daemon/manager
import client/gateway
import client/owned_assembly_test
import client/protocol
import client/serve
import core/clock
import core/ids
import core/json
import filepath
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import simplifile
import storage/access
import storage/catalogue
import telemetry/log
import weft/poll

// One real resident session under real custody. Both tests need the same
// arrangement — a catalogue, a lifetime, and an instance whose SQLite actor a
// test can suspend — and what each test is actually about is the attachments
// made on top of it.
type Resident {
  Resident(
    store: catalogue.Catalogue,
    lifetime: lifetime.Lifetime(serve.Instance),
    registry: manager.Manager(serve.Instance),
    session_id: String,
    incarnation: String,
    instance: serve.Instance,
  )
}

fn resident(epoch: String) -> Resident {
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
      epoch:,
      limit: 1,
    )
    as "the custody lifetime starts"
  let registry = lifetime.registry(lifetime)
  let assert Ok(view) =
    manager.create(
      registry,
      manager.Creation(epoch, settings.workspace, "reader", ""),
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
  Resident(
    store:,
    lifetime:,
    registry:,
    session_id: view.registration.id,
    incarnation:,
    instance:,
  )
}

// What an attachment's transport supplies to the hub, with the two
// capabilities kept as subjects so a test can say which of them the hub
// reached for: `closed` retires this socket, `stopped` retires the session.
type Attachment {
  Attachment(
    connection: gateway.ConnectionHandle,
    closed: Subject(Nil),
    stopped: Subject(Result(manager.Status, manager.Error)),
  )
}

fn attach(resident: Resident, name: String, epoch: String) -> Attachment {
  let principal = access.Principal(name, "Reader", access.MemberPrincipal)
  let assert Ok(digest) = access.credential_digest(string.repeat("b", 64))
    as "the fixture digest is valid"
  let closed = process.new_subject()
  let stopped = process.new_subject()
  let assert Ok(connection) =
    gateway.attach_authenticated(
      resident.instance.gateway,
      gateway.Binding(
        resident.session_id,
        epoch,
        resident.incarnation,
        name,
        principal,
        access.Owner,
        digest,
      ),
      fn() { Ok(#(principal, access.Owner)) },
      fn(_) { Nil },
      fn() { process.send(closed, Nil) },
      fn() {
        process.send(
          stopped,
          manager.stop_if_incarnation(
            resident.registry,
            resident.session_id,
            resident.incarnation,
          ),
        )
      },
      process.self(),
    )
    as "the attachment captures its exact-instance stop capability"
  Attachment(connection:, closed:, stopped:)
}

fn request(attachment: Attachment, id: Int, command: protocol.Command) {
  gateway.connection_request(
    attachment.connection,
    protocol.encode_command(protocol.CommandEnvelope(id, command)),
  )
}

fn answer(frame: Result(String, String)) -> protocol.Event {
  let assert Ok(text) = frame as "the gateway answered in band"
  let assert Ok(protocol.EventEnvelope(event:, ..)) =
    protocol.decode_event(text)
    as "the gateway's answer decodes"
  event
}

fn opened(event: protocol.Event) -> String {
  let assert protocol.SnapshotBegin(json.Object(fields)) = event
    as "a transfer opens with a snapshot_begin body"
  let assert Ok(json.String(id)) = list.key_find(fields, "snapshot_id")
    as "an open transfer names itself"
  id
}

pub fn sqlite_read_timeout_poison_stops_original_incarnation_without_self_wait_test() {
  process.trap_exits(True)
  let resident = resident("reader-failure")
  let attachment = attach(resident, "reader-connection", "reader-failure")

  // The inventory is taken before the stall: it walks the instance's own
  // record, but a fixture must not depend on that while the backend is down.
  let storage = storage_of(resident)
  let assert True = suspend_process(storage)
    as "stall the original SQLite actor"

  // The one capture remains queued after timeout. The callback returns only
  // Stopping, so it cannot deadlock waiting for its own gateway to retire.
  let first =
    request(attachment, 1, protocol.Subscribe(resident.session_id, None))
  let admitted_stop = process.receive(attachment.stopped, within: 1000)
  let queued_before = snapshot_requests(storage)
  let second = request(attachment, 2, protocol.CatchUp(0))
  let queued_after = snapshot_requests(storage)
  let resolved = manager.resolve(resident.registry, resident.session_id)
  let reopened = manager.open(resident.registry, resident.session_id)
  let assert True = resume_process(storage)
    as "release the original backend before asserting"

  assert result.is_error(first)
  let assert Ok(Ok(manager.Stopping(found))) = admitted_stop
    as "the stop callback acknowledges admission without waiting for itself"
  assert found == resident.incarnation
  assert queued_before == 1
  assert queued_after == queued_before
  assert result.is_error(second)
  assert result.is_error(resolved)
  assert result.is_error(reopened)
  assert process.receive(attachment.stopped, within: 50) == Error(Nil)

  let assert poll.Answered(Nil) =
    poll.until(within: 10_000, every: 5, attempt: fn() {
      case manager.get(resident.registry, resident.session_id) {
        Ok(manager.View(status: manager.Saved, ..)) -> poll.Done(Nil)
        Ok(manager.View(status: manager.RecoveryBlocked(reason), ..)) ->
          poll.Fail(reason)
        Ok(_) -> poll.Retry
        Error(_) -> poll.Fail("registry disappeared")
      }
    })
    as "normal original custody drain releases the reservation"
  retire(resident)
}

// A continuation's reads are funded from the client's own retention window and
// from the wall of the request they answer, never from the reader's whole
// budget. Reading a timeout there as reader health let a peer, by pacing one
// frame, close every attachment on the session and stop the incarnation for
// all of them.
pub fn a_continuation_read_timeout_costs_its_own_transfer_and_nothing_else_test() {
  process.trap_exits(True)
  let resident = resident("continuation-timeout")
  let reader = attach(resident, "slow-reader", "continuation-timeout")
  let bystander = attach(resident, "bystander", "continuation-timeout")

  // Both openings capture a transfer, and a connection may hold only one, so
  // both are drained over a live backend before anything is stalled.
  let subscribed =
    opened(
      answer(request(reader, 1, protocol.Subscribe(resident.session_id, None))),
    )
  let assert protocol.SnapshotEnd(_) = drain(reader, subscribed, 100, 0)
    as "the reader's recent window completes"
  let watching =
    opened(
      answer(request(
        bystander,
        1,
        protocol.Subscribe(resident.session_id, None),
      )),
    )
  let assert protocol.SnapshotEnd(_) = drain(bystander, watching, 100, 0)
    as "the bystander's recent window completes"

  // Reconciliation always names a descriptor range, so its first credit past
  // the metadata is a page read whatever the transcript holds.
  let reconciling = opened(answer(request(reader, 50, protocol.CatchUp(0))))
  let storage = storage_of(resident)
  let assert True = suspend_process(storage)
    as "stall the original SQLite actor"

  // Metadata pieces are pure, so the credits walk forward until the one that
  // needs the page. That read is the one whose wait expires.
  let refusal = drain(reader, reconciling, 200, 0)
  let attached_during = gateway.attached(resident.instance.gateway)
  let assert True = resume_process(storage)
    as "release the original backend before asserting"

  let assert protocol.ErrorEvent(code:, ..) = refusal
    as "the continuation is refused in band, not by a closed socket"
  assert code == "snapshot_failed"

  // Nothing else was touched: no attachment was closed, the incarnation was
  // not stopped, and the hub still serves the peer that was only watching.
  assert attached_during == 2
  assert process.receive(reader.closed, within: 50) == Error(Nil)
  assert process.receive(bystander.closed, within: 50) == Error(Nil)
  assert process.receive(reader.stopped, within: 50) == Error(Nil)
  assert process.receive(bystander.stopped, within: 50) == Error(Nil)
  assert result.is_ok(manager.resolve(resident.registry, resident.session_id))
  let assert protocol.SnapshotBegin(_) =
    answer(request(bystander, 2, protocol.CatchUp(0)))
    as "the hub is not poisoned: another peer still captures a transfer"

  retire(resident)
}

// Credits one transfer forward until it answers with something other than a
// chunk. The bound is a fixture guard rather than a protocol one: a transfer
// that never settles is a failure to report, not a loop to run.
fn drain(
  attachment: Attachment,
  snapshot_id: String,
  id: Int,
  index: Int,
) -> protocol.Event {
  let assert True = index < 64 as "a fixture transfer settles inside 64 credits"
  let credit = protocol.SnapshotNext(snapshot_id, index)
  case answer(request(attachment, id, credit)) {
    protocol.SnapshotChunk(_) ->
      drain(attachment, snapshot_id, id + 1, index + 1)
    settled -> settled
  }
}

fn storage_of(resident: Resident) -> process.Pid {
  let assert Ok(pid) =
    list.key_find(
      serve.instance_children(resident.instance),
      "the session storage",
    )
    as "the original storage owner is inventoried"
  pid
}

fn retire(resident: Resident) -> Nil {
  let watch = process.monitor(lifetime.witness(resident.lifetime))
  lifetime.shutdown(resident.lifetime)
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(5000)
    as "the original lifetime confirms drain"
  assert catalogue.close(resident.store) == Ok(Nil)
  Nil
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
