//// The project ledger's file: appending and replaying events, queueing and
//// settling effects, the scanner's cursors, and compaction.
////
//// The properties pinned here are the ones the engine's actor will rest on. An
//// event and its effects are written together or not at all, with a fault
//// injected inside SQLite by a trigger on a second connection so the failure
//// lands after the event row is written. Replaying pages in sequence order
//// without gaps. An effect with a given kind and key is one row however often
//// it is queued. Compaction deletes the old events and writes its snapshot in
//// one step, and a replay never begins inside the deleted range. A reopened
//// file keeps everything. A row that breaks its grammar is a typed error and
//// never a crash or a skipped row.

import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import sqlight
import storage/catalogue
import storage/project_ledger as ledger
import support/fixtures

fn open_in(name: String) -> #(String, ledger.Ledger) {
  let path = fixtures.scratch(name) <> "/ledger.db"
  let assert Ok(store) = ledger.open(path) as "the ledger opens"
  #(path, store)
}

fn event(n: Int) -> String {
  "{\"type\":\"event\",\"n\":" <> int.to_string(n) <> "}"
}

fn draft(kind: String, key: String, due_ms: Int) -> ledger.EffectDraft {
  ledger.EffectDraft(
    kind:,
    key:,
    payload_json: "{\"to\":\"" <> key <> "\"}",
    due_ms:,
  )
}

// Statements run on a connection of the test's own, standing in for a fault or
// for damage written by something other than this module.
fn raw(path: String, statements: String) -> Result(Nil, sqlight.Error) {
  let assert Ok(connection) = sqlight.open(path) as "the raw connection opens"
  let outcome = sqlight.exec(statements, on: connection)
  let assert Ok(Nil) = sqlight.close(connection) as "the raw connection closes"
  outcome
}

fn count(path: String, table: String) -> Int {
  let assert Ok(connection) = sqlight.open(path) as "the count connection opens"
  let rows =
    sqlight.query(
      "SELECT COUNT(*) FROM " <> table,
      on: connection,
      with: [],
      expecting: decode.at([0], decode.int),
    )
  let assert Ok(Nil) = sqlight.close(connection)
    as "the count connection closes"
  result.unwrap(rows, [-1]) |> list.first |> result.unwrap(-1)
}

// The integers from `first` through `last`.
fn numbers(first: Int, last: Int) -> List(Int) {
  int.range(from: first, to: last + 1, with: [], run: fn(all, n) { [n, ..all] })
  |> list.reverse
}

fn seqs(events: List(ledger.StoredEvent)) -> List(Int) {
  list.map(events, fn(stored) { stored.seq })
}

pub fn appended_events_replay_in_order_across_pages_test() {
  let #(_path, store) = open_in("pl-order")
  assert ledger.last_seq(store) == Ok(0)
  assert ledger.replay(store, 0, 10) == Ok([])
  let appended =
    numbers(1, 7)
    |> list.map(fn(n) { ledger.append(store, event(n), 1000 + n) })
  assert appended == list.map(numbers(1, 7), Ok)
  assert ledger.last_seq(store) == Ok(7)

  // Pages of three continue after the last sequence number received.
  let assert Ok(first) = ledger.replay(store, 0, 3)
  let assert Ok(second) = ledger.replay(store, 3, 3)
  let assert Ok(third) = ledger.replay(store, 6, 3)
  assert seqs(first) == [1, 2, 3]
  assert seqs(second) == [4, 5, 6]
  assert seqs(third) == [7]
  assert ledger.replay(store, 7, 3) == Ok([])

  // Each event comes back exactly as it went in, with its time.
  assert list.first(second)
    == Ok(ledger.StoredEvent(seq: 4, at_ms: 1004, event_json: event(4)))

  // A limit is clamped to a positive page, and no page exceeds the maximum.
  let assert Ok(clamped) = ledger.replay(store, 0, 0)
  assert seqs(clamped) == [1]
  assert ledger.close(store) == Ok(Nil)
}

pub fn malformed_input_is_refused_and_writes_nothing_test() {
  let #(path, store) = open_in("pl-input")
  assert result.is_error(ledger.append(store, "not json", 1))
  assert result.is_error(ledger.append(store, "", 1))
  assert result.is_error(ledger.append(store, event(1), -1))
  assert result.is_error(
    ledger.append_with_effects(store, event(1), 1, [
      draft("reply", "ok", 0),
      draft("", "no-kind", 0),
    ]),
  )
  assert result.is_error(
    ledger.append_with_effects(store, event(1), 1, [
      ledger.EffectDraft(
        kind: "reply",
        key: "k",
        payload_json: "nope",
        due_ms: 0,
      ),
    ]),
  )
  assert result.is_error(ledger.enqueue(store, draft("reply", "bad\nkey", 0)))
  assert result.is_error(ledger.enqueue(store, draft("reply", "k", -5)))
  assert count(path, "ledger_event") == 0
  assert count(path, "effect_row") == 0
  assert ledger.close(store) == Ok(Nil)
}

pub fn an_event_and_its_effects_are_written_together_test() {
  let #(path, store) = open_in("pl-together")
  assert ledger.append_with_effects(store, event(1), 10, [
      draft("reply", "a", 100),
      draft("pr", "b", 50),
    ])
    == Ok(1)
  assert count(path, "ledger_event") == 1
  let assert Ok(due) = ledger.effects_due(store, 100, 10)
  assert list.map(due, fn(effect) { #(effect.kind, effect.key) })
    == [#("pr", "b"), #("reply", "a")]
  assert ledger.close(store) == Ok(Nil)
}

pub fn a_fault_after_the_event_rolls_the_event_back_test() {
  let #(path, store) = open_in("pl-atomic")

  // The trigger fires on the second effect, after the event and the first
  // effect are already written inside the transaction.
  let assert Ok(Nil) =
    raw(
      path,
      "CREATE TRIGGER inject_fault BEFORE INSERT ON effect_row WHEN NEW.key = 'boom' BEGIN SELECT RAISE(ABORT, 'injected'); END",
    )
    |> result.replace_error(Nil)
  let outcome =
    ledger.append_with_effects(store, event(1), 10, [
      draft("reply", "fine", 0),
      draft("reply", "boom", 0),
    ])
  assert result.is_error(outcome)
  assert count(path, "ledger_event") == 0
  assert count(path, "effect_row") == 0
  assert ledger.last_seq(store) == Ok(0)

  // The failed attempt consumed no sequence number, and the ledger still works
  // once the fault is gone.
  let assert Ok(Nil) =
    raw(path, "DROP TRIGGER inject_fault") |> result.replace_error(Nil)
  assert ledger.append_with_effects(store, event(1), 10, [
      draft("reply", "fine", 0),
      draft("reply", "boom", 0),
    ])
    == Ok(1)
  assert count(path, "effect_row") == 2
  assert ledger.close(store) == Ok(Nil)
}

pub fn queueing_an_effect_again_replaces_its_row_test() {
  let #(path, store) = open_in("pl-replace")
  let assert Ok(Nil) = ledger.enqueue(store, draft("reply", "k", 100))
  assert ledger.defer(store, "reply", "k", 500) == Ok(1)
  assert ledger.defer(store, "reply", "k", 900) == Ok(2)
  let assert Ok([deferred]) = ledger.effects_due(store, 1000, 10)
  assert deferred.attempts == 2
  assert deferred.due_ms == 900

  // The same key with a new payload replaces the row and restarts the count.
  let newer =
    ledger.EffectDraft(
      kind: "reply",
      key: "k",
      payload_json: "{\"newer\":true}",
      due_ms: 200,
    )
  assert ledger.enqueue(store, newer) == Ok(Nil)
  assert count(path, "effect_row") == 1
  assert ledger.effects_due(store, 1000, 10)
    == Ok([
      ledger.Effect(
        kind: "reply",
        key: "k",
        payload_json: "{\"newer\":true}",
        attempts: 0,
        due_ms: 200,
      ),
    ])

  // The same key under another kind is a different action.
  let assert Ok(Nil) = ledger.enqueue(store, draft("pr", "k", 300))
  assert count(path, "effect_row") == 2
  assert ledger.close(store) == Ok(Nil)
}

pub fn effects_come_due_in_time_order_and_settle_once_test() {
  let #(_path, store) = open_in("pl-due")
  let assert Ok(Nil) = ledger.enqueue(store, draft("reply", "late", 300))
  let assert Ok(Nil) = ledger.enqueue(store, draft("reply", "b", 100))
  let assert Ok(Nil) = ledger.enqueue(store, draft("reply", "a", 100))
  let keys = fn(now) {
    ledger.effects_due(store, now, 10)
    |> result.map(list.map(_, fn(effect) { effect.key }))
  }
  assert keys(99) == Ok([])
  assert keys(100) == Ok(["a", "b"])
  assert keys(300) == Ok(["a", "b", "late"])
  assert ledger.effects_due(store, 300, 2) |> result.map(list.length) == Ok(2)

  // Settling removes the row, and settling again is not an error.
  assert ledger.settle(store, "reply", "a") == Ok(Nil)
  assert ledger.settle(store, "reply", "a") == Ok(Nil)
  assert keys(300) == Ok(["b", "late"])

  // A deferral of an action that is gone is stale.
  assert ledger.defer(store, "reply", "a", 900) == Error(ledger.Missing)
  assert ledger.close(store) == Ok(Nil)
}

pub fn the_scanner_cursor_is_per_session_and_replaced_test() {
  let #(_path, store) = open_in("pl-cursor")
  assert ledger.cursor(store, "session-a") == Ok(None)
  assert ledger.set_cursor(store, "session-a", "entry-1") == Ok(Nil)
  assert ledger.set_cursor(store, "session-b", "entry-9") == Ok(Nil)
  assert ledger.set_cursor(store, "session-a", "entry-2") == Ok(Nil)
  assert ledger.cursor(store, "session-a") == Ok(Some("entry-2"))
  assert ledger.cursor(store, "session-b") == Ok(Some("entry-9"))
  assert result.is_error(ledger.set_cursor(store, "", "entry-1"))
  assert result.is_error(ledger.set_cursor(store, "session-a", ""))
  assert ledger.close(store) == Ok(Nil)
}

pub fn compaction_keeps_the_tail_and_refuses_a_replay_into_the_hole_test() {
  let #(path, store) = open_in("pl-compact")
  list.each(numbers(1, 5), fn(n) {
    let assert Ok(_) = ledger.append(store, event(n), 1000 + n)
  })
  assert ledger.snapshot(store) == Ok(None)
  assert ledger.compact_before(store, 4, "{\"state\":\"s4\"}", 2000) == Ok(Nil)
  assert ledger.snapshot(store)
    == Ok(
      Some(ledger.Snapshot(
        before_seq: 4,
        at_ms: 2000,
        snapshot_json: "{\"state\":\"s4\"}",
      )),
    )
  assert count(path, "ledger_event") == 2

  // A replay from the start would silently lose events 1 to 3.
  assert ledger.replay(store, 0, 10) == Error(ledger.Compacted(floor: 4))
  assert ledger.replay(store, 2, 10) == Error(ledger.Compacted(floor: 4))
  let assert Ok(tail) = ledger.replay(store, 3, 10)
  assert seqs(tail) == [4, 5]

  // Numbering continues after the compacted range.
  assert ledger.append(store, event(6), 3000) == Ok(6)

  // A point at or below the snapshot's, or past the newest event, is refused.
  assert result.is_error(ledger.compact_before(store, 4, "{}", 3000))
  assert result.is_error(ledger.compact_before(store, 2, "{}", 3000))
  assert result.is_error(ledger.compact_before(store, 7, "{}", 3000))
  assert result.is_error(ledger.compact_before(store, 5, "not json", 3000))
  assert count(path, "ledger_event") == 3

  // A later compaction replaces the snapshot.
  assert ledger.compact_before(store, 6, "{\"state\":\"s6\"}", 3100) == Ok(Nil)
  assert result.map(
      ledger.snapshot(store),
      option.map(_, fn(s) { s.before_seq }),
    )
    == Ok(Some(6))
  assert count(path, "ledger_snapshot") == 1
  assert ledger.close(store) == Ok(Nil)
}

pub fn a_fault_while_writing_the_snapshot_deletes_nothing_test() {
  let #(path, store) = open_in("pl-compact-fault")
  list.each(numbers(1, 4), fn(n) {
    let assert Ok(_) = ledger.append(store, event(n), 1000 + n)
  })
  let assert Ok(Nil) =
    raw(
      path,
      "CREATE TRIGGER inject_fault BEFORE INSERT ON ledger_snapshot BEGIN SELECT RAISE(ABORT, 'injected'); END",
    )
    |> result.replace_error(Nil)
  assert result.is_error(ledger.compact_before(store, 3, "{}", 2000))
  assert count(path, "ledger_event") == 4
  assert ledger.snapshot(store) == Ok(None)
  assert ledger.close(store) == Ok(Nil)
}

pub fn a_closed_ledger_reopens_with_everything_test() {
  let #(path, store) = open_in("pl-reopen")
  let assert Ok(1) =
    ledger.append_with_effects(store, event(1), 10, [draft("reply", "k", 5)])
  let assert Ok(2) = ledger.append(store, event(2), 20)
  let assert Ok(Nil) = ledger.set_cursor(store, "session-a", "entry-7")
  let assert Ok(Nil) = ledger.compact_before(store, 2, "{\"s\":1}", 30)
  assert ledger.close(store) == Ok(Nil)
  let assert Ok(again) = ledger.open(path) as "the ledger reopens"
  assert ledger.last_seq(again) == Ok(2)
  assert ledger.cursor(again, "session-a") == Ok(Some("entry-7"))
  assert ledger.effects_due(again, 5, 10) |> result.map(list.length) == Ok(1)
  assert result.map(ledger.snapshot(again), option.map(_, fn(s) { s.at_ms }))
    == Ok(Some(30))
  let assert Ok(tail) = ledger.replay(again, 1, 10)
  assert tail == [ledger.StoredEvent(seq: 2, at_ms: 20, event_json: event(2))]
  assert ledger.close(again) == Ok(Nil)
}

pub fn a_damaged_row_is_a_typed_error_not_a_crash_test() {
  let #(path, store) = open_in("pl-damaged")
  let assert Ok(1) = ledger.append(store, event(1), 10)

  // Text that is not a JSON document, written past this module.
  let assert Ok(Nil) =
    raw(path, "INSERT INTO ledger_event(at_ms, event_json) VALUES(5, 'oops')")
    |> result.replace_error(Nil)
  assert ledger.replay(store, 0, 10)
    == Error(ledger.MalformedRow("an event row breaks its grammar"))

  // A page that stops before the damaged row is still readable.
  let assert Ok(head) = ledger.replay(store, 0, 1)
  assert seqs(head) == [1]

  // A value of the wrong type is an error too, whichever layer finds it.
  let assert Ok(Nil) =
    raw(path, "UPDATE ledger_event SET at_ms = 'later' WHERE seq = 2")
    |> result.replace_error(Nil)
  assert result.is_error(ledger.replay(store, 1, 10))

  // Effects and the snapshot are judged the same way.
  let assert Ok(Nil) =
    raw(
      path,
      "INSERT INTO effect_row VALUES('reply', 'k', 'oops', 0, 0); INSERT INTO ledger_snapshot VALUES(1, 2, 0, 'oops')",
    )
    |> result.replace_error(Nil)
  assert ledger.effects_due(store, 0, 10)
    == Error(ledger.MalformedRow("an effect row breaks its grammar"))
  assert ledger.snapshot(store)
    == Error(ledger.MalformedRow("the snapshot row breaks its grammar"))
  assert ledger.close(store) == Ok(Nil)
}

pub fn another_database_is_refused_unchanged_test() {
  let directory = fixtures.scratch("pl-foreign")

  // An unrelated database with tables of its own.
  let other = directory <> "/other.db"
  let assert Ok(Nil) =
    raw(other, "CREATE TABLE unrelated(a INTEGER)") |> result.replace_error(Nil)
  let assert Error(ledger.Unsupported) = ledger.open(other)
  assert count(other, "unrelated") == 0

  // The daemon's catalogue is a different kind of file.
  let catalogue_path = directory <> "/catalogue.db"
  let assert Ok(store) = catalogue.open(catalogue_path)
  assert catalogue.close(store) == Ok(Nil)
  let assert Error(ledger.Unsupported) = ledger.open(catalogue_path)
}
