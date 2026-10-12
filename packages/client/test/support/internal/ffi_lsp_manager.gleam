//// Test-only observation of the manager's processed startup acquisitions.
////
//// The transport gate holds startup while this OTP state snapshot proves that
//// every caller is parked. Neither the public query door nor Gleam's process
//// primitives expose that state, so the observer stays behind test-side FFI.

import client/lsp/manager.{type Manager}

/// Counts the callers parked in the manager's current start.
///
/// ## Examples
///
/// ```gleam
/// // ffi_lsp_manager.start_waiters(manager) == 3
/// ```
@external(erlang, "client_test_ffi", "lsp_start_waiters")
pub fn start_waiters(manager: Manager) -> Int
