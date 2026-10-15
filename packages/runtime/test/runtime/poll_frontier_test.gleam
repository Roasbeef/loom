//// A live effect can park without repeatedly reloading large payloads.
//// The checkpoint backstop still observes durable changes without a doorbell.

import core/clock
import core/register
import core/tx
import gleam/option.{None}
import machine/codec
import runtime/api
import runtime/writer
import session/session
import support/fake
import support/harness
import support/held_operation.{Assistant, Summary}
import support/recorder
import weft/poll

pub fn unchanged_summary_polls_do_not_reload_preparation_test() {
  let assert Ok(sess) = session.open_memory(clock.fixed(1000))
    as "the fixture session opens"
  let #(first, later, before, after) =
    held_operation.run(sess, Summary, 25, fn(held) {
      let first = held_operation.wait_for_reads(held, 8)
      let before = recorder.read(held.counters, "preparation")
      let later = held_operation.wait_for_reads(held, 8)
      #(first, later, before, recorder.read(held.counters, "preparation"))
    })
  assert first == poll.Answered(Nil)
  assert later == poll.Answered(Nil)
  assert before > 0
  assert after == before
}

pub fn quiet_steer_invalidates_a_parked_frontier_test() {
  let assert Ok(sess) = session.open_memory(clock.fixed(1000))
    as "the fixture session opens"
  let #(ready, admitted, observed) =
    held_operation.run(sess, Assistant, 25, fn(held) {
      let ready = held_operation.wait_for_reads(held, 8)
      let before = recorder.read(held.counters, "preparation")
      let admitted = api.steer_quietly(held.runtime, fake.user("quiet steer"))
      let observed =
        poll.until(within: 3000, every: 10, attempt: fn() {
          case recorder.read(held.counters, "preparation") > before {
            True -> poll.Done(Nil)
            False -> poll.Retry
          }
        })
      #(ready, admitted, observed)
    })
  assert ready == poll.Answered(Nil)
  let assert Ok(_) = admitted as "quiet steering commits without a doorbell"
  assert observed == poll.Answered(Nil)
}

pub fn independent_leaf_and_configuration_changes_reload_test() {
  let assert Ok(sess) = session.open_memory(clock.fixed(1000))
    as "the fixture session opens"
  let #(ready, committed, observed, configured, reloaded) =
    held_operation.run(sess, Assistant, 25, fn(held) {
      let ready = held_operation.wait_for_reads(held, 8)
      let before = recorder.read(held.counters, "preparation")
      let committed =
        writer.commit(
          held.runtime.tree.writer,
          tx.Tx(
            [
              tx.SetRegister(
                register.StrandLeaf,
                "main",
                register.leaf_value(None),
              ),
            ],
            [],
          ),
        )
      let observed =
        poll.until(within: 3000, every: 10, attempt: fn() {
          case recorder.read(held.counters, "preparation") > before {
            True -> poll.Done(Nil)
            False -> poll.Retry
          }
        })
      let before = recorder.read(held.counters, "preparation")
      let configured =
        writer.commit(
          held.runtime.tree.writer,
          tx.Tx(
            [
              tx.SetRegister(
                register.StrandConfig,
                "main",
                register.value(
                  codec.encode_configuration(harness.configuration()),
                ),
              ),
            ],
            [],
          ),
        )
      let reloaded =
        poll.until(within: 3000, every: 10, attempt: fn() {
          case recorder.read(held.counters, "preparation") > before {
            True -> poll.Done(Nil)
            False -> poll.Retry
          }
        })
      #(ready, committed, observed, configured, reloaded)
    })
  assert ready == poll.Answered(Nil)
  let assert Ok(_) = committed as "the independent leaf change commits"
  assert observed == poll.Answered(Nil)
  let assert Ok(_) = configured as "configuration can move independently"
  assert reloaded == poll.Answered(Nil)
}
