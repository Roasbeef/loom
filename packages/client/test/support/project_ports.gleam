//// The ports of a project actor in a test that has no worktrees, no sandbox
//// and no remote.
////
//// The actor's side of the daemon is a record of closures so that a test can
//// stand any of them in. Most tests are about one or two and need the rest to
//// exist and do nothing harmful: sessions that start and accept, a worktree
//// that is always removable, and the three ports of slice 2 (reading a head,
//// running a check, publishing) that say they have nothing to work with. A test
//// that is about one of those replaces it with `Ports(..ports, observe_head: ...)`.

import client/daemon/project_host
import client/goalstate
import client/internal/ffi_os
import client/peer_mail
import core/json
import gleam/erlang/process.{type Subject}
import gleam/option.{None}
import telemetry/log

/// Ports whose sessions start and accept every message, whose worktrees are
/// always removed, and which cannot read a head, run a check or publish.
pub fn inert() -> project_host.Ports {
  project_host.Ports(
    now_ms: ffi_os.system_time_ms,
    start_session: fn(request) { Ok("session-" <> request.key) },
    open_session: fn(_) { Ok(Nil) },
    remember_mandate: fn(_, _) { Nil },
    stop_session: fn(_) { Ok(Nil) },
    release_worktree: fn(_) { Ok(project_host.Removed) },
    endpoint_of: fn(session) {
      Ok(peer_mail.Endpoint(session, fn(_) { Ok(json.Null) }))
    },
    observe_head: fn(_) { Error("this test has no worktree to read") },
    run_check: fn(request) {
      goalstate.CheckResult(
        command: request.command,
        ending: goalstate.DidNotFinish(reason: "this test has no sandbox"),
        output: "",
        ran_at_ms: 0,
      )
    },
    publish: fn(_) { project_host.Unavailable("this test has no remote") },
    gh_runner: fn() { None },
    remote_url: fn() { None },
    logger: log.discard(),
  )
}

/// A clock that moves a hundred seconds each time it is read, so that every
/// back-off the actor sets is already over by its next pass and a row that
/// takes nine attempts takes a moment and not minutes.
///
/// ## Examples
///
/// ```gleam
/// let ports = project_host.Ports(..project_ports.inert(), now_ms: project_ports.racing_clock())
/// ```
pub fn racing_clock() -> fn() -> Int {
  stepping_clock(100_000)
}

/// A clock that moves `step_ms` each time it is read. A test whose work runs
/// in a task picks a step small enough that a loaded machine can't read its
/// way past the task's lease while the task is still running, because the row
/// would then start the work a second time.
///
/// ## Examples
///
/// ```gleam
/// let ports = project_host.Ports(..project_ports.inert(), now_ms: project_ports.stepping_clock(2000))
/// ```
pub fn stepping_clock(step_ms: Int) -> fn() -> Int {
  let made = process.new_subject()
  process.spawn_unlinked(fn() {
    let requests = process.new_subject()
    process.send(made, requests)
    race(requests, ffi_os.system_time_ms(), step_ms)
  })
  let assert Ok(requests) = process.receive(made, 1000)
    as "the clock's process starts"
  fn() { process.call(requests, 1000, fn(reply) { reply }) }
}

// Answers each read with the time and then moves the time on.
fn race(requests: Subject(Subject(Int)), now: Int, step_ms: Int) -> Nil {
  let reply = process.receive_forever(requests)
  process.send(reply, now)
  race(requests, now + step_ms, step_ms)
}
