//// What the daemon writes down when it slows or refuses an upgrade for its own
//// reasons.
////
//// A control socket, a terminal's session socket and a page's socket each
//// start as one HTTP request that passes a fixed chain of questions to the
//// root and the registry before it is upgraded: is the daemon ready, does the
//// credential authenticate, is the session resident, is a connection permit
//// free. Every one of them answers a caller that waited too long, or a
//// registry that is stopping, with the same bare status, so a client that
//// sees a 401, a 409 or a socket that closes before its first frame cannot
//// tell a revoked credential from a registry that has not answered for a
//// minute. Nothing was logged either, which is why a hang seen once on macOS
//// (a control path that timed out for minutes while the assets still
//// answered) could not name its own cause afterwards.
////
//// This module is that missing record. `refused` names the step and the
//// fixed reason a daemon-side question failed. `timed` names a step that took
//// long enough to matter even when it succeeded. Neither carries a
//// credential, a page key, a nonce or a ticket: a route class, a step name
//// and a reason drawn from the daemon's own fixed vocabulary are all a line
//// holds, so a caller that sends garbage can make the daemon write no more
//// than a caller that sends nothing.
////
//// Only failures that the client did not cause are recorded. A missing or
//// wrong credential is the caller's, and the routes answer it without a line
//// here; a registry that timed out, a root that was stopping and a session
//// that was not resident are the daemon's.

import host/bootstrap
import telemetry/field
import telemetry/level
import telemetry/log

/// Which upgrade a line is about.
pub type Route {
  /// `/v2/control`.
  Control

  /// `/v2/sessions/<id>/ws`, a terminal's socket.
  Session

  /// `/ui/p/<key>/sessions/<id>/ws`, a page's socket.
  Page

  /// `/v2/claim`, an invitee's one-command socket.
  Claim
}

/// A step that took at least this long is written down whether or not it
/// succeeded, in milliseconds. It is well above the cost of a healthy step,
/// which is a few microseconds, and well below the five-second bound every
/// registry call carries, so a registry that is answering slowly shows up
/// before it is answering not at all.
pub const slow_ms = 250

/// Runs one step of an upgrade and writes a line if it was slow.
///
/// ## Examples
///
/// ```gleam
/// // upgrade_log.timed(upgrade_log.Control, "ready", fn() {
/// //   root.ready(daemon, within: 1000)
/// // })
/// ```
pub fn timed(route: Route, step: String, run: fn() -> answer) -> answer {
  let started = bootstrap.monotonic_time_ms()
  let answer = run()
  let elapsed = bootstrap.monotonic_time_ms() - started
  case elapsed >= slow_ms {
    True ->
      log.warn(logger(), "daemon.upgrade_slow", [
        field.ident("route", route_name(route)),
        field.ident("step", step),
        field.count("elapsed_ms", elapsed),
      ])
    False -> Nil
  }
  answer
}

/// Writes down that a step refused an upgrade for a reason of the daemon's.
/// `reason` is a fixed word or phrase, never text the peer supplied.
///
/// ## Examples
///
/// ```gleam
/// // upgrade_log.refused(upgrade_log.Page, "resident", "session is opening")
/// ```
pub fn refused(route: Route, step: String, reason: String) -> Nil {
  log.warn(logger(), "daemon.upgrade_refused", [
    field.ident("route", route_name(route)),
    field.ident("step", step),
    field.text("reason", reason),
  ])
}

/// Writes down that an upgraded socket was closed before it served a frame,
/// which the peer sees as a close or a bare 1006 with no status.
///
/// ## Examples
///
/// ```gleam
/// // upgrade_log.closed_early(upgrade_log.Page, "transfer", reason)
/// ```
pub fn closed_early(route: Route, step: String, reason: String) -> Nil {
  log.warn(logger(), "daemon.socket_closed_early", [
    field.ident("route", route_name(route)),
    field.ident("step", step),
    field.text("reason", reason),
  ])
}

fn route_name(route: Route) -> String {
  case route {
    Control -> "control"
    Session -> "session"
    Page -> "page"
    Claim -> "claim"
  }
}

// The daemon installs the JSON handler at boot, so a logger writing through
// Erlang `logger` reaches `daemon.log` without a handle being threaded
// through the router, which is built before any of these steps run.
fn logger() -> log.Logger {
  log.erlang(threshold: level.Info)
}
