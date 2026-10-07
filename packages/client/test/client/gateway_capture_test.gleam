//// A slow storage actor costs one request, and only a dead one fences the hub.
////
//// A transfer's capture is asked of storage by a weft run, so the gateway's
//// mailbox never waits for it. These tests stand a scripted storage in front
//// of a real gateway: one that answers only when told to, and one that is
//// gone. They differ in what the hub is entitled to conclude. A deadline says
//// the actor was busy and refuses one request. A monitor that fired says the
//// actor is dead and fences the session for everyone. The real SQLite actor
//// stalled mid-flight is covered by `gateway_reader_failure_test`.

import client/gateway
import client/gateway_test
import client/protocol
import core/clock
import core/ids
import core/json
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import runtime/api
import session/session
import storage/access
import storage/snapshot
import storage/storage
import support/addresses
import weft/poll

// What the scripted storage answers with. Neither field is read by the
// transfer's own limits, so the smallest cut that decodes is enough.
fn cut() -> snapshot.Cut {
  snapshot.Cut(
    next_seq: 1,
    stats: storage.empty_stats(),
    cells: [],
    metadata_bytes: 0,
    recent: [],
  )
}

type Reply =
  Subject(Result(snapshot.Cut, snapshot.Error))

// A storage actor that holds its first answer until the test releases it and
// answers every later request at once. Holding the first is what makes the
// hub's wait expire; releasing it afterwards is the late reply, and the owner
// of the subject it answered is what shows where that reply was delivered.
type Storage {
  Storage(
    requests: Subject(Reply),
    release: Subject(Nil),
    late_owner: Subject(Result(process.Pid, Nil)),
  )
}

fn start_storage() -> Storage {
  let late_owner = process.new_subject()
  let ready = process.new_subject()

  // A subject can be received from only by the process that made it, so the
  // storage makes the two it listens on and hands them to the test.
  process.spawn(fn() {
    let requests = process.new_subject()
    let release = process.new_subject()
    process.send(ready, #(requests, release))
    serve(requests, release, late_owner, 0)
  })
  let assert Ok(#(requests, release)) = process.receive(ready, 1000)
    as "the scripted storage starts"
  Storage(requests:, release:, late_owner:)
}

fn serve(
  requests: Subject(Reply),
  release: Subject(Nil),
  late_owner: Subject(Result(process.Pid, Nil)),
  answered: Int,
) -> Nil {
  let reply = process.receive_forever(requests)
  case answered {
    0 -> {
      let _released = process.receive(release, 10_000)
      process.send(late_owner, process.subject_owner(reply))
      process.send(reply, Ok(cut()))
    }
    _ -> process.send(reply, Ok(cut()))
  }
  serve(requests, release, late_owner, answered + 1)
}

// The reader a session carries, with `capture` replaced. The wait it gives up
// after is its own and short, which is what a real exchange does when storage
// does not answer inside its budget.
fn reader(capture: fn() -> Result(snapshot.Cut, snapshot.Error)) {
  snapshot.Reader(
    capture: fn(_plan, _wait) { capture() },
    page: fn(_after, _before, _limit, _wait) { Error(snapshot.InvalidRequest) },
    lineage: fn(_from, _before, _limit, _wait) {
      Error(snapshot.InvalidRequest)
    },
    fragment: fn(_descriptor, _offset, _wait) { Error(snapshot.InvalidRequest) },
  )
}

fn waiting_on(storage: Storage) {
  reader(fn() {
    let reply = process.new_subject()
    process.send(storage.requests, reply)
    process.receive(reply, 200)
    |> result.replace_error(snapshot.ReadTimedOut)
    |> result.flatten
  })
}

type Rig {
  Rig(
    hub: gateway.Gateway,
    pid: process.Pid,
    session_id: String,
    runtime: api.Runtime,
  )
}

// A real network gateway over a real session, whose reader is the scripted
// one. The runtime is shared with the harness the fixture builds, so closing
// it closes the session too.
fn rig(seed: Int, scripted: snapshot.Reader) -> Rig {
  let id = ids.mint_session(ids.generator(clock.fixed(1000), seed)).0
  let harness = gateway_test.reserved_fixture(id)
  let runtime =
    api.Runtime(
      ..harness.runtime,
      session: session.Session(
        ..harness.runtime.session,
        snapshot_reader: scripted,
      ),
    )
  let name = addresses.new()
  let assert Ok(_) =
    gateway.start(gateway.default_options("capture-test", runtime), name)
    as "the gateway over the scripted reader starts"
  let assert Ok(pid) = addresses.owner(name)
    as "the started gateway owns a process"
  Rig(
    hub: gateway.Gateway(name:),
    pid:,
    session_id: ids.session_id_to_string(api.session_id(runtime)),
    runtime: harness.runtime,
  )
}

fn finish(rig: Rig) -> Nil {
  process.unlink(rig.pid)
  let monitor = process.monitor(rig.pid)
  process.send_abnormal_exit(rig.pid, "shutdown")
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
    as "the gateway stops"
  let assert Ok(Nil) = api.close(rig.runtime) as "the session closes"
  Nil
}

// What an attachment's transport supplies: one signal per capability, so a
// test can say which of them the hub reached for.
type Attachment {
  Attachment(
    connection: gateway.ConnectionHandle,
    closed: Subject(Nil),
    failed: Subject(Nil),
  )
}

fn attach(rig: Rig, name: String) -> Attachment {
  let principal = access.Principal(name, "Reader", access.MemberPrincipal)
  let assert Ok(digest) = access.credential_digest(string.repeat("c", 64))
    as "the fixture digest is valid"
  let closed = process.new_subject()
  let failed = process.new_subject()
  let assert Ok(connection) =
    gateway.attach_authenticated(
      rig.hub,
      gateway.Binding(
        rig.session_id,
        "capture-epoch",
        "capture-incarnation",
        name,
        principal,
        access.Owner,
        digest,
        None,
      ),
      fn() { Ok(#(principal, access.Owner)) },
      fn(_frame) { Nil },
      fn() { process.send(closed, Nil) },
      fn() { process.send(failed, Nil) },
      process.self(),
    )
    as "the attachment is admitted"
  Attachment(connection:, closed:, failed:)
}

fn subscribe(rig: Rig, attachment: Attachment, id: Int) {
  gateway.connection_request(
    attachment.connection,
    protocol.encode_command(protocol.CommandEnvelope(
      id,
      protocol.Subscribe(rig.session_id, None),
    )),
  )
}

// A request is asked from its own process, because the socket's call blocks
// until the hub answers and the point of these tests is what the hub does in
// the meantime.
fn subscribing(rig: Rig, attachment: Attachment, id: Int) {
  let answered = process.new_subject()
  process.spawn(fn() { process.send(answered, subscribe(rig, attachment, id)) })
  answered
}

fn event(frame: Result(String, String)) -> protocol.Event {
  let assert Ok(text) = frame as "the gateway answered in band"
  let assert Ok(protocol.EventEnvelope(event:, ..)) =
    protocol.decode_event(text)
    as "the answer decodes"
  event
}

pub fn a_slow_capture_refuses_one_request_and_fences_nothing_test() {
  let storage = start_storage()
  let rig = rig(9101, waiting_on(storage))
  let slow = attach(rig, "slow")
  let bystander = attach(rig, "bystander")

  // The capture is held by storage. The hub is still the same process, and it
  // answers while the capture is outstanding instead of waiting for it.
  let asked = subscribing(rig, slow, 1)
  assert gateway.attached(rig.hub) == 2

  // The wait expires, and that costs this request alone: refused in band with
  // the instruction to ask again.
  let assert Ok(frame) = process.receive(asked, 3000)
    as "the capture's deadline is answered, not waited out by the socket"
  let assert protocol.ErrorEvent(code:, message:, ..) = event(frame)
    as "the request is refused in band"
  assert code == "snapshot_failed"
  assert string.contains(message, "retry")

  // Nobody was disconnected or stopped, and the session still admits peers.
  assert gateway.attached(rig.hub) == 2
  assert process.receive(slow.closed, 50) == Error(Nil)
  assert process.receive(bystander.closed, 50) == Error(Nil)
  assert process.receive(slow.failed, 50) == Error(Nil)
  let _late_peer = attach(rig, "latecomer")

  // Storage finally answers. The reply goes to the run's worker, which has
  // already exited, and not to the hub.
  process.send(storage.release, Nil)
  let assert Ok(Ok(owner)) = process.receive(storage.late_owner, 1000)
    as "storage sent its late reply"
  assert owner != rig.pid
  let assert poll.Answered(Nil) =
    poll.until(within: 1000, every: 5, attempt: fn() {
      case process.is_alive(owner) {
        True -> poll.Retry
        False -> poll.Done(Nil)
      }
    })
    as "the late reply's recipient exited with its run"

  // The retry is the client's, and it is served by the same hub.
  let assert protocol.SnapshotBegin(json.Object(fields)) =
    event(subscribe(rig, slow, 2))
    as "the retried subscribe opens a transfer"
  assert list.key_find(fields, "session_id") == Ok(json.String(rig.session_id))
  let assert protocol.SnapshotBegin(_) = event(subscribe(rig, bystander, 3))
    as "the bystander is served as well"
  finish(rig)
}

pub fn a_dead_storage_actor_still_fences_the_session_test() {
  let rig = rig(9102, reader(fn() { Error(snapshot.ReaderUnavailable) }))
  let first = attach(rig, "first")
  let second = attach(rig, "second")

  // The exchange proved the actor gone, which no retry can repair. The hub
  // closes every attachment, asks its own incarnation to stop, and refuses to
  // admit another peer.
  let _asked = subscribing(rig, first, 1)
  let assert Ok(Nil) = process.receive(first.closed, 1000)
    as "the asking attachment is closed"
  let assert Ok(Nil) = process.receive(second.closed, 1000)
    as "every other attachment is closed too"
  let assert Ok(Nil) = process.receive(first.failed, 1000)
    as "the incarnation's stop capability is invoked"
  assert process.receive(second.failed, 50) == Error(Nil)
  let principal = access.Principal("late", "Late", access.MemberPrincipal)
  let assert Ok(digest) = access.credential_digest(string.repeat("c", 64))
    as "the fixture digest is valid"
  let admitted =
    gateway.attach_authenticated(
      rig.hub,
      gateway.Binding(
        rig.session_id,
        "capture-epoch",
        "capture-incarnation",
        "late",
        principal,
        access.Owner,
        digest,
        None,
      ),
      fn() { Ok(#(principal, access.Owner)) },
      fn(_frame) { Nil },
      fn() { Nil },
      fn() { Nil },
      process.self(),
    )
  assert result.is_error(admitted)
  finish(rig)
}
