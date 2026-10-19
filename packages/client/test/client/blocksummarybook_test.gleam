//// Focused boundary smoke test for `client/blocksummarybook`; the full
//// stateful model suite lives in `blocksummarybook_property_test.gleam`.

import client/blocksummarybook.{LiveAsk, Pace}
import core/clock
import core/ids
import gleam/string

const pace =
  Pace(
    floor_bytes: 512,
    every_bytes: 4096,
    every_lines: 40,
    window_bytes: 32_768,
    settled_concurrency: 2,
    settled_backlog: 3,
    live_concurrency: 2,
    max_streams: 4,
  )

pub fn stream_floor_and_coalescing_smoke_test() {
  let #(op, _) = ids.mint_op(ids.generator(clock.fixed(at: 1000), seed: 2))
  let short = string.repeat("ok\n", 60)
  let #(book, launches) =
    blocksummarybook.grow(
      blocksummarybook.new(),
      pace,
      generation: "g-1",
      strand: "main",
      operation: op,
      chunk: short,
    )
  assert launches == []
  assert blocksummarybook.tracks(book, "g-1")

  let #(book, launched) =
    blocksummarybook.grow(
      book,
      pace,
      generation: "g-1",
      strand: "main",
      operation: op,
      chunk: string.repeat("a", 4096),
    )
  let assert [LiveAsk(generation: "g-1", ..)] = launched
    as "crossing 4 KiB launches one live summary request"

  let book = blocksummarybook.ended(book, "g-1")
  let #(book, after) = blocksummarybook.landed(book, pace, "g-1")
  assert after == []
  assert !blocksummarybook.tracks(book, "g-1")
}
