//// Legacy Darwin discovery records carry a local-time birth string without
//// its timezone. This adapter retains the original observation for upgrades;
//// endpoint policy refuses an ambiguous mismatch while the PID remains alive.

import host/bootstrap.{type ProcessIdentity}

/// Observes the old Darwin birth format in the caller's inherited environment.
///
/// OTP has no native process birth query and the Gleam libraries cannot set
/// one subprocess's environment for `ps`. This is an upgrade-only observation;
/// new fences always use `bootstrap.process_identity` and its UTC marker.
///
/// ## Examples
///
/// ```gleam
/// // ffi_process.legacy_darwin_identity(pid)
/// ```
@external(erlang, "host_bootstrap_ffi", "legacy_darwin_process_identity")
pub fn legacy_darwin_identity(pid: Int) -> Result(ProcessIdentity, String)
