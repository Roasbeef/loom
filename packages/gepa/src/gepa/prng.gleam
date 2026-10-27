//// Deterministic randomness for the search's draws, in pure Gleam,
//// identical on both compile targets.
////
//// Every draw the search makes — the parent, the minibatch — must come out
//// the same when a log is replayed, so the generator is seeded from the
//// search id and the step number and from nothing else. The runtime's own
//// randomness would break replay, and a BEAM-only source would break the
//// portability this library promises its hosts, so the generator is
//// written here.
////
//// This is a copy of Loom's `evalstat/prng` (xorshift128 on 32-bit words,
//// seeded by salted FNV-1a), kept algorithm-for-algorithm identical so
//// that a host which also carries `evalstat` draws the same sequence from
//// the same seed, and the search logs it already holds replay to the same
//// parents and minibatches. The argument for the algorithm is repeated
//// here because it is the reason a reader must not "upgrade" it.
////
//// # Why 32-bit words, not xorshift64*
////
//// Gleam's `Int` is arbitrary precision on the BEAM and an IEEE double on
//// JavaScript, where integers above 2^53 lose low bits. A 64-bit xorshift
//// needs 64-bit intermediates, which the JavaScript build would silently
//// round, and the two targets would then disagree about every draw.
//// Marsaglia's xorshift128 keeps the whole state in four 32-bit words and
//// every intermediate below 2^45, where the standard library's bitwise
//// operations are exact on both targets. The output stream is therefore
//// one stream, and `first_outputs_are_fixed_test` pins its first values
//// on both targets.
////
//// # Seeding from a string
////
//// Each word of the state is the 32-bit FNV-1a hash of the seed text
//// prefixed with the word's position (`"0:"`, `"1:"`, …), over the text's
//// Unicode code points, so four distinct words come from one seed and two
//// seeds that differ in one character differ in all four. FNV's
//// multiplication by 16777619 would overflow 2^53, so `multiply_prime`
//// splits it into `(h mod 2^8)·2^24 + h·403`, which is the same product
//// modulo 2^32 and never exceeds 2^42. The state is then warmed by sixteen
//// discarded outputs so similar seeds do not share their first draws.

import gleam/bool
import gleam/int
import gleam/list
import gleam/string

/// Generator state: four 32-bit words, never all zero.
pub opaque type Prng {
  Prng(a: Int, b: Int, c: Int, d: Int)
}

/// The low 32 bits.
const mask32 = 0xFFFFFFFF

/// FNV-1a's 32-bit offset basis.
const fnv_offset = 0x811C9DC5

/// 2^32 as a float, for `unit`.
const two_32 = 4_294_967_296.0

/// How many outputs `from_string` discards before the state is handed out.
const warm_up_draws = 16

/// Seeds a generator from text, usually the search id and the step. The
/// same text always gives the same stream on both targets.
///
/// ## Examples
///
/// ```gleam
/// let #(first, _) = prng.next(prng.from_string("search/7"))
/// let #(again, _) = prng.next(prng.from_string("search/7"))
/// assert first == again
/// ```
pub fn from_string(seed: String) -> Prng {
  let word = fn(salt: String) { fnv1a(salt <> seed) }
  let a = word("0:")
  let b = word("1:")
  let c = word("2:")
  let d = word("3:")

  // The all-zero state is xorshift's one fixed point: it would emit zero
  // forever. The words are non-negative, so a zero sum is that state, and
  // it is replaced by fixed constants rather than refused, because a seed
  // that cannot fail is what keeps every caller total.
  use <- bool.lazy_guard(when: a + b + c + d == 0, return: fn() {
    warm_up(Prng(0x9E3779B9, 0x243F6A88, 0xB7E15162, 0x6A09E667))
  })
  warm_up(Prng(a, b, c, d))
}

/// Advances the generator and returns a uniform 32-bit integer in
/// `[0, 2^32)`.
///
/// ## Examples
///
/// ```gleam
/// let #(value, _) = prng.next(prng.from_string("seed"))
/// assert value >= 0 && value < 4_294_967_296
/// ```
pub fn next(prng: Prng) -> #(Int, Prng) {
  let Prng(a, b, c, d) = prng

  // Marsaglia's xorshift128 with shifts (11, 8, 19). The left shift is
  // masked at once because it is the only step that can leave 32 bits;
  // every other step is a right shift or an exclusive-or of 32-bit words.
  let t = int.bitwise_exclusive_or(a, int.bitwise_shift_left(a, 11))
  let t = int.bitwise_and(t, mask32)
  let t = int.bitwise_exclusive_or(t, int.bitwise_shift_right(t, 8))
  let out = int.bitwise_exclusive_or(d, int.bitwise_shift_right(d, 19))
  let out = int.bitwise_exclusive_or(out, t)
  #(out, Prng(b, c, d, out))
}

/// A uniform integer in `[0, bound)`, by reduction modulo the bound. The
/// bias of the reduction is below `bound / 2^32`, which for the bounds a
/// search draws (task and leader counts) is negligible. A bound below two
/// returns zero without advancing the generator, so a caller never has to
/// guard an empty or singleton draw.
///
/// ## Examples
///
/// ```gleam
/// let #(index, _) = prng.below(prng.from_string("seed"), 10)
/// assert index >= 0 && index < 10
/// ```
///
/// ```gleam
/// let #(index, _) = prng.below(prng.from_string("seed"), 1)
/// assert index == 0
/// ```
pub fn below(prng: Prng, bound: Int) -> #(Int, Prng) {
  use <- bool.guard(when: bound < 2, return: #(0, prng))
  let #(value, prng) = next(prng)
  #(value % bound, prng)
}

/// A uniform float in `[0, 1)`, with 32 bits of resolution.
///
/// ## Examples
///
/// ```gleam
/// let #(u, _) = prng.unit(prng.from_string("seed"))
/// assert u >=. 0.0 && u <. 1.0
/// ```
pub fn unit(prng: Prng) -> #(Float, Prng) {
  let #(value, prng) = next(prng)
  #(int.to_float(value) /. two_32, prng)
}

/// The 32-bit FNV-1a hash of a string's Unicode code points. Public so a
/// host can derive a sub-seed or a content id without another hash in its
/// dependencies, and so the fixed-output test can pin it on both targets.
///
/// ## Examples
///
/// ```gleam
/// assert prng.fnv1a("") == 0x811C9DC5
/// ```
pub fn fnv1a(text: String) -> Int {
  string.to_utf_codepoints(text)
  |> list.fold(fnv_offset, fn(hash, codepoint) {
    int.bitwise_exclusive_or(hash, string.utf_codepoint_to_int(codepoint))
    |> multiply_prime
  })
}

/// `hash · 16777619 mod 2^32` without an intermediate above 2^42. The
/// prime is `2^24 + 403`, so the product splits into a shifted low byte and
/// a small multiple; both targets compute each part exactly.
fn multiply_prime(hash: Int) -> Int {
  let high = int.bitwise_shift_left(int.bitwise_and(hash, 0xFF), 24)
  int.bitwise_and(high + hash * 403, mask32)
}

/// Discards the first outputs so two seeds whose hashes share a word do not
/// also share their first draws.
fn warm_up(prng: Prng) -> Prng {
  list.repeat(Nil, warm_up_draws)
  |> list.fold(prng, fn(state, _) { next(state).1 })
}
