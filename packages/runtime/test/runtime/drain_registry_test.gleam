//// Fault tests for the session's effect-generation drain ledger.
////
//// A reaper's normal `Down` is the only positive proof that its adopted
//// effects retired. These tests kill that witness and require the ledger to
//// fail with it, preserving the rule that missing evidence can never release
//// a writer lease or admit a replacement generation.

import gleam/erlang/process
import runtime/internal/drain_registry

/// Killing a claimed reaper must poison the ledger rather than remove the
/// generation as though it had drained normally.
pub fn abnormal_reaper_exit_poisoned_ledger_test() {
  let name = process.new_name(prefix: "drain-ledger-fault")
  let assert Ok(started) = drain_registry.start(name)
  let ledger = started.data
  let assert Ok(ledger_pid) = process.subject_owner(ledger)
  // Production links the ledger to its supervisor so lost proof stops the
  // session. The test unlinks only its gleeunit caller, which must remain
  // alive long enough to inspect that same abnormal exit.
  process.unlink(ledger_pid)
  let ledger_monitor = process.monitor(ledger_pid)
  let reaper =
    process.spawn_unlinked(fn() {
      process.receive_forever(process.new_subject())
    })
  let previous = drain_registry.claim(ledger, "main", reaper)
  assert previous == []

  process.kill(reaper)

  let assert Ok(process.ProcessDown(reason:, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(ledger_monitor, fn(down) { down })
    |> process.selector_receive(1000)
  assert reason == process.Killed
    as "an abnormal reaper must make the ledger fail closed"
}

/// A replacement claim must be released by the ledger's original monitor,
/// not by a late monitor which can observe only `noproc` after a clean exit.
pub fn replacement_claim_waits_for_ledger_authored_drain_test() {
  let name = process.new_name(prefix: "drain-ledger-barrier")
  let assert Ok(started) = drain_registry.start(name)
  let ledger = started.data
  let #(first, stop_first) = parked_reaper()
  assert drain_registry.claim(ledger, "main", first) == []

  let #(second, stop_second) = parked_reaper()
  let claimed = process.new_subject()
  let _claimant =
    process.spawn_unlinked(fn() {
      process.send(claimed, drain_registry.claim(ledger, "main", second))
    })

  assert process.receive(claimed, within: 20) == Error(Nil)
    as "the replacement must remain behind its live predecessor"
  process.send(stop_first, Nil)
  assert process.receive(claimed, within: 1000) == Ok([])
    as "the original monitor's Normal Down must open the exact claim"

  // Leave the ledger with a clean final generation so the test exercises the
  // same positive acknowledgement used by an orderly session shutdown.
  process.send(stop_second, Nil)
}

fn parked_reaper() -> #(process.Pid, process.Subject(Nil)) {
  let ready = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      let stop = process.new_subject()
      process.send(ready, stop)
      let _stop = process.receive_forever(stop)
      Nil
    })
  #(pid, process.receive_forever(ready))
}
