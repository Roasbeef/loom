//// Pending reads must follow the IDs owned by the active run, including
//// staged tool results and each inbox queue, without decoding other queues.

import core/clock
import core/ids
import core/json
import core/register
import core/tx.{DeleteRegister, SetRegister, Tx}
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import machine/operation.{PendingCustom, ReplayNever, ReplaySafe}
import machine/queue
import runtime/api
import runtime/supervisor
import runtime/writer
import session/session
import storage/storage
import support/fake
import support/harness
import support/recorder
import weft/poll

pub fn owned_inbox_and_staged_result_survive_unrelated_corruption_test() {
  let rec = recorder.start()
  let started = process.new_subject()
  let assert Ok(original) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session opens"
  let get_register = original.store.get_register
  let get_registers = original.store.get_registers
  let list_registers = original.store.list_registers
  let store =
    storage.Storage(
      ..original.store,
      get_register: fn(handle, ns, key) {
        case ns, key {
          register.PendingEntry, "unrelated-corrupt" -> {
            let _ = recorder.bump(rec, "unrelated-read")
            Nil
          }
          register.PendingEntry, _ -> {
            let _ = recorder.bump(rec, "pending-point")
            Nil
          }
          _, _ -> Nil
        }
        get_register(handle, ns, key)
      },
      get_registers: fn(handle, ns, keys) {
        case ns {
          register.PendingEntry -> {
            let _ = recorder.bump(rec, "pending-batch")
            case list.length(keys) > 128 {
              True -> {
                let _ = recorder.bump(rec, "oversize")
                Nil
              }
              False -> Nil
            }
            case list.contains(keys, "unrelated-corrupt") {
              True -> {
                let _ = recorder.bump(rec, "unrelated-read")
                Nil
              }
              False -> Nil
            }
            Nil
          }
          _ -> Nil
        }
        get_registers(handle, ns, keys)
      },
      list_registers: fn(handle, ns, prefix) {
        case ns {
          register.PendingEntry -> {
            let _ = recorder.bump(rec, "pending-list")
            Nil
          }
          _ -> Nil
        }
        list_registers(handle, ns, prefix)
      },
    )
  let sess = session.Session(..original, store:)
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [#("read", ReplaySafe)],
      fn(spec) {
        case fake.turn(spec) {
          0 -> fake.Reply(fake.tool_use("working", [#("c1", "read")], 4))
          _ -> fake.Reply(fake.answer("done", 3))
        }
      },
      fn(_) {
        let release = process.new_subject()
        process.send(started, release)
        let assert Ok(Nil) = process.receive(release, within: 5000)
          as "the queued inputs must land before tool completion"
        fake.ToolReply(text: "result", is_error: False, terminate: False)
      },
    )
  let assert Ok(rt) =
    api.open(sess, eff, api.default_options(harness.configuration()))
    as "the runtime opens"
  let assert Ok(op) = api.prompt(rt, [fake.user("hello")]) as "the run starts"
  let assert Ok(release) = process.receive(started, within: 5000)
    as "the tool is in flight"
  let assert Ok(steer) = api.steer_quietly(rt, fake.user("steer"))
    as "steer is queued"
  let assert Ok(follow) = api.follow_up(rt, fake.user("follow"))
    as "follow-up is queued"
  let assert Ok(Some(session.Cell(value: meta, ..))) = session.op_meta(sess, op)
    as "operation metadata is present"
  let assert Ok(Some(session.Cell(value: state, seq:))) =
    session.op_state(sess, op)
    as "operation state is present"
  let assert Ok(plan) =
    queue.enqueue_write(
      meta,
      state,
      seq,
      ids.generator(clock.fixed(at: 123), seed: 456),
      PendingCustom(
        custom_type: "pending-test",
        data: Some(json.String("write")),
      ),
    )
    as "a deferred write is queued"
  let assert Ok(_) = writer.commit(rt.tree.writer, plan.tx)
    as "the deferred write commits"
  let assert Ok(_) =
    writer.commit(
      rt.tree.writer,
      Tx(
        writes: [
          SetRegister(
            register.PendingEntry,
            "unrelated-corrupt",
            register.value(json.String("bad")),
          ),
        ],
        expected: [],
      ),
    )
    as "unrelated corruption is installed after admission"
  process.send(release, Nil)
  let assert Ok(outcome) = api.await_result(rt, op, within_ms: 5000)
    as "the run completes despite unrelated corruption"
  harness.assert_completed(outcome)
  let projection = harness.final_projection(sess)
  assert projection
    == [
      "user:hello", "assistant:tool_use:working|call(c1)read",
      "tool:read:c1:ok:result", "user:steer", "assistant:stop:done",
      "user:follow", "assistant:stop:done",
    ]
  let assert Ok(entries) =
    storage.get_entries(sess.store, [steer, follow, plan.entry])
    as "all three queued entries are placed"
  assert dict.size(entries) == 3
  let assert Ok(Some(_)) =
    storage.get_register(
      original.store,
      register.PendingEntry,
      "unrelated-corrupt",
    )
    as "another owner's payload is untouched"
  let assert Ok(_) =
    writer.commit(
      rt.tree.writer,
      Tx(
        writes: [DeleteRegister(register.PendingEntry, "unrelated-corrupt")],
        expected: [],
      ),
    )
    as "the synthetic corruption is removed before invariant checks"
  harness.assert_placement_invariants(original)
  assert recorder.read(rec, "tool:read:c1") == 1
  assert recorder.read(rec, "pending-list") == 0
  assert recorder.read(rec, "unrelated-read") == 0
  assert recorder.read(rec, "pending-point") == 0
  assert recorder.read(rec, "pending-batch") > 0
  assert recorder.read(rec, "oversize") == 0
  assert api.close(rt) == Ok(Nil)
  let assert Ok(recorder_pid) = process.subject_owner(rec)
  process.unlink(recorder_pid)
  process.kill(recorder_pid)
}

// The in-flight inbox is read in multiple exact batches before placement.
pub fn large_inbox_crosses_batch_boundary_test() {
  let rec = recorder.start()
  let started = process.new_subject()
  let assert Ok(original) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session opens"
  let get_registers = original.store.get_registers
  let store =
    storage.Storage(..original.store, get_registers: fn(handle, ns, keys) {
      case ns, list.length(keys) {
        register.PendingEntry, 128 -> {
          let _ = recorder.bump(rec, "full-batch")
          Nil
        }
        _, _ -> Nil
      }
      get_registers(handle, ns, keys)
    })
  let sess = session.Session(..original, store:)
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [#("read", ReplaySafe)],
      fn(spec) {
        case fake.turn(spec) {
          0 -> fake.Reply(fake.tool_use("working", [#("c1", "read")], 4))
          _ -> fake.Reply(fake.answer("done", 3))
        }
      },
      fn(_) {
        let release = process.new_subject()
        process.send(started, release)
        let assert Ok(Nil) = process.receive(release, within: 20_000)
          as "the queued inputs land before tool completion"
        fake.ToolReply(text: "result", is_error: False, terminate: False)
      },
    )
  let assert Ok(rt) =
    api.open(sess, eff, api.default_options(harness.configuration()))
    as "the runtime opens"
  let assert Ok(op) = api.prompt(rt, [fake.user("hello")]) as "the run starts"
  let assert Ok(release) = process.receive(started, within: 5000)
    as "the tool is in flight"
  let labels =
    int.range(from: 1, to: 131, with: [], run: fn(acc, n) {
      ["queued-" <> int.to_string(n), ..acc]
    })
    |> list.reverse
  list.each(labels, fn(label) {
    let assert Ok(_) = api.steer_quietly(rt, fake.user(label))
      as "each steer is queued"
    Nil
  })
  process.send(release, Nil)
  let assert Ok(outcome) = api.await_result(rt, op, within_ms: 20_000)
    as "the run completes"
  harness.assert_completed(outcome)
  let projection = harness.final_projection(sess)
  list.each(labels, fn(label) {
    assert list.length(
        list.filter(projection, fn(line) { line == "user:" <> label }),
      )
      == 1
  })
  assert recorder.read(rec, "full-batch") > 0
  assert api.close(rt) == Ok(Nil)
}

pub fn missing_owned_steer_faults_recovered_run_test() {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session opens"
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [#("write", ReplayNever)],
      fn(_) { fake.Reply(fake.tool_use("working", [#("c1", "write")], 4)) },
      fn(_) { fake.ToolHang },
    )
  let base = api.default_options(harness.configuration())
  let assert Ok(rt) = api.open(sess, eff, base) as "the runtime opens"
  let assert Ok(_) = api.prompt(rt, [fake.user("start")]) as "the run starts"
  wait_for(fn() { recorder.read(rec, "tool:write:c1") >= 1 }, 5000)
  let assert Ok(queued) = api.steer_quietly(rt, fake.user("queued"))
    as "the steer is queued"
  process.kill(rt.tree.supervisor)
  wait_for(fn() { !process.is_alive(rt.tree.supervisor) }, 1000)
  let assert Ok(_) =
    storage.commit(
      sess.store,
      Tx(
        writes: [
          DeleteRegister(register.PendingEntry, ids.entry_id_to_string(queued)),
        ],
        expected: [],
      ),
    )
    as "the owned payload is removed"
  let options =
    api.Options(
      ..base,
      tolerance: supervisor.Tolerance(intensity: 2, period: 1),
    )
  let assert Ok(rebooted) = api.open(sess, eff, options)
    as "the tree initially opens"
  wait_for(fn() { !process.is_alive(rebooted.tree.supervisor) }, 5000)
  assert session.close(sess) == Ok(Nil)
  let assert Ok(recorder_pid) = process.subject_owner(rec)
  process.unlink(recorder_pid)
  process.kill(recorder_pid)
}

fn wait_for(condition: fn() -> Bool, within: Int) -> Nil {
  assert poll.until(within:, every: 10, attempt: fn() {
      case condition() {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    == poll.Answered(Nil)
}
