//// Controller tests exercise real sys operations, dropping acknowledgements only.

import cap/report
import cap/runtime
import ext/internal/ffi_live_sys
import ext/internal/live_actor
import ext/internal/live_runtime
import ext/live
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/int
import gleam/result
import gleeunit/should
import weft
import weft/poll

@external(erlang, "live_runtime_test_ffi", "artifact")
fn artifact() -> #(BitArray, String)

@external(erlang, "live_runtime_test_ffi", "counter")
fn counter() -> Dynamic

@external(erlang, "live_runtime_test_ffi", "first")
fn first(counter: Dynamic) -> Bool

@external(erlang, "live_runtime_test_ffi", "queued")
fn queued(pid: process.Pid) -> Bool

fn original(state: String, _: runtime.Asked) {
  use count <- result.try(int.parse(state) |> result.replace_error("count"))
  Ok(#(int.to_string(count + 1), runtime.Refused("fixture", "ok")))
}

fn controller(sys: live_runtime.Sys, pause_ms: Int) {
  let assert Ok(controller) =
    live_runtime.start_with_sys(
      live_runtime.Config("v1", "counter", ["fixture"], "", pause_ms, 4096),
      live.Definition("0", original),
      sys,
    )
    as "trusted controller starts"
  controller
}

fn control(
  controller: live_runtime.Controller,
  event: String,
  args: report.Value,
) {
  live_runtime.ask(controller, runtime.Asked(runtime.Event(event), args, 1000))
}

fn prepare_args(id: String) {
  let #(bytes, digest) = artifact()
  report.object([
    #("transition", report.string(id)),
    #("from", report.string("v1")),
    #("boundary", report.string("counter")),
    #("version", report.string("v2")),
    #("slot", report.string("b")),
    #("entry", report.string("loom_live_b@fixture")),
    #("migration", report.string("loom_live_b@fixture")),
    #("atom_baseline", report.list([])),
    #(
      "modules",
      report.list([
        report.object([
          #("name", report.string("loom_live_b@fixture")),
          #("bytes", report.bytes(bytes)),
          #("digest", report.string(digest)),
        ]),
      ]),
    ),
  ])
}

fn transition(id: String) {
  report.object([#("transition", report.string(id))])
}

fn status_field(controller: live_runtime.Controller, name: String) {
  let assert runtime.Answered(value) =
    control(controller, "__loom_live_status", report.object([]))
    as "controller status remains available during cleanup"
  let assert Ok(value) = report.field(value, name) as "status field exists"
  let assert Ok(value) = report.as_string(value) as "status field is text"
  value
}

fn await_resumed(controller: live_runtime.Controller) {
  poll.until(2000, 10, fn() {
    case status_field(controller, "pending") {
      "" -> poll.Done(Nil)
      _ -> poll.Retry
    }
  })
  |> should.equal(poll.Answered(Nil))
}

pub fn lost_sys_acknowledgements_keep_cleanup_custody_test() {
  let suspended = counter()
  let compensated = counter()
  let resumed = counter()
  let controller =
    controller(
      live_runtime.Sys(
        fn(pid, within) {
          use Nil <- result.try(ffi_live_sys.suspend(pid, within))
          case first(suspended) {
            True -> Error("suspend acknowledgement lost")
            False -> Ok(Nil)
          }
        },
        fn(pid, change, within) {
          use Nil <- result.try(ffi_live_sys.change(pid, change, within))
          case first(compensated) {
            True -> Error("compensation acknowledgement lost")
            False -> Ok(Nil)
          }
        },
        fn(pid, within) {
          use Nil <- result.try(ffi_live_sys.resume(pid, within))
          case first(resumed) {
            True -> Error("resume acknowledgement lost")
            False -> Ok(Nil)
          }
        },
      ),
      100,
    )
  let component = live_runtime.component(controller)
  let pid = live_actor.pid(component)
  let ordinary = runtime.Asked(runtime.Tool("count"), report.object([]), 100)
  let _ = live_runtime.ask(controller, ordinary)
  case control(controller, "__loom_live_prepare", prepare_args("lost")) {
    runtime.Refused(_, _) -> Nil
    _ -> panic as "lost acknowledgement refuses preparation"
  }
  status_field(controller, "pending") |> should.equal("lost")
  case control(controller, "__loom_live_commit", transition("lost")) {
    runtime.Refused(_, _) -> Nil
    _ -> panic as "cleaning preparation cannot publish"
  }
  await_resumed(controller)
  let _ = live_runtime.ask(controller, ordinary)
  live_actor.inspect(component, 1000).state |> should.equal("2")
  live_actor.pid(component) |> should.equal(pid)
  status_field(controller, "last_status") |> should.equal("aborted")
  retire(controller)
}

pub fn repeated_prepare_and_queued_invocation_publish_once_test() {
  let controller =
    controller(
      live_runtime.Sys(
        ffi_live_sys.suspend,
        ffi_live_sys.change,
        ffi_live_sys.resume,
      ),
      1000,
    )
  let component = live_runtime.component(controller)
  let ordinary = runtime.Asked(runtime.Tool("count"), report.object([]), 1000)
  let _ = live_runtime.ask(controller, ordinary)
  let args = prepare_args("publish")
  let prepared = control(controller, "__loom_live_prepare", args)
  control(controller, "__loom_live_prepare", args) |> should.equal(prepared)

  // Queued work reaches the retained state owner's actual suspended mailbox.
  let work =
    weft.new([fn() { Ok(live_actor.invoke(component, ordinary)) }])
    |> weft.deadline(1000)
    |> weft.start_detached
  poll.until(250, 1, fn() {
    case queued(live_actor.pid(component)) {
      True -> poll.Done(Nil)
      False -> poll.Retry
    }
  })
  |> should.equal(poll.Answered(Nil))
  let _ = control(controller, "__loom_live_commit", transition("publish"))
  case weft.pull(work, 1000) {
    weft.PulledOutcome(weft.Completed(_, _)) -> Nil
    _ -> panic as "queued invocation resumes after publication"
  }
  live_actor.inspect(component, 1000).state |> should.equal("103")
  let _ = control(controller, "__loom_live_commit", transition("publish"))
  live_actor.inspect(component, 1000).state |> should.equal("103")
  retire(controller)
}

pub fn commit_after_expiry_restores_populated_state_test() {
  let controller =
    controller(
      live_runtime.Sys(
        ffi_live_sys.suspend,
        ffi_live_sys.change,
        ffi_live_sys.resume,
      ),
      100,
    )
  let component = live_runtime.component(controller)
  let ordinary = runtime.Asked(runtime.Tool("count"), report.object([]), 100)
  let _ = live_runtime.ask(controller, ordinary)
  let _ = control(controller, "__loom_live_prepare", prepare_args("expired"))
  process.sleep(150)
  let _ = control(controller, "__loom_live_commit", transition("expired"))
  await_resumed(controller)
  let _ = live_runtime.ask(controller, ordinary)
  live_actor.inspect(component, 1000).state |> should.equal("2")
  status_field(controller, "last_status") |> should.equal("aborted")
  retire(controller)
}

pub fn lost_publish_resume_acknowledgement_never_overwrites_resumed_work_test() {
  let resumed = counter()
  let controller =
    controller(
      live_runtime.Sys(
        ffi_live_sys.suspend,
        ffi_live_sys.change,
        fn(pid, within) {
          use Nil <- result.try(ffi_live_sys.resume(pid, within))
          case first(resumed) {
            True -> Error("publication resume acknowledgement lost")
            False -> Ok(Nil)
          }
        },
      ),
      1000,
    )
  let component = live_runtime.component(controller)
  let ordinary = runtime.Asked(runtime.Tool("count"), report.object([]), 100)
  let _ = live_runtime.ask(controller, ordinary)
  let _ = control(controller, "__loom_live_prepare", prepare_args("resume"))
  case control(controller, "__loom_live_commit", transition("resume")) {
    runtime.Refused(_, _) -> Nil
    _ -> panic as "missing resume acknowledgement retains transition"
  }

  // The resumed actor can finish work before the controller receives a retry.
  // Recovery resumes publication; it cannot compensate over that newer state.
  let _ = live_actor.invoke(component, ordinary)
  await_resumed(controller)
  live_actor.inspect(component, 1000).state |> should.equal("103")
  status_field(controller, "last_status") |> should.equal("committed")
  retire(controller)
}

// Normal test-process exit does not retire linked actors that do not trap exits.
// Both original monitors must settle before the fixture returns.
fn retire(controller: live_runtime.Controller) {
  let controller_pid = live_runtime.pid(controller)
  let component_pid = live_actor.pid(live_runtime.component(controller))
  let controller_watch = process.monitor(controller_pid)
  let component_watch = process.monitor(component_pid)
  process.unlink(controller_pid)
  process.unlink(component_pid)
  process.kill(controller_pid)
  process.kill(component_pid)
  process.new_selector()
  |> process.select_specific_monitor(controller_watch, fn(_) { Nil })
  |> process.selector_receive(1000)
  |> should.equal(Ok(Nil))
  process.new_selector()
  |> process.select_specific_monitor(component_watch, fn(_) { Nil })
  |> process.selector_receive(1000)
  |> should.equal(Ok(Nil))
}
