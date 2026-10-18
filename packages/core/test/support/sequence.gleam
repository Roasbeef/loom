//// A counting helper for tests that build a fixed shape by folding over a
//// run of integers (nested containers, long fixture lists). The stdlib this
//// package pins has no `list.range`, and none of these uses is random.

import gleam/int
import gleam/list

/// An inclusive integer range as a list. Requires `start <= stop`.
pub fn range(from start: Int, to stop: Int) -> List(Int) {
  int.range(from: start, to: stop + 1, with: [], run: fn(acc, n) { [n, ..acc] })
  |> list.reverse
}
