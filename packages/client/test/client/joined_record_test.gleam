//// A settled join answer kept as text and read back
//// (protocol-change/107, slice 4b).
////
//// A join asked again after a seeded child's session was ended is answered from
//// this record, so what is read back has to be the entry that was kept, in every
//// field and for every kind of result, and text that is not a record has to read
//// as nothing.

import client/joined_record
import client/remote_spawn.{type Joined}
import client/state_object.{type State, Clean, State}
import core/clock
import core/ids
import core/json as core_json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import qcheck
import tools/agent

const property_seed = 10_703

fn handle() -> agent.Handle {
  let #(op, _) = ids.mint_op(ids.generator(clock.fixed(at: 1), seed: 9))
  agent.Handle(
    strand: "sub:^main/finish-the-cache-0123456789abcdef",
    operation: op,
  )
}

fn usage() -> remote_spawn.ChildUsage {
  remote_spawn.ChildUsage(
    input: 11,
    output: 7,
    cache_read: 3,
    cache_write: 2,
    cost: 0.25,
  )
}

fn a_state() -> State {
  State(
    hash: state_object.hash_of(<<"bundle">>),
    size: 6,
    tip: "0123456789abcdef0123456789abcdef01234567",
    base: Some("89abcdef0123456789abcdef0123456789abcdef"),
    dirty: Clean,
  )
}

fn entry(
  outcome: agent.Outcome,
  report: String,
  result: agent.TerminalResult,
) -> Joined {
  entry_owing(outcome, report, result, 0)
}

fn entry_owing(
  outcome: agent.Outcome,
  report: String,
  result: agent.TerminalResult,
  owed: Int,
) -> Joined {
  remote_spawn.Ready(
    handle: handle(),
    outcome:,
    report:,
    result:,
    notes: [#("plan", core_json.String("done")), #("n", core_json.Int(3))],
    usage: usage(),
    owed:,
    state: Some(a_state()),
  )
}

fn schema() -> agent.ResultSchema {
  let assert Ok(parsed) =
    core_json.parse(
      "{\"type\":\"object\",\"properties\":{\"files\":{\"type\":\"integer\"}},\"required\":[\"files\"]}",
    )
  let assert Ok(found) = agent.parse_result_schema(parsed)
  found
}

fn round_trips(found: Joined) -> Bool {
  case joined_record.encode(found) {
    Ok(text) -> joined_record.decode(text) == Ok(found)
    Error(Nil) -> False
  }
}

pub fn every_outcome_and_kind_of_result_reads_back_as_it_was_kept_test() {
  let outcomes = [
    agent.Completed,
    agent.Failed("it broke"),
    agent.Aborted,
    agent.BudgetExpired,
    agent.ParentFinished,
    agent.Released,
    agent.TokenBudgetSpent,
  ]
  list.each(outcomes, fn(outcome) {
    assert round_trips(entry(outcome, "done", agent.NoResultAsked))
  })

  // A result that was given, one that is absent, and one that does not match.
  assert round_trips(entry(
    agent.Completed,
    "done",
    agent.ResultGiven(core_json.Object([#("files", core_json.Int(2))])),
  ))
  assert round_trips(entry(agent.Completed, "", agent.ResultAbsent(schema())))
  assert round_trips(entry(
    agent.Completed,
    "done",
    agent.ResultUnusable(
      schema(),
      core_json.Object([#("files", core_json.String("two"))]),
      agent.FieldWrongType("files", agent.IntegerField, "string"),
    ),
  ))
}

pub fn an_entry_with_no_commits_and_no_notes_reads_back_test() {
  let bare =
    remote_spawn.Ready(
      handle: handle(),
      outcome: agent.Completed,
      report: "line one\nline \"two\"\n",
      result: agent.NoResultAsked,
      notes: [],
      usage: usage(),
      owed: 0,
      state: None,
    )
  assert round_trips(bare)
}

pub fn a_pending_entry_is_not_an_answer_and_is_not_kept_test() {
  assert joined_record.encode(remote_spawn.Pending(handle(), 5)) == Error(Nil)
}

pub fn text_that_is_not_a_record_reads_as_nothing_test() {
  assert joined_record.decode("") == Error(Nil)
  assert joined_record.decode("not json") == Error(Nil)
  assert joined_record.decode("{}") == Error(Nil)

  // A record with a word that is not an outcome, or a handle that is not one.
  let assert Ok(text) =
    joined_record.encode(entry(agent.Completed, "done", agent.NoResultAsked))
  assert joined_record.decode(replace(text, "\"completed\"", "\"vanished\""))
    == Error(Nil)
  assert joined_record.decode(replace(text, "#", "@")) == Error(Nil)
}

pub fn any_report_and_count_reads_back_test() {
  let config =
    qcheck.default_config()
    |> qcheck.with_test_count(200)
    |> qcheck.with_seed(qcheck.seed(property_seed))
  qcheck.run(
    config,
    qcheck.tuple2(qcheck.string(), qcheck.bounded_int(0, 50)),
    fn(drawn) {
      let #(report, owed) = drawn
      let found =
        entry_owing(agent.Completed, report, agent.NoResultAsked, owed)
      assert round_trips(found)
    },
  )
}

fn replace(text: String, old: String, new: String) -> String {
  string.replace(text, old, new)
}
