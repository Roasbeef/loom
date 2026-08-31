import cap/actor
import cap/fs
import cap/internal/channel
import cap/internal/dispatch
import cap/internal/wire
import cap/task
import core/msgpack
import gleam/erlang/process
import gleam/list
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

// --- helpers ------------------------------------------------------------

// Install a fake channel whose `call` is the given function, bypassing
// the actor so cap-module marshalling and error mapping are tested
// deterministically.
fn install_fake(
  with call: fn(String, msgpack.MsgPackValue, Int) ->
    Result(msgpack.MsgPackValue, channel.CallError),
) -> Nil {
  dispatch.install(channel.Channel(call:))
}

fn map(entries: List(#(String, msgpack.MsgPackValue))) -> msgpack.MsgPackValue {
  wire.args(entries)
}

// Strip the u32 length prefix and read a frame's kind and id.
fn frame_head(bytes: BitArray) -> Result(#(Int, String), Nil) {
  case bytes {
    <<_size:size(32), payload:bits>> ->
      case msgpack.decode(payload) {
        Ok(envelope) ->
          case
            wire.int_field(envelope, "id"),
            wire.string_field(envelope, "kind")
          {
            Ok(id), Ok(kind) -> Ok(#(id, kind))
            _, _ -> Error(Nil)
          }
        Error(_) -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

// --- cap/fs marshalling + error mapping ---------------------------------

pub fn fs_read_ok_test() {
  install_fake(with: fn(cap, _args, _deadline) {
    case cap {
      "fs.read" -> Ok(map([#("contents", msgpack.StringValue("file body"))]))
      _ -> Error(channel.Denied("unexpected", cap))
    }
  })
  assert fs.read("/x.txt") == Ok("file body")
}

pub fn fs_read_not_found_test() {
  install_fake(with: fn(_cap, _args, _deadline) {
    Error(channel.Denied("not_found", "no such file"))
  })
  assert fs.read("/missing") == Error(fs.NotFound("/missing"))
}

pub fn fs_read_denied_test() {
  install_fake(with: fn(_cap, _args, _deadline) {
    Error(channel.Denied("policy", "outside workspace"))
  })
  assert fs.read("/etc/shadow") == Error(fs.PermissionDenied("/etc/shadow"))
}

pub fn fs_read_channel_down_test() {
  install_fake(with: fn(_cap, _args, _deadline) {
    Error(channel.Unreachable("channel gone"))
  })
  assert fs.read("/x") == Error(fs.FsUnavailable("channel gone"))
}

pub fn fs_write_ok_test() {
  install_fake(with: fn(cap, args, _deadline) {
    // The arguments must carry path and contents.
    let path = wire.string_field(args, "path")
    let contents = wire.string_field(args, "contents")
    case cap, path, contents {
      "fs.write", Ok("/out"), Ok("data") -> Ok(msgpack.NilValue)
      _, _, _ -> Error(channel.Denied("bad_args", ""))
    }
  })
  assert fs.write("/out", "data") == Ok(Nil)
}

pub fn fs_list_test() {
  install_fake(with: fn(_cap, _args, _deadline) {
    Ok(
      map([
        #(
          "entries",
          msgpack.ArrayValue([
            map([
              #("name", msgpack.StringValue("a")),
              #("is_dir", msgpack.BoolValue(False)),
            ]),
            map([
              #("name", msgpack.StringValue("sub")),
              #("is_dir", msgpack.BoolValue(True)),
            ]),
          ]),
        ),
      ]),
    )
  })
  assert fs.list("/dir")
    == Ok([fs.DirEntry("a", False), fs.DirEntry("sub", True)])
}

// --- channel actor: round trip + cancel-on-death ------------------------

pub fn channel_round_trip_test() {
  let sent = process.new_subject()
  let send = fn(bytes) {
    process.send(sent, bytes)
    Nil
  }
  let assert Ok(handle) = channel.start(<<9, 9, 9>>, send)
  let ch = channel.to_channel(handle)

  // The call blocks awaiting the cap_result, so run it in its own process.
  let result = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let channel.Channel(call:) = ch
      process.send(result, call("fs.read", map([]), 1000))
    })

  // The first call gets id 0; deliver its result.
  let assert Ok(bytes) = process.receive(sent, 1000)
  assert frame_head(bytes) == Ok(#(0, "cap_call"))
  channel.deliver(handle, 0, channel.CapOk(msgpack.StringValue("ok")))

  assert process.receive(result, 1000) == Ok(Ok(msgpack.StringValue("ok")))
  channel.stop(handle)
}

// `stop` must settle in-flight callers in-band (Unreachable), like `fail`,
// rather than abandoning them to wait out their deadline (C-F3).
pub fn stop_settles_inflight_calls_test() {
  let sent = process.new_subject()
  let send = fn(bytes) {
    process.send(sent, bytes)
    Nil
  }
  let assert Ok(handle) = channel.start(<<3>>, send)
  let ch = channel.to_channel(handle)

  // A caller blocked on a long-deadline call.
  let result = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let channel.Channel(call:) = ch
      process.send(result, call("proc.run", map([]), 60_000))
    })
  let assert Ok(call_bytes) = process.receive(sent, 1000)
  assert frame_head(call_bytes) == Ok(#(0, "cap_call"))

  // Stopping the channel unblocks the caller at once with Unreachable — not
  // after the 60s deadline. A 1s receive proves it settled in-band.
  channel.stop(handle)
  let assert Ok(settled) = process.receive(result, 1000)
  assert case settled {
    Error(channel.Unreachable(_)) -> True
    _ -> False
  }
}

// Re-installing over a live channel slot must be refused, so a process
// surviving a prior execution cannot act under a new execution's token
// (C-F1). The refusal lifts once the prior channel's actor is reaped.
pub fn install_exclusive_refuses_over_live_channel_test() {
  dispatch.reset()
  let assert Ok(h1) = channel.start(<<1>>, fn(_bytes) { Nil })
  let assert Ok(owner1) = process.subject_owner(channel.subject(h1))
  let assert Ok(Nil) =
    dispatch.install_exclusive(channel.to_channel(h1), owner1)

  let assert Ok(h2) = channel.start(<<2>>, fn(_bytes) { Nil })
  let assert Ok(owner2) = process.subject_owner(channel.subject(h2))
  // h1's actor is still alive, so the second install refuses.
  assert dispatch.install_exclusive(channel.to_channel(h2), owner2)
    == Error(Nil)

  // Reap the prior channel; a re-install may now proceed.
  channel.stop(h1)
  wait_until_dead(owner1, 1000)
  let assert Ok(Nil) =
    dispatch.install_exclusive(channel.to_channel(h2), owner2)

  channel.stop(h2)
  dispatch.reset()
}

fn wait_until_dead(pid: process.Pid, budget_ms: Int) -> Nil {
  case process.is_alive(pid) && budget_ms > 0 {
    True -> {
      process.sleep(10)
      wait_until_dead(pid, budget_ms - 10)
    }
    False -> Nil
  }
}

pub fn channel_cancels_dead_caller_test() {
  let sent = process.new_subject()
  let send = fn(bytes) {
    process.send(sent, bytes)
    Nil
  }
  let assert Ok(handle) = channel.start(<<1>>, send)
  let ch = channel.to_channel(handle)

  // A caller that blocks forever awaiting a reply that never comes.
  let caller =
    process.spawn_unlinked(fn() {
      let channel.Channel(call:) = ch
      let _ = call("proc.run", map([]), 60_000)
      Nil
    })

  // Its cap_call frame (id 0) goes out.
  let assert Ok(call_bytes) = process.receive(sent, 1000)
  assert frame_head(call_bytes) == Ok(#(0, "cap_call"))

  // Kill the caller: the channel's monitor must emit a cancel for id 0.
  process.kill(caller)
  let assert Ok(cancel_bytes) = process.receive(sent, 1000)
  assert frame_head(cancel_bytes) == Ok(#(0, "cancel"))
  channel.stop(handle)
}

// --- cap/task: ordering, concurrency, failures, cancellation ------------

pub fn parallel_map_preserves_order_test() {
  // Earlier items sleep longer, so completion order reverses input order;
  // the result must still be in input order.
  let result =
    task.parallel_map([1, 2, 3, 4, 5], max_concurrency: 3, with: fn(x) {
      process.sleep({ 6 - x } * 8)
      Ok(x * 10)
    })
  assert result == Ok([10, 20, 30, 40, 50])
}

pub fn parallel_map_concurrency_one_is_sequential_test() {
  let order = process.new_subject()
  let _ =
    task.parallel_map([0, 1, 2], max_concurrency: 1, with: fn(i) {
      process.send(order, i)
      Ok(i)
    })
  assert drain(order, []) == [0, 1, 2]
}

pub fn parallel_map_aggregates_failures_test() {
  let result =
    task.parallel_map([0, 1, 2, 3], max_concurrency: 4, with: fn(i) {
      case i % 2 {
        0 -> Ok(i)
        _ -> Error(i)
      }
    })
  assert result == Error([task.Returned(1, 1), task.Returned(3, 3)])
}

pub fn parallel_map_worker_crash_is_reported_test() {
  // A worker whose process dies before returning becomes a `Crashed`
  // failure, never a crash of the runner. Self-kill stands in for a
  // program panic without the noisy SASL crash report.
  let result =
    task.parallel_map([0], max_concurrency: 1, with: fn(_i) {
      process.kill(process.self())
      process.sleep(10_000)
      Ok(0)
    })
  assert result == Error([task.Crashed(0, "killed")])
}

pub fn parallel_map_fail_fast_cancels_rest_test() {
  let escaped = process.new_subject()
  let result =
    task.parallel_map_fail_fast([0, 1, 2], max_concurrency: 3, with: fn(i) {
      case i {
        0 -> Error("boom")
        _ -> {
          process.sleep(300)
          process.send(escaped, i)
          Ok(i)
        }
      }
    })
  assert result == Error(task.Returned(0, "boom"))
  // The slow tasks were killed before they could report.
  assert process.receive(escaped, 120) == Error(Nil)
}

pub fn parallel_map_fail_fast_reports_the_triggering_failure_test() {
  let escaped = process.new_subject()
  let result =
    task.parallel_map_fail_fast([0, 1], max_concurrency: 2, with: fn(i) {
      case i {
        0 -> {
          process.sleep(300)
          process.send(escaped, Nil)
          Ok(i)
        }
        _ -> Error("boom")
      }
    })
  assert result == Error(task.Returned(1, "boom"))
  // The absent result at index zero records cancellation, not a second
  // failure which may replace the error that triggered that cancellation.
  assert process.receive(escaped, 120) == Error(Nil)
}

pub fn race_returns_first_and_cancels_losers_test() {
  let escaped = process.new_subject()
  let winner =
    task.race([
      fn() {
        process.sleep(300)
        process.send(escaped, 1)
        Ok("slow")
      },
      fn() {
        process.sleep(10)
        Ok("fast")
      },
    ])
  assert winner == Ok("fast")
  assert process.receive(escaped, 120) == Error(Nil)
}

pub fn both_success_test() {
  assert task.both(fn() { Ok(1) }, fn() { Ok("a") }) == Ok(#(1, "a"))
}

pub fn both_failure_test() {
  assert task.both(
      fn() {
        process.sleep(100)
        Ok(1)
      },
      fn() { Error("x") },
    )
    == Error(task.Returned(1, "x"))
}

fn drain(subject: process.Subject(a), acc: List(a)) -> List(a) {
  case process.receive(subject, 50) {
    Ok(value) -> drain(subject, [value, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

// --- cap/actor: state, call, get, bounded mailbox ordering --------------

type CounterMsg {
  Increment
  ReadCount(reply: actor.Reply(Int))
}

pub fn actor_send_and_call_test() {
  let assert Ok(address) =
    actor.spawn(0, fn(state, message) {
      case message {
        Increment -> actor.continue(state + 1)
        ReadCount(reply:) -> {
          actor.reply(reply, state)
          actor.continue(state)
        }
      }
    })
  actor.send(address, Increment)
  actor.send(address, Increment)
  actor.send(address, Increment)
  assert actor.call(address, ReadCount, timeout: 1000) == Ok(3)
  assert actor.get(address, timeout: 1000) == Ok(3)
  actor.shutdown(address)
}

type CollectMsg {
  Push(value: Int)
  Snapshot(reply: actor.Reply(List(Int)))
}

pub fn actor_bounded_mailbox_preserves_order_test() {
  // Bound of 2, five sends: three senders park briefly, then all five are
  // handled in admission order.
  let assert Ok(address) =
    actor.spawn_bounded([], 2, fn(state, message) {
      case message {
        Push(value:) -> actor.continue([value, ..state])
        Snapshot(reply:) -> {
          actor.reply(reply, list.reverse(state))
          actor.continue(state)
        }
      }
    })
  list.each([1, 2, 3, 4, 5], fn(value) { actor.send(address, Push(value)) })
  assert actor.call(address, Snapshot, timeout: 2000) == Ok([1, 2, 3, 4, 5])
  actor.shutdown(address)
}
