//// Direct writer and api coverage: committed-event publication through
//// the writer's subscriber seam, read routing, follow-up draining at a
//// may-finish checkpoint, awaiting a result the strand register has
//// since moved past, and the two blackboard write doors — including
//// `steer_marking`, which is a queue admission and a write-once claim in
//// one transaction.

import core/clock
import core/ids
import core/json
import core/register
import core/tx.{SetRegister, Tx}
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import machine/operation
import machine/queue
import runtime/api
import runtime/writer
import session/session
import support/fake
import support/harness
import support/recorder

pub fn writer_publishes_committed_events_test() {
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
    as "the memory session must open"
  let events = process.new_subject()
  let name = process.new_name(prefix: "writer_under_test")
  let assert Ok(started) =
    writer.start(
      writer.Options(session: sess, after_commit: fn(_) { Nil }, subscribers: [
        events,
      ]),
      name,
    )
    as "the writer must start"
  let w = started.data
  let commit_tx =
    Tx(
      writes: [
        SetRegister(
          ns: register.FactCustom,
          key: "note",
          value: register.value(json.String("hello")),
        ),
      ],
      expected: [],
    )
  let assert Ok(_) = writer.commit(w, commit_tx) as "the commit must apply"
  // The event was published before the commit reply, so it is already
  // in our mailbox.
  let assert Ok(writer.Committed(ordinal: 1, ..)) =
    process.receive(events, within: 1000)
    as "the subscriber must see the first committed event"
  // A late subscriber sees subsequent commits.
  let late = process.new_subject()
  writer.subscribe(w, late)
  let second_tx =
    Tx(
      writes: [
        SetRegister(
          ns: register.FactCustom,
          key: "note",
          value: register.value(json.String("again")),
        ),
      ],
      expected: [],
    )
  let assert Ok(_) = writer.commit(w, second_tx)
    as "the second commit must apply"
  let assert Ok(writer.Committed(ordinal: 2, ..)) =
    process.receive(late, within: 1000)
    as "the late subscriber must see the second committed event"
  // Reads route through the writer too.
  let assert Ok(Some(_)) = writer.get_register(w, register.FactCustom, "note")
    as "the read must find the committed register"
  process.send_exit(started.pid)
}

pub fn follow_up_is_drained_at_may_finish_test() {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(spec) {
        case fake.turn(spec) {
          0 -> fake.Reply(fake.answer("First", 3))
          _ -> fake.Reply(fake.answer("Second", 4))
        }
      },
      fn(_run) {
        fake.ToolReply(text: "unused", is_error: False, terminate: False)
      },
    )
  let assert Ok(rt) =
    api.open(sess, eff, api.default_options(harness.configuration()))
    as "the session tree must boot"
  // Accept quietly so the follow-up is admitted before any driving.
  let assert Ok(op) = api.accept_quietly(rt, [fake.user("Hello")])
    as "acceptance must succeed"
  let assert Ok(_entry) = api.follow_up(rt, fake.user("One more thing"))
    as "follow-up admission must succeed"
  let assert Ok(outcome) = api.await_result(rt, op, within_ms: 5000)
    as "the run must complete"
  harness.assert_completed(outcome)
  // The follow-up waited for the may-finish boundary: it comes after the
  // first answer, and the run only finished after answering it.
  assert harness.final_projection(sess)
    == [
      "user:Hello",
      "assistant:stop:First",
      "user:One more thing",
      "assistant:stop:Second",
    ]
  harness.assert_placement_invariants(sess)
  process.kill(rt.tree.supervisor)
}

pub fn await_result_survives_a_later_run_test() {
  // `strand.last_result` is one latest-wins register per strand, so a
  // second run overwrites the first's terminal record. A waiter keyed on
  // the first operation — a parent polling a fast child, say — must
  // still observe that operation's own result: the terminal transaction
  // records it operation-keyed, immune to the overwrite. Before that
  // record existed this await spun to timeout and returned `Error(Nil)`,
  // indistinguishable from "still running".
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(spec) {
        case fake.turn(spec) {
          0 -> fake.Reply(fake.answer("first answer", 3))
          _ -> fake.Reply(fake.answer("second answer", 4))
        }
      },
      fn(_run) {
        fake.ToolReply(text: "unused", is_error: False, terminate: False)
      },
    )
  let assert Ok(rt) =
    api.open(sess, eff, api.default_options(harness.configuration()))
    as "the session tree must boot"
  let assert Ok(first_op) = api.prompt(rt, [fake.user("one")])
    as "the first prompt must be accepted"
  let assert Ok(first) = api.await_result(rt, first_op, within_ms: 5000)
    as "the first run must complete"
  harness.assert_completed(first)
  // A second run lands and overwrites the strand's latest-wins register.
  let assert Ok(second_op) = api.prompt(rt, [fake.user("two")])
    as "the second prompt must be accepted"
  let assert Ok(second) = api.await_result(rt, second_op, within_ms: 5000)
    as "the second run must complete"
  harness.assert_completed(second)
  // The first operation's result is still observable, and is genuinely
  // the first operation's — not the latest one relabeled.
  let assert Ok(replayed) = api.await_result(rt, first_op, within_ms: 1000)
    as "the first operation's result must survive the second run"
  assert replayed == first
  process.kill(rt.tree.supervisor)
}

// --- the blackboard's two doors --------------------------------------------

// `put_fact` is last-write-wins and its docstring now says so. This is
// what that costs, stated as a test rather than left to be discovered:
// two writers reading the same cell and appending to it lose one of the
// two appends, silently and with both writes reporting success.
pub fn put_fact_is_last_write_wins_test() {
  let rt = fact_runtime()
  let assert Ok(Nil) = api.put_fact(rt, "review/findings", json.Array([]))
    as "the cell must seed"
  // Two readers, both reading before either writes — the ordinary shape
  // of two agents reporting into one cell.
  let assert Ok(Some(json.Array(first))) = api.fact(rt, "review/findings")
  let assert Ok(Some(json.Array(second))) = api.fact(rt, "review/findings")
  let assert Ok(Nil) =
    api.put_fact(
      rt,
      "review/findings",
      json.Array(list.append(first, [json.String("auth.gleam:42")])),
    )
  let assert Ok(Nil) =
    api.put_fact(
      rt,
      "review/findings",
      json.Array(list.append(second, [json.String("jail.gleam:7")])),
    )
  // One finding, not two. Nothing refused; the first append is simply
  // gone.
  let assert Ok(Some(json.Array(kept))) = api.fact(rt, "review/findings")
  assert kept == [json.String("jail.gleam:7")]
  process.kill(rt.tree.supervisor)
}

// And the door that makes the concurrent case expressible: the same
// write with the seq it was read at asserted, so the loser is told it
// lost instead of never finding out.
pub fn put_fact_expecting_refuses_a_stale_write_test() {
  let rt = fact_runtime()
  let assert Ok(seeded) =
    api.put_fact_expecting(
      rt,
      "review/findings",
      json.Array([]),
      expected: None,
    )
    as "an absent cell is a legitimate expectation"
  // The same cell claimed twice from the same read: the first wins, the
  // second is refused with the key it lost on.
  let assert Ok(Some(api.FactCell(value: json.Array(items), seq:))) =
    api.fact_cell(rt, "review/findings")
  assert seq == seeded
  let assert Ok(_next) =
    api.put_fact_expecting(
      rt,
      "review/findings",
      json.Array(list.append(items, [json.String("auth.gleam:42")])),
      expected: Some(seq),
    )
  let assert Error(api.FactConflict(key: "review/findings")) =
    api.put_fact_expecting(
      rt,
      "review/findings",
      json.Array(list.append(items, [json.String("jail.gleam:7")])),
      expected: Some(seq),
    )
    as "a write from a stale read must be refused, not silently applied"
  // Re-read, re-decide, re-write: the whole point of being told.
  let assert Ok(Some(api.FactCell(value: json.Array(fresh), seq: moved))) =
    api.fact_cell(rt, "review/findings")
  let assert Ok(_final) =
    api.put_fact_expecting(
      rt,
      "review/findings",
      json.Array(list.append(fresh, [json.String("jail.gleam:7")])),
      expected: Some(moved),
    )
  let assert Ok(Some(json.Array(both))) = api.fact(rt, "review/findings")
  assert both == [json.String("auth.gleam:42"), json.String("jail.gleam:7")]
  // It is the same door, not a wider one: reserved keys are refused
  // here exactly as they are to `put_fact`.
  let assert Error(api.ReservedFactKey(key: "escalation/esc-1")) =
    api.put_fact_expecting(
      rt,
      "escalation/esc-1",
      json.String("forged"),
      expected: None,
    )
    as "the compare-and-set door is not a way past the reservations"
  process.kill(rt.tree.supervisor)
}

// --- steer_marking ---------------------------------------------------------

// The whole point of the door: the item and the claim are one commit, so
// there is no order in which a crash can leave one without the other.
pub fn steer_marking_queues_the_item_and_writes_the_mark_test() {
  let rt = marking_runtime()
  let assert Ok(op) = api.accept_quietly(rt, [fake.user("Hello")])
    as "acceptance must succeed"
  let assert Ok(_entry) =
    api.steer_marking(rt, fake.user("injected"), mark: claim("r"))
    as "the marked admission must land"
  assert steer_count(rt, op) == 1
  let assert Ok(Some(json.String("r"))) = api.fact(rt, mark_key("r"))
    as "the mark must be durable"
  process.kill(rt.tree.supervisor)
}

// The exactly-once property, at the level the property lives: a second
// claim on the same cell is refused *and queues nothing*. Without the
// `None` expectation the second admission would simply succeed, and an
// injector that re-derived the same decision after a restart would put a
// second copy of the same text into the conversation.
pub fn steer_marking_refuses_a_second_claim_on_the_same_mark_test() {
  let rt = marking_runtime()
  let assert Ok(op) = api.accept_quietly(rt, [fake.user("Hello")])
    as "acceptance must succeed"
  let assert Ok(_entry) =
    api.steer_marking(rt, fake.user("injected"), mark: claim("r"))
    as "the first claim must land"
  let assert Error(api.FactConflict(key:)) =
    api.steer_marking(rt, fake.user("injected again"), mark: claim("r"))
    as "a second claim on a taken mark must be refused"
  assert key == mark_key("r")
  // The refusal is a refusal of the whole transaction: one item on the
  // queue, not two.
  assert steer_count(rt, op) == 1
  process.kill(rt.tree.supervisor)
}

// A stale mark is not the seq race the admission ladder exists for, so
// it must not be retried into a `RaceLost` that names the wrong cause —
// and a *different* mark on the same run is admitted normally, which is
// what shows the refusal above was about the cell and not about the run.
pub fn steer_marking_admits_a_different_mark_on_the_same_run_test() {
  let rt = marking_runtime()
  let assert Ok(op) = api.accept_quietly(rt, [fake.user("Hello")])
    as "acceptance must succeed"
  let assert Ok(_first) =
    api.steer_marking(rt, fake.user("one"), mark: claim("first"))
    as "the first claim must land"
  let assert Ok(_second) =
    api.steer_marking(rt, fake.user("two"), mark: claim("second"))
    as "a claim on another cell must land"
  assert steer_count(rt, op) == 2
  process.kill(rt.tree.supervisor)
}

// The two write paths stay disjoint. This door writes reserved cells for
// harness code; an ordinary fact belongs to `put_fact`, and letting a
// caller reach one through the other would make the reservation
// decorative.
pub fn steer_marking_refuses_an_unreserved_key_test() {
  let rt = marking_runtime()
  let assert Ok(op) = api.accept_quietly(rt, [fake.user("Hello")])
    as "acceptance must succeed"
  let assert Error(api.UnreservedFactKey(key: "agent/main/note")) =
    api.steer_marking(
      rt,
      fake.user("injected"),
      mark: api.Mark(key: "agent/main/note", value: json.String("r")),
    )
    as "an unreserved mark must be refused"
  assert steer_count(rt, op) == 0
  process.kill(rt.tree.supervisor)
}

// An idle strand refuses the admission — and, because the mark rides in
// the same transaction, spends nothing. A claim that was written while
// its message was refused would be the worst of both: the injector would
// believe it had fired, and nothing would ever have been injected.
pub fn steer_marking_on_an_idle_strand_spends_no_claim_test() {
  let rt = marking_runtime()
  let assert Error(api.QueueRejected(reason: queue.NoActiveRun)) =
    api.steer_marking(rt, fake.user("injected"), mark: claim("r"))
    as "an idle strand has nothing to steer"
  let assert Ok(None) = api.fact(rt, mark_key("r"))
    as "a refused admission must leave the claim unspent"
  process.kill(rt.tree.supervisor)
}

// --- send_to_strand_marking -------------------------------------------

// Exactly-once on the fresh-run door: an idle strand's send takes the
// accept-quietly-marking path, and the mark lands in the same commit as
// the accepted run — the same guarantee `steer_marking` gives the steer
// door, applied to the door that had no marking equivalent before this.
pub fn send_to_strand_marking_starts_a_fresh_run_and_writes_the_mark_test() {
  let rt = marking_runtime()
  let assert Ok(api.Started(operation: _op)) =
    api.send_to_strand_marking(
      rt,
      to: "main",
      message: fake.user("wake up"),
      mark: claim("wake"),
    )
    as "an idle strand must accept a fresh run"
  let assert Ok(Some(json.String("wake"))) = api.fact(rt, mark_key("wake"))
    as "the mark must be durable"
  assert harness.final_projection(rt.session) == ["user:wake up"]
    as "the accepted run must actually hold the message"
  process.kill(rt.tree.supervisor)
}

// The exactly-once property traced through the real reconciliation: the
// first attempt opens the run, so the second attempt's `steer_marking`
// finds an *open* run rather than `NoActiveRun` and never falls back to
// `accept_quietly_marking` at all. It is the mark's own stale
// expectation on that steer commit — not a race against the strand —
// that refuses it, and the refusal is of the whole transaction, so no
// second copy of the message reaches the run's queue.
pub fn send_to_strand_marking_a_second_time_is_refused_and_does_not_double_start_test() {
  let rt = marking_runtime()
  let mark = claim("wake")
  let assert Ok(api.Started(operation: op)) =
    api.send_to_strand_marking(
      rt,
      to: "main",
      message: fake.user("wake up"),
      mark:,
    )
    as "the first attempt must start a fresh run"
  let assert Error(api.FactConflict(key:)) =
    api.send_to_strand_marking(
      rt,
      to: "main",
      message: fake.user("wake up again"),
      mark:,
    )
    as "the second attempt must meet the mark already spent, via a steer"
  assert key == mark_key("wake")
  assert steer_count(rt, op) == 0
    as "the refused transaction must not have queued a second copy"
  process.kill(rt.tree.supervisor)
}

// An already-open run steers exactly like a direct `steer_marking` call:
// the fresh-run fallback never triggers because `NoActiveRun` never
// fires, so this door behaves identically to the one it wraps whenever
// there is a run to steer onto.
pub fn send_to_strand_marking_steers_an_open_run_test() {
  let rt = marking_runtime()
  let assert Ok(op) = api.accept_quietly(rt, [fake.user("Hello")])
    as "acceptance must succeed"
  let assert Ok(api.Steered(entry: _)) =
    api.send_to_strand_marking(
      rt,
      to: "main",
      message: fake.user("also this"),
      mark: claim("wake"),
    )
    as "an open run must be steered, not accepted"
  assert steer_count(rt, op) == 1
  let assert Ok(Some(json.String("wake"))) = api.fact(rt, mark_key("wake"))
    as "the mark must be durable"
  process.kill(rt.tree.supervisor)
}

// `send_to_strand_marking` is its own entry point and carries its own
// reserved-key guard rather than trusting `accept_quietly_marking`, which
// has none (it trusts its own caller, like `accept_quietly`). A refused
// guard must leave the idle strand untouched.
pub fn send_to_strand_marking_refuses_an_unreserved_key_test() {
  let rt = marking_runtime()
  let assert Error(api.UnreservedFactKey(key: "agent/main/note")) =
    api.send_to_strand_marking(
      rt,
      to: "main",
      message: fake.user("wake up"),
      mark: api.Mark(key: "agent/main/note", value: json.String("wake")),
    )
    as "an unreserved mark must be refused"
  // Nothing was queued or started: the strand is still idle enough to
  // accept a fresh run cleanly.
  let assert Ok(_op) = api.accept_quietly(rt, [fake.user("Hello")])
    as "the guard must have refused before touching admission"
  process.kill(rt.tree.supervisor)
}

fn mark_key(rule: String) -> String {
  api.rule_fact_prefix <> "fired/main/" <> rule
}

fn claim(rule: String) -> api.Mark {
  api.Mark(key: mark_key(rule), value: json.String(rule))
}

// How many steer items the operation's durable inbox holds.
fn steer_count(rt: api.Runtime, op: ids.OpId) -> Int {
  case session.op_state(rt.session, op) {
    Ok(Some(session.Cell(
      value: operation.RunState(inbox: operation.Inbox(steer:, ..), ..),
      ..,
    ))) -> list.length(steer)
    _ -> -1
  }
}

// A runtime whose provider never settles, so the run it accepts stays
// open for as long as the test needs one to steer.
fn marking_runtime() -> api.Runtime {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(_spec) { fake.Hang },
      fn(_run) {
        fake.ToolReply(text: "unused", is_error: False, terminate: False)
      },
    )
  let assert Ok(rt) =
    api.open(sess, eff, api.default_options(harness.configuration()))
    as "the session tree must boot"
  rt
}

// A runtime with nothing driving it: these two are about the durable
// cell, not about a run.
fn fact_runtime() -> api.Runtime {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(_spec) { fake.Reply(fake.answer("unused", 1)) },
      fn(_run) {
        fake.ToolReply(text: "unused", is_error: False, terminate: False)
      },
    )
  let assert Ok(rt) =
    api.open(sess, eff, api.default_options(harness.configuration()))
    as "the session tree must boot"
  rt
}
