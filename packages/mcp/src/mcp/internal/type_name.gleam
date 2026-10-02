//// Generated declarations prefer short semantic names. Identity belongs to
//// the renderer's trusted ordinal keys, rather than server text or a digest.
//// All preferred spellings are reserved before allocating collision suffixes:
//// a hostile spelling that imitates a suffix therefore cannot capture it.
//// Names remain ASCII and bounded even after Erlang converts them to atoms.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list

const reserved = [
  "Bool", "False", "Float", "Int", "List", "Nil", "None", "Option", "Result",
  "Some", "String", "True", "UtfCodepoint", "BitArray", "Ok", "Error",
]

/// Allocates one module's declaration and constructor names in request order.
/// A record's type and constructor share one request deliberately.
///
/// ## Examples
///
/// ```gleam
/// type_name.allocate([#("McpT0InputN1", "Question")])
/// // -> A table mapping the trusted key to Question.
/// ```
pub fn allocate(requests: List(#(String, String))) -> Dict(String, String) {
  let preferred = dict.from_list(list.map(requests, fn(r) { #(r.1, Nil) }))
  let occupied = dict.from_list(list.map(reserved, fn(r) { #(r, Nil) }))
  let #(names, _, _) =
    list.fold(requests, #(dict.new(), occupied, dict.new()), fn(state, request) {
      let #(names, occupied, next) = state
      let #(key, semantic) = request
      let start = case dict.get(next, semantic) {
        Ok(ordinal) -> ordinal
        Error(Nil) -> 2
      }
      let #(chosen, following) = case dict.has_key(occupied, semantic) {
        False -> #(semantic, start)
        True -> available(semantic, preferred, occupied, start)
      }
      #(
        dict.insert(names, key, chosen),
        dict.insert(occupied, chosen, Nil),
        dict.insert(next, semantic, following),
      )
    })
  names
}

// A collision suffix contains only trusted ordinals. Each retry varies a
// bounded counter, rather than growing an identifier until it exceeds an atom.
fn available(
  semantic: String,
  preferred: Dict(String, Nil),
  occupied: Dict(String, Nil),
  attempt: Int,
) -> #(String, Int) {
  let candidate = semantic <> int.to_string(attempt)
  case dict.has_key(preferred, candidate) || dict.has_key(occupied, candidate) {
    True -> available(semantic, preferred, occupied, attempt + 1)
    False -> #(candidate, attempt + 1)
  }
}
