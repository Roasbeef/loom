//// The goal cell's codec, tested the way a pure codec can be: every
//// shape the wire can present, each either decoding to exactly the goal
//// that wrote it or refusing with an error naming the field that broke.
////
//// Three kinds of test. The **codec** round-trips goals in every state
//// the cell can hold — four statuses, six causes and three phases — and
//// pins the stored field names in one written-out assertion, so a rename
//// shows up as a diff here rather than as a silently unreadable cell on
//// somebody's disk. The **defaults** check that the fields with a zero
//// value meaning "nothing recorded yet" — the five counters, the cost and
//// the two nullable strings — may be absent, while the six fields the
//// owner always writes may not. The **malformed catalogue** feeds the
//// decoder every wrong shape: a non-object, each required field absent,
//// each field present and mistyped, an unknown status word, a status and
//// reason that do not belong together, a phase whose state and operation
//// disagree, a non-positive budget, and the cross-field violations, each
//// of which must come back as an error naming where it came from.

import client/goalstate.{type Goal}
import core/clock
import core/ids.{type OpId}
import core/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string

// --- fixtures -------------------------------------------------------------

// The advisor run a stored `awaiting_verdict` phase names, and the primary
// run a stored `continuing` phase names. Minted rather than written out as
// UUID text, because `decode_phase` holds an operation to the same
// UUIDv7-with-RFC-variant rule `core/ids` holds every other id to.
fn a_feed_run() -> OpId {
  let #(id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 1000), seed: 7))
  id
}

fn a_woken_run() -> OpId {
  let #(id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 1000), seed: 23))
  id
}

// A goal mid-flight, with every field far enough from its default that a
// decoder quietly swapping in the default would show — the phase included,
// which is why this fixture is awaiting a verdict rather than idle. Built
// through `decode` rather than spelled as a record, so the fixture is
// itself a claim that the stored shape reads back.
fn working_goal() -> Goal {
  let assert Ok(goal) =
    goalstate.decode(
      json.Object([
        #("objective", json.String("make the failing storage race test pass")),
        #("status", json.String("active")),
        #("reason", json.Null),
        #(
          "phase",
          goalstate.encode_phase(goalstate.AwaitingVerdict(feed: a_feed_run())),
        ),
        #("token_budget", json.Int(400_000)),
        #("tokens_used", json.Int(51_200)),
        #("accounted_through_seq", json.Int(3417)),
        #("cost_used", json.Float(0.41)),
        #("continuations", json.Int(3)),
        #("zero_progress", json.Int(1)),
        #("unanswered_feeds", json.Int(2)),
        #("created_ms", json.Int(1_726_000_000_000)),
        #("updated_ms", json.Int(1_726_003_600_000)),
        #("reviewer_note", json.Null),
      ]),
    )
    as "the §1 example payload decodes"
  goal
}

// A goal carrying the one optional value that is not a zero: the
// reviewer's note, which only a terminal verdict writes. Terminal goals
// are idle, because the verdict that ended the goal also closed the feed.
fn completed_goal() -> Goal {
  goalstate.Goal(
    ..working_goal(),
    status: goalstate.Complete,
    phase: goalstate.Idle,
    reviewer_note: Some("the race test passes on the seeded run"),
  )
}

// A goal a bound stopped, which is the state whose cause the cell has to
// carry beside the status word.
fn held_goal() -> Goal {
  goalstate.Goal(
    ..working_goal(),
    status: goalstate.Limited(by: goalstate.ByContinuationCap),
    phase: goalstate.Idle,
  )
}

// Every status the cell can hold, cause and all. The list is exhaustive
// by hand rather than generated, so a new cause has to be added here to
// be considered tested.
fn every_status() -> List(goalstate.Status) {
  [
    goalstate.Active,
    goalstate.Paused(by: goalstate.ByOperator),
    goalstate.Paused(by: goalstate.ByAbort),
    goalstate.Paused(by: goalstate.ByZeroProgress),
    goalstate.Paused(by: goalstate.ByUnresponsiveReviewer),
    goalstate.Limited(by: goalstate.ByTokenBudget),
    goalstate.Limited(by: goalstate.ByContinuationCap),
    goalstate.Complete,
  ]
}

// --- the codec ------------------------------------------------------------

// Every state the cell can hold, round-tripped: the goal the actor
// writes, the one a bound trip leaves, and the terminal one carrying a
// note.
pub fn every_state_round_trips_test() {
  let states = [working_goal(), completed_goal(), held_goal()]

  list.each(states, fn(goal) {
    assert goalstate.decode(goalstate.encode(goal)) == Ok(goal)
  })
}

// The status is only half the state once a cause rides beside it, so
// every status-and-cause pair round-trips through the whole cell rather
// than only through `encode_status`.
pub fn every_status_round_trips_through_the_cell_test() {
  list.each(every_status(), fn(status) {
    let goal = goalstate.Goal(..working_goal(), status:, phase: goalstate.Idle)

    assert goalstate.decode(goalstate.encode(goal)) == Ok(goal)
  })
}

// The three phases, each through its own codec pair and each as the wire
// object protocol 044 §1 names.
pub fn every_phase_round_trips_test() {
  let phases = [
    goalstate.Idle,
    goalstate.AwaitingVerdict(feed: a_feed_run()),
    goalstate.Continuing(woken: a_woken_run()),
  ]

  list.each(phases, fn(phase) {
    assert goalstate.decode_phase(goalstate.encode_phase(phase)) == Ok(phase)
  })

  // The idle object written out, because the null operation is the part a
  // writer is most likely to leave out by accident.
  assert goalstate.encode_phase(goalstate.Idle)
    == json.Object([
      #("state", json.String("idle")),
      #("operation", json.Null),
    ])
  assert goalstate.encode_phase(goalstate.Continuing(woken: a_woken_run()))
    == json.Object([
      #("state", json.String("continuing")),
      #("operation", json.String(ids.op_id_to_string(a_woken_run()))),
    ])
}

// The stored form written out rather than computed, so a change to the
// field names shows up as a diff here and not as a silently unreadable
// cell on somebody's disk. This is the §1 object, field for field.
pub fn the_stored_form_is_the_documented_object_test() {
  let assert json.Object(fields) = goalstate.encode(working_goal())
    as "the stored goal is an object"

  assert list.map(fields, fn(field) { field.0 })
    == [
      "objective", "status", "reason", "phase", "token_budget", "tokens_used",
      "accounted_through_seq", "cost_used", "continuations", "zero_progress",
      "unanswered_feeds", "created_ms", "updated_ms", "reviewer_note",
    ]
  assert list.key_find(fields, "status") == Ok(json.String("active"))
  assert list.key_find(fields, "reason") == Ok(json.Null)
  assert list.key_find(fields, "token_budget") == Ok(json.Int(400_000))
  assert list.key_find(fields, "cost_used") == Ok(json.Float(0.41))
  assert list.key_find(fields, "zero_progress") == Ok(json.Int(1))
  assert list.key_find(fields, "unanswered_feeds") == Ok(json.Int(2))
  assert list.key_find(fields, "reviewer_note") == Ok(json.Null)
}

// A stopped goal stores its cause in the sibling field, which is what
// the operator's panel reads to say more than "paused".
pub fn a_stopped_goal_stores_its_cause_test() {
  let assert json.Object(fields) = goalstate.encode(held_goal())
    as "the stored goal is an object"

  assert list.key_find(fields, "status") == Ok(json.String("budget_limited"))
  assert list.key_find(fields, "reason") == Ok(json.String("continuation_cap"))
}

// A goal with no note says so with null, not by leaving the field out:
// absence means an older writer, and the two must not be confused.
pub fn a_goal_without_a_note_stores_null_test() {
  let assert json.Object(fields) = goalstate.encode(working_goal())
    as "the stored goal is an object"

  assert list.key_find(fields, "reviewer_note") == Ok(json.Null)
}

// The note round-trips both ways: present as a string, absent as null,
// and each reading back to the goal that wrote it.
pub fn a_reviewer_note_round_trips_test() {
  assert goalstate.decode(goalstate.encode(completed_goal()))
    == Ok(completed_goal())

  let assert json.Object(fields) = goalstate.encode(completed_goal())
    as "the stored goal is an object"
  assert list.key_find(fields, "reviewer_note")
    == Ok(json.String("the race test passes on the seeded run"))
}

// `new` is the goal a `goal_set` pins: active, idle, zeroed accounting
// and counters, both timestamps at the pin, no note yet.
pub fn a_new_goal_is_active_with_zeroed_accounting_test() {
  let goal = goalstate.new("land the migration", 400_000, 1_726_000_000_000)

  assert goalstate.status_of(goal) == goalstate.Active
  assert goal.phase == goalstate.Idle
  assert goalstate.tokens_used_of(goal) == 0
  assert goal.zero_progress == 0
  assert goal.unanswered_feeds == 0
  assert goalstate.reviewer_note_of(goal) == None
  assert goalstate.decode(goalstate.encode(goal)) == Ok(goal)

  let assert json.Object(fields) = goalstate.encode(goal)
    as "the stored goal is an object"
  assert list.key_find(fields, "created_ms") == Ok(json.Int(1_726_000_000_000))
  assert list.key_find(fields, "updated_ms") == Ok(json.Int(1_726_000_000_000))
}

// The status words and their cause words, each way. `decode_status` names
// all four accepted words in its refusal, so an operator reading a
// corrupt cell can see what was expected rather than only what arrived.
pub fn status_words_and_reasons_round_trip_test() {
  let words = [
    #(goalstate.Active, "active", None),
    #(goalstate.Paused(by: goalstate.ByOperator), "paused", Some("operator")),
    #(goalstate.Paused(by: goalstate.ByAbort), "paused", Some("aborted")),
    #(
      goalstate.Paused(by: goalstate.ByZeroProgress),
      "paused",
      Some("zero_progress"),
    ),
    #(
      goalstate.Paused(by: goalstate.ByUnresponsiveReviewer),
      "paused",
      Some("reviewer_unresponsive"),
    ),
    #(
      goalstate.Limited(by: goalstate.ByTokenBudget),
      "budget_limited",
      Some("token_budget"),
    ),
    #(
      goalstate.Limited(by: goalstate.ByContinuationCap),
      "budget_limited",
      Some("continuation_cap"),
    ),
    #(goalstate.Complete, "complete", None),
  ]

  list.each(words, fn(row) {
    let #(status, word, reason) = row
    assert goalstate.encode_status(status) == word
    assert goalstate.encode_reason(status) == reason
    assert goalstate.decode_status(word, reason) == Ok(status)
  })
}

// The pairing is the point of the reason field: a `paused` with no cause
// would tell the operator the harness is holding their goal and refuse to
// say why, and a cause on a status that cannot carry one is a writer that
// means something this decoder does not.
pub fn the_status_and_its_reason_must_belong_together_test() {
  assert goalstate.decode_status("paused", None)
    == Error("client/goalstate.decode: a paused goal must carry a reason")
  assert goalstate.decode_status("budget_limited", None)
    == Error(
      "client/goalstate.decode: a budget_limited goal must carry a reason",
    )
  assert goalstate.decode_status("active", Some("operator"))
    == Error(
      "client/goalstate.decode: active carries no reason, got \"operator\"",
    )
  assert goalstate.decode_status("complete", Some("token_budget"))
    == Error(
      "client/goalstate.decode: complete carries no reason, got \"token_budget\"",
    )
  assert goalstate.decode_status("paused", Some("token_budget"))
    == Error(
      "client/goalstate.decode: \"token_budget\" is not a reason a paused "
      <> "goal can carry",
    )
  assert goalstate.decode_status("budget_limited", Some("aborted"))
    == Error(
      "client/goalstate.decode: \"aborted\" is not a reason a budget_limited "
      <> "goal can carry",
    )
}

// --- defaults -------------------------------------------------------------

// The fields that may be absent are the ones whose zero value means
// "nothing recorded yet": the five counters, the cost and the two
// nullable strings. A payload carrying only what the owner always writes
// decodes to a goal with everything else zeroed.
pub fn the_optional_fields_take_the_defaults_test() {
  let stored =
    json.Object([
      #("objective", json.String("land the migration")),
      #("status", json.String("paused")),
      #("reason", json.String("operator")),
      #("phase", goalstate.encode_phase(goalstate.Idle)),
      #("token_budget", json.Int(400_000)),
      #("created_ms", json.Int(1_726_000_000_000)),
      #("updated_ms", json.Int(1_726_000_000_000)),
    ])

  let expected = goalstate.new("land the migration", 400_000, 1_726_000_000_000)
  let assert Ok(carried) = goalstate.decode(stored)
    as "a payload with only the required fields still decodes"

  // The carried status is the stored one, not the fresh goal's.
  assert goalstate.status_of(carried)
    == goalstate.Paused(by: goalstate.ByOperator)
  assert carried
    == goalstate.Goal(
      ..expected,
      status: goalstate.Paused(by: goalstate.ByOperator),
    )
}

// The cost is a number either way on the wire: an integer cost reads as
// the same value a float cost would have carried.
pub fn an_integer_cost_reads_as_a_number_test() {
  let stored =
    json.Object([
      #("objective", json.String("land the migration")),
      #("status", json.String("active")),
      #("phase", goalstate.encode_phase(goalstate.Idle)),
      #("token_budget", json.Int(400_000)),
      #("cost_used", json.Int(0)),
      #("created_ms", json.Int(1000)),
      #("updated_ms", json.Int(2000)),
    ])

  let assert Ok(goal) = goalstate.decode(stored)
    as "an integer cost still decodes"

  assert goal.cost_used == 0.0
}

// Null in the note slot is present and means the same as absence, and the
// same holds of the reason slot on a status that carries no cause.
pub fn a_null_note_reads_as_none_test() {
  let stored =
    json.Object([
      #("objective", json.String("land the migration")),
      #("status", json.String("active")),
      #("reason", json.Null),
      #("phase", goalstate.encode_phase(goalstate.Idle)),
      #("token_budget", json.Int(400_000)),
      #("reviewer_note", json.Null),
      #("created_ms", json.Int(1000)),
      #("updated_ms", json.Int(2000)),
    ])

  // The timestamps differ here (2000 vs 1000), so the expected goal is
  // built from `new` with the one field overridden rather than spelled
  // out, keeping the zero-defaults in one place.
  assert goalstate.decode(stored)
    == Ok(
      goalstate.Goal(
        ..goalstate.new("land the migration", 400_000, 1000),
        updated_ms: 2000,
      ),
    )
}

// An absent phase operation is the same absence a null one is, so an
// idle phase may be stored either way.
pub fn an_absent_phase_operation_reads_as_idle_test() {
  assert goalstate.decode_phase(json.Object([#("state", json.String("idle"))]))
    == Ok(goalstate.Idle)
}

// --- the malformed catalogue ----------------------------------------------

// Every catalogue entry below is one field wrong and the rest right, so
// each carries the well-formed idle phase. Threading it through this
// helper keeps every entry about its own field rather than about the
// phase it had to spell to get there.
fn with_phase(fields: List(#(String, json.JsonValue))) -> json.JsonValue {
  json.Object(
    list.append(fields, [#("phase", goalstate.encode_phase(goalstate.Idle))]),
  )
}

// Every way a cell can be wrong, each of which must be an error naming
// the field that broke rather than a crash or a half-read goal.
fn malformed() -> List(#(String, json.JsonValue)) {
  [
    #("a bare string", json.String("x")),
    #("a bare array", json.Array([])),
    #("a bare number", json.Int(3)),
    #("a bare boolean", json.Bool(True)),
    #("a bare null", json.Null),
    #("an absent objective", with_phase([])),
    #(
      "an absent status",
      with_phase([
        #("objective", json.String("x")),
        #("token_budget", json.Int(100)),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "an absent phase",
      json.Object([
        #("objective", json.String("x")),
        #("status", json.String("active")),
        #("token_budget", json.Int(100)),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "an absent budget",
      with_phase([
        #("objective", json.String("x")),
        #("status", json.String("active")),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "an absent created_ms",
      with_phase([
        #("objective", json.String("x")),
        #("status", json.String("active")),
        #("token_budget", json.Int(100)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "an absent updated_ms",
      with_phase([
        #("objective", json.String("x")),
        #("status", json.String("active")),
        #("token_budget", json.Int(100)),
        #("created_ms", json.Int(1000)),
      ]),
    ),
    #(
      "an empty objective",
      with_phase([
        #("objective", json.String("")),
        #("status", json.String("active")),
        #("token_budget", json.Int(100)),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "a numeric objective",
      with_phase([
        #("objective", json.Int(1)),
        #("status", json.String("active")),
        #("token_budget", json.Int(100)),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "an unknown status word",
      with_phase([
        #("objective", json.String("x")),
        #("status", json.String("finished")),
        #("token_budget", json.Int(100)),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "a numeric status",
      with_phase([
        #("objective", json.String("x")),
        #("status", json.Int(1)),
        #("token_budget", json.Int(100)),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "a paused status with no reason",
      with_phase([
        #("objective", json.String("x")),
        #("status", json.String("paused")),
        #("token_budget", json.Int(100)),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "an active status carrying a reason",
      with_phase([
        #("objective", json.String("x")),
        #("status", json.String("active")),
        #("reason", json.String("operator")),
        #("token_budget", json.Int(100)),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "a reason belonging to the other status",
      with_phase([
        #("objective", json.String("x")),
        #("status", json.String("budget_limited")),
        #("reason", json.String("zero_progress")),
        #("token_budget", json.Int(100)),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "a numeric reason",
      with_phase([
        #("objective", json.String("x")),
        #("status", json.String("paused")),
        #("reason", json.Int(1)),
        #("token_budget", json.Int(100)),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "a textual phase",
      json.Object([
        #("objective", json.String("x")),
        #("status", json.String("active")),
        #("phase", json.String("idle")),
        #("token_budget", json.Int(100)),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "an unknown phase state",
      json.Object([
        #("objective", json.String("x")),
        #("status", json.String("active")),
        #(
          "phase",
          json.Object([
            #("state", json.String("reviewing")),
            #("operation", json.Null),
          ]),
        ),
        #("token_budget", json.Int(100)),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "an awaiting phase naming no operation",
      json.Object([
        #("objective", json.String("x")),
        #("status", json.String("active")),
        #(
          "phase",
          json.Object([
            #("state", json.String("awaiting_verdict")),
            #("operation", json.Null),
          ]),
        ),
        #("token_budget", json.Int(100)),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "an idle phase naming an operation",
      json.Object([
        #("objective", json.String("x")),
        #("status", json.String("active")),
        #(
          "phase",
          json.Object([
            #("state", json.String("idle")),
            #("operation", json.String(ids.op_id_to_string(a_woken_run()))),
          ]),
        ),
        #("token_budget", json.Int(100)),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "a phase operation that is not an operation id",
      json.Object([
        #("objective", json.String("x")),
        #("status", json.String("active")),
        #(
          "phase",
          json.Object([
            #("state", json.String("continuing")),
            #("operation", json.String("not-a-uuid")),
          ]),
        ),
        #("token_budget", json.Int(100)),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "a zero budget",
      with_phase([
        #("objective", json.String("x")),
        #("status", json.String("active")),
        #("token_budget", json.Int(0)),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "a negative budget",
      with_phase([
        #("objective", json.String("x")),
        #("status", json.String("active")),
        #("token_budget", json.Int(-100)),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "a textual budget",
      with_phase([
        #("objective", json.String("x")),
        #("status", json.String("active")),
        #("token_budget", json.String("400000")),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "a negative created_ms",
      with_phase([
        #("objective", json.String("x")),
        #("status", json.String("active")),
        #("token_budget", json.Int(100)),
        #("created_ms", json.Int(-1)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "a negative updated_ms",
      with_phase([
        #("objective", json.String("x")),
        #("status", json.String("active")),
        #("token_budget", json.Int(100)),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(-1)),
      ]),
    ),
    #(
      "a textual tokens_used",
      with_phase([
        #("objective", json.String("x")),
        #("status", json.String("active")),
        #("token_budget", json.Int(100)),
        #("tokens_used", json.String("51200")),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "a null tokens_used",
      with_phase([
        #("objective", json.String("x")),
        #("status", json.String("active")),
        #("token_budget", json.Int(100)),
        #("tokens_used", json.Null),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "a negative tokens_used",
      with_phase([
        #("objective", json.String("x")),
        #("status", json.String("active")),
        #("token_budget", json.Int(100)),
        #("tokens_used", json.Int(-1)),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "a negative continuations",
      with_phase([
        #("objective", json.String("x")),
        #("status", json.String("active")),
        #("token_budget", json.Int(100)),
        #("continuations", json.Int(-1)),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "a negative zero_progress",
      with_phase([
        #("objective", json.String("x")),
        #("status", json.String("active")),
        #("token_budget", json.Int(100)),
        #("zero_progress", json.Int(-1)),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "a negative unanswered_feeds",
      with_phase([
        #("objective", json.String("x")),
        #("status", json.String("active")),
        #("token_budget", json.Int(100)),
        #("unanswered_feeds", json.Int(-1)),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "a textual cost",
      with_phase([
        #("objective", json.String("x")),
        #("status", json.String("active")),
        #("token_budget", json.Int(100)),
        #("cost_used", json.String("0.41")),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "a numeric reviewer_note",
      with_phase([
        #("objective", json.String("x")),
        #("status", json.String("active")),
        #("token_budget", json.Int(100)),
        #("reviewer_note", json.Int(1)),
        #("created_ms", json.Int(1000)),
        #("updated_ms", json.Int(2000)),
      ]),
    ),
    #(
      "updated before created",
      with_phase([
        #("objective", json.String("x")),
        #("status", json.String("active")),
        #("token_budget", json.Int(100)),
        #("created_ms", json.Int(2000)),
        #("updated_ms", json.Int(1000)),
      ]),
    ),
  ]
}

pub fn every_malformed_cell_is_an_error_test() {
  list.each(malformed(), fn(row) {
    let #(name, payload) = row
    case goalstate.decode(payload) {
      Ok(_goal) -> panic as { name <> " decoded instead of being refused" }

      // The report names where it came from, so an operator holding a
      // corrupt cell can find the decoder that refused it.
      Error(message) -> {
        assert string.starts_with(message, "client/goalstate.decode: ")
        assert message != "client/goalstate.decode: "
      }
    }
  })
}

// The cross-field refusals name the invariant they protect, because the
// error is what an operator reads when a cell goes bad.
pub fn the_cross_field_refusals_are_worded_test() {
  let assert Ok(#(_name, negative_tokens)) =
    list.find(malformed(), fn(row) { row.0 == "a negative tokens_used" })
    as "the catalogue carries this entry"

  let assert Error(message) = goalstate.decode(negative_tokens)
    as "a negative tokens_used is refused"
  assert message
    == "client/goalstate.decode: tokens_used must not be negative, got -1"

  let assert Ok(#(_name, before_created)) =
    list.find(malformed(), fn(row) { row.0 == "updated before created" })
    as "the catalogue carries this entry"

  let assert Error(message) = goalstate.decode(before_created)
    as "an updated before its created is refused"
  assert message
    == "client/goalstate.decode: updated_ms 1000 is before created_ms 2000"

  let assert Ok(#(_name, no_phase)) =
    list.find(malformed(), fn(row) { row.0 == "an absent phase" })
    as "the catalogue carries this entry"

  let assert Error(message) = goalstate.decode(no_phase)
    as "an absent phase is refused"
  assert message == "client/goalstate.decode: phase is required"

  let assert Ok(#(_name, mismatched)) =
    list.find(malformed(), fn(row) {
      row.0 == "an awaiting phase naming no operation"
    })
    as "the catalogue carries this entry"

  let assert Error(message) = goalstate.decode(mismatched)
    as "a phase whose state and operation disagree is refused"
  assert message
    == "client/goalstate.decode: phase state \"awaiting_verdict\" does not "
    <> "match the operation beside it"
}

// --- the doc examples -------------------------------------------------------

// The examples asserted in the module's doc comments, so the prose a
// reader learns the API from is the same code a test proves.
pub fn the_doc_examples_hold_test() {
  // `new` and its three accessors.
  let goal = goalstate.new("land the migration", 400_000, 1_726_000_000_000)
  assert goalstate.status_of(goal) == goalstate.Active
  assert goal.phase == goalstate.Idle
  assert goalstate.tokens_used_of(goal) == 0
  assert goalstate.reviewer_note_of(goal) == None

  assert goalstate.status_of(goalstate.new("x", 100, 0)) == goalstate.Active
  assert goalstate.tokens_used_of(goalstate.new("x", 100, 0)) == 0
  assert goalstate.reviewer_note_of(goalstate.new("x", 100, 0)) == None

  // The status words and the cause beside them.
  assert goalstate.encode_status(goalstate.Active) == "active"
  assert goalstate.encode_status(goalstate.Limited(by: goalstate.ByTokenBudget))
    == "budget_limited"
  assert goalstate.encode_reason(goalstate.Paused(by: goalstate.ByAbort))
    == Some("aborted")
  assert goalstate.encode_reason(goalstate.Active) == None
  assert goalstate.decode_status("complete", None) == Ok(goalstate.Complete)
  assert goalstate.decode_status("paused", Some("aborted"))
    == Ok(goalstate.Paused(by: goalstate.ByAbort))
  assert goalstate.decode_status("finished", None)
    == Error(
      "client/goalstate.decode: status must be one of \"active\", "
      <> "\"paused\", \"budget_limited\" or \"complete\", got \"finished\"",
    )

  // `decode_phase` of `encode_phase`.
  assert goalstate.decode_phase(goalstate.encode_phase(goalstate.Idle))
    == Ok(goalstate.Idle)

  // `decode` of `encode`.
  let example = goalstate.new("make the race test pass", 400_000, 1000)
  assert goalstate.decode(goalstate.encode(example)) == Ok(example)
}
