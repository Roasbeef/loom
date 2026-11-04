//// Output arrival cannot renew an absolute collection deadline.

import gleam/erlang/process
import support/fake_broker
import tools/tool

pub fn output_cannot_renew_the_collection_deadline_test() {
  let events = process.new_subject()
  process.send(events, fake_broker.stdout("a"))
  process.send(events, fake_broker.stdout("b"))
  process.send(events, fake_broker.exited(code: 0, stdout_bytes: 2))
  let readings = process.new_subject()
  process.send(readings, 100)
  process.send(readings, 101)
  process.send(readings, 110)

  assert tool.collect_before(events, 110, fn() {
      let assert Ok(now) = process.receive(readings, 0)
        as "clock read is scripted"
      now
    })
    == Error(Nil)

  // Settlement remains unread after the absolute window expires.
  assert process.receive(events, 0)
    == Ok(fake_broker.exited(code: 0, stdout_bytes: 2))
}

pub fn settlement_before_the_deadline_preserves_all_bytes_test() {
  let events = process.new_subject()
  process.send(events, fake_broker.stdout("a"))
  process.send(events, fake_broker.stdout("b"))
  process.send(events, fake_broker.exited(code: 0, stdout_bytes: 2))
  let assert Ok(collected) = tool.collect_before(events, 110, fn() { 100 })
    as "the scripted clock stays within the window"
  assert collected.stdout == <<"ab":utf8>>
}

pub fn existing_idle_collection_accepts_queued_events_test() {
  let events = process.new_subject()
  process.send(events, fake_broker.stdout("a"))
  process.send(events, fake_broker.exited(code: 0, stdout_bytes: 1))
  let assert Ok(collected) = tool.collect_events(events, waiting: 0)
    as "zero idle wait still accepts already queued events"
  assert collected.stdout == <<"a":utf8>>
}
