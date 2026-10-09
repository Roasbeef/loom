//// How a daemon answers "where is this recipient" for peer mail, against its
//// real catalogue (protocol-change/078, the peer mail reach addendum).
////
//// A recipient is found in one of three states. Resident, it has an endpoint.
//// Held by this catalogue but not resident, it is saved: a message to it waits
//// for the owner to open it, and nothing here opens it. Held by no catalogue,
//// it is refused, because nothing will ever open it. A session handed to
//// another orchestrator leaves a tombstone, which this daemon redirects from.
//// `peer_remote_test` proves what the senders do with each answer; this proves
//// the daemon gives it.

import client/daemon/main
import client/daemon/server
import client/daemon_server_test as wire
import client/peer_mail
import client/peers
import core/clock
import core/ids
import gleam/option.{None}
import storage/catalogue

// A session no catalogue here holds, in the canonical form the decoder
// requires.
const unheld = "0198c0de-0000-7000-8000-000000000001"

// The id of a move that the tombstones here were made by.
const move = "0192f3c1-7b0e-7d2a-9c11-4f5a6b7c8d9e"

// A registration this catalogue holds and no runtime was ever opened for,
// which is what a saved session is to a peer: held, and not resident.
fn saved(store: catalogue.Catalogue, seed: Int) -> String {
  let #(minted, _) = ids.mint_session(ids.generator(clock.fixed(0), seed))
  let id = ids.session_id_to_string(minted)
  let record =
    catalogue.Registration(
      id:,
      path: "/never-opened-peer-lookup-test/" <> id <> ".db",
      workspace: "/workspace",
      name: "Saved",
      configuration: "",
      profile: None,
      model: None,
      executor: "",
      pool: "",
      created_at: 0,
      request_key: id,
      state: catalogue.Reserved,
      subtitle: None,
    )
  let assert Ok(_) = catalogue.reserve(store, record)
  let assert Ok(_) = catalogue.confirm(store, id)
  id
}

// A session this catalogue handed to another orchestrator.
fn tombstone(store: catalogue.Catalogue, seed: Int) -> String {
  let id = saved(store, seed)
  let assert Ok(_) = catalogue.begin_move(store, id, op: move, to: "laptop")
  let assert Ok(_) = catalogue.finish_move(store, id, op: move)
  id
}

pub fn a_recipient_this_catalogue_holds_but_has_not_opened_is_not_open_test() {
  wire.fixture(fn(_, ready, _port, _credential) {
    let assert Ok(store) = catalogue.open(ready.state_root <> "/catalogue.db")
      as "fixture administration opens the durable catalogue"
    let held = saved(store, 820)
    let local =
      server.local_peer(ready.registry, fn(_) { Error(peer_mail.Unreachable) })

    // Held and not resident is a wait for the owner to open it. Held by no
    // catalogue is a refusal, which nothing will ever cure.
    assert local(held) == Error(peer_mail.NotOpen)
    let assert Error(peer_mail.Refused(_)) = local(unheld)
      as "a session no catalogue holds is refused"

    // A tombstone is still a held row, so the local answer is the same and the
    // session directory behind it decides where the session went.
    assert local(tombstone(store, 821)) == Error(peer_mail.NotOpen)
    assert catalogue.close(store) == Ok(Nil)
  })
}

pub fn the_owner_answers_a_saved_recipient_apart_from_one_it_does_not_hold_test() {
  wire.fixture(fn(_, ready, _port, _credential) {
    let assert Ok(store) = catalogue.open(ready.state_root <> "/catalogue.db")
      as "fixture administration opens the durable catalogue"
    let held = saved(store, 822)
    let serve = main.peer_command(ready.registry, fn(_) { None })
    let roster =
      peer_mail.Roster("0198c0de-0000-7000-8000-0000000000aa", "main")

    // The text a sender turns back into `NotOpen`, and the refusal it does not.
    assert serve(held, roster) == Error(peer_mail.not_open_reason)
    assert serve(unheld, roster) == Error(peers.not_running)
    assert catalogue.close(store) == Ok(Nil)
  })
}
