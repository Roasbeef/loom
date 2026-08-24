//// ORCH-M3 (pi §4.6): an abort must retain a genuinely-settled
//// response's reported usage. The race is built deterministically: the
//// abort request is queued from the writer's post-commit seam of the
//// *request intent* commit — while the strand is still blocked inside
//// that commit call and before the effect process exists — so the
//// mailbox order is exactly RequestAbort first, then the real
//// settlement. The settlement must then commit as `aborted` under its
//// reserved ids with its real usage, not be dropped for a zero-usage
//// synthetic.

import core/clock
import gleam/erlang/process
import runtime/api
import runtime/supervisor
import session/session
import support/fake
import support/harness
import support/recorder

pub fn abort_retains_settled_usage_test() {
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
          0 -> fake.Reply(fake.answer("The full answer", 7))
          _ -> fake.Reply(fake.answer("unexpected turn", 1))
        }
      },
      fn(_run) {
        fake.ToolReply(text: "unused", is_error: False, terminate: False)
      },
    )
  // The rendezvous: commit 4 is the request intent (acceptance,
  // run-start checkpoint, generation ready, intent). Its post-commit
  // seam hands the test an ack subject and blocks the writer — and with
  // it the strand, which is awaiting this very commit's reply — until
  // the test has queued the abort.
  let trigger: process.Subject(process.Subject(Nil)) = process.new_subject()
  let base = api.default_options(harness.configuration())
  let options =
    api.Options(
      ..base,
      poll_interval_ms: 200,
      tolerance: supervisor.Tolerance(intensity: 10_000, period: 10),
      after_commit: fn(ordinal) {
        case ordinal == 4 {
          False -> Nil
          True -> {
            let ack: process.Subject(Nil) = process.new_subject()
            process.send(trigger, ack)
            let assert Ok(Nil) = process.receive(ack, 5000)
              as "the abort rendezvous must complete"
            Nil
          }
        }
      },
    )
  let assert Ok(rt) = api.open(sess, eff, options)
    as "the session tree must boot"
  let assert Ok(op) = api.accept_quietly(rt, [fake.user("work")])
    as "acceptance must succeed"
  api.nudge(rt)
  let assert Ok(ack) = process.receive(trigger, 5000)
    as "the intent commit must reach its seam"
  // Queued while the strand is still inside the intent commit: the
  // abort precedes the settlement in the strand's mailbox.
  api.abort(rt)
  process.send(ack, Nil)
  let assert Ok(last) = api.await_result(rt, op, within_ms: 10_000)
    as "the aborted run must reach its terminal result"
  harness.assert_aborted(last)
  // The billed tokens of the genuinely-settled response survive the
  // abort: the ledger holds the real 7, not the zero-usage synthetic.
  assert harness.ledger_total(sess) == 7
  process.kill(rt.tree.supervisor)
}
