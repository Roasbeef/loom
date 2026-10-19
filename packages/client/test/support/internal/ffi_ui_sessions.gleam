//// Fixture ownership of a temporary UI ticket service.
////
//// The production handle is opaque and intentionally has no lifecycle API.
//// Its PID is needed only to witness cleanup of the memory regression's own
//// service, including when the fixture body fails. No pure API exposes it.

import client/daemon/ui_sessions
import gleam/erlang/process.{type Pid}

/// The process this fixture owns and must monitor before running its body.
///
/// ## Examples
///
/// ```gleam
/// // let watch = process.monitor(ffi_ui_sessions.pid(tickets))
/// ```
@external(erlang, "client_test_ffi", "ui_sessions_pid")
pub fn pid(tickets: ui_sessions.Sessions) -> Pid
