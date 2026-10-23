//// Standard sys operations have no public Gleam or weft caller wrapper.
//// This satellite-only bridge supplies bounded suspend/change/resume calls;
//// the target remains the weft actor and owns all state and callback swaps.

import ext/internal/live_types
import gleam/erlang/process.{type Pid}

/// Suspends the existing state owner without removing its mailbox.
///
/// ## Examples
///
/// ```gleam
/// // ffi_live_sys.suspend(pid, 1000)
/// ```
///
@external(erlang, "ext_live_sys", "suspend")
pub fn suspend(pid: Pid, within: Int) -> Result(Nil, String)

/// Runs the target's opt-in atomic migration callback while suspended.
///
/// ## Examples
///
/// ```gleam
/// // ffi_live_sys.change(pid, extra, 1000)
/// ```
///
@external(erlang, "ext_live_sys", "change")
pub fn change(
  pid: Pid,
  extra: live_types.Change,
  within: Int,
) -> Result(Nil, String)

/// Resumes the same process after publication or compensation.
///
/// ## Examples
///
/// ```gleam
/// // ffi_live_sys.resume(pid, 1000)
/// ```
///
@external(erlang, "ext_live_sys", "resume")
pub fn resume(pid: Pid, within: Int) -> Result(Nil, String)

/// Reads wall time for the native transition's bounded compensation window.
///
/// ## Examples
///
/// ```gleam
/// // ffi_live_sys.now()
/// ```
///
@external(erlang, "ext_live_sys", "now")
pub fn now() -> Int
