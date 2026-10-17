//// A small, measured batch removes serial code-server round trips from the
//// first domain's session assembly. Admission validates configuration first;
//// this hint then runs before any domain resource owner starts. Daemon readiness
//// and invalid configuration never pay for it.
////
//// These are ordinary production Gleam modules observed on that path. They
//// have no on_load or NIF initialization. Keep this bounded inventory tied to
//// cold-session evidence rather than loading every application module. OTP
//// owns the existing code cache: later domains need no application-level flag,
//// and any failure leaves the ordinary demand-loading path available.
//// This hint is not the application's dependency declaration; unlisted modules
//// and runtime extensions continue to load on demand.

import client/internal/ffi_code
import gleam/erlang/atom.{type Atom}
import gleam/list

/// Offers the measured batch as an optional hint. Both native rejection and
/// an unrecognized native reply fall through to ordinary module loading; an
/// optimization must not introduce a new domain-admission failure.
///
/// ## Examples
///
/// ```gleam
/// startup.prepare() // -> Nil
/// ```
@internal
pub fn prepare() -> Nil {
  let _ = ffi_code.ensure_loaded(modules())
  Nil
}

/// The fixed production inventory, also exposed for release-artifact checks.
/// Atom creation is bounded by these literals and takes no external input.
///
/// ## Examples
///
/// ```gleam
/// list.length(startup.modules()) // -> 25
/// ```
@internal
pub fn modules() -> List(Atom) {
  list.map(
    [
      "client@gateway",
      "storage@sqlite",
      "client@async_runs",
      "client@directories",
      "tools@codemode",
      "runtime@effects",
      "client@serve",
      "broker@broker",
      "client@agency",
      "client@memory_overview",
      "client@remote_child",
      "machine@codec",
      "runtime@hooks",
      "client@scratch",
      "broker@framing",
      "client@daemon@domain",
      "runtime@strand_runtime",
      "client@jobs",
      "client@catalog",
      "client@codemode",
      "client@peer_mail",
      "tools@fs",
      "runtime@api",
      "tools@agent",
      "core@codec",
    ],
    atom.create,
  )
}
