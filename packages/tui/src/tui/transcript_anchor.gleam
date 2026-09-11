//// A viewport follows durable message identity rather than total row growth.
////
//// Adding older pages, finishing a tool, changing detail mode, and wrapping at
//// another width all change row counts differently. A row remembers its entry
//// and its position within that entry's presentation, so repeated text cannot
//// make the viewport jump to another message.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// Provenance of one wrapped durable row.
pub type Row {
  Row(
    /// Durable entry and block identity, including the owner for tool calls.
    entry: String,
    /// Stable presentation line within the entry.
    part: Int,
    /// Wrapped row within that line, starting at its chronological top.
    wrapped: Int,
  )
}

/// Relocates the first durable row visible from the top of the old viewport.
///
/// A missing anchor means the bounded cache no longer owns that entry. The
/// caller keeps its requested offset and clamps against the remaining window.
///
/// ## Examples
///
/// ```gleam
/// // transcript_anchor.relocate(previous, next, offset, height)
/// ```
@internal
pub fn relocate(
  previous: List(Option(Row)),
  next: List(Option(Row)),
  offset: Int,
  height: Int,
  previous_prefix: Int,
  next_prefix: Int,
) -> Option(Int) {
  let visible =
    previous
    |> list.index_map(fn(row, index) {
      #(row, previous_prefix + index - offset)
    })
    |> list.filter(fn(pair) { pair.1 >= 0 && pair.1 < height })
    |> list.reverse
  use #(anchor, relative) <- option.then(
    list.find_map(visible, fn(pair) {
      case pair.0 {
        Some(row) -> Ok(#(row, pair.1))
        None -> Error(Nil)
      }
    })
    |> option.from_result,
  )
  let candidates =
    next
    |> list.index_map(fn(row, index) { #(row, index) })
    |> list.filter_map(fn(pair) {
      case pair.0 {
        Some(row) if row.entry == anchor.entry -> Ok(#(row, pair.1))
        Some(_) | None -> Error(Nil)
      }
    })
  candidates
  |> list.sort(fn(a, b) {
    int.compare(distance(a.0, anchor), distance(b.0, anchor))
  })
  |> list.first
  |> result.map(fn(found) { int.max(0, next_prefix + found.1 - relative) })
  |> option.from_result
}

fn distance(row: Row, anchor: Row) -> Int {
  int.absolute_value(row.part - anchor.part)
  * 100_000
  + int.absolute_value(row.wrapped - anchor.wrapped)
}
