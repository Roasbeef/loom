//// Test-only accounting for terms copied across BEAM process boundaries.
////
//// Neither Gleam's standard library nor weft exposes a term's flattened
//// word count. The VM primitive lets regression tests distinguish shared
//// fields from closures that would duplicate unrelated state on a copy.

/// Counts words in a term with sharing removed, including closure captures.
///
/// ## Examples
///
/// ```gleam
/// assert ffi_memory.flat_words([1, 2]) == 4
/// ```
@external(erlang, "erts_debug", "flat_size")
pub fn flat_words(value: a) -> Int
