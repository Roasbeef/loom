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
import telemetry/log

/// Ports whose sessions start and accept every message, whose worktrees are
/// always removed, and which cannot read a head, run a check or publish.
pub fn inert() -> project_host.Ports {
  project_host.Ports(
    now_ms: ffi_os.system_time_ms,
    start_session: fn(request) { Ok("session-" <> request.key) },
    open_session: fn(_) { Ok(Nil) },
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
    logger: log.discard(),
  )
}
