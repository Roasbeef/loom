//// The pure half of `client/notice`: the completion marks' keys and the
//// idle clock the heartbeat samples with.
////
//// The delivery half needs a session and is exercised where its callers
//// are, in `jobs_test` and `async_runs_test`. What is here is the
//// arithmetic a fencepost error would hide in: when a beat is due, what a
//// busy sample does to the stretch, and that a due beat restarts it.

import client/advisor
import client/gateway_test
import client/notice
import core/attention
import core/clock
import core/ids
import core/message
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import runtime/api
import session/session

const interval = 600_000

pub fn a_job_and_an_execution_never_share_a_mark_test() {
  // The variant is part of the key, so a job and an execution that
  // happened to share an id could never spend each other's mark.
  assert notice.key(notice.Job(id: "ab"))
    != notice.key(notice.Execution(id: "ab"))
  assert notice.key(notice.Job(id: "ab")) == "client/notice/job/ab"
  assert notice.key(notice.Escalation(id: "policy-1", seq: 7))
    == "client/notice/escalation/policy-1/7"
}

pub fn the_first_idle_sample_only_starts_the_stretch_test() {
  let #(_clock, due) =
    notice.observe(
      notice.idle_clock(),
      "main",
      notice.Idle,
      now: 1000,
      interval_ms: interval,
    )
  assert due == notice.NotDue
}

pub fn a_whole_idle_interval_is_due_and_not_a_moment_before_test() {
  let clock = idle_at(notice.idle_clock(), 0)
  let #(_clock, early) =
    notice.observe(
      clock,
      "main",
      notice.Idle,
      now: interval - 1,
      interval_ms: interval,
    )
  assert early == notice.NotDue
  let #(_clock, due) =
    notice.observe(
      clock,
      "main",
      notice.Idle,
      now: interval,
      interval_ms: interval,
    )
  assert due == notice.Due
}

pub fn a_beat_restarts_the_stretch_test() {
  // Once the first interval has passed, a beat must repeat every interval
  // rather than on every sample after it.
  let clock = idle_at(notice.idle_clock(), 0)
  let #(clock, first) =
    notice.observe(
      clock,
      "main",
      notice.Idle,
      now: interval,
      interval_ms: interval,
    )
  assert first == notice.Due
  let #(clock, next_sample) =
    notice.observe(
      clock,
      "main",
      notice.Idle,
      now: interval + 60_000,
      interval_ms: interval,
    )
  assert next_sample == notice.NotDue
  let #(_clock, second) =
    notice.observe(
      clock,
      "main",
      notice.Idle,
      now: 2 * interval,
      interval_ms: interval,
    )
  assert second == notice.Due
}

pub fn a_busy_sample_restarts_the_stretch_from_the_next_idle_one_test() {
  // A strand that just finished a turn has not been idle for the time
  // before that turn, so a heartbeat must never land on it at once.
  let clock = idle_at(notice.idle_clock(), 0)
  let #(clock, busy) =
    notice.observe(
      clock,
      "main",
      notice.Busy,
      now: interval - 10,
      interval_ms: interval,
    )
  assert busy == notice.NotDue
  let clock = idle_at(clock, interval)
  let #(_clock, too_soon) =
    notice.observe(
      clock,
      "main",
      notice.Idle,
      now: interval + interval - 1,
      interval_ms: interval,
    )
  assert too_soon == notice.NotDue
}

pub fn strands_keep_separate_stretches_test() {
  let clock = idle_at(notice.idle_clock(), 0)
  let #(clock, _) =
    notice.observe(
      clock,
      "sub:x",
      notice.Idle,
      now: interval / 2,
      interval_ms: interval,
    )
  let #(clock, main) =
    notice.observe(
      clock,
      "main",
      notice.Idle,
      now: interval,
      interval_ms: interval,
    )
  let #(_clock, sub) =
    notice.observe(
      clock,
      "sub:x",
      notice.Idle,
      now: interval,
      interval_ms: interval,
    )
  assert main == notice.Due
  assert sub == notice.NotDue
}

pub fn a_strand_that_owns_nothing_is_forgotten_test() {
  // An owner whose work all ended starts from nothing if it ever owns work
  // again, rather than inheriting a stretch that began before it.
  let clock = idle_at(notice.idle_clock(), 0)
  let clock = notice.retain(clock, ["sub:other"])
  let #(_clock, due) =
    notice.observe(
      clock,
      "main",
      notice.Idle,
      now: interval,
      interval_ms: interval,
    )
  assert due == notice.NotDue
}

pub fn idle_stretches_beat_once_per_interval_test() {
  // Sampled every minute for an hour of idleness, a ten-minute interval
  // beats exactly six times: the first stretch starts at the first sample
  // and every beat restarts it.
  let samples =
    list.repeat(Nil, 61) |> list.index_map(fn(_, minute) { minute * 60_000 })
  let #(_clock, beats) =
    list.fold(samples, #(notice.idle_clock(), 0), fn(carried, now) {
      let #(clock, due) =
        notice.observe(
          carried.0,
          "main",
          notice.Idle,
          now:,
          interval_ms: interval,
        )
      case due {
        notice.Due -> #(clock, carried.1 + 1)
        notice.NotDue -> #(clock, carried.1)
      }
    })
  assert beats == 6
}

pub fn the_heartbeat_names_every_live_piece_of_work_test() {
  let text = notice.heartbeat_text(interval, ["job a: make", "job b: soak"])
  assert text != ""
  assert list.all(
    ["[loom] idle heartbeat", "10m", "- job a: make", "- job b: soak"],
    fn(needle) { string.contains(text, needle) },
  )
}

fn idle_at(clock: notice.IdleClock, now: Int) -> notice.IdleClock {
  let #(clock, _due) =
    notice.observe(clock, "main", notice.Idle, now:, interval_ms: interval)
  clock
}

pub fn the_advisor_is_never_woken_by_a_notice_test() {
  // `client/notice` restates the advisor's name to avoid an import cycle;
  // this is what keeps the two spellings one fact.
  assert notice.advisor_strand == advisor.strand
  assert !notice.may_wake(advisor.strand)
  assert !notice.may_wake("sub:main/probe-0a1b")
  assert notice.may_wake("main")
}

// --- sampling through the owner's functions --------------------------------

// A sample reaches its strand only through the two functions it is given, so
// a strand on another node is sampled the same way. The wake sends what it
// was asked to send to a subject, which is how the test sees it.
fn sample_at(
  idle: notice.IdleClock,
  activity: Result(notice.Activity, String),
  woken: Subject(#(String, String)),
  now: Int,
) -> notice.IdleClock {
  notice.sample(
    fn(_strand) { activity },
    fn(strand, text) {
      process.send(woken, #(strand, text))
      Ok(Nil)
    },
    idle,
    "main",
    now:,
    interval_ms: interval,
    lines: fn() { ["job 01: make"] },
  )
}

pub fn a_sample_wakes_an_idle_strand_through_the_supplied_function_test() {
  let woken = process.new_subject()
  let idle = sample_at(notice.idle_clock(), Ok(notice.Idle), woken, 0)

  // The first sample starts the stretch and wakes nobody.
  assert process.receive(woken, 10) == Error(Nil)

  // A whole interval later the beat is due, and the text names the work.
  let _idle = sample_at(idle, Ok(notice.Idle), woken, interval)
  let assert Ok(#("main", text)) = process.receive(woken, 10)
    as "the due beat reaches the supplied function"
  assert string.contains(text, "[loom] idle heartbeat")
  assert string.contains(text, "job 01: make")
}

pub fn a_busy_or_unreadable_strand_is_never_woken_test() {
  let woken = process.new_subject()
  let idle = sample_at(notice.idle_clock(), Ok(notice.Idle), woken, 0)

  // Busy forgets the stretch, so nothing is due however late it is.
  let idle = sample_at(idle, Ok(notice.Busy), woken, interval * 2)
  assert process.receive(woken, 10) == Error(Nil)

  // An unreadable strand is left out of the sample altogether: it fires
  // nothing and keeps whatever stretch it had.
  let idle = sample_at(idle, Error("unreadable"), woken, interval * 4)
  assert process.receive(woken, 10) == Error(Nil)
  let _idle = sample_at(idle, Ok(notice.Idle), woken, interval * 4)
  assert process.receive(woken, 10) == Error(Nil)
}

// Whether the strand has put anything on its branch. A run that was accepted
// has placed its prompt, and one that already finished still has, so this does
// not depend on whether the fixture's provider has settled yet.
fn main_has_run(runtime: api.Runtime) -> Bool {
  let assert Ok(Some(session.Cell(value: leaf, ..))) =
    session.strand_leaf(runtime.session, "main")
    as "the strand must be seeded"
  leaf != None
}

fn an_ask_of_main(runtime: api.Runtime) -> Nil {
  let ask =
    attention.Ask(
      header: attention.Header(
        id: "ask-0000000001",
        created_at: 1,
        routing: attention.ToOwner,
        anchor: attention.Anchor(
          operation: ids.mint_op(ids.generator(clock.fixed(at: 5), seed: 9)).0,
          step_id: "turn-1:tools",
          source_index: 0,
        ),
        strand: "main",
        parents: [],
      ),
      why: None,
      questions: [attention.Question("q1", "Retry?", attention.Confirm, [])],
      state: attention.AskOpen,
    )
  let assert Ok(Nil) =
    api.put_reserved_fact(
      runtime,
      attention.ask_key(ask.header.id),
      attention.encode_ask(ask),
    )
    as "the ask record must be written"
  Nil
}

// A heartbeat exists to make an idle owner look at its jobs. An owner that
// stopped on an ask is looking at the owner instead, so the beat is skipped
// rather than starting a run that carries on without the answer.
pub fn a_heartbeat_skips_a_strand_waiting_on_the_owner_test() {
  let runtime = gateway_test.reserved_fixture(session_id(701)).runtime
  an_ask_of_main(runtime)

  assert notice.beat(runtime, "main", "[loom] idle heartbeat") == Ok(Nil)
  assert !main_has_run(runtime)
}

pub fn a_heartbeat_still_wakes_an_idle_strand_with_no_ask_test() {
  let runtime = gateway_test.reserved_fixture(session_id(702)).runtime

  assert notice.beat(runtime, "main", "[loom] idle heartbeat") == Ok(Nil)
  assert main_has_run(runtime)
}

// Past the held queue's limit a completion notice is refused with the queue's
// own words and spends no mark. The jobs and executions services drop a
// failed delivery, as they always have, because the finished record is read by
// `job_poll` or `join`, so what the model loses is the wake and not the result.
pub fn a_notice_past_the_held_limit_is_refused_and_spends_no_mark_test() {
  let runtime = gateway_test.reserved_fixture(session_id(703)).runtime
  an_ask_of_main(runtime)
  list.each(list.repeat(Nil, api.next_run_limit), fn(_) {
    let assert Ok(api.Held(..)) =
      api.send_to_strand(
        runtime,
        to: "main",
        message: message.UserMessage(
          content: [message.UserText(text: "held", text_signature: None)],
          timestamp: 0,
          origin: None,
        ),
      )
    Nil
  })

  let assert Error(reason) =
    notice.deliver(runtime, "main", notice.Job(id: "j1"), "[loom] job j1 done")
  assert string.contains(reason, "NextRunFull")
  assert api.fact(runtime, notice.key(notice.Job(id: "j1"))) == Ok(None)
}

fn session_id(seed: Int) -> ids.SessionId {
  let #(id, _) =
    ids.mint_session(ids.generator(clock.stepping(1_756_000_000_000, 1), seed))
  id
}
