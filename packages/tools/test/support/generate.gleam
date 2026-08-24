//// Deterministic pseudo-random generation for the hashline property
//// suite: a seeded SplitMix64 generator (same pattern as core's
//// test/support/generate.gleam — copied, not cross-imported, per the
//// package test-isolation rule) plus content and line generators.

import gleam/int
import gleam/list
import gleam/string

/// Pseudo-random generator state.
pub type Seed {
  Seed(state: Int)
}

const mask_64 = 0xFFFFFFFFFFFFFFFF

/// Builds a seed from any integer.
pub fn seed(n: Int) -> Seed {
  Seed(state: int.bitwise_and(n, mask_64))
}

/// Draws the next 64-bit value.
pub fn next(seed: Seed) -> #(Int, Seed) {
  let state = int.bitwise_and(seed.state + 0x9E3779B97F4A7C15, mask_64)
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
  #(z, Seed(state:))
}

/// Draws an integer in `[min, max]`, both inclusive.
pub fn int_between(seed: Seed, min: Int, max: Int) -> #(Int, Seed) {
  let #(raw, seed) = next(seed)
  #(min + raw % { max - min + 1 }, seed)
}

/// Draws a boolean.
pub fn bool(seed: Seed) -> #(Bool, Seed) {
  let #(n, seed) = int_between(seed, 0, 1)
  #(n == 1, seed)
}

/// Draws a list of `count` generated values.
pub fn list_of(
  seed: Seed,
  count: Int,
  generate: fn(Seed) -> #(a, Seed),
) -> #(List(a), Seed) {
  list_of_loop(seed, count, generate, [])
}

fn list_of_loop(
  seed: Seed,
  remaining: Int,
  generate: fn(Seed) -> #(a, Seed),
  accumulator: List(a),
) -> #(List(a), Seed) {
  case remaining <= 0 {
    True -> #(list.reverse(accumulator), seed)
    False -> {
      let #(value, seed) = generate(seed)
      list_of_loop(seed, remaining - 1, generate, [value, ..accumulator])
    }
  }
}

// Deliberately varied: ascii words, punctuation, accents, CJK, emoji,
// combining marks, and a carriage return for CRLF shapes.
const fragments = [
  "let", "case", "fn", "->", "  ", "responder", "münchen", "søster", "日本語", "🦀",
  "e\u{0301}", "\r", "\"quoted\"", "0123456789", "___", "x = y + z",
]

/// Draws one line of content: 0–4 fragments concatenated. Never
/// contains `\n`.
pub fn line(seed: Seed) -> #(String, Seed) {
  let #(count, seed) = int_between(seed, 0, 4)
  let #(parts, seed) =
    list_of(seed, count, fn(seed) {
      let #(index, seed) = int_between(seed, 0, list.length(fragments) - 1)
      let fragment = case list.drop(fragments, index) {
        [chosen, ..] -> chosen
        [] -> "?"
      }
      #(fragment, seed)
    })
  #(string.concat(parts), seed)
}

/// Draws whole-file content: `line_count` lines, with or without a
/// trailing newline.
pub fn content(seed: Seed, line_count: Int) -> #(String, Seed) {
  let #(lines, seed) = list_of(seed, line_count, line)
  let #(trailing, seed) = bool(seed)
  join_content(lines, trailing, seed)
}

/// Draws whole-file content biased toward duplicate and blank lines:
/// every line comes from a pool of just two drawn lines plus the empty
/// line, so identical siblings and blank runs are the norm — the
/// shapes that defeat per-line anchor checks.
pub fn duplicate_heavy_content(seed: Seed, line_count: Int) -> #(String, Seed) {
  let #(first, seed) = line(seed)
  let #(second, seed) = line(seed)
  let pool = ["", first, second]
  let #(lines, seed) =
    list_of(seed, line_count, fn(seed) {
      let #(index, seed) = int_between(seed, 0, 2)
      let chosen = case list.drop(pool, index) {
        [line, ..] -> line
        [] -> ""
      }
      #(chosen, seed)
    })
  let #(trailing, seed) = bool(seed)
  join_content(lines, trailing, seed)
}

fn join_content(
  lines: List(String),
  trailing: Bool,
  seed: Seed,
) -> #(String, Seed) {
  let joined = string.join(lines, with: "\n")
  case trailing && joined != "" {
    True -> #(joined <> "\n", seed)
    False -> #(joined, seed)
  }
}
