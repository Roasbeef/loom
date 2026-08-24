//// Direct writer and api coverage: committed-event publication through
//// the writer's subscriber seam, read routing, follow-up draining at a
//// may-finish checkpoint, and awaiting a result the strand register has
//// since moved past.

import core/clock
import core/json
import core/register
import core/tx.{SetRegister, Tx}
import gleam/erlang/process
import gleam/option.{Some}
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
