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
//// answers after the sender's deadline. "The recipient is saved" and "the
//// recipient is gone" are the owner's catalogue, scripted through the rig's
//// residency cell: the port answers `peer_mail.not_open_reason` for the first
//// and `peers.not_running` for the second, as the production handler
//// (`main.peer_command`) does. A second port stands for the orchestrator a
//// session is moved to.

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
import gleam/list
import gleam/option.{None, Some}
import support/addresses
import support/peer_rig.{Gone, Pass, Resident, Saved}
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
    // What the recipient's owner was asked, one line per question, so a test
    // can show that it was not asked.
    asked: Subject(String),
    // The orchestrator the recipient is moved to, which starts listening with
    // the recipient resident, and the move itself.
    listen_new: fn() -> Nil,
    move: fn() -> Nil,
  )
}

type Lag {
  ReadLag(reply: Subject(Int))
  SetLag(ms: Int)
}

type Owner {
  ReadOwner(reply: Subject(String))
  MoveTo(name: String)
}

// A sender on one orchestrator and a recipient on another. Nothing listens on
// the recipient's port until `listen` is called.
fn hosts(seed: Int) -> Hosts {
  hosts_on(seed, peer_rig.ticking(1000))
}

// The same hosts with the sender's clock supplied.
fn hosts_on(seed: Int, sender_clock: clock.Clock) -> Hosts {
  let sender_id = peer_rig.session_id(seed)
  let recipient_id = peer_rig.session_id(seed + 1)
  let sender_name = ids.session_id_to_string(sender_id)
  let recipient_name = ids.session_id_to_string(recipient_id)
  let sender = gateway_test.reserved_fixture(sender_id).runtime
  let recipient = gateway_test.reserved_fixture(recipient_id).runtime
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
  let new_name = process.new_name("peer_remote_new_port")
  let new_port = address.Address(node: node.self(), name: new_name)
  let beta = orchestrators.plain("beta", "beta@127.0.0.1")
  let gamma = orchestrators.plain("gamma", "gamma@127.0.0.1")
  let owner = start_owner()
  let port_of = fn(orchestrator: orchestrators.Orchestrator) {
    case orchestrator.name {
      "gamma" -> new_port
      _ -> port
    }
  }
  let sessions =
    session_directory.Directory(
      ..session_directory.none(),
      lookup: fn(session) {
        case session == recipient_name {
          True ->
            case process.call(owner, 1000, ReadOwner) {
              "gamma" -> Ok(session_directory.Elsewhere(orchestrator: gamma))
              _ -> Ok(session_directory.Elsewhere(orchestrator: beta))
            }
          False -> Error(session_directory.Unknown)
        }
      },
      reach: fn(orchestrator, session) {
        remote_peer.at(port_of(orchestrator), session, answers_within_ms)
      },
      describe: fn(orchestrator, session) {
        case
          orchestrator_port.ask_description(
            port_of(orchestrator),
            session,
            answers_within_ms,
          )
        {
          Ok(answer) -> answer
          Error(Nil) -> Error(peer_mail.unreachable_reason)
        }
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
      describe: peers.described(
        fn(id) {
          case id == sender_name {
            True -> Ok(json.Object([#("id", json.String(id))]))
            False -> Error("not_found")
          }
        },
        sessions,
      ),
    )
  let lag = start_lag()
  let rig_script = peer_rig.start_script([], Pass)
  let asked = process.new_subject()

  // The recipient's handler, as the daemon builds it (`main.peer_command`): a
  // session this orchestrator holds and has open is called, one it holds
  // saved is `not_open_reason`, and any other is not running. A delivery waits
  // `lag` after it commits, which is zero unless a test sets it.
  let handler = fn(session, command) {
    case session == recipient_name {
      False -> Error(peers.not_running)
      True -> {
        process.send(asked, kind_of(command))
        case process.call(rig_script, 1000, peer_rig.Lookup) {
          Gone -> Error(peers.not_running)
          Saved -> Error(peer_mail.not_open_reason)
          Resident -> {
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
    }
  }

  // The catalogue's description, as `server.local_description` gives it: the
  // session's lifecycle as the owner knows it, whether or not it is open.
  let describe = fn(session) {
    process.send(asked, "describe")
    case session == recipient_name {
      False -> Error("not_found")
      True ->
        Ok(
          json.Object([
            #("session_id", json.String(session)),
            #("served_by", json.String("beta")),
            #(
              "status",
              json.Object([
                #(
                  "state",
                  json.String(
                    case process.call(rig_script, 1000, peer_rig.Lookup) {
                      Resident -> "resident"
                      Saved | Gone -> "saved"
                    },
                  ),
                ),
              ]),
            ),
          ]),
        )
    }
  }
  let held = fn(session) {
    case session == recipient_name {
      True -> Ok(Owned)
      False -> Ok(NotOwned)
    }
  }

  // The orchestrator a session is moved to: it always has the recipient open.
  let new_handler = fn(session, command) {
    case session == recipient_name {
      False -> Error(peers.not_running)
      True -> local.call(command) |> peer_mail.plain
    }
  }
  Hosts(
    rig: peer_rig.Rig(
      sender:,
      recipient:,
      sender_name:,
      recipient_name:,
      script: rig_script,
      wiring: peers.Wiring(source, json.Null, Some(directory)),
      source:,
      target: local,
    ),
    port:,
    lag:,
    listen: fn() {
      let assert Ok(_) =
        orchestrator_port.start_with(
          name,
          held,
          handler,
          describe,
          orchestrator_port.declining(),
        )
        as "the recipient's port starts"
      Nil
    },
    asked:,
    listen_new: fn() {
      let assert Ok(_) =
        orchestrator_port.start_serving(new_name, held, new_handler)
        as "the new owner's port starts"
      Nil
    },
    move: fn() { process.send(owner, MoveTo("gamma")) },
  )
}

// What a served command is, for a test that asks what the owner was sent.
fn kind_of(command: peer_mail.Command) -> String {
  case command {
    peer_mail.Roster(source, _) -> "roster " <> source
    peer_mail.Deliver(..) -> "deliver"
    _ -> "other"
  }
}

fn start_owner() -> Subject(Owner) {
  let assert Ok(started) =
    actor.new("beta")
    |> actor.on_message(fn(name, message: Owner) {
      case message {
        ReadOwner(reply:) -> {
          process.send(reply, name)
          actor.continue(name)
        }
        MoveTo(name: next) -> actor.continue(next)
      }
    })
    |> actor.start
    as "the owner cell starts"
  started.data
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

pub fn the_port_serves_five_commands_and_refuses_every_other_test() {
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

  // A peer does not write the recipient's own description, which is what the
  // command named `Describe` does. The catalogue read a listing needs is the
  // port's `Describe` message.
  assert reach.call(peer_mail.Describe("main", "overwritten")) == refused
  let assert Ok(json.Array([])) = rig.target.call(peer_mail.Links("main"))
    as "the recipient is untouched"

  // The roster is served, and a session that granted this sender nothing
  // lists nothing.
  assert reach.call(peer_mail.Roster(rig.sender_name, "main"))
    == Ok(json.Array([]))

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

// A field reached through a path of object keys.
fn at(value: json.JsonValue, path: List(String)) -> json.JsonValue {
  list.fold(path, value, fn(found, key) { peer_rig.field(found, key) })
}

// Everything the owner was asked so far, oldest first.
fn flushed(asked: Subject(String)) -> List(String) {
  case process.receive(asked, 50) {
    Ok(kind) -> [kind, ..flushed(asked)]
    Error(Nil) -> []
  }
}

pub fn the_roster_of_a_session_on_another_orchestrator_is_its_owners_own_test() {
  let hosts = hosts(3050)
  hosts.listen()
  let rig = hosts.rig
  let assert Ok(_) =
    peers.link(rig.source, remote(hosts), "main", "main", MayWake)
    as "the pair is linked across orchestrators"

  // The recipient is open: its owner lists the strand it granted this sender
  // and describes the session from its own catalogue.
  let assert Ok(json.Array([listed])) = peers.roster(rig.wiring, "main")
    as "the roster lists the remote recipient"
  assert peer_rig.field(listed, "session") == json.String(rig.recipient_name)
  assert peer_rig.field(listed, "running") == json.Bool(True)
  let assert json.Array([strand]) = peer_rig.field(listed, "exported_strands")
    as "the owner lists the granted strand"
  assert peer_rig.field(strand, "strand") == json.String("main")
  assert peer_rig.field(strand, "wake") == json.String("may_wake")
  assert at(listed, ["metadata", "served_by"]) == json.String("beta")
  assert at(listed, ["metadata", "status", "state"]) == json.String("resident")

  // The owner's inspection shows the wake permission of the link.
  let assert Ok(inspected) = peers.inspect(rig.wiring, "main", None, 59_000)
    as "the inspection answers"
  let assert json.Array([outgoing]) = peer_rig.field(inspected, "outgoing")
  assert peer_rig.field(outgoing, "wake") == json.String("may_wake")
  assert at(outgoing, ["metadata", "served_by"]) == json.String("beta")

  // The owner saves the session. It is still described, from the catalogue,
  // and listed as not running with no strands, as a local one is.
  peer_rig.set_resident(rig, Saved)
  let assert Ok(json.Array([saved])) = peers.roster(rig.wiring, "main")
  assert peer_rig.field(saved, "running") == json.Bool(False)
  assert peer_rig.field(saved, "exported_strands") == json.Null
  assert at(saved, ["metadata", "status", "state"]) == json.String("saved")
  let assert Ok(inspected) = peers.inspect(rig.wiring, "main", None, 59_000)
  let assert json.Array([outgoing]) = peer_rig.field(inspected, "outgoing")
  assert peer_rig.field(outgoing, "wake") == json.Null
  assert at(outgoing, ["metadata", "status", "state"]) == json.String("saved")
}

pub fn an_owner_that_cannot_be_reached_leaves_its_row_unavailable_and_the_rest_listed_test() {
  let hosts = hosts(3055)
  let rig = hosts.rig

  // Nothing listens on the owner's port.
  let assert Ok(_) =
    rig.source.call(peer_mail.Link("main", rig.recipient_name, "main"))
    as "the sender records the link"
  let assert Ok(json.Array([listed])) = peers.roster(rig.wiring, "main")
    as "an unreachable owner does not fail the listing"
  assert peer_rig.field(listed, "session") == json.String(rig.recipient_name)
  assert at(listed, ["metadata", "unavailable"])
    == json.String(peer_mail.unreachable_reason)
  assert at(listed, ["exported_strands", "unavailable"])
    == json.String(peer_mail.unreachable_reason)
  let assert Ok(inspected) = peers.inspect(rig.wiring, "main", None, 59_000)
    as "nor does it fail the inspection"
  let assert json.Array([outgoing]) = peer_rig.field(inspected, "outgoing")
  assert peer_rig.field(outgoing, "wake") == json.Null
}

pub fn a_listing_read_is_given_less_time_than_a_delivery_test() {
  let delivery =
    peer_mail.Deliver(
      peer_mail.Source("s", "main", json.Null),
      "main",
      "m1",
      "hello",
    )
  assert remote_peer.wait_ms(peer_mail.Roster("s", "main"))
    == remote_peer.read_ms
  assert remote_peer.wait_ms(delivery) == remote_peer.call_ms
  assert remote_peer.read_ms < remote_peer.call_ms
}

pub fn a_session_that_is_unlinked_or_not_granted_stays_hidden_from_its_owner_test() {
  let hosts = hosts(3056)
  hosts.listen()
  let rig = hosts.rig
  let reach = remote(hosts)
  let assert Ok(_) = peers.link(rig.source, reach, "main", "main", MayWake)
    as "the pair is linked across orchestrators"

  // A session the recipient granted nothing learns nothing from its roster,
  // and neither does the sender through a strand it was not granted from.
  let stranger = "0198c0de-0000-7000-8000-0000000000aa"
  assert reach.call(peer_mail.Roster(stranger, "main")) == Ok(json.Array([]))
  assert reach.call(peer_mail.Roster(rig.sender_name, "elsewhere"))
    == Ok(json.Array([]))

  // Unlinked, the sender lists nothing for the pair and asks its owner
  // nothing at all: there is no link to list and no grant to read.
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
  let _earlier = flushed(hosts.asked)
  let assert Ok(json.Array([])) = peers.roster(rig.wiring, "main")
  let assert Ok(inspected) = peers.inspect(rig.wiring, "main", None, 59_000)
  assert peer_rig.field(inspected, "outgoing") == json.Array([])
  assert flushed(hosts.asked) == []

  // A session the owner's catalogue does not hold is not described.
  assert directory.describe("0198c0de-0000-7000-8000-000000000009")
    == Error("not_found")
}

pub fn a_description_is_asked_of_the_owner_only_when_this_catalogue_has_none_test() {
  let owned = fn(_) { Ok(json.String("here")) }
  let lookups = process.new_subject()
  let beta = orchestrators.plain("beta", "beta@127.0.0.1")
  let sessions = fn(answer) {
    session_directory.Directory(
      ..session_directory.none(),
      lookup: fn(session) {
        process.send(lookups, session)
        answer
      },
      describe: fn(_orchestrator, session) {
        Ok(json.String("owner of " <> session))
      },
    )
  }
  let missing = fn(_) { Error("not_found") }

  // A session described here is never looked up.
  assert peers.described(owned, sessions(Error(session_directory.Unknown)))("s")
    == Ok(json.String("here"))
  assert process.receive(lookups, 50) == Error(Nil)

  // A miss goes to the session's owner, and an owner that could not be asked is
  // unavailable. `Here` and `Unknown` leave this catalogue's own error.
  assert peers.described(
      missing,
      sessions(Ok(session_directory.Elsewhere(orchestrator: beta))),
    )("s")
    == Ok(json.String("owner of s"))
  assert peers.described(
      missing,
      sessions(Error(session_directory.Unreachable(["beta"]))),
    )("s")
    == Error(peer_mail.unreachable_reason)
  assert peers.described(missing, sessions(Ok(session_directory.Here)))("s")
    == Error("not_found")
  assert peers.described(missing, sessions(Error(session_directory.Unknown)))(
      "s",
    )
    == Error("not_found")
}

pub fn an_owner_tells_a_saved_session_from_one_it_does_not_hold_test() {
  let hosts = hosts(3057)
  hosts.listen()
  let rig = hosts.rig
  let reach = remote(hosts)
  let ask = peer_mail.SentReceipt(rig.sender_name, "main", "m")

  // Open, saved and gone are three different answers across the wire, and the
  // sender can tell the second from the third.
  assert reach.call(ask) == Ok(json.Null)
  peer_rig.set_resident(rig, Saved)
  assert reach.call(ask) == Error(peer_mail.NotOpen)
  peer_rig.set_resident(rig, Gone)
  assert reach.call(ask) == Error(peer_mail.Refused(peers.not_running))
}

pub fn a_send_to_a_saved_session_on_another_orchestrator_waits_and_is_delivered_once_test() {
  let hosts = hosts(3060)
  hosts.listen()
  let rig = hosts.rig
  let assert Ok(_) =
    peers.link(rig.source, remote(hosts), "main", "main", MayWake)
    as "the pair is linked while the recipient is open"
  peer_rig.set_resident(rig, Saved)
  let #(armings, name) = drainer(hosts)
  let open = arming(armings)
  open.wake()

  // The owner answers that the recipient is saved: the send is queued, with
  // the words that say why, and nothing reached the recipient.
  let assert Ok(queued) = peer_rig.send(rig, "m1")
    as "a send to a saved session is queued"
  assert peers.is_queued(queued)
  assert peer_rig.field(queued, "note")
    == json.String(peers.queued_unopened_note)
  assert peer_rig.receipts(rig.recipient) == 0
  let assert Some(peer_outbox.Row(
    state: peer_outbox.Pending(wait: peer_outbox.OnOpen, ..),
    ..,
  )) = peer_rig.row(rig, "m1")
    as "the row waits for an open"
  peer_outbox_drain.poke(name)

  // The drainer asks again and finds it saved, and waits twice as long.
  let first = arming(armings)
  assert first.delay_ms == peer_outbox_drain.retry_interval_ms
  first.wake()
  let second = arming(armings)
  assert second.delay_ms == 2 * peer_outbox_drain.retry_interval_ms
  assert peer_rig.receipts(rig.recipient) == 0

  // The owner opens the session, and the next pass delivers it.
  peer_rig.set_resident(rig, Resident)
  second.wake()
  wait_for("the message was admitted", fn() { admitted(hosts, "m1") })
  assert peer_rig.receipts(rig.recipient) == 1

  // Sending it again is the stored receipt, and not a second message.
  let assert Ok(_) = peer_rig.send(rig, "m1")
  assert peer_rig.receipts(rig.recipient) == 1
}

pub fn a_message_that_waits_an_hour_for_a_session_on_another_orchestrator_is_refused_test() {
  let #(now, set_now) = peer_rig.settable_clock(0)
  let hosts = hosts_on(3070, now)
  hosts.listen()
  let rig = hosts.rig
  let assert Ok(_) =
    peers.link(rig.source, remote(hosts), "main", "main", MayWake)
    as "the pair is linked while the recipient is open"
  peer_rig.set_resident(rig, Saved)
  let assert Ok(queued) = peer_rig.send(rig, "m1")
  assert peers.is_queued(queued)

  // Not yet an hour: still owed.
  set_now(peer_outbox.pending_ttl_ms)
  assert list.length(peer_rig.due(rig)) == 1

  // An hour and a millisecond: refused, in words that say it was not opened.
  set_now(peer_outbox.pending_ttl_ms + 1)
  assert peer_rig.due(rig) == []
  let assert Some(peer_outbox.Row(state: peer_outbox.Refused(reason), ..)) =
    peer_rig.row(rig, "m1")
    as "the row is refused"
  assert reason == peer_mail.not_opened_in_time_reason
  assert peer_rig.receipts(rig.recipient) == 0
}

pub fn a_session_deleted_while_a_message_waits_for_it_ends_the_message_refused_test() {
  let hosts = hosts(3080)
  hosts.listen()
  let rig = hosts.rig
  let assert Ok(_) =
    peers.link(rig.source, remote(hosts), "main", "main", MayWake)
    as "the pair is linked while the recipient is open"
  peer_rig.set_resident(rig, Saved)
  let assert Ok(queued) = peer_rig.send(rig, "m1")
  assert peers.is_queued(queued)

  // The owner's catalogue no longer holds it, so nothing will open it.
  peer_rig.set_resident(rig, Gone)
  let assert [row] = peer_rig.due(rig)
  assert peers.resend(rig.wiring, row)
    == peer_outbox.Rejected(peers.not_running)
  assert peer_rig.due(rig) == []
  assert peer_rig.receipts(rig.recipient) == 0
}

pub fn a_session_moved_while_a_message_waits_for_it_is_delivered_by_its_new_owner_test() {
  let hosts = hosts(3090)
  hosts.listen()
  let rig = hosts.rig
  let assert Ok(_) =
    peers.link(rig.source, remote(hosts), "main", "main", MayWake)
    as "the pair is linked while the recipient is open"
  peer_rig.set_resident(rig, Saved)
  let assert Ok(queued) = peer_rig.send(rig, "m1")
  assert peers.is_queued(queued)

  // The session is handed to another orchestrator, where it is open. The next
  // attempt resolves its owner again and follows it there.
  hosts.listen_new()
  hosts.move()
  let assert [row] = peer_rig.due(rig)
  let assert peer_outbox.Receipt(_) = peers.resend(rig.wiring, row)
    as "the new owner admits the message"
  assert peer_rig.receipts(rig.recipient) == 1
  assert peer_rig.due(rig) == []
}

pub fn an_owner_that_serves_no_descriptions_leaves_the_row_unavailable_and_keeps_serving_test() {
  // A port that was not given a catalogue to describe from refuses the
  // question, as a port with no description to give does.
  let name = process.new_name("peer_remote_undescribing_port")
  let port = address.Address(node: node.self(), name:)
  let beta = orchestrators.plain("beta", "beta@127.0.0.1")
  let assert Ok(_) =
    orchestrator_port.start_serving(
      name,
      fn(_) { Ok(Owned) },
      fn(_session, _command) { Ok(json.Null) },
    )
    as "the port starts"
  assert orchestrator_port.ask_description(port, "s", answers_within_ms)
    == Ok(Error(orchestrator_port.peer_unserved))

  // The asker reads the refusal as a description that is not available, and
  // the port is still there to answer the questions it does serve.
  let sessions =
    session_directory.Directory(
      ..session_directory.none(),
      lookup: fn(_) { Ok(session_directory.Elsewhere(orchestrator: beta)) },
      describe: fn(_orchestrator, session) {
        case
          orchestrator_port.ask_description(port, session, answers_within_ms)
        {
          Ok(answer) -> answer
          Error(Nil) -> Error(peer_mail.unreachable_reason)
        }
      },
    )
  assert peers.described(fn(_) { Error("not_found") }, sessions)("s")
    == Error(orchestrator_port.peer_unserved)
  assert orchestrator_port.ask(port, "s", answers_within_ms) == Ok(Owned)
}

fn remote_peer_unused(session: String) -> peer_mail.Endpoint {
  peer_mail.Endpoint(session, fn(_) { Error(peer_mail.Unreachable) })
}
