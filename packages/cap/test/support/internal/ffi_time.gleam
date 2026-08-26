//// Test-only wall-time measurement, for the `cap/actor` bounded-queue
//// perf smoke (issue #45). Mirrors
//// `conformance/test/support/internal/ffi_time.gleam` exactly: production
//// Loom code takes time from the injected `core/clock.Clock` capability,
//// and this exists solely so a test can measure a real elapsed interval,
//// which a deterministic injected clock cannot provide by definition.

// Single-variant type standing in for the Erlang atom `microsecond`, so
// no atom is built at runtime.
type Unit {
  Microsecond
}

// Uses OTP's erlang:monotonic_time/1. No pure alternative exists:
// measuring real elapsed time is inherently effectful.
@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: Unit) -> Int

/// The current monotonic time in microseconds. Only differences are
/// meaningful.
pub fn now_us() -> Int {
  monotonic_time(Microsecond)
}
