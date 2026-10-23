//// Trusted actor fixtures exercise preservation independently of the loader.
//// Authored module loading remains confined to the real jailed acceptance.

import cap/report
import cap/runtime
import ext/internal/ffi_live_sys
import ext/internal/live_actor
import ext/internal/live_types
import ext/live
import gleam/erlang/process
import gleam/int
import gleam/option.{Some}
import gleam/result

pub fn malformed_transition_keeps_populated_actor_test() {
  let definition = live.Definition("0", count)
  let assert Ok(component) = live_actor.start(definition, "v1", "", 4096, 1000)
    as "the trusted state owner starts"
  let pid = live_actor.pid(component)
  let asked =
    runtime.Asked(runtime.Tool("echo"), report.string("ordinary"), 100)
  let _ = live_actor.invoke(component, asked)
  assert live_actor.inspect(component, 1000).state == "1"
  let assert Ok(Nil) = ffi_live_sys.suspend(pid, 1000)
    as "standard sys suspends"
  let changed =
    ffi_live_sys.change(
      pid,
      live_types.Change(
        live.Definition("99", fn(_, _) { Error("replacement") }),
        "v2",
        "",
        Some("malformed"),
      ),
      1000,
    )
  assert result.is_error(changed)
    as "total state decoding refuses malformed migration"
  let assert Ok(Nil) = ffi_live_sys.resume(pid, 1000) as "standard sys resumes"
  let _ = live_actor.invoke(component, asked)
  assert live_actor.pid(component) == pid
  assert live_actor.inspect(component, 1000).state == "2"
    as "failed migration retains both populated state and original callback"
  process.unlink(pid)
  process.kill(pid)
}

pub fn callback_crash_and_deadline_keep_state_test() {
  let definition =
    live.Definition("0", fn(state, asked) {
      case asked.invocation {
        runtime.Tool("crash") -> panic as "intentional isolated callback crash"
        runtime.Tool("timeout") -> {
          process.sleep(200)
          Ok(#("99", runtime.Answered(report.string("late"))))
        }
        _ -> count(state, asked)
      }
    })
  let assert Ok(component) = live_actor.start(definition, "v1", "", 4096, 1000)
    as "the state owner starts"
  let pid = live_actor.pid(component)
  let ordinary = runtime.Asked(runtime.Tool("echo"), report.string(""), 100)
  let _ = live_actor.invoke(component, ordinary)
  let _ =
    live_actor.invoke(
      component,
      runtime.Asked(runtime.Tool("crash"), report.string(""), 20),
    )
  let _ =
    live_actor.invoke(
      component,
      runtime.Asked(runtime.Tool("timeout"), report.string(""), 20),
    )
  let _ = live_actor.invoke(component, ordinary)
  assert live_actor.pid(component) == pid
  assert live_actor.inspect(component, 1000).state == "2"
    as "crashed and timed-out callbacks cannot publish state"
  process.unlink(pid)
  process.kill(pid)
}

fn count(
  state: String,
  _asked: runtime.Asked,
) -> Result(#(String, runtime.Answer), String) {
  use count <- result.try(
    int.parse(state) |> result.replace_error("invalid counter"),
  )
  Ok(#(int.to_string(count + 1), runtime.Answered(report.string("counted"))))
}

pub fn malformed_and_oversized_callback_state_preserve_current_test() {
  let definition =
    live.Definition("0", fn(state, asked) {
      case asked.invocation {
        runtime.Tool("malformed") ->
          Ok(#("invalid", runtime.Answered(report.string("ignored"))))
        runtime.Tool("oversized") ->
          Ok(#("123456789", runtime.Answered(report.string("ignored"))))
        _ -> count(state, asked)
      }
    })
  let assert Ok(component) = live_actor.start(definition, "v1", "", 8, 1000)
    as "bounded state owner starts"
  let ordinary = runtime.Asked(runtime.Tool("echo"), report.string(""), 100)
  let _ = live_actor.invoke(component, ordinary)
  let malformed =
    live_actor.invoke(
      component,
      runtime.Asked(runtime.Tool("malformed"), report.string(""), 100),
    )
  let oversized =
    live_actor.invoke(
      component,
      runtime.Asked(runtime.Tool("oversized"), report.string(""), 100),
    )
  assert malformed
    == runtime.Refused(
      "live_callback_failed",
      "live state is not a JSON document",
    )
  assert oversized
    == runtime.Refused(
      "live_callback_failed",
      "live state exceeds its native byte bound",
    )
  let _ = live_actor.invoke(component, ordinary)
  assert live_actor.inspect(component, 1000).state == "2"
    as "rejected documents never replace populated state"
  let pid = live_actor.pid(component)
  process.unlink(pid)
  process.kill(pid)
}
