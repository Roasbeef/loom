//// Tests for the production join: marks to profiles by journal order, the
//// unmarked exclusion, and the rule that an original session file is never
//// opened.

import core/clock
import core/entry.{MessageEntry}
import core/ids.{type EntryId}
import core/json
import core/message.{AssistantMessage, Stop, Usage, UsageCost}
import core/register
import core/tx.{type Write, InsertEntry, SetRegister, Tx}
import core/usage_evidence
import eval/production.{
  Answer, Attempt, Failed, HoldoutRate, Row, Session, Succeeded, Unmarked,
}
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import storage/sqlite
import storage/storage

fn answer(entry: String, seq: Int) -> production.Answer {
  Answer(entry:, seq:, provider: "p", model: "m", api: "a")
}

fn attempt(seq: Int, profile: option.Option(String)) -> production.Attempt {
  Attempt(seq:, provider: "p", model: "m", api: "a", profile:)
}

pub fn production_join_excludes_unmarked_test() {
  // Attempts journal profile one, then profile two; each answer follows its
  // own attempt. Entry c is unmarked and must not count against profile two.
  let session =
    Session(
      answers: [answer("a", 2), answer("b", 4), answer("c", 6), answer("d", 8)],
      attempts: [
        attempt(1, Some("one")),
        attempt(3, Some("one")),
        attempt(5, Some("two")),
        attempt(7, Some("two")),
      ],
      marks: dict.from_list([
        #("a", Succeeded),
        #("b", Failed),
        #("d", Succeeded),
      ]),
    )
  let table =
    production.rows(production.tally(session), [
      HoldoutRate(profile: "two", passed: 3, trials: 4),
    ])
  let assert [one, two] = table as "two profiles"

  assert one == Row(Some("one"), 1, 1, 0, None)
  assert two.unmarked == 1
  assert two.succeeded == 1
  assert two.failed == 0

  // One success, no failure: the unmarked answer is not in the denominator.
  assert production.marked_rate(two) == Some(1.0)
  assert production.marked_rate(one) == Some(0.5)
  assert two.holdout == Some(HoldoutRate("two", 3, 4))
  assert string.contains(production.render(table), "unmarked")
}

pub fn an_unjournaled_answer_reports_under_the_absent_profile_test() {
  let session =
    Session(
      answers: [answer("a", 1)],
      attempts: [attempt(2, Some("late"))],
      marks: dict.new(),
    )
  assert production.tally(session) == [#(None, Unmarked)]
}

fn generator() -> ids.Generator {
  ids.generator(clock.stepping(from: 1000, by: 1), seed: 11)
}

fn assistant(id: EntryId) -> entry.Entry {
  MessageEntry(
    id:,
    parent: None,
    seq: 0,
    ts: 0,
    message: AssistantMessage(
      content: [],
      api: "a",
      provider: "p",
      model: "m",
      response_model: None,
      response_id: None,
      diagnostics: None,
      usage: Usage(
        input: 1,
        output: 1,
        cache_read: 0,
        cache_write: 0,
        cache_write_1h: None,
        reasoning: None,
        total_tokens: 2,
        cost: UsageCost(
          input: 0.0,
          output: 0.0,
          cache_read: 0.0,
          cache_write: 0.0,
          total: 0.0,
        ),
        evidence: usage_evidence.priced_api(),
      ),
      stop_reason: Stop,
      deferred: None,
      error_message: None,
      raw_stop_reason: None,
      end_turn: None,
      timestamp: 0,
    ),
    terminate: False,
  )
}

fn attempt_fact(key: String, profile: String) -> Write {
  SetRegister(
    register.FactCustom,
    "evolution/attempt/" <> key,
    register.RegisterValue(
      json.Object([
        #("provider", json.String("p")),
        #("model", json.String("m")),
        #("api", json.String("a")),
        #("ordinal", json.Int(0)),
        #("digest", json.String("d")),
        #("profile_id", json.String(profile)),
      ]),
    ),
  )
}

fn mark_fact(id: EntryId, outcome: String) -> Write {
  SetRegister(
    register.FactCustom,
    "prompt/evolution-outcome/" <> ids.entry_id_to_string(id),
    register.RegisterValue(
      json.Object([
        #("version", json.Int(1)),
        #("principal", json.String("operator")),
        #("outcome", json.String(outcome)),
      ]),
    ),
  )
}

pub fn production_join_reads_copies_test() {
  let state = "build/production-test/copies"
  let _ = simplifile.delete(state)
  let assert Ok(Nil) = simplifile.create_directory_all(state <> "/sessions")
  let path = state <> "/sessions/s.db"
  let #(first, gen) = ids.mint_entry(generator())
  let #(second, _) = ids.mint_entry(gen)

  // The writer stays open for the whole join, holding its lease.
  let assert Ok(store) =
    sqlite.open(sqlite.config(path:, owner: "writer"), clock.fixed(at: 10_000))
  let assert Ok(_) =
    storage.commit(
      store,
      Tx(
        writes: [
          attempt_fact("a1", "profile-x"),
          InsertEntry(assistant(first)),
          attempt_fact("a2", "profile-y"),
          InsertEntry(assistant(second)),
          mark_fact(first, "succeeded"),
        ],
        expected: [],
      ),
    )
  let assert Ok(before) = simplifile.read_bits(path)
  let assert Ok(info_before) = simplifile.file_info(path)

  let assert Ok(table) = production.join(state, 0, [])

  let assert Ok(after) = simplifile.read_bits(path)
  let assert Ok(info_after) = simplifile.file_info(path)
  let assert Ok(names) = simplifile.read_directory(state <> "/sessions")

  assert table
    == [
      Row(Some("profile-x"), 1, 0, 0, None),
      Row(Some("profile-y"), 0, 0, 1, None),
    ]

  // The original was neither opened nor written, and no copy is left behind.
  assert after == before
  assert info_after.mtime_seconds == info_before.mtime_seconds
  assert list.all(names, fn(name) { !string.contains(name, "production") })
  let assert Error(sqlite.LeaseHeld(owner: "writer", ..)) =
    sqlite.open(sqlite.config(path:, owner: "other"), clock.fixed(at: 10_001))

  // A cutoff after every commit leaves nothing to join.
  let assert Ok(none) = production.join(state, 10_001, [])
  assert none == []
  let assert Ok(Nil) = storage.close(store)
}

pub fn a_malformed_mark_is_an_error_not_an_unmarked_answer_test() {
  let state = "build/production-test/corrupt"
  let _ = simplifile.delete(state)
  let assert Ok(Nil) = simplifile.create_directory_all(state <> "/sessions")
  let #(first, _) = ids.mint_entry(generator())
  let assert Ok(store) =
    sqlite.open(
      sqlite.config(path: state <> "/sessions/s.db", owner: "writer"),
      clock.fixed(at: 10_000),
    )
  let assert Ok(_) =
    storage.commit(
      store,
      Tx(
        writes: [
          InsertEntry(assistant(first)),
          SetRegister(
            register.FactCustom,
            "prompt/evolution-outcome/" <> ids.entry_id_to_string(first),
            register.RegisterValue(json.String("succeeded")),
          ),
        ],
        expected: [],
      ),
    )
  let _closed = storage.close(store)

  let assert Error(reason) = production.join(state, 0, [])
  assert string.contains(reason, "mark")
}
