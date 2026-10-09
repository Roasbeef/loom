//// Peer mail between two orchestrators, with real orchestrator ports in one
//// VM (protocol-change/078, phase 4).
////
//// The sender and the recipient are real runtimes, each behind its own
//// `peer_mail.handle`. The recipient's orchestrator port is the production
//// `orchestrator_port.start_serving`, and the sender reaches it through the
//// production `remote_peer.at` and `peers.routed`. Only the node is shared:
//// `node.self()` stands in for the peer's node, so the messages take the same
//// send, monitor and reply path they take over distribution.
////
//// "The owner is unreachable" is the real condition, not a script: the
//// recipient's port is not started, so the monitor ends at once with
//// `noproc`. "The reply is lost" is a port that commits the message and then
//// answers after the sender's deadline.

import client/gateway_test
import client/orchestrators
import client/peer_mail.{MayWake}
import client/peer_outbox
import client/peer_outbox_drain
import client/peers
import client/remote/address
import client/remote/orchestrator_port.{type Message, NotOwned, Owned}
import client/remote/remote_peer
import client/session_directory
import core/clock
import core/ids
import core/json
import gleam/erlang/node
import gleam/erlang/process.{type Subject}
import gleam/option.{Some}
import support/addresses
import support/peer_rig.{Pass}
import weft/actor
import weft/poll
import weft/registry as drainer_address

// How long the sender waits for the recipient's port.
const answers_within_ms = 300

// How long a lost-reply port takes to answer a delivery: past the sender's
// wait, so the sender never hears it.
const lag_ms = 900

type Hosts {
  Hosts(
    rig: peer_rig.Rig,
    port: address.Address(Message),
    lag: Subject(Lag),
    listen: fn() -> Nil,
  )
}

type Lag {
  ReadLag(reply: Subject(Int))
  SetLag(ms: Int)
}

// A sender on one orchestrator and a recipient on another. Nothing listens on
// the recipient's port until `listen` is called.
fn hosts(seed: Int) -> Hosts {
  let sender_id = peer_rig.session_id(seed)
  let recipient_id = peer_rig.session_id(seed + 1)
  let sender_name = ids.session_id_to_string(sender_id)
  let recipient_name = ids.session_id_to_string(recipient_id)
  let sender = gateway_test.reserved_fixture(sender_id).runtime
  let recipient = gateway_test.reserved_fixture(recipient_id).runtime
  let sender_clock = peer_rig.ticking(1000)
  let source =
    peer_mail.Endpoint(sender_name, fn(command) {
      peer_mail.handle(sender, sender_clock, command) |> peer_mail.refused
    })
  let local =
    peer_mail.Endpoint(recipient_name, fn(command) {
      peer_mail.handle(recipient, clock.fixed(0), command) |> peer_mail.refused
    })
  let name = process.new_name("peer_remote_port")
  let port = address.Address(node: node.self(), name:)
  let beta = orchestrators.plain("beta", "beta@127.0.0.1")
  let sessions =
    session_directory.Directory(
      ..session_directory.none(),
      lookup: fn(session) {
        case session == recipient_name {
          True -> Ok(session_directory.Elsewhere(orchestrator: beta))
          False -> Error(session_directory.Unknown)
        }
      },
      reach: fn(_orchestrator, session) {
        remote_peer.at(port, session, answers_within_ms)
      },
    )
  let directory =
    peers.Directory(
      resolve: peers.routed(
        fn(id) {
          case id == sender_name {
            True -> Ok(source)
            False -> Error(peer_mail.Refused("not resident"))
          }
        },
        sessions,
      ),
      describe: fn(id) { Ok(json.Object([#("id", json.String(id))])) },
    )
  let lag = start_lag()

  // The recipient's handler, as the daemon builds it (`main.peer_command`): a
  // session this orchestrator holds is called, any other is not running. A
  // delivery waits `lag` after it commits, which is zero unless a test sets
  // it.
  let handler = fn(session, command) {
    case session == recipient_name {
      False -> Error(peers.not_running)
      True -> {
        let answered = local.call(command) |> peer_mail.plain
        case command {
          peer_mail.Deliver(..) ->
            process.sleep(process.call(lag, 1000, ReadLag))
          _ -> Nil
        }
        answered
      }
    }
  }
  let held = fn(session) {
    case session == recipient_name {
      True -> Ok(Owned)
      False -> Ok(NotOwned)
    }
  }
  Hosts(
    rig: peer_rig.Rig(
      sender:,
      recipient:,
      sender_name:,
      recipient_name:,
      script: peer_rig.start_script([], Pass),
      wiring: peers.Wiring(source, json.Null, Some(directory)),
      source:,
      target: local,
    ),
    port:,
    lag:,
    listen: fn() {
      let assert Ok(_) = orchestrator_port.start_serving(name, held, handler)
        as "the recipient's port starts"
      Nil
    },
  )
}

fn start_lag() -> Subject(Lag) {
  let assert Ok(started) =
    actor.new(0)
    |> actor.on_message(fn(ms, message: Lag) {
      case message {
        ReadLag(reply:) -> {
          process.send(reply, ms)
          actor.continue(ms)
        }
        SetLag(ms: next) -> actor.continue(next)
      }
    })
    |> actor.start
    as "the lag cell starts"
  started.data
}

// The recipient as the sender's directory resolves it: an endpoint on the
// other orchestrator.
fn remote(hosts: Hosts) -> peer_mail.Endpoint {
  let assert Some(directory) = hosts.rig.wiring.directory
    as "the rig has a directory"
  let assert Ok(endpoint) = directory.resolve(hosts.rig.recipient_name)
    as "the recipient resolves"
  endpoint
}

type Arming {
  Arming(delay_ms: Int, wake: fn() -> Nil)
}

// A drainer over the sender whose timer arms into the returned subject, as in
// the drainer's own tests.
fn drainer(
  hosts: Hosts,
) -> #(Subject(Arming), drainer_address.Address(peer_outbox_drain.Message)) {
  let armings = process.new_subject()
  let name = addresses.new()
  let options =
    peer_outbox_drain.options(hosts.rig.wiring, fn(delay_ms, wake) {
      process.send(armings, Arming(delay_ms:, wake:))
    })
  let assert Ok(_) = peer_outbox_drain.start(options, name)
    as "the drainer starts"
  #(armings, name)
}

fn arming(armings: Subject(Arming)) -> Arming {
  let assert Ok(found) = process.receive(armings, 2000)
    as "the drainer armed its timer"
  found
}

fn wait_for(what: String, check: fn() -> Bool) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(within: 5000, every: 10, attempt: fn() {
      case check() {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as what
  Nil
}

fn admitted(hosts: Hosts, id: String) -> Bool {
  case peer_rig.row(hosts.rig, id) {
    Some(peer_outbox.Row(state: peer_outbox.Admitted(..), ..)) -> True
    _ -> False
  }
}

pub fn a_session_on_another_orchestrator_is_linked_sent_to_and_receipted_test() {
  let hosts = hosts(3000)
  hosts.listen()
  let rig = hosts.rig

  // The grant is written on the recipient's orchestrator, and the link is
  // recorded on the sender's.
  let assert Ok(_) =
    peers.link(rig.source, remote(hosts), "main", "main", MayWake)
    as "the owner links across orchestrators"
  let assert Ok(json.Array([_])) = rig.target.call(peer_mail.Grants("main"))
    as "the recipient holds the grant"
  let assert Ok(json.Array([_])) = rig.source.call(peer_mail.Links("main"))
    as "the sender holds the link"

  let assert Ok(receipt) = peer_rig.send(rig, "m1") as "the message is admitted"
  assert peer_rig.field(receipt, "admitted") == json.Bool(True)
  assert peer_rig.receipts(rig.recipient) == 1
  assert admitted(hosts, "m1")

  // The receipt lookup reaches the recipient's orchestrator and finds the
  // receipt the sender holds.
  let assert Ok(looked_up) =
    remote(hosts).call(peer_mail.SentReceipt(rig.sender_name, "main", "m1"))
    as "the recipient's orchestrator answers the receipt lookup"
  assert looked_up == receipt

  // Sending again with the same id is the same receipt and not a second
  // message.
  assert peer_rig.send(rig, "m1") == Ok(receipt)
  assert peer_rig.receipts(rig.recipient) == 1

  // Unlinking removes the grant on the recipient's orchestrator too.
  let assert Some(directory) = rig.wiring.directory as "the rig has a directory"
  let assert Ok(_) =
    peers.unlink_session(
      directory,
      rig.source,
      "main",
      rig.recipient_name,
      "main",
    )
    as "the owner unlinks across orchestrators"
  let assert Ok(json.Array([])) = rig.target.call(peer_mail.Grants("main"))
    as "the recipient's grant is gone"
}

pub fn the_port_serves_four_commands_and_refuses_every_other_test() {
  let hosts = hosts(3010)
  hosts.listen()
  let rig = hosts.rig
  let reach = remote_peer.at(hosts.port, rig.recipient_name, answers_within_ms)

  // Each of these would succeed on the recipient's own endpoint, so an error
  // here is the port's refusal and not the session's.
  let refused = Error(peer_mail.Refused(orchestrator_port.peer_unserved))
  assert reach.call(peer_mail.Inbox("main", "", 10)) == refused
  assert reach.call(peer_mail.History("main", 0, 10)) == refused
  assert reach.call(peer_mail.Links("main")) == refused
  assert reach.call(peer_mail.Overview) == refused
  assert reach.call(peer_mail.OutboxDue) == refused
  assert reach.call(peer_mail.Link("main", "anywhere", "main")) == refused
  let assert Ok(json.Array([])) = rig.target.call(peer_mail.Links("main"))
    as "the recipient is untouched"

  // A served command for a session this orchestrator does not hold is the
  // refusal a local send to a session that is not running gets.
  let elsewhere =
    remote_peer.at(hosts.port, "0198c0de-0000-7000-8000-000000000009", 300)
  assert elsewhere.call(peer_mail.SentReceipt("a", "main", "m"))
    == Error(peer_mail.Refused(peers.not_running))
}

pub fn a_session_no_orchestrator_holds_is_not_running_and_not_queued_test() {
  let hosts = hosts(3020)
  hosts.listen()
  let rig = hosts.rig
  let nowhere = "0198c0de-0000-7000-8000-000000000009"
  let assert Ok(_) = rig.source.call(peer_mail.Link("main", nowhere, "main"))
    as "the sender records the link"
  assert peers.send(rig.wiring, "main", nowhere, "main", "m1", "hello")
    == Error(peers.not_running)
}

pub fn an_unreachable_owner_queues_and_the_drainer_delivers_once_it_is_back_test() {
  let hosts = hosts(3030)
  let rig = hosts.rig
  let assert Ok(_) = peers.link(rig.source, rig.target, "main", "main", MayWake)
    as "the pair is linked while both are up"
  let #(armings, name) = drainer(hosts)
  let open = arming(armings)
  open.wake()

  // Nothing is listening on the recipient's port, so the monitor ends at once
  // with `noproc` and the send is queued.
  let assert Ok(queued) = peer_rig.send(rig, "m1")
  assert peers.is_queued(queued)
  assert peer_rig.receipts(rig.recipient) == 0
  peer_outbox_drain.poke(name)
  let waiting = arming(armings)
  assert waiting.delay_ms == peer_outbox_drain.retry_interval_ms

  // The recipient's orchestrator comes up, and the next pass delivers.
  hosts.listen()
  waiting.wake()
  wait_for("the message was admitted", fn() { admitted(hosts, "m1") })
  assert peer_rig.receipts(rig.recipient) == 1
}

pub fn a_lost_reply_is_delivered_once_and_the_repeat_gets_the_stored_receipt_test() {
  let hosts = hosts(3040)
  let rig = hosts.rig
  let assert Ok(_) = peers.link(rig.source, rig.target, "main", "main", MayWake)
    as "the pair is linked while both are up"
  process.send(hosts.lag, SetLag(lag_ms))
  hosts.listen()
  let #(armings, name) = drainer(hosts)
  let open = arming(armings)
  open.wake()

  // The recipient commits and answers after the sender stopped waiting.
  let assert Ok(queued) = peer_rig.send(rig, "m1")
  assert peers.is_queued(queued)
  assert peer_rig.receipts(rig.recipient) == 1
  peer_outbox_drain.poke(name)
  let waiting = arming(armings)

  // The port is free again once its slow answer has gone out. The retry then
  // finds the stored receipt and no second message is made.
  process.send(hosts.lag, SetLag(0))
  process.sleep(lag_ms)
  waiting.wake()
  wait_for("the repeat was answered with the receipt", fn() {
    admitted(hosts, "m1")
  })
  assert peer_rig.receipts(rig.recipient) == 1
}

pub fn a_resident_session_is_never_looked_up_test() {
  let lookups = process.new_subject()
  let route =
    peers.routed(
      fn(_) { Ok(peer_mail.Endpoint("here", fn(_) { Ok(json.Null) })) },
      session_directory.Directory(
        ..session_directory.none(),
        lookup: fn(session) {
          process.send(lookups, session)
          Error(session_directory.Unknown)
        },
        reach: fn(_, session) { remote_peer_unused(session) },
      ),
    )
  let assert Ok(_) = route("here")
  assert process.receive(lookups, 50) == Error(Nil)
}

pub fn a_miss_is_unreachable_only_when_the_directory_could_not_tell_test() {
  let missing = Error(peer_mail.Refused("not resident"))
  let with = fn(answer) {
    peers.routed(
      fn(_) { missing },
      session_directory.Directory(
        ..session_directory.none(),
        lookup: fn(_) { answer },
        reach: fn(_, session) { remote_peer_unused(session) },
      ),
    )
  }
  let assert Error(peer_mail.Unreachable) =
    with(Error(session_directory.Unreachable(["beta"])))("s")
  assert with(Error(session_directory.Unknown))("s") == missing
  assert with(Ok(session_directory.Here))("s") == missing
}

fn remote_peer_unused(session: String) -> peer_mail.Endpoint {
  peer_mail.Endpoint(session, fn(_) { Error(peer_mail.Unreachable) })
}
