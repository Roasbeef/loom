//// The M3 acceptance test: the scripted demo drives a real session —
//// prompt, subagent strand, durable inter-strand messaging, escalation
//// approval, fork, navigation, compaction, catch-up replay — entirely
//// through the Part 1.6 protocol, and every step must land.

import client/demo
import client/protocol
import core/entry
import core/ids
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
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

pub fn an_event_before_a_correlated_reply_is_deferred_test() {
  let inbox = process.new_subject()
  let deferred = process.new_subject()
  let event = compaction_event()
  let reply =
    protocol.EventEnvelope(
      reply_to: Some(8),
      seq: Some(13),
      event: protocol.OpTransitionEvent(
        op: "op-8",
        strand: "main",
        phase: "compacting",
      ),
    )
  process.send(inbox, protocol.encode_event(event))
  process.send(inbox, protocol.encode_event(reply))

  let assert Ok(Nil) =
    demo.await_correlated_reply(
      inbox,
      deferred,
      8,
      fn(envelope) { envelope.event == reply.event },
      "compact main",
      2,
    )
  let assert Ok(observed) =
    demo.next_buffered_event(inbox, deferred, "compaction event")
  assert observed == event
}

pub fn a_missed_live_event_is_recovered_from_catch_up_test() {
  let replayed = [compaction_event()]
  let assert Ok(Nil) =
    demo.find_replayed_event(
      replayed,
      fn(envelope) { envelope == compaction_event() },
      "the compaction entry appeared",
    )
}

fn compaction_event() -> protocol.EventEnvelope {
  let assert Ok(id) = ids.parse_entry_id("0198d9c1-9800-7314-a374-f17f2219c14e")
  protocol.EventEnvelope(
    reply_to: None,
    seq: Some(12),
    event: protocol.EntryEvent(record: protocol.EntryRecord(
      strand: "main",
      entry: entry.CompactionEntry(
        id:,
        parent: None,
        seq: 12,
        ts: 0,
        summary: demo.summary_text,
        retained_tail: [],
        tokens_before: 10,
        from_hook: False,
        usage: None,
      ),
    )),
  )
}
