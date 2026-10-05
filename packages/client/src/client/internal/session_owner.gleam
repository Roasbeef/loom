//// The ownership label for a service process that works for one session.
////
//// `telemetry/owner` labels a process under a path it is given, and the
//// path of a session service is the session's canonical id, which every
//// service already reaches through the `Runtime` handle it was wired with.
//// This module is the one place that turns a runtime into that path, so
//// the agency, the background jobs actor and the scanners cannot spell the
//// session key differently from the gateway.
////
//// A label is per process and a process labels only itself, so each
//// caller invokes `label` at the top of its own initialiser, the code a
//// supervisor runs inside the child it just spawned. A service whose
//// wiring holds the runtime only as a borrowed `fn() -> Result(Runtime,
//// Nil)` calls `label_borrowed`: the borrow is answered once the session
//// is open, which is before the service tier starts, and a refusal leaves
//// the process unlabelled rather than failing its start.

import core/ids
import gleam/result
import runtime/api.{type Runtime}
import telemetry/owner.{type Role}

/// Labels the calling process as `role` under the session `runtime`
/// belongs to.
///
/// ## Examples
///
/// ```gleam
/// // session_owner.label(runtime, owner.Agency)
/// ```
///
pub fn label(runtime: Runtime, role: Role) -> Nil {
  owner.label(path(runtime), role)
}

/// Labels the calling process as `role` under the session of a runtime
/// that is only borrowed. If the borrow is refused the process stays
/// unlabelled, which an inspector reports as `unknown`.
///
/// ## Examples
///
/// ```gleam
/// // session_owner.label_borrowed(wiring.runtime, owner.BackgroundJobs)
/// ```
///
pub fn label_borrowed(borrow: fn() -> Result(Runtime, Nil), role: Role) -> Nil {
  borrow()
  |> result.map(label(_, role))
  |> result.unwrap(Nil)
}

/// The owner path of a runtime's session: its canonical id, the same key
/// the gateway's label and every log line use.
///
/// ## Examples
///
/// ```gleam
/// // session_owner.path(runtime)
/// // -> [#("session", "01a1...")]
/// ```
///
pub fn path(runtime: Runtime) -> List(#(String, String)) {
  [#("session", ids.session_id_to_string(api.session_id(runtime)))]
}
