//// Regression coverage for writer renewal ownership across restarts.
////
//// A timer addressed through the writer's registered name outlives the process
//// which scheduled it. If a replacement claims that name before the timer
//// fires, the predecessor tick lands on the replacement and starts a second
//// renewal cadence. The real writer is opaque, so this test distinguishes the
//// incarnations by giving each one a different interval and observes the
//// replacement's injected `renew_lease` closure. No early renewal may arrive
//// from its predecessor's deadline.

import core/clock
import gleam/erlang/process
import gleam/option.{Some}
import gleam/otp/actor
import runtime/writer
import session/session.{type Session, Session}

fn observable_session(
  base: Session,
  interval: Int,
  renewed: process.Subject(Nil),
) -> Session {
  Session(
    ..base,
    renew_lease: fn() {
      process.send(renewed, Nil)
      Ok(Nil)
    },
    lease_interval_ms: Some(interval),
  )
}

fn start_writer(
  session: Session,
  name: process.Name(writer.Message),
) -> actor.Started(process.Subject(writer.Message)) {
  let assert Ok(started) =
    writer.start(
      writer.Options(session:, after_commit: fn(_) { Nil }, subscribers: []),
      name,
    )
    as "the writer incarnation must start"
  started
}

fn stop_writer(started: actor.Started(process.Subject(writer.Message))) -> Nil {
  process.unlink(started.pid)
  let monitor = process.monitor(started.pid)
  process.kill(started.pid)
  let assert Ok(process.ProcessDown(reason: process.Killed, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
    as "the writer incarnation must stop and release its name"
  Nil
}

pub fn predecessor_renewal_timer_cannot_reach_replacement_test() {
  let assert Ok(base) = session.open_memory(clock.fixed(at: 1000))
    as "the backing memory session must open"
  let renewed = process.new_subject()
  let name = process.new_name(prefix: "writer-renewal-incarnation")

  let predecessor = start_writer(observable_session(base, 100, renewed), name)
  stop_writer(predecessor)

  let replacement = start_writer(observable_session(base, 1000, renewed), name)
  // The predecessor's 100 ms timer fires during this window. A name-addressed
  // tick would invoke the replacement's closure even though its own 1 s timer
  // is nowhere near due.
  assert process.receive(renewed, within: 300) == Error(Nil)
  stop_writer(replacement)
}
