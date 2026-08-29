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
  let observed_seq = process.new_subject()
  process.send(observed_seq, 0)
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

  let assert Ok(observed_reply) =
    demo.await_correlated_reply(
      inbox,
      deferred,
      observed_seq,
      8,
      fn(envelope) { envelope.event == reply.event },
      "compact main",
      2,
    )
  assert observed_reply == reply
  let assert Ok(observed) =
    demo.await_buffered_event(
      inbox,
      deferred,
      observed_seq,
      fn(envelope) {
        case envelope.seq {
          Some(seq) -> seq > 10 && envelope == event
          None -> False
        }
      },
      "compaction event",
      1,
    )
  assert observed == event
}

pub fn a_missed_live_event_is_recovered_from_catch_up_test() {
  let replayed = [compaction_event()]
  let assert Ok(#(matched, unmatched)) =
    demo.find_replayed_event(
      replayed,
      fn(envelope) { envelope == compaction_event() },
      11,
      "the compaction entry appeared",
    )
  assert matched == compaction_event()
  assert unmatched == []
}

pub fn catch_up_does_not_accept_an_old_matching_result_test() {
  let old_done =
    protocol.EventEnvelope(
      reply_to: None,
      seq: Some(12),
      event: protocol.StrandResultEvent(
        strand: "main",
        op: "old-op",
        status: "done",
        error: None,
      ),
    )
  let newer_open =
    protocol.EventEnvelope(
      reply_to: None,
      seq: Some(13),
      event: protocol.OpTransitionEvent(
        op: "new-op",
        strand: "main",
        phase: "compacting",
      ),
    )
  let result =
    demo.find_replayed_event(
      [old_done, newer_open],
      fn(envelope) {
        case envelope.event {
          protocol.StrandResultEvent(strand: "main", status: "done", ..) -> True
          _ -> False
        }
      },
      12,
      "compaction done",
    )
  assert result
    == Error("compaction done: the event was absent from catch-up replay")
}

pub fn two_recoveries_use_distinct_request_ids_test() {
  let ids = process.new_subject()
  process.send(ids, 1_000_000)
  let first = demo.next_recovery_id(ids)
  let second = demo.next_recovery_id(ids)
  assert #(first, second) == #(1_000_000, 1_000_001)
}

pub fn catch_up_consumes_prefix_and_preserves_suffix_test() {
  let before = transition_event(11, "before", "starting")
  let target = compaction_event()
  let after = transition_event(13, "after", "compacting")
  let assert Ok(#(matched, unmatched)) =
    demo.find_replayed_event(
      [before, target, after],
      fn(envelope) { envelope == target },
      10,
      "the compaction entry appeared",
    )
  assert matched == target
  assert !list.contains(unmatched, before)
  assert unmatched == [after]
}

pub fn post_snapshot_live_events_are_deferred_in_order_test() {
  let deferred = process.new_subject()
  let inbox = process.new_subject()
  let observed_seq = process.new_subject()
  process.send(observed_seq, 0)
  let replayed = transition_event(9, "replay", "starting")
  let first_live = transition_event(10, "live-1", "compacting")
  let second_live = transition_event(11, "live-2", "done")
  let assert demo.KeepReplaying(collected) =
    demo.collect_or_defer(replayed, 10, deferred, [])
  let assert demo.StopAtLiveBoundary(collected) =
    demo.collect_or_defer(first_live, 10, deferred, collected)
  assert list.reverse(collected) == [replayed]
  process.send(inbox, protocol.encode_event(second_live))
  let assert Ok(first) =
    demo.next_buffered_event(inbox, deferred, observed_seq, "first live")
  let assert Ok(second) =
    demo.next_buffered_event(inbox, deferred, observed_seq, "second live")
  assert [first, second] == [first_live, second_live]
}

pub fn a_seq_less_event_stops_replay_and_is_deferred_test() {
  let deferred = process.new_subject()
  let inbox = process.new_subject()
  let observed_seq = process.new_subject()
  process.send(observed_seq, 0)
  let ephemeral =
    protocol.EventEnvelope(
      reply_to: None,
      seq: None,
      event: protocol.OpTransitionEvent(
        op: "ephemeral",
        strand: "main",
        phase: "compacting",
      ),
    )
  let assert demo.StopAtLiveBoundary([]) =
    demo.collect_or_defer(ephemeral, 10, deferred, [])
  let assert Ok(observed) =
    demo.next_buffered_event(inbox, deferred, observed_seq, "ephemeral event")
  assert observed == ephemeral
}

pub fn catch_up_reply_wait_preserves_an_earlier_live_event_test() {
  let inbox = process.new_subject()
  let deferred = process.new_subject()
  let observed_seq = process.new_subject()
  process.send(observed_seq, 0)
  let live = transition_event(14, "live", "compacting")
  let reply =
    protocol.EventEnvelope(
      reply_to: Some(1_000_000),
      seq: None,
      event: protocol.SnapshotEvent(protocol.ResumeSnapshot(next_seq: 15)),
    )
  process.send(inbox, protocol.encode_event(live))
  process.send(inbox, protocol.encode_event(reply))
  let assert Ok(15) =
    demo.await_resume_reply(inbox, deferred, observed_seq, 1_000_000, 2)
  let assert Ok(observed) =
    demo.next_buffered_event(inbox, deferred, observed_seq, "live event")
  assert observed == live
}

fn transition_event(seq: Int, op: String, phase: String) {
  protocol.EventEnvelope(
    reply_to: None,
    seq: Some(seq),
    event: protocol.OpTransitionEvent(op:, strand: "main", phase:),
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
