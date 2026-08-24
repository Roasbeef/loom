//// The injected time capability.
////
//// Loom's pure packages never read the operating system clock. Anything
//// that needs a timestamp receives a `Clock` value and threads it
//// explicitly: reading the clock returns both the current Unix-millisecond
//// time and the successor clock to use for the next read. The runtime
//// injects a clock wrapping a real time source; tests construct
//// deterministic fixed or stepping clocks and get reproducible timestamps.
////
//// This module performs no I/O itself. An injected function is only ever
//// *called*, never created here, so `core` stays pure — impurity, if any,
//// belongs to whoever built the clock.

/// A source of Unix-millisecond timestamps, read via `read`.
///
/// Constructed with `from_function` (runtime injection), `fixed`, or
/// `stepping` (test fixtures). The representation is private so all reads
/// flow through `read` and fixtures cannot be confused with real time.
pub opaque type Clock {
  /// Wraps an injected reader. Invariant: the function returns the current
  /// Unix time in milliseconds; the clock value itself never changes.
  InjectedClock(get: fn() -> Int)
  /// Always reads `now`. Invariant: `now` is a Unix-ms timestamp.
  FixedClock(now: Int)
  /// Reads `now`, then advances by `step`. Invariants: `now` is a Unix-ms
  /// timestamp; `step` is non-negative so time never runs backwards.
  SteppingClock(now: Int, step: Int)
}

/// Wraps an externally supplied time source, typically the runtime's real
/// system clock. The function must return Unix time in milliseconds.
///
/// ## Examples
///
/// ```gleam
/// let injected = clock.from_function(fn() { 1_700_000_000_000 })
/// assert clock.read(injected).0 == 1_700_000_000_000
/// ```
///
pub fn from_function(get: fn() -> Int) -> Clock {
  InjectedClock(get:)
}

/// A test fixture clock that always reads the same instant.
///
/// ## Examples
///
/// ```gleam
/// let fixture = clock.fixed(at: 42)
/// let #(first, fixture) = clock.read(fixture)
/// let #(second, _fixture) = clock.read(fixture)
/// assert first == 42 && second == 42
/// ```
///
pub fn fixed(at now: Int) -> Clock {
  FixedClock(now:)
}

/// A test fixture clock that starts at `from` and moves forward by `by`
/// milliseconds on every read. A negative step is clamped to zero so time
/// never runs backwards.
///
/// ## Examples
///
/// ```gleam
/// let fixture = clock.stepping(from: 100, by: 10)
/// let #(first, fixture) = clock.read(fixture)
/// let #(second, _fixture) = clock.read(fixture)
/// assert first == 100 && second == 110
/// ```
///
pub fn stepping(from now: Int, by step: Int) -> Clock {
  case step < 0 {
    True -> SteppingClock(now:, step: 0)
    False -> SteppingClock(now:, step:)
  }
}

/// Reads the clock, returning the current Unix-ms time and the clock to use
/// for the next read. Callers must thread the returned clock; reusing the
/// old value re-reads the same instant on fixture clocks.
///
/// ## Examples
///
/// ```gleam
/// let #(now, _next) = clock.read(clock.fixed(at: 7))
/// assert now == 7
/// ```
///
pub fn read(clock: Clock) -> #(Int, Clock) {
  case clock {
    InjectedClock(get:) -> #(get(), clock)
    FixedClock(now:) -> #(now, clock)
    SteppingClock(now:, step:) -> #(now, SteppingClock(now: now + step, step:))
  }
}
