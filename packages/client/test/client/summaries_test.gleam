//// The summary sink: the rendezvous between the effect process that
//// receives a summary and the driver process that has to report on it.
////
//// Two behaviours here are load-bearing and neither is obvious. A read
//// with nothing filed reads as `Absent`, which `client/wiring` turns
//// into a *retryable* failure rather than an empty summary — a
//// `CompactionEntry` whose summary is nothing would silently replace a
//// conversation with a blank. And the sink is bounded: a long-lived
//// server must not accumulate summary text nobody will ask for again.

import client/summaries
import core/clock
import core/ids
import gleam/int
import gleam/list
import gleam/option.{None}

fn op(seed: Int) -> ids.OpId {
  let #(operation, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed:))
  operation
}

fn sink() -> summaries.Summaries {
  let assert Ok(started) = summaries.start() as "the sink must start"
  started
}

pub fn a_recorded_settlement_reads_back_test() {
  let store = sink()
  let key = summaries.key(op(1), "task-1", 1)
  summaries.record(
    store,
    key:,
    settlement: summaries.Produced(summary: "the account", usage: None),
  )
  assert summaries.read(store, key:)
    == summaries.Recorded(settlement: summaries.Produced(
      summary: "the account",
      usage: None,
    ))
}

// The read is idempotent: hooks are replayable, so a driver may ask the
// same question twice and must get the same answer.
pub fn reading_does_not_consume_test() {
  let store = sink()
  let key = summaries.key(op(1), "task-1", 1)
  summaries.record(
    store,
    key:,
    settlement: summaries.Failed(message: "no", retryable: True),
  )
  assert summaries.read(store, key:) == summaries.read(store, key:)
}

pub fn nothing_filed_is_absent_test() {
  assert summaries.read(sink(), key: summaries.key(op(1), "task-1", 1))
    == summaries.Absent
}

// The key separates attempts, so a retry cannot read the failed
// attempt's record and call it progress.
pub fn attempts_are_separate_records_test() {
  let store = sink()
  summaries.record(
    store,
    key: summaries.key(op(1), "task-1", 1),
    settlement: summaries.Failed(message: "the first attempt", retryable: True),
  )
  assert summaries.read(store, key: summaries.key(op(1), "task-1", 2))
    == summaries.Absent
}

pub fn operations_are_separate_records_test() {
  let store = sink()
  summaries.record(
    store,
    key: summaries.key(op(1), "task-1", 1),
    settlement: summaries.Produced(summary: "one", usage: None),
  )
  assert summaries.read(store, key: summaries.key(op(2), "task-1", 1))
    == summaries.Absent
}

// A later settlement for the same attempt supersedes the earlier one
// without growing the sink.
pub fn a_repeated_key_replaces_rather_than_accumulates_test() {
  let store = sink()
  let key = summaries.key(op(1), "task-1", 1)
  list.each(int_range(1, summaries.capacity * 2), fn(_) {
    summaries.record(
      store,
      key:,
      settlement: summaries.Produced(summary: "latest", usage: None),
    )
  })
  assert summaries.read(store, key:)
    == summaries.Recorded(settlement: summaries.Produced(
      summary: "latest",
      usage: None,
    ))
}

// Bounded: past the capacity the oldest record goes, and its read
// becomes `Absent` — which is a retry, not a fabricated summary.
pub fn the_oldest_record_is_evicted_test() {
  let store = sink()
  let oldest = summaries.key(op(1), "task-0", 1)
  summaries.record(
    store,
    key: oldest,
    settlement: summaries.Produced(summary: "oldest", usage: None),
  )
  list.each(int_range(1, summaries.capacity + 1), fn(index) {
    summaries.record(
      store,
      key: summaries.key(op(1), "task-" <> int.to_string(index), 1),
      settlement: summaries.Produced(summary: "later", usage: None),
    )
  })
  assert summaries.read(store, key: oldest) == summaries.Absent
  // The newest survives.
  assert summaries.read(
      store,
      key: summaries.key(
        op(1),
        "task-" <> int.to_string(summaries.capacity + 1),
        1,
      ),
    )
    != summaries.Absent
}

// `gleam/list` carries no range in this stdlib; a tiny one keeps the
// bound tests readable.
fn int_range(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..int_range(from + 1, to)]
  }
}
