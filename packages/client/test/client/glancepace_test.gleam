//// The glance schedule, stepped event by event with no process and no
//// clock: every decision the loop makes about when to ask is a value here.

import client/glancepace.{
  type Book, type Plan, Asking, Covered, Ended, Fresh, Launch, Pace, Settled,
  Stepped, Summarized, Tick, Unusable,
}
import gleam/list
import gleam/option.{None, Some}

const pace = Pace(
  every_ms: 20_000,
  retry_ms: 1000,
  retry_cap_ms: 5000,
  concurrency: 2,
  retire_after_ms: 60_000,
)

// --- first and later requests ----------------------------------------------------

// The first step of an operation is due at once, so the title arrives one
// model round trip after the agent's first tool call.
pub fn a_first_step_launches_at_once_test() {
  let plan = step(glancepace.new(), Stepped("a", "op1", Some(900)), 0)

  assert plan.launch == [Launch("a", "op1", 900)]
  assert plan.wake == None
}

// While a request is out, further steps book activity and launch nothing.
pub fn a_strand_has_one_request_out_test() {
  let plan =
    glancepace.new()
    |> run([
      #(Stepped("a", "op1", Some(1)), 0),
      #(Stepped("a", "op1", Some(2)), 5),
    ])

  assert plan.launch == []
  let assert Ok(track) = glancepace.track(plan.book, "a")
  assert track.phase == Asking(since: 0)
  assert track.activity == Fresh
  assert track.context == 2
}

// A landed summary makes the next one due `every_ms` after the request
// started, and the wake is armed for exactly then.
pub fn a_refresh_waits_out_the_interval_test() {
  let plan =
    glancepace.new()
    |> run([
      #(Stepped("a", "op1", None), 0),
      #(Stepped("a", "op1", None), 1000),
      #(Settled("a", "op1", Summarized), 3000),
    ])

  assert plan.launch == []
  assert plan.wake == Some(20_000)

  let early = step(plan.book, Tick, 19_999)
  assert early.launch == []

  let due = step(plan.book, Tick, 20_000)
  assert due.launch == [Launch("a", "op1", 0)]
}

// A strand that has not stepped since its last request began is covered,
// and a covered strand is never asked again however long it idles.
pub fn a_quiet_strand_is_not_asked_again_test() {
  let plan =
    glancepace.new()
    |> run([
      #(Stepped("a", "op1", None), 0),
      #(Settled("a", "op1", Summarized), 2000),
    ])

  assert plan.wake == None
  assert step(plan.book, Tick, 50_000).launch == []
  let assert Ok(track) = glancepace.track(plan.book, "a")
  assert track.activity == Covered
}

// --- the global cap -----------------------------------------------------------------

// The session never has more than `concurrency` requests out, and a freed
// slot goes to the strand that was waiting at once, not at the next wake.
pub fn the_cap_holds_and_a_freed_slot_is_reused_test() {
  let plan =
    glancepace.new()
    |> run([
      #(Stepped("a", "op1", None), 0),
      #(Stepped("b", "op2", None), 1),
    ])
  let capped = step(plan.book, Stepped("c", "op3", None), 2)

  assert capped.launch == []
  assert capped.wake == None

  let freed = step(capped.book, Settled("a", "op1", Summarized), 3)
  assert freed.launch == [Launch("c", "op3", 0)]
}

// When several strands are due at once, the most overdue win the slots.
pub fn the_most_overdue_strand_goes_first_test() {
  let one = Pace(..pace, concurrency: 1)
  let book = glancepace.new()
  let plan = glancepace.step(book, Stepped("a", "op1", None), 0, one)
  let plan = glancepace.step(plan.book, Stepped("c", "op3", None), 5, one)
  let plan = glancepace.step(plan.book, Stepped("b", "op2", None), 10, one)
  let plan =
    glancepace.step(plan.book, Settled("a", "op1", Summarized), 20, one)

  assert plan.launch == [Launch("c", "op3", 0)]
}

// --- failures -----------------------------------------------------------------------

// An unusable answer leaves the strand fresh and backs it off: one second,
// then two, then four, then the five-second cap.
pub fn failures_back_off_to_the_cap_test() {
  let plan =
    glancepace.new()
    |> run([
      #(Stepped("a", "op1", None), 0),
      #(Settled("a", "op1", Unusable), 100),
    ])
  assert plan.wake == Some(1100)
  let assert Ok(track) = glancepace.track(plan.book, "a")
  assert track.activity == Fresh

  let retried = step(plan.book, Tick, 1100)
  assert retried.launch == [Launch("a", "op1", 0)]
  let second = step(retried.book, Settled("a", "op1", Unusable), 1200)
  assert second.wake == Some(3200)

  let third =
    second.book
    |> run([#(Tick, 3200), #(Settled("a", "op1", Unusable), 3300)])
  assert third.wake == Some(7300)

  let capped =
    third.book
    |> run([#(Tick, 7300), #(Settled("a", "op1", Unusable), 7400)])
  assert capped.wake == Some(12_400)
}

// A summary after failures resets the streak.
pub fn a_summary_resets_the_streak_test() {
  let plan =
    glancepace.new()
    |> run([
      #(Stepped("a", "op1", None), 0),
      #(Settled("a", "op1", Unusable), 10),
      #(Tick, 1010),
      #(Settled("a", "op1", Summarized), 1020),
    ])

  let assert Ok(track) = glancepace.track(plan.book, "a")
  assert track.failures == 0
  assert track.due == 21_010
}

// --- operations ending and succeeding -------------------------------------------------

// A request that found its operation no longer live forgets the strand.
pub fn an_ended_operation_is_forgotten_test() {
  let plan =
    glancepace.new()
    |> run([#(Stepped("a", "op1", None), 0), #(Settled("a", "op1", Ended), 10)])

  assert glancepace.track(plan.book, "a") == Error(Nil)
  assert plan.wake == None
}

// A successor operation that starts while its predecessor's request is out
// waits for that request, then launches at once, and the old answer does
// not push the new operation's schedule back.
pub fn a_successor_waits_for_its_predecessor_test() {
  let plan =
    glancepace.new()
    |> run([
      #(Stepped("a", "op1", None), 0),
      #(Stepped("a", "op2", Some(7)), 5),
    ])
  assert plan.launch == []

  let settled = step(plan.book, Settled("a", "op1", Summarized), 9)
  assert settled.launch == [Launch("a", "op2", 7)]
}

// --- retirement ---------------------------------------------------------------------

// A strand quiet for `retire_after_ms` with nothing out is forgotten, which
// is what bounds the book on a session that spawns many sub-agents.
pub fn a_quiet_strand_retires_test() {
  let plan =
    glancepace.new()
    |> run([
      #(Stepped("a", "op1", None), 0),
      #(Settled("a", "op1", Summarized), 10),
    ])

  let assert Ok(_kept) =
    glancepace.track(step(plan.book, Tick, 59_999).book, "a")
  assert glancepace.track(step(plan.book, Tick, 60_000).book, "a") == Error(Nil)
}

// A strand with a request out is never retired, so its settlement always
// finds its track.
pub fn an_asking_strand_is_not_retired_test() {
  let plan = step(glancepace.new(), Stepped("a", "op1", None), 0)
  let later = step(plan.book, Tick, 1_000_000)

  let assert Ok(track) = glancepace.track(later.book, "a")
  assert track.phase == Asking(since: 0)
}

// A step on a strand never booked, or a tick on an empty book, is harmless.
pub fn an_empty_book_plans_nothing_test() {
  let plan = step(glancepace.new(), Tick, 0)

  assert plan.launch == []
  assert plan.wake == None
  let settled = step(glancepace.new(), Settled("x", "op", Summarized), 0)
  assert settled.launch == []
  let assert Ok(track) =
    step(settled.book, Stepped("x", "op", None), 1).book
    |> glancepace.track("x")
  assert track.phase == Asking(since: 1)
}

// --- fixtures -------------------------------------------------------------------------

fn step(book: Book, event: glancepace.Event, now: Int) -> Plan {
  glancepace.step(book, event, now, pace)
}

fn run(book: Book, events: List(#(glancepace.Event, Int))) -> Plan {
  list.fold(events, step(book, Tick, 0), fn(plan, pair) {
    step(plan.book, pair.0, pair.1)
  })
}
