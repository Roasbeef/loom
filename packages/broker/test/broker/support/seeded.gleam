//// A seeded generator for the broker's property tests, so that a failing
//// run reproduces from the number it printed.
////
//// It is the generator `machine`'s property tests use: a SplitMix64 draw
//// with the state threaded explicitly, so nothing is read from a clock or a
//// global and the same seed always yields the same sequence of draws. A
//// test that draws a plan from a seed and prints the seed in its failure
//// message can be re-run on that seed alone.
////
//// What a seed reproduces is the plan, not the schedule. A test that drives
//// real processes from a plan still has the scheduler's choices to make, so
//// a plan that fails once may need several runs to fail again; the plan is
//// what can be written down and replayed.

import gleam/int
import gleam/list

/// The generator state. Opaque so that a draw can only advance it.
pub opaque type Seed {
  Seed(state: Int)
}

const mask_64 = 0xFFFFFFFFFFFFFFFF

/// A generator started from `seed_value`.
///
/// ## Examples
///
/// ```gleam
/// let #(first, _next) = seeded.between(seeded.new(7), 0, 9)
/// ```
pub fn new(seed_value: Int) -> Seed {
  Seed(state: seed_value)
}

/// The next 64-bit draw and the advanced generator.
///
/// ## Examples
///
/// ```gleam
/// let #(raw, seed) = seeded.next(seeded.new(1))
/// ```
pub fn next(seed: Seed) -> #(Int, Seed) {
  let state = int.bitwise_and(seed.state + 0x9E3779B97F4A7C15, mask_64)
  let z =
    int.bitwise_and(
      int.bitwise_exclusive_or(state, int.bitwise_shift_right(state, 30))
        * 0xBF58476D1CE4E5B9,
      mask_64,
    )
  let z =
    int.bitwise_and(
      int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 27))
        * 0x94D049BB133111EB,
      mask_64,
    )
  #(int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 31)), Seed(state:))
}

/// A draw in `min` to `max`, inclusive.
///
/// ## Examples
///
/// ```gleam
/// let #(width, seed) = seeded.between(seeded.new(3), 1, 6)
/// ```
pub fn between(seed: Seed, min: Int, max: Int) -> #(Int, Seed) {
  let #(raw, seed) = next(seed)
  #(min + raw % { max - min + 1 }, seed)
}

/// Draws `count` values with `draw`, in order, threading the generator.
///
/// ## Examples
///
/// ```gleam
/// let #(rolls, _seed) =
///   seeded.repeat(seeded.new(5), 3, fn(seed) { seeded.between(seed, 1, 6) })
/// ```
pub fn repeat(
  seed: Seed,
  count: Int,
  draw: fn(Seed) -> #(a, Seed),
) -> #(List(a), Seed) {
  let #(drawn, seed) =
    list.fold(list.repeat(Nil, count), #([], seed), fn(state, _) {
      let #(drawn, seed) = state
      let #(value, seed) = draw(seed)
      #([value, ..drawn], seed)
    })
  #(list.reverse(drawn), seed)
}
