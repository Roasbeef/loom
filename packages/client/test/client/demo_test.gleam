//// The M3 acceptance test: the scripted demo drives a real session —
//// prompt, subagent strand, durable inter-strand messaging, escalation
//// approval, fork, navigation, compaction, catch-up replay — entirely
//// through the Part 1.6 protocol, and every step must land.

import client/demo
import gleam/list
import gleam/string

pub fn acceptance_flow_test() {
  let assert Ok(lines) = demo.run()
    as "the protocol-driven acceptance flow must complete"
  // Every acceptance milestone appears in the narrative, in order.
  let expected = [
    "subscribed", "prompted main", "research strand", "reported to main",
    "escalation approved", "forked main", "navigated", "compacted", "queue_mode",
    "caught up", "final snapshot", "served:",
  ]
  let assert Ok(_) =
    list.try_fold(expected, lines, fn(remaining, marker) {
      case
        list.drop_while(remaining, fn(line) { !string.contains(line, marker) })
      {
        [] -> Error(marker)
        [_, ..rest] -> Ok(rest)
      }
    })
    as "every acceptance milestone must appear in the narrative, in order"
}
