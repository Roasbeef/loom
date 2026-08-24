//// FFI confinement (spec §0.2): every `@external` the server entry
//// point needs, in one place. Each declaration names the OTP function
//// behind it and why no pure alternative exists. Nothing else in this
//// package touches foreign code.

/// Wall-clock milliseconds since the Unix epoch, for the server's
/// injected `Clock`. OTP `erlang:system_time(millisecond)` via the
/// package FFI — time is an ambient OS fact; §0.2 requires it injected
/// from exactly one place, and this is that place for `client/serve`.
@external(erlang, "client_ffi", "system_time_ms")
pub fn system_time_ms() -> Int

/// A strictly increasing positive integer, for the server's injected
/// entropy seam (seeds must never repeat within a session lifetime —
/// spec-gaps WP-E item 6). OTP
/// `erlang:unique_integer([positive, monotonic])`; no pure function can
/// promise VM-wide uniqueness.
@external(erlang, "client_ffi", "unique_positive_integer")
pub fn unique_positive_integer() -> Int

/// Resolves an executable name against `PATH`, for the default
/// `loom-exec` helper lookup. OTP `os:find_executable/1`; `PATH`
/// resolution is an OS question with no pure answer.
@external(erlang, "client_ffi", "find_executable")
pub fn find_executable(name: String) -> Result(String, Nil)

/// Blocks the calling process until the OS delivers `SIGTERM`, so the
/// server can close its runtime (releasing the session lease) before
/// the VM exits. OTP `os:set_signal/2` plus a `gen_event` handler
/// swapped into `erl_signal_server` — signal delivery is inherently a
/// runtime-system affair. Swapping replaces the default handler, whose
/// response to `SIGTERM` is an immediate `init:stop()`; ours forwards
/// the signal here instead so shutdown runs in order.
@external(erlang, "client_ffi", "wait_for_sigterm")
pub fn wait_for_sigterm() -> Nil

/// Stops the VM with the given exit code, for startup failures that
/// have already printed their reason (§0.2 permits a documented halt in
/// an entry point — there is nothing to supervise before the tree
/// exists). OTP `erlang:halt/1`; the return type is a free variable
/// because the call never returns.
@external(erlang, "client_ffi", "halt")
pub fn halt(code: Int) -> anything
