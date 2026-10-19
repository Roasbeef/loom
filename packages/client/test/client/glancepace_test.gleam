//// Focused smoke test for `client/glancepace`; the full stateful model
//// and backoff/cap suite lives in `glancepace_property_test.gleam`.

import client/glancepace.{
  Asking, Covered, Fresh, Launch, Pace, Settled, Stepped, Summarized, Tick,
}
import gleam/option.{None, Some}

const pace =
  Pace(
    every_ms: 20_000,
    retry_ms: 1000,
    retry_cap_ms: 5000,
    concurrency: 2,
    retire_after_ms: 60_000,
  )

pub fn first_step_refresh_and_retirement_smoke_test() {
  let first =
    glancepace.step(glancepace.new(), Stepped("a", "op1", Some(900)), 0, pace)
  assert first.launch == [Launch("a", "op1", 900)]
  assert first.wake == None

  let during =
    glancepace.step(first.book, Stepped("a", "op1", Some(1200)), 5, pace)
  assert during.launch == []
  let assert Ok(track) = glancepace.track(during.book, "a")
  assert track.phase == Asking(since: 0)
  assert track.activity == Fresh

  let settled =
    glancepace.step(during.book, Settled("a", "op1", Summarized), 3000, pace)
  assert settled.wake == Some(20_000)

  let quiet =
    glancepace.step(
      glancepace.step(settled.book, Tick, 20_000, pace).book,
      Settled("a", "op1", Summarized),
      21_000,
      pace,
    )
  let assert Ok(covered) = glancepace.track(quiet.book, "a")
  assert covered.activity == Covered
  assert glancepace.track(
      glancepace.step(quiet.book, Tick, 81_000, pace).book,
      "a",
    )
    == Error(Nil)
}
