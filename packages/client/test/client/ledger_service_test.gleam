//// The `loom_ledger` process (protocol-change/086): what it does with a line
//// offered to it, what it does with a peer's head, and that it stays up
//// whatever a peer sends. Every test runs real services over real files in
//// one VM, with the peers supplied by the test, so the protocol is exercised
//// without a distribution. `ledger_distribution_test` runs it across
//// emulators.

import client/ledger_service.{
  type Observation, Accepted, AlreadyHeld, Behind, Connected, Entries, Extended,
  Head, Loaded, NotDurable, Pull, Reach, Refused,
}
import client/membership_entry.{Upsert}
import client/membership_ledger
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import support/ledger_rig as rig
import support/membership_fixture as fixture
import support/membership_log as history
import support/remote_fixtures
import weft/poll

// Genesis and three entries: two members, then a revoke.
fn log() -> history.Log {
  history.genesis()
  |> history.enroll("hub", [])
  |> history.enroll("laptop", ["hub"])
  |> history.revoke("laptop")
}

fn genesis_line() -> BitArray {
  let assert [genesis] = history.lines(history.genesis())
  genesis
}

fn line_text(line: BitArray) -> String {
  let assert Ok(text) = bit_array.to_string(line) as "lines are text"
  text
}

fn offer(r: rig.Rig, line: BitArray) -> ledger_service.Offered {
  let assert Ok(offered) = ledger_service.offer(r.service, line, 5000)
    as "the service answers"
  offered
}

fn status(r: rig.Rig) -> ledger_service.Status {
  let assert Ok(status) = ledger_service.status(r.service, 5000)
    as "the service answers"
  status
}

fn step_of(status: ledger_service.Status) -> String {
  let assert Some(ledger_service.Rejected(refusal:, ..)) = status.last_refusal
    as "a refusal was recorded"
  membership_ledger.step(refusal)
}

// --- a line offered to the process ----------------------------------------------------

pub fn an_offered_line_extends_the_chain_and_the_file_test() {
  let lines = history.lines(log())
  let assert [genesis, hub, ..rest] = lines
  let r = rig.start("service-offer", [genesis], rig.patient, [])

  let assert Accepted(head) = offer(r, hub)
  assert head.seq == 1
  assert rig.head_seq(r) == 1
  assert rig.file(r) == rig.text_of([genesis, hub])

  // The remaining lines apply in order, and the file keeps them.
  list.each(rest, fn(line) {
    let assert Accepted(_) = offer(r, line)
  })
  assert rig.file(r) == rig.text_of(lines)
}

pub fn observers_see_the_loaded_ledger_then_each_entry_once_it_is_on_disk_test() {
  let lines = history.lines(log())
  let assert [genesis, hub, ..] = lines
  let directory = remote_fixtures.scratch("service-observed")
  let path = directory <> "/ledger.log"
  let seen = process.new_subject()

  // The observer reads the file at the moment it is told: the line it is told
  // about must already be there.
  let observer = fn(observation: Observation) {
    case observation {
      Loaded(_) -> process.send(seen, #("loaded", True))
      Extended(entry:, ..) -> {
        let assert Ok(text) = simplifile.read(path)
        let written =
          string.contains(text, line_text(membership_entry.line(entry)))
        process.send(seen, #("extended", written))
      }
      Connected(_) -> process.send(seen, #("connected", True))
    }
  }
  let r = rig.start_in(directory, [genesis], rig.patient, [observer])

  // `Loaded` arrived before `start` returned.
  assert process.receive(seen, 0) == Ok(#("loaded", True))
  let assert Accepted(_) = offer(r, hub)
  assert process.receive(seen, 1000) == Ok(#("extended", True))
  assert process.receive(seen, 50) == Error(Nil)
}

pub fn a_duplicate_a_gap_and_a_fork_are_told_apart_test() {
  let assert [genesis, hub, _laptop, revoke] = history.lines(log())
  let r = rig.start("service-outcomes", [genesis, hub], rig.patient, [])

  assert offer(r, hub) == AlreadyHeld
  assert offer(r, genesis) == AlreadyHeld

  // The entry after next is a gap: ignored, with the head to start from.
  let assert Behind(head) = offer(r, revoke)
  assert head.seq == 1

  // A different entry at a sequence number this node holds is a fork.
  let base = history.genesis()
  let genesis_head = membership_ledger.head(base.ledger)
  let other =
    fixture.line(
      membership_entry.Entry(
        ..fixture.entry(1, genesis_head.id, Upsert(fixture.member("hub", []))),
        time: fixture.other_stamp,
      ),
    )
  let assert Refused(membership_ledger.Fork(seq: 1, ..)) = offer(r, other)

  // Neither a duplicate nor a gap is a refusal.
  assert status(r).last_refusal != None
  assert step_of(status(r)) == "fork"
  assert rig.head_seq(r) == 1
}

pub fn a_refusal_is_recorded_and_changes_nothing_else_test() {
  let assert [genesis, hub, laptop, ..] = history.lines(log())
  let r = rig.start("service-refusal", [genesis], rig.patient, [])

  let assert Refused(membership_ledger.Unreadable(_)) =
    offer(r, <<"not a line":utf8>>)
  let after_garbage = status(r)
  assert step_of(after_garbage) == "malformed"
  let assert Some(ledger_service.Rejected(seq: None, ..)) =
    after_garbage.last_refusal

  // The node keeps applying lines that extend its chain: a refusal is not a
  // state that stops the next entry.
  let assert Accepted(_) = offer(r, hub)
  let assert Accepted(_) = offer(r, laptop)
  assert rig.head_seq(r) == 2

  // The next refusal replaces the last.
  let stranger = fn(entry) {
    let assert Ok(signed) =
      membership_entry.seal(entry, fixture.stranger_signer())
    membership_entry.line(signed)
  }
  let head = status(r).ledger |> membership_ledger.head
  let forged =
    stranger(fixture.entry(3, head.id, fixture.revoke_kind("laptop")))
  let assert Refused(_) = offer(r, forged)
  assert step_of(status(r)) == "bad_signature"
}

pub fn a_line_the_file_cannot_take_is_not_applied_or_told_to_anyone_test() {
  let assert [genesis, hub, ..] = history.lines(log())
  let directory = remote_fixtures.scratch("service-undurable")
  let seen = process.new_subject()
  let r =
    rig.start_in(directory, [genesis], rig.patient, [
      fn(observation) { process.send(seen, observation) },
    ])
  let assert Ok(Loaded(_)) = process.receive(seen, 0)

  // With the directory gone the new file cannot be made beside the old one.
  let assert Ok(Nil) = simplifile.delete(directory)
  let assert NotDurable(_) = offer(r, hub)
  assert rig.head_seq(r) == 0
  assert process.receive(seen, 50) == Error(Nil)

  // Once the disk is back the same line applies, so nothing was lost or
  // half done.
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
  let assert Ok(Nil) = simplifile.write(r.path, rig.text_of([genesis]))
  let assert Accepted(_) = offer(r, hub)
  assert rig.head_seq(r) == 1
}

pub fn entries_are_read_with_the_bounds_of_a_pull_test() {
  let lines = history.lines(log())
  let r = rig.start("service-read", lines, rig.patient, [])
  let assert [_, one, two, three] = lines

  let assert Ok(Entries(lines: got, head_seq: 3)) =
    ledger_service.entries(r.service, 0, 64, 1000)
  assert got == [one, two, three]
  let assert Ok(Entries(lines: got, ..)) =
    ledger_service.entries(r.service, 1, 1, 1000)
  assert got == [two]

  // A limit below one is read as one, and a start past the head is empty.
  let assert Ok(Entries(lines: got, ..)) =
    ledger_service.entries(r.service, 0, 0, 1000)
  assert got == [one]
  let assert Ok(Entries(lines: got, head_seq: 3)) =
    ledger_service.entries(r.service, 99, 64, 1000)
  assert got == []
}

pub fn a_peers_pull_is_answered_from_the_file_test() {
  let lines = history.lines(log())
  let r = rig.start("service-pulled", lines, rig.patient, [])
  let reply = process.new_subject()
  process.send(
    ledger_service.wire(r.service),
    Pull(after: 1, limit: 64, reply:),
  )
  let assert Ok(Entries(lines: got, head_seq: 3)) = process.receive(reply, 1000)
  assert got == list.drop(lines, 2)
}

// --- heads and pulls --------------------------------------------------------------------

pub fn a_node_that_meets_a_peer_behind_it_is_pulled_from_test() {
  let lines = history.lines(log())
  let ahead = rig.start("service-ahead", lines, rig.patient, [])
  let behind = rig.start("service-behind", [genesis_line()], rig.patient, [])

  // A connects to B. A sends its head, B is behind and pulls.
  ledger_service.meet(ahead.service, rig.reach_to("behind", behind))
  assert rig.await_head(behind, 3) == Ok(3)
  assert rig.file(behind) == rig.text_of(lines)
}

pub fn the_tick_finds_a_peer_that_was_introduced_late_test() {
  let lines = history.lines(log())
  let ahead = rig.start("service-tick-ahead", lines, rig.brisk, [])
  let behind = rig.start("service-tick-behind", [genesis_line()], rig.brisk, [])
  assert rig.head_seq(behind) == 0

  // No node-up and no offer: only the periodic head can reach B.
  rig.set_peers(ahead, [rig.reach_to("behind", behind)])
  assert rig.await_head(behind, 3) == Ok(3)
}

fn indexes(count: Int) -> List(Int) {
  list.index_map(list.repeat(Nil, count), fn(_, index) { index })
}

fn long_log(enrolled: Int, revoked: Int) -> history.Log {
  let names = indexes(enrolled)
  let enrolled_log =
    list.fold(names, history.genesis(), fn(log, index) {
      history.enroll(log, "m" <> int.to_string(index), [])
    })
  list.fold(indexes(revoked), enrolled_log, fn(log, index) {
    history.revoke(log, "m" <> int.to_string(index))
  })
}

pub fn a_long_gap_is_pulled_in_bounded_batches_test() {
  // Seventy entries after genesis need two pulls of at most 64.
  let long = long_log(60, 10)
  let lines = history.lines(long)
  assert list.length(lines) == 71
  let ahead = rig.start("service-long-ahead", lines, rig.patient, [])
  let behind =
    rig.start("service-long-behind", [genesis_line()], rig.patient, [])
  ledger_service.meet(ahead.service, rig.reach_to("behind", behind))
  assert rig.await_head(behind, 70) == Ok(70)
  assert rig.file(behind) == rig.text_of(lines)
}

pub fn a_revoke_reaches_a_node_the_origin_never_connects_to_test() {
  // A reaches B and B reaches C. A and C are not connected.
  let lines = history.lines(log())
  let assert [genesis, hub, laptop, revoke] = lines
  let a = rig.start("service-relay-a", [genesis], rig.patient, [])
  let b = rig.start("service-relay-b", [genesis], rig.patient, [])
  let c = rig.start("service-relay-c", [genesis], rig.patient, [])
  rig.set_peers(a, [rig.reach_to("b", b)])
  rig.set_peers(b, [rig.reach_to("c", c)])

  let assert Accepted(_) = offer(a, hub)
  let assert Accepted(_) = offer(a, laptop)
  assert rig.await_head(c, 2) == Ok(2)

  // The revoke is applied at A and arrives at C through B.
  let assert Accepted(_) = offer(a, revoke)
  assert rig.await_head(c, 3) == Ok(3)
  let assert Ok(final) = ledger_service.status(c.service, 1000)
  assert membership_ledger.members(final.ledger)
    |> list.map(fn(member) { member.name })
    == ["hub"]
}

// --- a peer that misbehaves --------------------------------------------------------------

fn head_of(seq: Int, inbox) -> ledger_service.Message {
  Head(seq:, id: <<0:size(256)>>, from: inbox)
}

fn expect_pull(inbox, within: Int) {
  let assert Ok(Pull(after:, limit:, reply:)) = process.receive(inbox, within)
    as "the service pulled"
  #(after, limit, reply)
}

pub fn a_peer_that_answers_garbage_gets_a_refusal_and_not_a_crash_test() {
  let r = rig.start("service-garbage", [genesis_line()], rig.patient, [])
  let wire = ledger_service.wire(r.service)
  let peer = process.new_subject()

  process.send(wire, head_of(3, peer))
  let #(after, limit, reply) = expect_pull(peer, 1000)
  assert after == 0
  assert limit == 64

  // Garbage lines, and a claim that there is more.
  process.send(
    reply,
    Entries(lines: [<<"garbage":utf8>>, <<>>, <<0:size(64)>>], head_seq: 99),
  )
  let status = status(r)
  assert step_of(status) == "malformed"
  assert process.is_alive(ledger_service.pid(r.service))

  // The exchange ended, so the next head is pulled on again.
  process.send(wire, head_of(3, peer))
  let #(_, _, _) = expect_pull(peer, 1000)
  assert rig.head_seq(r) == 0
}

pub fn a_pull_that_is_never_answered_ends_at_its_deadline_test() {
  let timing = rig.Timing(tick_ms: 3_600_000, pull_within_ms: 100)
  let r = rig.start("service-deadline", [genesis_line()], timing, [])
  let wire = ledger_service.wire(r.service)
  let silent = process.new_subject()
  let live = process.new_subject()

  // The first peer never answers. The second peer's head waits behind that
  // pull, and is pulled on once the deadline passes.
  process.send(wire, head_of(5, silent))
  let #(_, _, _) = expect_pull(silent, 1000)
  process.send(wire, head_of(7, live))
  let #(_, _, _) = expect_pull(live, 5000)
}

pub fn a_head_that_would_start_a_second_pull_waits_for_the_first_test() {
  let r = rig.start("service-postponed", [genesis_line()], rig.patient, [])
  let wire = ledger_service.wire(r.service)
  let first = process.new_subject()
  let second = process.new_subject()

  process.send(wire, head_of(5, first))
  let #(_, _, reply) = expect_pull(first, 1000)
  process.send(wire, head_of(7, second))

  // While the first pull is out, the second peer is not asked.
  assert process.receive(second, 200) == Error(Nil)

  // An answer that moves nothing ends the first exchange, and the second head
  // is judged then.
  process.send(reply, Entries(lines: [], head_seq: 5))
  let #(after, _, _) = expect_pull(second, 1000)
  assert after == 0
}

pub fn heads_that_ask_nothing_are_only_recorded_test() {
  let lines = history.lines(log())
  let r = rig.start("service-recorded", lines, rig.patient, [])
  let wire = ledger_service.wire(r.service)
  let peer = process.new_subject()

  // Behind this node: nothing to pull, but the peer's head is remembered.
  process.send(wire, head_of(1, peer))
  let status = status(r)
  let assert [reported] = status.reported
  assert reported.seq == 1
  assert reported.ms_since >= 0
  assert process.receive(peer, 100) == Error(Nil)
}

pub fn equal_heads_with_different_identities_record_a_fork_test() {
  let base = history.genesis()
  let genesis_head = membership_ledger.head(base.ledger)
  let kind = Upsert(fixture.member("hub", []))
  let mine = fixture.line(fixture.entry(1, genesis_head.id, kind))
  let theirs =
    fixture.line(
      membership_entry.Entry(
        ..fixture.entry(1, genesis_head.id, kind),
        time: fixture.other_stamp,
      ),
    )
  let assert [genesis] = history.lines(base)
  let ours = rig.start("service-fork-ours", [genesis, mine], rig.patient, [])
  let other =
    rig.start("service-fork-theirs", [genesis, theirs], rig.patient, [])

  // The other node announces itself. Its head has our sequence number and
  // another identity, so we ask for that one entry and refuse it.
  ledger_service.meet(other.service, rig.reach_to("ours", ours))
  let assert poll.Answered(Nil) = await_refusal(ours)
  let assert Some(ledger_service.Rejected(
    seq: Some(1),
    refusal: membership_ledger.Fork(seq: 1, ours: held, theirs: offered),
  )) = status(ours).last_refusal
  assert membership_entry.id_to_bytes(held) == rig.id_of(mine)
  assert membership_entry.id_to_bytes(offered) == rig.id_of(theirs)

  // The fork changed neither node.
  assert rig.file(ours) == rig.text_of([genesis, mine])
  assert rig.file(other) == rig.text_of([genesis, theirs])
}

fn await_refusal(r: rig.Rig) -> poll.Outcome(Nil, Nil) {
  poll.until(within: 10_000, every: 20, attempt: fn() {
    case status(r).last_refusal {
      Some(_) -> poll.Done(Nil)
      None -> poll.Retry
    }
  })
}

pub fn a_connected_peer_is_announced_to_the_observers_test() {
  let seen = process.new_subject()
  let r =
    rig.start("service-connected", [genesis_line()], rig.patient, [
      fn(observation) { process.send(seen, observation) },
    ])
  let assert Ok(Loaded(_)) = process.receive(seen, 0)
  let heads = process.new_subject()
  ledger_service.meet(
    r.service,
    Reach(node: "peer@10.0.0.9", deliver: fn(message) {
      process.send(heads, message)
    }),
  )
  assert process.receive(seen, 1000) == Ok(Connected("peer@10.0.0.9"))

  // The peer was told the head.
  let assert Ok(Head(seq: 0, ..)) = process.receive(heads, 1000)
}
