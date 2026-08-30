//// The public drain witness must survive the useful worker it guards.
////
//// This is the small invariant every composed provider boundary relies on:
//// worker Down initiates child cancellation, but owner Down is withheld until
//// that child independently proves its drain.

import gleam/erlang/process
import provider/custodian

pub fn worker_crash_keeps_witness_until_child_drain_test() {
  let ready = process.new_subject()
  let adopted = process.new_subject()
  let cancelled = process.new_subject()
  let child_ready = process.new_subject()
  let child =
    process.spawn_unlinked(fn() {
      let release = process.new_subject()
      process.send(child_ready, release)
      let _release = process.receive_forever(release)
      Nil
    })
  let release = process.receive_forever(child_ready)
  let worker =
    process.spawn_unlinked(fn() {
      let start = process.new_subject()
      let stop = process.new_subject()
      process.send(ready, #(start, stop))
      let owner = process.receive_forever(start)
      let accepted =
        custodian.adopt_owner(owner, child, fn() {
          process.send(cancelled, Nil)
        })
      process.send(adopted, accepted)
      process.receive_forever(process.new_subject())
    })
  let #(start, stop) = process.receive_forever(ready)
  let owner = custodian.start(worker, stop, Nil, process.self())
  process.send(start, owner)
  assert process.receive(adopted, within: 1000) == Ok(True)
  let witness = custodian.owner(owner)
  let witness_monitor = process.monitor(witness)

  process.kill(worker)

  assert process.receive(cancelled, within: 1000) == Ok(Nil)
  assert process.is_alive(child)
  assert process.is_alive(witness)
  process.send(release, Nil)
  assert process.new_selector()
    |> process.select_specific_monitor(witness_monitor, fn(_down) { True })
    |> process.selector_receive(1000)
    == Ok(True)
}
