//// The pure half of `client/notice`: the completion marks' keys and the
//// idle clock the heartbeat samples with.
////
//// The delivery half needs a session and is exercised where its callers
//// are, in `jobs_test` and `async_runs_test`. What is here is the
//// arithmetic a fencepost error would hide in: when a beat is due, what a
//// busy sample does to the stretch, and that a due beat restarts it.

import client/advisor
import client/notice
import gleam/list
import gleam/string

const interval = 600_000

pub fn a_job_and_an_execution_never_share_a_mark_test() {
  // The variant is part of the key, so a job and an execution that
  // happened to share an id could never spend each other's mark.
  assert notice.key(notice.Job(id: "ab"))
    != notice.key(notice.Execution(id: "ab"))
  assert notice.key(notice.Job(id: "ab")) == "client/notice/job/ab"
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
