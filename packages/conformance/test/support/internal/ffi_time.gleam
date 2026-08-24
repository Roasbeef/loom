//// Test-only wall-time measurement for the performance smoke tests.
////
//// Production Loom code takes time from the injected `core/clock.Clock`
//// capability; this module exists solely so tests can measure real
//// elapsed intervals, which a deterministic injected clock by definition
//// cannot provide.

// Single-variant type standing in for the Erlang atom `microsecond`, so
// no atom is built at runtime.
type Unit {
  Microsecond
}

// Uses OTP's erlang:monotonic_time/1. No pure alternative exists:
// measuring real elapsed time is inherently effectful, and the injected
// deterministic Clock cannot observe it.
@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: Unit) -> Int

/// The current monotonic time in microseconds. Only differences are
/// meaningful.
pub fn now_us() -> Int {
  monotonic_time(Microsecond)
}
