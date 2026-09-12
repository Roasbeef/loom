//// The advisor's emission guard, tested the way a pure decision function
//// can be: every rule stated once, with the state it needs built through
//// the same API the actor uses.
////
//// Four kinds of test. The **rules** each pin one clause of the design —
//// the cooldown, the duplicate ring, the two queue caps — including the
//// exact prose the advisor reads back, because that wording is how the
//// model learns a rule it is never told in its instructions. The
//// **invariant fold** drives a scripted run of verdicts and run ends past
//// the guard and asserts after every step that the queue and the ring are
//// still inside their bounds, which is the claim a single rule test
//// cannot make. The **codec** round-trips guards built by those same
//// transitions, and then feeds the decoder a catalogue of malformed cells
//// that must each come back as an error naming the field that broke. The
//// **degenerate policies** check the zero cases, where a misconfigured
//// bound must close a channel rather than open one.

import client/advisorguard.{
  type Guard, type Policy, Block, Deliver, Downgraded, Dropped, Nudge, Policy,
  Queued, Quiet, Silent,
}
import core/json
import gleam/list
import gleam/string

// --- fixtures -------------------------------------------------------------

// A tight policy, so a cap is reached in three steps rather than in eight.
// Every field is named rather than updated from the default, because a
// test that reads `pending_cap: 2` should not send its reader to another
// module to learn what the other three are.
fn tight() -> Policy {
  Policy(
    block_cooldown_runs: 2,
    recent_ring: 3,
    pending_cap: 2,
    pending_bytes: 40,
  )
}

// The guard after one delivered block, which is the state every cooldown
// test starts from.
fn after_a_block(policy: Policy) -> Guard {
  let #(decision, guard) =
    advisorguard.decide(advisorguard.new(), policy, Block(text: "one"))
  assert decision == Deliver(text: "one")
  guard
}

// The digests the guard is holding, read back out of the encoded cell.
// `recent` is deliberately not on the public surface — nothing but this
// module's own bound checks has a use for it — so the codec is the way in.
fn recent_of(guard: Guard) -> List(String) {
  let assert json.Object(fields) = advisorguard.encode(guard)
    as "the stored guard is an object"
  let assert Ok(json.Array(items)) = list.key_find(fields, "recent")
    as "the stored guard carries a recent array"
  list.map(items, fn(item) {
    let assert json.String(text) = item as "a stored digest is a string"
    text
  })
}

fn bytes_of(queue: List(String)) -> Int {
  list.fold(queue, 0, fn(sum, text) { sum + string.byte_size(text) })
}

// --- the cooldown ---------------------------------------------------------

// Nothing rations the first block: the window is measured from a delivery
// and there has not been one.
pub fn a_first_block_is_delivered_test() {
  let #(decision, guard) =
    advisorguard.decide(advisorguard.new(), tight(), Block(text: "one"))

  assert decision == Deliver(text: "one")

  // Delivery does not queue. The primary is being woken with this text,
  // so folding it into the next run start as well would say it twice.
  assert advisorguard.pending(guard) == []
}

// A second block in the same run as the first. The elapsed count is zero
// and the prose says so in words rather than as "0 runs ago".
pub fn a_block_in_the_same_run_is_downgraded_test() {
  let #(decision, guard) =
    advisorguard.decide(after_a_block(tight()), tight(), Block(text: "two"))

  assert decision
    == Downgraded(
      text: "two",
      reason: "a block was already delivered during this run and the cooldown "
        <> "is 2 runs; this advice was queued as a nudge for the primary's "
        <> "next run start",
    )

  // The downgrade is a channel change, not a refusal: the text is on the
  // queue and the primary reads it at its next run start.
  assert advisorguard.pending(guard) == ["two"]
}

// One run of the two has passed, so the window is still shut.
pub fn a_block_one_run_into_the_cooldown_is_downgraded_test() {
  let guard = advisorguard.primary_run_ended(after_a_block(tight()))
  let #(decision, guard) =
    advisorguard.decide(guard, tight(), Block(text: "two"))

  assert decision
    == Downgraded(
      text: "two",
      reason: "a block was delivered 1 run ago and the cooldown is 2 runs; "
        <> "this advice was queued as a nudge for the primary's next run "
        <> "start",
    )
  assert advisorguard.pending(guard) == ["two"]
}

// The window is measured in primary runs, so two run ends open it again.
pub fn a_block_after_the_cooldown_is_delivered_test() {
  let guard =
    after_a_block(tight())
    |> advisorguard.primary_run_ended
    |> advisorguard.primary_run_ended

  let #(decision, guard) =
    advisorguard.decide(guard, tight(), Block(text: "two"))

  assert decision == Deliver(text: "two")
  assert advisorguard.runs(guard) == 2

  // The second delivery re-arms the window against the run it landed in,
  // or a session's third block would be free.
  let #(third, _guard) = advisorguard.decide(guard, tight(), Block(text: "x"))
  assert third
    == Downgraded(
      text: "x",
      reason: "a block was already delivered during this run and the cooldown "
        <> "is 2 runs; this advice was queued as a nudge for the primary's "
        <> "next run start",
    )
}

// A nudge is never rationed by the cooldown. The window exists to stop
// the primary being steered, and a nudge does not steer it.
pub fn the_cooldown_does_not_reach_a_nudge_test() {
  let #(decision, guard) =
    advisorguard.decide(after_a_block(tight()), tight(), Nudge(text: "two"))

  assert decision == Queued(text: "two")
  assert advisorguard.pending(guard) == ["two"]
}

// --- the duplicate ring ---------------------------------------------------

// Case and wrapping carry no meaning, so the same concern said twice is
// one piece of advice however the model happened to lay it out.
pub fn the_same_advice_in_a_different_shape_is_dropped_test() {
  let #(_first, guard) =
    advisorguard.decide(
      advisorguard.new(),
      tight(),
      Nudge(text: "Rerun   the\tmigration\nfirst."),
    )

  let #(decision, after) =
    advisorguard.decide(
      guard,
      tight(),
      Nudge(text: "  rerun the migration first.  "),
    )

  assert decision
    == Dropped(reason: "the advisor already delivered this advice")

  // A drop records nothing at all, so the queue the primary reads is
  // unchanged and the ring did not age by one.
  assert after == guard
}

// One ring across both channels: repeating a delivered block in the
// quieter voice is the same text arriving a second time.
pub fn a_delivered_block_cannot_come_back_as_a_nudge_test() {
  let #(decision, _guard) =
    advisorguard.decide(after_a_block(tight()), tight(), Nudge(text: "one"))

  assert decision
    == Dropped(reason: "the advisor already delivered this advice")
}

// Draining the queue does not clear the ring. The primary has now read
// the nudge, which is exactly when saying it again is a repeat.
pub fn a_drained_nudge_is_still_a_duplicate_test() {
  let #(_queued, guard) =
    advisorguard.decide(advisorguard.new(), tight(), Nudge(text: "one"))
  let #(drained, guard) = advisorguard.take_pending(guard)

  assert drained == ["one"]

  let #(decision, _guard) =
    advisorguard.decide(guard, tight(), Nudge(text: "one"))
  assert decision
    == Dropped(reason: "the advisor already delivered this advice")
}

// The ring is a window, not a ledger: once a digest has aged out the
// advice is sayable again, which is what stops a long session from
// silently accumulating a permanent list of things nobody may mention.
pub fn the_oldest_digest_ages_out_of_the_ring_test() {
  let policy = Policy(..tight(), recent_ring: 1, pending_cap: 8)
  let #(_first, guard) =
    advisorguard.decide(advisorguard.new(), policy, Nudge(text: "one"))

  assert list.length(recent_of(guard)) == 1

  let #(_second, guard) = advisorguard.decide(guard, policy, Nudge(text: "two"))

  // The ring holds one digest, so the first has gone and only the second
  // is still remembered.
  assert list.length(recent_of(guard)) == 1
  assert recent_of(guard) != recent_of(advisorguard.new())

  let #(decision, _guard) =
    advisorguard.decide(guard, policy, Nudge(text: "one"))
  assert decision == Queued(text: "one")
}

// --- the queue caps -------------------------------------------------------

pub fn the_queue_stops_at_its_count_cap_test() {
  let policy = Policy(..tight(), pending_cap: 2, pending_bytes: 4096)
  let #(_one, guard) =
    advisorguard.decide(advisorguard.new(), policy, Nudge(text: "one"))
  let #(_two, guard) = advisorguard.decide(guard, policy, Nudge(text: "two"))
  let #(decision, after) =
    advisorguard.decide(guard, policy, Nudge(text: "three"))

  assert decision
    == Dropped(
      reason: "the nudge queue is full; it drains at the primary's next run start",
    )

  // Oldest first, and the refused nudge left no trace: a full queue must
  // not silently evict the advice the primary is about to read.
  assert advisorguard.pending(after) == ["one", "two"]
  assert after == guard
}

pub fn the_queue_stops_at_its_byte_cap_test() {
  let policy = Policy(..tight(), pending_cap: 8, pending_bytes: 10)
  let #(_one, guard) =
    advisorguard.decide(advisorguard.new(), policy, Nudge(text: "abcde"))

  // Exactly at the cap is inside it, so the second five bytes fit.
  let #(second, guard) =
    advisorguard.decide(guard, policy, Nudge(text: "fghij"))
  assert second == Queued(text: "fghij")

  // One byte past is not, even though six of the eight slots are free.
  let #(decision, _guard) = advisorguard.decide(guard, policy, Nudge(text: "k"))
  assert decision
    == Dropped(
      reason: "the nudge queue is full; it drains at the primary's next run start",
    )
}

// A downgraded block is a nudge by the time it reaches the queue, so a
// full queue refuses it on the same terms. This is the one path where a
// block can vanish entirely, and the advisor is told which rule did it.
pub fn a_downgraded_block_meets_the_queue_cap_test() {
  let policy = Policy(..tight(), pending_cap: 1)
  let guard = after_a_block(policy)
  let #(_nudge, guard) = advisorguard.decide(guard, policy, Nudge(text: "two"))
  let #(decision, after) =
    advisorguard.decide(guard, policy, Block(text: "three"))

  assert decision
    == Dropped(
      reason: "the nudge queue is full; it drains at the primary's next run start",
    )
  assert after == guard
}

// --- the other verdicts ---------------------------------------------------

// `Quiet` is the expected common case, and it must cost nothing: a quiet
// advisor that aged the ring would slowly forget what it had delivered.
pub fn quiet_records_nothing_test() {
  let #(_queued, guard) =
    advisorguard.decide(after_a_block(tight()), tight(), Nudge(text: "two"))
  let #(decision, after) = advisorguard.decide(guard, tight(), Quiet)

  assert decision == Silent
  assert after == guard
}

// Advice that normalizes to nothing is a malformed tool call, not advice.
// It is refused before the ring, so it never fills a slot in it.
pub fn advice_that_is_only_whitespace_is_dropped_test() {
  let #(nudge, after_nudge) =
    advisorguard.decide(advisorguard.new(), tight(), Nudge(text: " \n\t  "))
  let #(block, after_block) =
    advisorguard.decide(advisorguard.new(), tight(), Block(text: ""))

  assert nudge == Dropped(reason: "empty advice")
  assert block == Dropped(reason: "empty advice")
  assert after_nudge == advisorguard.new()
  assert after_block == advisorguard.new()
}

pub fn take_pending_drains_once_test() {
  let #(_one, guard) =
    advisorguard.decide(advisorguard.new(), tight(), Nudge(text: "one"))
  let #(_two, guard) = advisorguard.decide(guard, tight(), Nudge(text: "two"))
  let #(drained, guard) = advisorguard.take_pending(guard)

  assert drained == ["one", "two"]
  assert advisorguard.pending(guard) == []

  // The second drain is empty rather than a repeat, which is what lets
  // the run-start hook call it unconditionally.
  let #(again, _guard) = advisorguard.take_pending(guard)
  assert again == []
}

// --- degenerate policies --------------------------------------------------

// A cap of zero closes the queue instead of admitting one nudge, which is
// the failure an off-by-one in the count check would produce.
pub fn a_zero_count_cap_admits_nothing_test() {
  let policy = Policy(..tight(), pending_cap: 0)
  let #(decision, _guard) =
    advisorguard.decide(advisorguard.new(), policy, Nudge(text: "one"))

  assert decision
    == Dropped(
      reason: "the nudge queue is full; it drains at the primary's next run start",
    )
}

// A cooldown of zero is no cooldown: consecutive blocks are delivered.
pub fn a_zero_cooldown_delivers_every_block_test() {
  let policy = Policy(..tight(), block_cooldown_runs: 0)
  let #(decision, _guard) =
    advisorguard.decide(after_a_block(policy), policy, Block(text: "two"))

  assert decision == Deliver(text: "two")
}

// A ring of zero remembers nothing, so every repeat is sayable again.
pub fn a_zero_ring_remembers_nothing_test() {
  let policy = Policy(..tight(), recent_ring: 0, pending_cap: 8)
  let #(_first, guard) =
    advisorguard.decide(advisorguard.new(), policy, Nudge(text: "one"))
  let #(decision, _guard) =
    advisorguard.decide(guard, policy, Nudge(text: "one"))

  assert recent_of(guard) == []
  assert decision == Queued(text: "one")
}

// --- the invariant fold ---------------------------------------------------

// One step of a scripted session: either the advisor said something, or
// the primary finished a run.
type Step {
  Say(verdict: advisorguard.Verdict)
  RunEnd
}

// A script long enough that the caps and the ring are all reached, with
// repeats, empties and blocks interleaved the way a real session would
// deliver them.
fn script() -> List(Step) {
  [
    Say(Block(text: "the migration has no down step")),
    Say(Nudge(text: "the test name says list, the body asserts a dict")),
    Say(Quiet),
    Say(Block(text: "the migration has no down step")),
    RunEnd,
    Say(Nudge(text: "  THE   migration has no down STEP ")),
    Say(Nudge(text: "this one is long enough to go past forty bytes on its own")),
    Say(Block(text: "")),
    RunEnd,
    Say(Nudge(text: "a fourth")),
    Say(Quiet),
    Say(Block(text: "a fifth, which should now clear the window")),
    RunEnd,
    Say(Nudge(text: "a sixth")),
    Say(Nudge(text: "a seventh")),
    RunEnd,
    Say(Block(text: "an eighth")),
    Say(Quiet),
  ]
}

// The bounds every one of those steps has to leave standing. A single
// rule test asserts one clause against one state; this asserts all of
// them against every state the script reaches, which is where an
// interaction between the ring trim and the queue caps would show.
pub fn a_scripted_session_stays_inside_every_bound_test() {
  let policy = tight()
  let guard =
    list.fold(script(), advisorguard.new(), fn(guard, step) {
      let moved = apply(guard, policy, step)

      let queued = advisorguard.pending(moved)
      assert list.length(queued) <= policy.pending_cap
      assert bytes_of(queued) <= policy.pending_bytes
      assert list.length(recent_of(moved)) <= policy.recent_ring

      // The run clock only ever moves forward, and only on a run end.
      assert advisorguard.runs(moved) >= advisorguard.runs(guard)

      moved
    })

  // Four run ends in the script, and the guard counted all four.
  assert advisorguard.runs(guard) == 4

  // The whole scripted state still round-trips, which is the property the
  // actor depends on after every one of these steps.
  assert advisorguard.decode(advisorguard.encode(guard)) == Ok(guard)
}

fn apply(guard: Guard, policy: Policy, step: Step) -> Guard {
  case step {
    RunEnd -> advisorguard.primary_run_ended(guard)

    Say(verdict:) -> {
      let #(_decision, moved) = advisorguard.decide(guard, policy, verdict)
      moved
    }
  }
}

// --- the cell -------------------------------------------------------------

// Every shape the cell can be in: empty, counted, carrying a delivered
// block, carrying a ring, carrying a queue, and all of those at once.
fn shapes() -> List(Guard) {
  let policy = Policy(..tight(), pending_cap: 8, pending_bytes: 4096)
  let counted = advisorguard.primary_run_ended(advisorguard.new())
  let blocked = after_a_block(policy)
  let #(_queued, nudged) =
    advisorguard.decide(advisorguard.new(), policy, Nudge(text: "two"))
  let #(_both, both) =
    advisorguard.decide(
      advisorguard.primary_run_ended(blocked),
      policy,
      Nudge(text: "three"),
    )

  [advisorguard.new(), counted, blocked, nudged, both]
}

pub fn every_shape_round_trips_through_its_cell_test() {
  list.each(shapes(), fn(guard) {
    assert advisorguard.decode(advisorguard.encode(guard)) == Ok(guard)
  })
}

// The stored form written out rather than computed, so a change to the
// field names shows up as a diff here and not as a silently unreadable
// cell on somebody's disk.
pub fn the_stored_form_is_the_documented_object_test() {
  let #(_queued, guard) =
    advisorguard.decide(after_a_block(tight()), tight(), Nudge(text: "two"))
  let assert json.Object(fields) = advisorguard.encode(guard)
    as "the stored guard is an object"

  assert list.map(fields, fn(field) { field.0 })
    == ["runs", "lastBlockRun", "recent", "pending"]
  assert list.key_find(fields, "runs") == Ok(json.Int(0))
  assert list.key_find(fields, "lastBlockRun") == Ok(json.Int(0))
  assert list.key_find(fields, "pending")
    == Ok(json.Array([json.String("two")]))
}

// A guard that has delivered nothing says so with null, not by leaving
// the field out: absence means an older writer, and the two must not be
// confused.
pub fn a_guard_with_no_delivered_block_stores_null_test() {
  let assert json.Object(fields) = advisorguard.encode(advisorguard.new())
    as "the stored guard is an object"

  assert list.key_find(fields, "lastBlockRun") == Ok(json.Null)
}

// The cell a session starts from. `Null` is what an unwritten fact reads
// back as, and an object whose fields are all absent is what an older
// writer leaves; both are a guard that has seen nothing.
pub fn an_absent_or_empty_cell_decodes_to_a_fresh_guard_test() {
  assert advisorguard.decode(json.Null) == Ok(advisorguard.new())
  assert advisorguard.decode(json.Object([])) == Ok(advisorguard.new())
}

// Absence is per field: a cell carrying only a run count is a guard that
// has counted runs and remembered nothing else.
pub fn an_absent_field_takes_the_empty_guards_value_test() {
  let partial = json.Object([#("runs", json.Int(2))])
  let expected =
    advisorguard.primary_run_ended(
      advisorguard.primary_run_ended(advisorguard.new()),
    )

  assert advisorguard.decode(partial) == Ok(expected)
}

// Every way a cell can be wrong, each of which must be an error naming
// the field rather than a crash or a half-read guard. The two arithmetic
// ones are the reason the type is opaque: a negative run count and a
// block recorded past the run count both make the cooldown arithmetic
// meaningless, and neither can be produced by any transition here.
fn malformed() -> List(#(String, json.JsonValue)) {
  [
    #("a bare string", json.String("x")),
    #("a bare array", json.Array([])),
    #("a bare number", json.Int(3)),
    #("a bare boolean", json.Bool(True)),
    #("a null run count", json.Object([#("runs", json.Null)])),
    #("a textual run count", json.Object([#("runs", json.String("3"))])),
    #("a negative run count", json.Object([#("runs", json.Int(-1))])),
    #("a textual block run", json.Object([#("lastBlockRun", json.String("1"))])),
    #("a negative block run", json.Object([#("lastBlockRun", json.Int(-1))])),
    #(
      "a block run past the run count",
      json.Object([#("runs", json.Int(1)), #("lastBlockRun", json.Int(2))]),
    ),
    #(
      "a ring that is not an array",
      json.Object([#("recent", json.String("x"))]),
    ),
    #(
      "a ring of numbers",
      json.Object([#("recent", json.Array([json.Int(1)]))]),
    ),
    #(
      "a queue that is not an array",
      json.Object([#("pending", json.Object([]))]),
    ),
    #(
      "a queue holding a null",
      json.Object([#("pending", json.Array([json.Null]))]),
    ),
  ]
}

pub fn every_malformed_cell_is_an_error_test() {
  list.each(malformed(), fn(row) {
    let #(name, payload) = row
    case advisorguard.decode(payload) {
      Ok(_guard) -> panic as { name <> " decoded instead of being refused" }

      // The report names where it came from, so an operator holding a
      // corrupt cell can find the decoder that refused it.
      Error(message) -> {
        assert string.starts_with(message, "client/advisorguard.decode: ")
        assert message != "client/advisorguard.decode: "
      }
    }
  })
}
