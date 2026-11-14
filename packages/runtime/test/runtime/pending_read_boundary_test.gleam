//// Runtime placement at failure and abort boundaries with queued inputs.
//// The provider is held until the test has durably populated the inbox.

import core/clock
import core/ids
import core/json
import core/register
import core/tx
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import machine/codec
import machine/operation.{PendingCustom}
import machine/queue
import provider/stream
import runtime/api
import runtime/writer
import session/session
import storage/storage
import support/fake
import support/harness
import support/recorder

type Boundary {
  Fail
  Abort
}

pub fn failure_drain_places_queued_inputs_once_test() {
  let #(rt, sess, rec, release, op) = start(Fail)
  let #(steer, follow, write) = queue_inputs(rt, sess, op)
  process.send(release, Nil)
  let assert Ok(outcome) = api.await_result(rt, op, within_ms: 5000)
    as "the failed request must recover after the queued steer"
  harness.assert_completed(outcome)
  assert recorder.read(rec, "failure-drain") > 0
  let projection = harness.final_projection(sess)
  assert count(projection, "user:steer") == 1
  assert count(projection, "user:follow") == 1
  let assert Ok(entries) =
    storage.get_entries(sess.store, [steer, follow, write])
    as "the placed entries must be readable"
  assert dict.size(entries) == 3
  harness.assert_placement_invariants(sess)
  close(rt, rec)
}

pub fn abort_places_write_and_discards_drained_inputs_once_test() {
  let #(rt, sess, rec, _release, op) = start(Abort)
  let #(steer, follow, write) = queue_inputs(rt, sess, op)
  api.abort(rt)
  let assert Ok(outcome) = api.await_result(rt, op, within_ms: 5000)
    as "the aborted run must terminate"
  harness.assert_aborted(outcome)
  let assert Ok(entries) =
    storage.get_entries(sess.store, [steer, follow, write])
    as "the terminal entries must be readable"
  assert dict.size(entries) == 1
  assert dict.has_key(entries, write)
  assert !dict.has_key(entries, steer)
  assert !dict.has_key(entries, follow)
  harness.assert_placement_invariants(sess)
  close(rt, rec)
}

fn start(boundary: Boundary) {
  let rec = recorder.start()
  let ready = process.new_subject()
  let assert Ok(original) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session opens"
  let commit = original.store.commit
  let store =
    storage.Storage(..original.store, commit: fn(handle, transaction) {
      let result = commit(handle, transaction)
      case result {
        Ok(_) -> {
          let tx.Tx(writes:, ..) = transaction
          let entered =
            list.any(writes, fn(write) {
              case write {
                tx.SetRegister(register.OpState, _, value) ->
                  case codec.decode_state(value.payload) {
                    Ok(operation.RunState(phase: operation.FailureDrain(..), ..)) ->
                      True
                    _ -> False
                  }
                _ -> False
              }
            })
          case entered {
            True -> {
              let _ = recorder.bump(rec, "failure-drain")
              Nil
            }
            False -> Nil
          }
        }
        Error(_) -> Nil
      }
      result
    })
  let sess = session.Session(..original, store:)
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(_) {
        case recorder.bump(rec, "boundary-requests") {
          1 -> {
            let release = process.new_subject()
            process.send(ready, release)
            case boundary {
              Fail -> {
                process.receive_forever(release)
                fake.Refuse(stream.HttpError(
                  status: 400,
                  api_error_type: "invalid_request_error",
                  message: "bad request",
                  retry_after_ms: None,
                ))
              }
              Abort -> fake.Hang
            }
          }
          _ -> fake.Reply(fake.answer("recovered", 3))
        }
      },
      fn(_) {
        fake.ToolReply(text: "unused", is_error: False, terminate: False)
      },
    )
  let assert Ok(rt) =
    api.open(sess, eff, api.default_options(harness.configuration()))
    as "the runtime opens"
  let assert Ok(op) = api.prompt(rt, [fake.user("start")]) as "the run starts"
  let assert Ok(release) = process.receive(ready, within: 5000)
    as "the provider is held before settlement"
  #(rt, sess, rec, release, op)
}

fn queue_inputs(rt: api.Runtime, sess: session.Session, op: ids.OpId) {
  let assert Ok(steer) = api.steer_quietly(rt, fake.user("steer"))
    as "the steer is queued"
  let assert Ok(follow) = api.follow_up(rt, fake.user("follow"))
    as "the follow-up is queued"
  let assert Ok(Some(session.Cell(value: meta, ..))) = session.op_meta(sess, op)
    as "the operation metadata exists"
  let assert Ok(Some(session.Cell(value: state, seq:))) =
    session.op_state(sess, op)
    as "the operation state exists"
  let assert Ok(plan) =
    queue.enqueue_write(
      meta,
      state,
      seq,
      ids.generator(clock.fixed(at: 123), seed: 456),
      PendingCustom(
        custom_type: "boundary-test",
        data: Some(json.String("write")),
      ),
    )
    as "the deferred write is queued"
  let assert Ok(_) = writer.commit(rt.tree.writer, plan.tx)
    as "the deferred write commits"
  #(steer, follow, plan.entry)
}

fn count(lines: List(String), line: String) -> Int {
  list.length(list.filter(lines, fn(item) { item == line }))
}

fn close(rt: api.Runtime, rec) {
  assert api.close(rt) == Ok(Nil)
  let assert Ok(pid) = process.subject_owner(rec)
  process.unlink(pid)
  process.kill(pid)
}
