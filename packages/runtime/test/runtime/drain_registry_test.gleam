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
