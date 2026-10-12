//// The outbox drainer, stepped by hand on a fake timer wheel.
////
//// The drainer arms its timer through an injected `after`, so a test records
//// each arming, decides when it rings, and can see that no arming was made.
//// The sender and recipient are real runtimes behind a scripted network
//// (`support/peer_rig`): the network answers "nobody" for a chosen number of
//// deliveries and then reaches the recipient, so the assertions are about
//// what the recipient stored, which is what exactly-once means.

import client/peer_mail
import client/peer_outbox
import client/peer_outbox_drain
import client/peers
import core/clock
import core/ids
import core/json
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{Some}
import runtime/api
import simplifile
import support/addresses
import support/notes_session
import support/peer_rig.{Down, Gone, Lose, Pass, Resident, Saved}
import weft/poll
import weft/registry as address

type Arming {
  Arming(delay_ms: Int, wake: fn() -> Nil)
}

// Starts a drainer over `rig` whose timer arms into the returned subject
// rather than into the clock, and the name a doorbell reaches it by.
fn drainer(
  rig: peer_rig.Rig,
) -> #(Subject(Arming), address.Address(peer_outbox_drain.Message)) {
  let armings = process.new_subject()
  let name = addresses.new()
  let options =
    peer_outbox_drain.options(rig.wiring, fn(delay_ms, wake) {
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

// A timer that was not armed is shown by waiting out a window in which one
// would have been.
fn assert_no_arming(armings: Subject(Arming)) -> Nil {
  let assert Error(Nil) = process.receive(armings, 200)
    as "the drainer holds no timer"
  Nil
}

fn wait_for(what: String, check: fn() -> Bool) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(within: 3000, every: 5, attempt: fn() {
      case check() {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as what
  Nil
}

pub fn an_outbox_with_nothing_owed_runs_one_pass_and_keeps_no_timer_test() {
  let rig = peer_rig.rig(2000, [], Pass)
  let #(armings, _name) = drainer(rig)

  // The pass at session open is armed at once.
  let first = arming(armings)
  assert first.delay_ms == 0
  first.wake()

  // It finds nothing, so nothing is armed after it.
  assert_no_arming(armings)
  assert peer_rig.counts(rig) == #(0, 0)
}

pub fn the_drainer_delivers_one_message_after_the_owner_was_unreachable_twice_test() {
  // The inline attempt and the first pass find nobody; the second pass finds
  // the recipient.
  let rig = peer_rig.rig(2010, [Down, Down], Pass)
  let #(armings, name) = drainer(rig)
  let open = arming(armings)
  open.wake()
  assert_no_arming(armings)

  let assert Ok(queued) = peer_rig.send(rig, "m1")
  assert peers.is_queued(queued)
  peer_outbox_drain.poke(name)

  // A queued message arms the one fixed interval, and that is all it arms.
  let first = arming(armings)
  assert first.delay_ms == peer_outbox_drain.retry_interval_ms
  first.wake()
  let second = arming(armings)
  assert second.delay_ms == peer_outbox_drain.retry_interval_ms
  assert peer_rig.receipts(rig.recipient) == 0
  second.wake()

  wait_for("the recipient admitted the message", fn() {
    peer_rig.receipts(rig.recipient) == 1
  })
  assert_no_arming(armings)
  assert peer_rig.counts(rig) == #(3, 3)
  assert peer_rig.stored_receipt(rig, "m1") != json.Null
  assert peer_rig.due(rig) == []
}

pub fn a_lost_reply_is_delivered_once_and_settled_by_the_drainer_test() {
  let rig = peer_rig.rig(2020, [Lose], Pass)
  let #(armings, name) = drainer(rig)
  let open = arming(armings)
  open.wake()
  let assert Ok(queued) = peer_rig.send(rig, "m1")
  assert peers.is_queued(queued)
  peer_outbox_drain.poke(name)

  // The recipient already holds the message.
  assert peer_rig.receipts(rig.recipient) == 1
  let retry = arming(armings)
  retry.wake()
  wait_for("the row learned the receipt", fn() {
    peer_rig.stored_receipt(rig, "m1") != json.Null
  })

  // The repeat got the stored receipt: still one message.
  assert peer_rig.receipts(rig.recipient) == 1
  assert_no_arming(armings)
}

pub fn a_definitive_refusal_is_never_attempted_again_test() {
  let rig = peer_rig.rig(2030, [], Pass)
  peer_rig.set_resident(rig, Gone)
  assert peer_rig.send(rig, "m1") == Error(peers.not_running)
  let #(armings, _name) = drainer(rig)
  let open = arming(armings)
  open.wake()

  // The refused row is finished: no further lookup, no delivery, no timer.
  assert_no_arming(armings)
  assert peer_rig.counts(rig) == #(0, 1)
}

pub fn a_poke_while_waiting_does_not_arm_a_second_timer_test() {
  let rig = peer_rig.rig(2040, [], Down)
  let #(armings, name) = drainer(rig)
  let open = arming(armings)
  open.wake()
  let assert Ok(_) = peer_rig.send(rig, "m1")
  peer_outbox_drain.poke(name)
  let waiting = arming(armings)
  assert waiting.delay_ms == peer_outbox_drain.retry_interval_ms
  peer_outbox_drain.poke(name)
  peer_outbox_drain.poke(name)
  assert_no_arming(armings)
}

pub fn a_session_that_did_not_answer_is_asked_once_per_pass_test() {
  let rig = peer_rig.rig(2050, [], Down)
  let #(armings, name) = drainer(rig)
  let open = arming(armings)
  open.wake()
  let assert Ok(_) = peer_rig.send(rig, "a")
  let assert Ok(_) = peer_rig.send(rig, "b")
  let assert Ok(_) = peer_rig.send(rig, "c")
  peer_outbox_drain.poke(name)
  assert peer_rig.counts(rig) == #(3, 3)

  // Three rows are owed to one session, and a pass asks it once.
  let pass = arming(armings)
  pass.wake()
  let _next = arming(armings)
  assert peer_rig.counts(rig) == #(4, 4)
  assert list.length(peer_rig.due(rig)) == 3
}

pub fn a_message_owed_for_an_hour_is_refused_and_ends_the_timer_test() {
  let #(now, set_now) = peer_rig.settable_clock(0)
  let rig = peer_rig.rig_on(2060, [], Down, now)
  let #(armings, name) = drainer(rig)
  let open = arming(armings)
  open.wake()
  let assert Ok(_) = peer_rig.send(rig, "m1")
  peer_outbox_drain.poke(name)
  let waiting = arming(armings)
  assert peer_rig.counts(rig) == #(1, 1)

  set_now(peer_outbox.pending_ttl_ms + 1)
  waiting.wake()
  wait_for("the row was refused instead of attempted", fn() {
    case peer_rig.row(rig, "m1") {
      Some(peer_outbox.Row(state: peer_outbox.Refused("owner unreachable"), ..)) ->
        True
      _ -> False
    }
  })

  // No attempt was made for the expired message, and the timer stopped: a new
  // message arms it again, which a machine still waiting would not.
  assert peer_rig.counts(rig) == #(1, 1)
  assert_no_arming(armings)
  let assert Ok(_) = peer_rig.send(rig, "m2")
  peer_outbox_drain.poke(name)
  let again = arming(armings)
  assert again.delay_ms == peer_outbox_drain.retry_interval_ms
}

pub fn unlinking_a_queued_message_ends_its_delivery_test() {
  let rig = peer_rig.rig(2070, [], Down)
  let #(armings, name) = drainer(rig)
  let open = arming(armings)
  open.wake()
  let assert Ok(_) = peer_rig.send(rig, "m1")
  peer_outbox_drain.poke(name)
  let waiting = arming(armings)
  let assert Ok(_) = peers.unlink(rig.source, rig.target, "main", "main")
  process.send(rig.script, peer_rig.SetThen(Pass))
  waiting.wake()

  // The pass found no row, so nothing was delivered and nothing is armed. The
  // machine is idle again: a new message arms it, which a waiting one would
  // not.
  assert_no_arming(armings)
  assert peer_rig.receipts(rig.recipient) == 0
  assert peer_rig.counts(rig) == #(1, 1)
  let assert Ok(_) =
    peers.link(rig.source, rig.target, "main", "main", peer_mail.MayWake)
  process.send(rig.script, peer_rig.SetThen(Down))
  let assert Ok(_) = peer_rig.send(rig, "m2")
  peer_outbox_drain.poke(name)
  let again = arming(armings)
  assert again.delay_ms == peer_outbox_drain.retry_interval_ms
}

pub fn a_saved_recipient_slows_the_drainer_to_a_cap_and_is_delivered_once_open_test() {
  let rig = peer_rig.rig(2090, [], Pass)
  peer_rig.set_resident(rig, Saved)
  let #(armings, name) = drainer(rig)
  let open = arming(armings)
  open.wake()
  assert_no_arming(armings)
  let assert Ok(queued) = peer_rig.send(rig, "m1")
  assert peers.is_queued(queued)
  peer_outbox_drain.poke(name)

  // A queued message is first attempted one fixed interval later. Each pass
  // that finds the recipient still saved doubles the wait, to the cap.
  let delays = waits(armings, 8)
  assert delays
    == [
      5000,
      10_000,
      20_000,
      40_000,
      80_000,
      160_000,
      peer_outbox_drain.max_retry_interval_ms,
      peer_outbox_drain.max_retry_interval_ms,
    ]
  assert peer_rig.receipts(rig.recipient) == 0

  // The owner opens the session; the next pass delivers, exactly once, and
  // nothing is armed after it. The arming is taken first, so the pass that
  // made it has finished before the session is opened.
  let waiting = arming(armings)
  assert waiting.delay_ms == peer_outbox_drain.max_retry_interval_ms
  peer_rig.set_resident(rig, Resident)
  waiting.wake()
  wait_for("the recipient admitted the message", fn() {
    peer_rig.receipts(rig.recipient) == 1
  })
  assert_no_arming(armings)
  assert peer_rig.stored_receipt(rig, "m1") != json.Null
}

pub fn an_owner_that_does_not_answer_returns_the_drainer_to_the_fixed_interval_test() {
  let rig = peer_rig.rig(2100, [], Down)
  peer_rig.set_resident(rig, Saved)
  let #(armings, name) = drainer(rig)
  let open = arming(armings)
  open.wake()
  let assert Ok(_) = peer_rig.send(rig, "m1")
  peer_outbox_drain.poke(name)
  assert waits(armings, 3) == [5000, 10_000, 20_000]

  // The directory now finds the owner, which does not answer. Whatever might
  // have opened the recipient may have opened it, so the wait is the fixed
  // one again and stays so while the owner is silent.
  let waiting = arming(armings)
  assert waiting.delay_ms == 40_000
  peer_rig.set_resident(rig, Resident)
  waiting.wake()
  assert waits(armings, 2) == [5000, 5000]
}

pub fn one_owner_that_does_not_answer_keeps_the_fixed_interval_beside_a_saved_recipient_test() {
  let rig = peer_rig.rig(2120, [], Down)
  let #(armings, name) = drainer(rig)
  let open = arming(armings)
  open.wake()

  // One message waits on an owner that does not answer and another on a
  // recipient that is saved.
  let other = ids.session_id_to_string(peer_rig.session_id(2125))
  let assert Ok(_) = rig.source.call(peer_mail.Link("main", other, "main"))
    as "the sender records the second link"
  let assert Ok(silent) = peer_rig.send(rig, "m1")
  assert peers.is_queued(silent)
  let assert Ok(saved) =
    peers.send(rig.wiring, "main", other, "main", "m2", "hello")
  assert peer_rig.field(saved, "note")
    == json.String(peers.queued_unopened_note)
  peer_outbox_drain.poke(name)

  // Whatever order the pass attempts them in, the owner that is silent may be
  // back by the next pass, so the interval does not grow.
  assert waits(armings, 3) == [5000, 5000, 5000]
}

pub fn a_saved_recipient_is_asked_once_per_pass_beside_a_silent_owner_test() {
  let rig = peer_rig.rig(2130, [], Down)
  let #(armings, name) = drainer(rig)
  let open = arming(armings)
  open.wake()

  // One message waits on an owner that does not answer, which keeps the pass at
  // the fixed interval, and three wait on a recipient that is saved.
  let assert Ok(_) = peer_rig.send(rig, "m1")
  let saved = ids.session_id_to_string(peer_rig.session_id(2135))
  let assert Ok(_) = rig.source.call(peer_mail.Link("main", saved, "main"))
    as "the sender records the link"
  list.each(["s1", "s2", "s3"], fn(id) {
    let assert Ok(queued) =
      peers.send(rig.wiring, "main", saved, "main", id, "hello")
    assert peers.is_queued(queued)
  })
  let before = peer_rig.other_lookups(rig)
  assert before == 3
  peer_outbox_drain.poke(name)

  // The pass asks the saved recipient's owner once, not once for each of the
  // three messages, and the next pass is still the fixed one.
  let first = arming(armings)
  first.wake()
  let second = arming(armings)
  assert second.delay_ms == peer_outbox_drain.retry_interval_ms
  assert peer_rig.other_lookups(rig) == before + 1
}

pub fn a_message_to_a_saved_recipient_is_not_reattempted_by_a_doorbell_test() {
  let rig = peer_rig.rig(2110, [], Pass)
  peer_rig.set_resident(rig, Saved)
  let #(armings, name) = drainer(rig)
  let open = arming(armings)
  open.wake()
  let assert Ok(_) = peer_rig.send(rig, "m1")
  peer_outbox_drain.poke(name)
  let first = arming(armings)
  assert first.delay_ms == peer_outbox_drain.retry_interval_ms
  first.wake()
  let second = arming(armings)
  assert second.delay_ms == 10_000

  // The machine's own settle rings the doorbell after each pass. It must not
  // put the interval back to the fixed one.
  peer_outbox_drain.poke(name)
  peer_outbox_drain.poke(name)
  assert_no_arming(armings)
  second.wake()
  let third = arming(armings)
  assert third.delay_ms == 20_000
}

// The delays of the next `count` armings, each woken as soon as it is seen.
fn waits(armings: Subject(Arming), count: Int) -> List(Int) {
  case count {
    0 -> []
    _ -> {
      let next = arming(armings)
      next.wake()
      [next.delay_ms, ..waits(armings, count - 1)]
    }
  }
}

pub fn a_reopened_sender_resumes_draining_what_it_owed_test() {
  let assert Ok(here) = simplifile.current_directory()
    as "locate the test workspace"
  let root = here <> "/build/peer-outbox-restart-test"
  let _cleared = simplifile.delete_all([root])
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "create the session directory"
  let path = root <> "/session.db"
  let network = peer_rig.network(2081, [Down], Pass)

  // The first incarnation queues a message and ends without delivering it.
  let first = notes_session.open(path, clock.fixed(1000))
  let before =
    peer_rig.attach(network, first.runtime, "sender", clock.fixed(1000))
  let assert Ok(queued) = peer_rig.send(before, "m1")
  assert peers.is_queued(queued)
  assert peer_rig.receipts(network.recipient) == 0
  assert api.close(first.runtime) == Ok(Nil)

  // The second opens the same store with a new drainer and no doorbell. Its
  // pass at session open finds the row and delivers it.
  let second = notes_session.open(path, clock.fixed(1000))
  let after =
    peer_rig.attach(network, second.runtime, "sender", clock.fixed(1000))
  let #(armings, _name) = drainer(after)
  let open = arming(armings)
  assert open.delay_ms == 0
  open.wake()
  wait_for("the reopened sender delivered the message", fn() {
    peer_rig.receipts(network.recipient) == 1
  })
  wait_for("the row recorded the receipt", fn() {
    peer_rig.stored_receipt(after, "m1") != json.Null
  })
  assert_no_arming(armings)
  assert api.close(second.runtime) == Ok(Nil)
  let _removed = simplifile.delete_all([root])
  Nil
}
