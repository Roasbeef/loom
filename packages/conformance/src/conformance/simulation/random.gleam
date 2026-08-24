//// The simulation's only source of choice: a splittable SplitMix64
//// generator.
////
//// Every decision a simulated run makes — which settlement a turn
//// produces, which commit boundary is killed, which effect is starved —
//// is drawn from one `Rng` descended from one integer seed. Nothing here
//// touches the world, so a seed printed by a failing run reproduces that
//// run's decisions exactly.
////
//// Splitting matters as much as seeding. The script generator and the
//// fault-schedule generator each get their own stream, so adding a draw
//// to one does not shift the other's values; that is what lets a
//// regression corpus keep meaning as the generators grow.

import gleam/int
import gleam/list

/// Generator state. Copy it freely: every function is pure and returns
/// the successor state alongside its value.
pub opaque type Rng {
  Rng(state: Int)
}

const mask_64 = 0xFFFFFFFFFFFFFFFF

const gamma = 0x9E3779B97F4A7C15

/// Builds a generator from any integer seed.
///
/// ## Examples
///
/// ```gleam
/// // random.from_seed(1)
/// ```
///
pub fn from_seed(seed: Int) -> Rng {
  Rng(state: int.bitwise_and(seed, mask_64))
}

/// Draws the next 64-bit value (SplitMix64), never negative.
///
/// ## Examples
///
/// ```gleam
/// // let #(value, rng) = random.next(random.from_seed(7))
/// ```
///
pub fn next(rng: Rng) -> #(Int, Rng) {
  let state = int.bitwise_and(rng.state + gamma, mask_64)
  let z = state
  let z =
    int.bitwise_and(
      int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 30))
        * 0xBF58476D1CE4E5B9,
      mask_64,
    )
  let z =
    int.bitwise_and(
      int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 27))
        * 0x94D049BB133111EB,
      mask_64,
    )
  let z = int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 31))
  #(z, Rng(state:))
}

/// Splits off an independent stream, returning it and this stream's
/// successor. Use it to give each generator its own axis of choice.
///
/// ## Examples
///
/// ```gleam
/// // let #(scripts, rest) = random.split(rng)
/// ```
///
pub fn split(rng: Rng) -> #(Rng, Rng) {
  let #(raw, rng) = next(rng)
  #(from_seed(int.bitwise_exclusive_or(raw, gamma)), rng)
}

/// Draws an integer in `[min, max]`, both inclusive. A reversed range
/// yields `min`.
///
/// ## Examples
///
/// ```gleam
/// // let #(n, rng) = random.int_between(rng, 1, 6)
/// ```
///
pub fn int_between(rng: Rng, min: Int, max: Int) -> #(Int, Rng) {
  case max <= min {
    True -> #(min, rng)
    False -> {
      let #(raw, rng) = next(rng)
      #(min + raw % { max - min + 1 }, rng)
    }
  }
}

/// Draws a boolean with even odds.
///
/// ## Examples
///
/// ```gleam
/// // let #(heads, rng) = random.bool(rng)
/// ```
///
pub fn bool(rng: Rng) -> #(Bool, Rng) {
  let #(n, rng) = int_between(rng, 0, 1)
  #(n == 1, rng)
}

/// Draws `True` with the given percentage chance.
///
/// ## Examples
///
/// ```gleam
/// // let #(unlucky, rng) = random.chance(rng, 25)
/// ```
///
pub fn chance(rng: Rng, percent: Int) -> #(Bool, Rng) {
  let #(n, rng) = int_between(rng, 1, 100)
  #(n <= percent, rng)
}

/// Picks one element of a list, or `fallback` when it is empty.
///
/// ## Examples
///
/// ```gleam
/// // let #(choice, rng) = random.pick(rng, ["a", "b"], "a")
/// ```
///
pub fn pick(rng: Rng, items: List(a), fallback: a) -> #(a, Rng) {
  case list.length(items) {
    0 -> #(fallback, rng)
    count -> {
      let #(index, rng) = int_between(rng, 0, count - 1)
      case list.drop(items, index) {
        [chosen, ..] -> #(chosen, rng)
        [] -> #(fallback, rng)
      }
    }
  }
}

/// Picks one element by relative weight. Non-positive weights never win;
/// an empty or wholly non-positive list yields `fallback`.
///
/// ## Examples
///
/// ```gleam
/// // let #(choice, rng) = random.weighted(rng, [#(3, "common"), #(1, "rare")], "common")
/// ```
///
pub fn weighted(rng: Rng, choices: List(#(Int, a)), fallback: a) -> #(a, Rng) {
  let total =
    list.fold(choices, 0, fn(sum, choice) {
      case choice.0 > 0 {
        True -> sum + choice.0
        False -> sum
      }
    })
  case total <= 0 {
    True -> #(fallback, rng)
    False -> {
      let #(draw, rng) = int_between(rng, 1, total)
      #(walk(choices, draw, fallback), rng)
    }
  }
}

fn walk(choices: List(#(Int, a)), draw: Int, fallback: a) -> a {
  case choices {
    [] -> fallback
    [#(weight, value), ..rest] ->
      case weight > 0 && draw <= weight {
        True -> value
        False -> walk(rest, draw - int.max(weight, 0), fallback)
      }
  }
}

/// Draws `count` values from a generator, threading the state.
///
/// ## Examples
///
/// ```gleam
/// // let #(values, rng) = random.list_of(rng, 3, random.bool)
/// ```
///
pub fn list_of(
  rng: Rng,
  count: Int,
  draw: fn(Rng) -> #(a, Rng),
) -> #(List(a), Rng) {
  case count <= 0 {
    True -> #([], rng)
    False -> {
      let #(value, rng) = draw(rng)
      let #(rest, rng) = list_of(rng, count - 1, draw)
      #([value, ..rest], rng)
    }
  }
}
