//// Peer mail between two orchestrators, against the shipped daemon: two real
//// `bin/loomd` processes that trust each other over TLS distribution and list
//// each other under `[orchestrators.<name>]` (issue #697,
//// protocol-change/078, phase 4).
////
//// A session `a` lives on `alpha` and a session `b` on `bravo`. Each
//// orchestrator keeps its own catalogue, so a message from `a` to `b` has to
//// find `b`'s owner (the session directory), cross to it (the orchestrator
//// port's `PeerCommand`), and be admitted by `b`'s own Agency. When `bravo`
//// cannot be reached the message is recorded in `a`'s outbox and delivered
//// later, once.
////
//// ## What it proves
////
//// `a_message_to_an_unreachable_orchestrator_is_delivered_once_it_returns_test_`
////
//// 1. `a` is linked to `b` by the control command on `alpha`, which writes the
////    recipient's grant on `bravo`.
//// 2. A send of `m1` is admitted, `b`'s transcript holds exactly one peer
////    message for it, and `a`'s outbox row is `admitted`.
//// 3. `bravo` is stopped. A send of `m2` answers `queued`, and `a`'s row is
////    `pending` with the text it must deliver.
//// 4. `alpha` is frozen while `bravo` starts again and `b` is opened, and then
////    runs again. The freeze orders the events: a retry that landed after
////    `bravo` was up and before `b` was resident would be refused, as
////    protocol-change/077 requires of a send to a session that is not running.
//// 5. `b`'s transcript holds exactly one peer message for `m2`, and `a`'s row
////    is `admitted` with the recipient's receipt. The drainer did it with no
////    help from the test.
//// 6. A send of `m2` again, with the same id and text, answers that receipt
////    and adds nothing to `b`'s transcript.
////
//// `a_message_between_directory_members_is_delivered_once_the_owner_returns_test_`
////
//// The same six steps with the session directory's Khepri cluster
//// (protocol-change/079): `alpha`, `bravo` and an executor are its members,
//// and `a` and `b` are remote sessions on that executor, since a member
//// records only the sessions it places on executors. `alpha` finds `b`'s owner
//// in its own copy of the owner records instead of asking `bravo`, which is
//// what lets it know whom to queue for while `bravo` is down.
////
//// `a_first_link_over_a_slow_handshake_still_links_test_`
////
//// A link cut with the probe's `drop` step would not do for the unreachable
//// part: `alpha` connects on demand (`session_directory.over_distribution`),
//// so the next question repairs the link, and the message would be delivered
//// at once instead of queued. The owner has to be down.
////
//// ## Prerequisites and skips
////
//// Sessions here are local, so the daemons run a helper pool and the host has to
//// enforce a policy. A host whose helper cannot prints `SKIP shipped remote
//// peer mail: ...` and passes, as the other shipped fixtures do. The messages
//// wake `b`, whose model URL has nothing listening, so its run fails; the
//// message is in the transcript before the run starts.
////
//// ## Running it
////
//// ```sh
//// make server-shipment
//// make sandbox && install -m 0755 packages/sandbox/loom-exec bin/loom-exec
//// export LOOM_BOOTSTRAP_E2E_SERVER=$PWD/bin/loomd
//// export LOOM_TEST_PROVIDER_KEY=loom-provider-fixture-key
//// bash scripts/test.sh client --match 'client@daemon_shipped_peer_mail_test:'
//// ```
////
//// The daemons, credentials and control commands are the vocabulary of
//// `support/remote_daemons`, arranged for two orchestrators by
//// `support/remote_duo`, which also reads a daemon's store from a copy. The
//// fixture directory is under `/var/tmp` and short, because a daemon binds unix
//// sockets below its state root.

import client/peer_outbox
import client/tui_e2e_test.{type EunitTest}
import core/json.{type JsonValue}
import gleam/erlang/process
import gleam/option.{None, Some}
import support/remote_daemons
import support/remote_duo.{type Duo}
import weft/poll

const skip_label = "shipped remote peer mail"

// How long the drainer may take to deliver once both sides are ready: one
// retry interval and the directory's deadline, with room.
const delivered_within_ms = 40_000

const member_label = "shipped remote peer mail between directory members"

pub fn a_message_to_an_unreachable_orchestrator_is_delivered_once_it_returns_test_() -> EunitTest {
  remote_duo.shipped(skip_label, fn(duo) {
    let keys = remote_duo.provision(duo)
    remote_duo.configure(duo, keys, None)
    let alpha = remote_daemons.start(duo.alpha)
    let bravo = remote_daemons.start(duo.bravo)
    delivered_once(duo, alpha, bravo, fn(control, key, layout) {
      remote_daemons.create_local_and_settle(control, 1, key, layout.workspace)
    })
  })
}

pub fn a_message_between_directory_members_is_delivered_once_the_owner_returns_test_() -> EunitTest {
  remote_duo.shipped(member_label, fn(duo) {
    let keys = remote_duo.provision(duo)
    remote_duo.configure_members(duo, keys, None)
    let members = remote_duo.start_members(duo)
    delivered_once(duo, members.alpha, members.bravo, fn(control, key, _layout) {
      remote_daemons.create_and_settle(
        control,
        1,
        key,
        remote_duo.executor_name,
        remote_duo.workspace_name,
      )
    })
  })
}

const slow_label = "shipped remote peer mail over a slow first handshake"

// How long `bravo` is held stopped while `alpha` makes the first connection to
// it. It is longer than the bound a session lookup puts on one connection, so
// the first attempt at the handshake cannot finish inside it.
const handshake_held_ms = 3000

pub fn a_first_link_over_a_slow_handshake_still_links_test_() -> EunitTest {
  remote_duo.shipped(slow_label, fn(duo) {
    let keys = remote_duo.provision(duo)
    remote_duo.configure(duo, keys, None)
    let alpha = remote_daemons.start(duo.alpha)
    let bravo = remote_daemons.start(duo.bravo)
    let on_alpha = remote_daemons.open_control(alpha)
    let on_bravo = remote_daemons.open_control(bravo)
    let #(a, settled) =
      remote_daemons.create_local_and_settle(
        on_alpha,
        1,
        "e2e-a",
        duo.alpha.workspace,
      )
    assert remote_daemons.settled_state(settled) == "resident"
      as { "a opens: " <> json.to_string(settled) }
    let #(b, settled) =
      remote_daemons.create_local_and_settle(
        on_bravo,
        1,
        "e2e-b",
        duo.bravo.workspace,
      )
    assert remote_daemons.settled_state(settled) == "resident"
      as { "b opens: " <> json.to_string(settled) }

    // Nothing has connected `alpha` to `bravo` yet, so the link pays for the
    // first TLS handshake. `bravo` is held stopped while it does: the
    // connection is accepted by its kernel and the handshake waits, which is
    // what a loaded machine does to it, without loading this one. It runs
    // again after a fixed time, whatever `alpha` is doing.
    remote_duo.freeze(duo.bravo)
    let thaw =
      process.spawn(fn() {
        process.sleep(handshake_held_ms)
        remote_duo.thaw(duo.bravo)
      })
    let linked = remote_daemons.peers_link(on_alpha, 10, a, b)
    let _ = thaw
    remote_duo.thaw(duo.bravo)
    assert remote_daemons.field(linked, "event") == json.String("peers.link")
      as { "a slow first handshake still links: " <> json.to_string(linked) }
    Nil
  })
}

// The six steps, with `a` created on `alpha` and `b` on `bravo` by `create`,
// which is given the control socket, the request key and the daemon's layout.
fn delivered_once(
  duo: Duo,
  alpha: remote_daemons.Running,
  bravo: remote_daemons.Running,
  create: fn(remote_daemons.Control, String, remote_daemons.Layout) ->
    #(String, JsonValue),
) -> Nil {
  let on_alpha = remote_daemons.open_control(alpha)
  let on_bravo = remote_daemons.open_control(bravo)
  let #(a, settled) = create(on_alpha, "e2e-a", duo.alpha)
  assert remote_daemons.settled_state(settled) == "resident"
    as { "a opens: " <> json.to_string(settled) }
  let #(b, settled) = create(on_bravo, "e2e-b", duo.bravo)
  assert remote_daemons.settled_state(settled) == "resident"
    as { "b opens: " <> json.to_string(settled) }

  // The owner links the pair from `alpha`, which writes the grant on
  // `bravo`: the first command that crosses.
  let linked = remote_daemons.peers_link(on_alpha, 10, a, b)
  assert remote_daemons.field(linked, "event") == json.String("peers.link")
    as { "the link answers peers.link: " <> json.to_string(linked) }

  // A send to a session on a reachable orchestrator is admitted exactly as a
  // local one is.
  let sent =
    remote_daemons.peers_send(on_alpha, 11, a, b, "m1", "first message")
  assert remote_daemons.field(sent, "event") == json.String("peers.send")
    as { "the send answers peers.send: " <> json.to_string(sent) }
  assert remote_daemons.field(body_of(sent), "admitted") == json.Bool(True)
    as { "the send is admitted: " <> json.to_string(sent) }
  await_peer_messages(duo, b, "first message", 1)
  await_row(duo, a, b, "m1", Admitted)

  // `bravo` goes away with `b` resident on it. The send is recorded and
  // answers `queued`; nothing reached `b`.
  remote_daemons.retire(duo.bravo.paths)
  let queued =
    remote_daemons.peers_send(on_alpha, 12, a, b, "m2", "second message")
  assert remote_daemons.field(queued, "event") == json.String("peers.send")
    as { "the send answers peers.send: " <> json.to_string(queued) }
  assert remote_daemons.field(body_of(queued), "state") == json.String("queued")
    as { "the send is queued: " <> json.to_string(queued) }
  await_row(duo, a, b, "m2", Pending)

  // `alpha` is frozen while `bravo` starts again and `b` is opened, so that
  // no retry runs in between. When it runs again its drainer finds `b`
  // resident.
  remote_duo.freeze(duo.alpha)
  let bravo = remote_daemons.start(duo.bravo)
  let on_bravo = remote_daemons.open_control(bravo)
  let reopened = remote_daemons.reopen_session(on_bravo, 100, b)
  assert remote_daemons.settled_state(reopened) == "resident"
    as { "b opens again: " <> json.to_string(reopened) }
  remote_duo.thaw(duo.alpha)

  // The drainer delivers it, once.
  await_row(duo, a, b, "m2", Admitted)
  await_peer_messages(duo, b, "second message", 1)
  await_peer_messages(duo, b, "first message", 1)

  // The same id and text again is the stored receipt, and `b` gains nothing.
  let receipt = row_receipt(duo, a, b, "m2")
  let again =
    remote_daemons.peers_send(on_alpha, 13, a, b, "m2", "second message")
  assert remote_daemons.field(again, "event") == json.String("peers.send")
    as { "the repeat answers peers.send: " <> json.to_string(again) }
  assert body_of(again) == receipt
    as { "the repeat answers the stored receipt: " <> json.to_string(again) }
  assert peer_messages(duo, b, "second message") == Ok(1)
  Nil
}

// --- control commands --------------------------------------------------------

fn body_of(reply: JsonValue) -> JsonValue {
  remote_daemons.field(reply, "body")
}

// --- what the stores hold ----------------------------------------------------

type Standing {
  Pending
  Admitted
}

// The sender's outbox row for `message_id`, read from a copy of `alpha`'s
// store. A copy that could not be read is no row yet.
fn row(
  duo: Duo,
  source: String,
  target: String,
  message_id: String,
) -> Result(peer_outbox.Row, String) {
  let key = peer_outbox.key("main", target, message_id)
  case remote_duo.session_fact(duo, duo.alpha, source, key) {
    Ok(Some(value)) -> peer_outbox.decode(value)
    Ok(None) -> Error("no outbox row yet")
    Error(reason) -> Error(reason)
  }
}

fn await_row(
  duo: Duo,
  source: String,
  target: String,
  message_id: String,
  want: Standing,
) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(within: delivered_within_ms, every: 500, attempt: fn() {
      case row(duo, source, target, message_id), want {
        Ok(peer_outbox.Row(state: peer_outbox.Pending(..), ..)), Pending
        | Ok(peer_outbox.Row(state: peer_outbox.Admitted(..), ..)), Admitted
        -> poll.Done(Nil)
        Ok(peer_outbox.Row(state: peer_outbox.Refused(reason:), ..)), _ ->
          poll.Fail("the message was refused: " <> reason)
        _, _ -> poll.Retry
      }
    })
    as { "the outbox row for " <> message_id <> " reaches its state" }
  Nil
}

fn row_receipt(
  duo: Duo,
  source: String,
  target: String,
  message_id: String,
) -> JsonValue {
  let assert Ok(peer_outbox.Row(state: peer_outbox.Admitted(receipt:), ..)) =
    row(duo, source, target, message_id)
    as "the row holds the recipient's receipt"
  receipt
}

// Every message in these steps lands on `bravo`, so the counts read its store.
fn peer_messages(
  duo: Duo,
  session: String,
  text: String,
) -> Result(Int, String) {
  remote_duo.peer_messages(duo, duo.bravo, session, text)
}

fn await_peer_messages(
  duo: Duo,
  session: String,
  text: String,
  want: Int,
) -> Nil {
  remote_duo.await_peer_messages(duo, duo.bravo, session, text, want)
}
