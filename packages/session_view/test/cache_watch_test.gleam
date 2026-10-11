//// The cache ledger decides which two usage rows may be compared. These
//// tests pin its three gates: a sequence is folded once, a pushed row waits
//// for a capture that covers it, and a model switch fences the strand's next
//// operation. The terminal's own tests drive the same ledger through its
//// reducer (`cache_miss_notice_test`, `session_pushed_test`).

import core/message
import core/usage_evidence
import gleam/dict
import gleam/option.{None, Some}
import session_view/cache_miss
import session_view/cache_watch

// A row that read a large cached prefix, priced so a miss has a figure.
fn warm() -> message.Usage {
  message.Usage(
    input: 200,
    output: 400,
    cache_read: 40_000,
    cache_write: 0,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: 40_600,
    cost: message.UsageCost(0.0006, 0.006, 0.012, 0.0, 0.0186),
    evidence: usage_evidence.priced_api(),
  )
}

// The row after a long pause: the cached read collapsed and the prefix was
// written again.
fn cold() -> message.Usage {
  message.Usage(
    input: 200,
    output: 400,
    cache_read: 0,
    cache_write: 40_000,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: 40_600,
    cost: message.UsageCost(0.0006, 0.006, 0.0, 0.15, 0.1566),
    evidence: usage_evidence.priced_api(),
  )
}

pub fn a_sequence_is_admitted_once_test() {
  let assert Ok(ledger) =
    cache_watch.admit(cache_watch.new(), "main", 5, Some("op"), warm(), 0, None)
  let assert Error(Nil) =
    cache_watch.admit(ledger, "main", 5, Some("op"), warm(), 10, None)
    as "a duplicate push is refused"
  let assert Error(Nil) =
    cache_watch.admit(ledger, "main", 4, Some("op"), warm(), 10, None)
    as "a delayed older push is refused"
  assert dict.size(ledger.pending) == 1
}

pub fn a_first_row_the_capture_already_holds_is_not_a_baseline_test() {
  let assert Ok(ledger) =
    cache_watch.admit(
      cache_watch.new(),
      "main",
      5,
      Some("op"),
      warm(),
      0,
      Some(9),
    )
  assert ledger.pending == dict.new()
  assert dict.get(ledger.seen, "main") == Ok(5)
}

pub fn a_held_row_settles_only_under_a_covering_capture_test() {
  let assert Ok(ledger) =
    cache_watch.admit(cache_watch.new(), "main", 5, Some("a"), warm(), 0, None)
  let #(ledger, missed) = cache_watch.settle(ledger, 5, cache_watch.Live)
  assert missed == []
  assert dict.size(ledger.pending) == 1

  let #(ledger, missed) = cache_watch.settle(ledger, 6, cache_watch.Live)
  assert missed == []
  assert ledger.pending == dict.new()

  // Ten minutes later the prefix is gone, and the settled row says so.
  let assert Ok(ledger) =
    cache_watch.admit(ledger, "main", 8, Some("b"), cold(), 600_000, None)
  let #(_, missed) = cache_watch.settle(ledger, 9, cache_watch.Live)
  let assert [cache_watch.Missed(strand: "main", miss:)] = missed
  assert miss.idle_ms == 600_000
  assert miss.tokens == 40_000
}

pub fn a_fenced_operation_seeds_nothing_test() {
  let ledger = cache_watch.forget(cache_watch.new(), "main")
  let assert Ok(ledger) =
    cache_watch.admit(ledger, "main", 5, Some("old"), warm(), 0, None)
  let #(ledger, _) = cache_watch.settle(ledger, 6, cache_watch.Live)
  assert dict.get(ledger.fences, "main") == Ok(Some("old"))
  assert dict.get(ledger.watches, "main") == Error(Nil)

  let assert Ok(ledger) =
    cache_watch.admit(ledger, "main", 7, Some("new"), warm(), 10, None)
  let #(ledger, _) = cache_watch.settle(ledger, 8, cache_watch.Live)
  assert dict.get(ledger.fences, "main") == Error(Nil)
  assert dict.get(ledger.watches, "main") != Error(Nil)
}

pub fn a_replay_observes_nothing_test() {
  let #(ledger, missed) =
    cache_watch.observe(
      cache_watch.new(),
      "main",
      warm(),
      0,
      cache_watch.Replayed,
    )
  assert missed == None
  assert cache_watch.outlook(ledger, "main", 0) == None

  let #(ledger, _) =
    cache_watch.observe(ledger, "main", warm(), 0, cache_watch.Live)
  assert cache_watch.outlook(ledger, "main", 0) == Some(cache_miss.Unheld)
  assert cache_watch.outlook(ledger, "main", 120_000)
    == Some(cache_miss.Idle(120_000))
}
