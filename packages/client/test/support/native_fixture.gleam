//// A test owns the native daemon it starts, separately from its sessions.
////
//// Headless and ACP clients intentionally leave a per-user daemon running.
//// Their fixtures instead allocate private state before starting a managed
//// body, then retire its recorded native identity after success, assertion
//// failure or deadline. Cleanup runs outside that deadline, before reporting
//// the body outcome. Receive subjects must be created inside the body: their
//// ownership belongs to the managed worker that drives the fixture.

import broker/token
import gleam/bit_array
import host/bootstrap as native
import host/endpoint
import support/remote_daemons
import weft

/// Runs a fixture below a private directory and retires its `state` daemon.
///
/// `within_ms` bounds the body, leaving the caller's enclosing test deadline
/// room for native retirement. The directory remains available for diagnostics.
/// The endpoint's process-birth fence limits retirement to this fixture's VM.
///
/// ## Examples
///
/// ```gleam
/// // use directory <- native_fixture.with_directory("loom-run", 120_000)
/// // drive(directory)
/// ```
pub fn with_directory(
  label: String,
  within_ms: Int,
  body: fn(String) -> a,
) -> a {
  let directory =
    "build/"
    <> label
    <> "-"
    <> bit_array.base16_encode(token.production_entropy()(8))
  let assert Ok(Nil) = native.ensure_private_directory(directory)
    as "fixture state lives below a private directory"
  let assert Ok(directory) = native.canonical_directory(directory)
    as "the daemon receives absolute fixture paths"
  let assert Ok(paths) = endpoint.paths(directory <> "/state")
    as "native ownership is known before the managed body starts"
  let outcomes =
    weft.new([fn() { Ok(body(directory)) }])
    |> weft.deadline(within_ms)
    |> weft.start

  // Session hangup is deliberately weaker than native retirement. Observe the
  // recorded process's departure even when the body crashed or was cancelled.
  remote_daemons.retire(paths)
  let assert [weft.Completed(0, value)] = outcomes
    as "the fixture body completes before native teardown"
  value
}
