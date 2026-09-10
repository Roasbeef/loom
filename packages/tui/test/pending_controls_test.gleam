//// Live controls reconcile through credited snapshots, including cuts which
//// skip the idle interval and queues containing identical text from two peers.

import core/clock
import core/ids
import core/json
import core/register
import gleam/list
import gleam/option.{None, Some}
import machine/codec
import machine/operation
import machine/strand
import tui
import tui/session_channel
import tui/snapshot
import tui/snapshot_view
import tui_test/pushed

fn cell(namespace, key, value) {
  json.Object([
    #("namespace", json.String(register.ns_to_string(namespace))),
    #("key", json.String(key)),
    #("seq", json.Int(1)),
    #("value", value),
  ])
}

fn metadata(current, pending) {
  let assert Ok(json.Object(base)) = json.parse(pushed.metadata())
    as "the transfer fixture has valid metadata"
  let cells = [
    cell(
      register.StrandConfig,
      "main",
      codec.encode_configuration(
        strand.StrandConfiguration(
          strand.ModelIdentity("test", "test"),
          strand.ThinkingOff,
          [],
        ),
      ),
    ),
    cell(register.StrandLeaf, "main", json.Null),
    cell(
      register.StrandState,
      "main",
      codec.encode_strand_state(strand.StrandState(current, [])),
    ),
  ]
  let cells = case current {
    None -> cells
    Some(op) -> [
      cell(
        register.OpState,
        ids.op_id_to_string(op),
        codec.encode_state(operation.CompactionState(
          operation.Running,
          None,
          operation.Deciding("fixture"),
        )),
      ),
      ..cells
    ]
  }
  json.to_string(
    json.Object([
      #("cells", json.Array(cells)),
      #("pending_inputs", json.Array(pending)),
      ..list.filter(base, fn(pair) { pair.0 != "cells" })
    ]),
  )
}

fn pending(id, kind) {
  json.Object([
    #("id", json.String(id)),
    #("strand", json.String("main")),
    #("kind", json.String(kind)),
    #("text", json.String("same instruction")),
  ])
}

fn captured(model, data) {
  let channel =
    session_channel.replay(snapshot.Expected("A", "epoch", "incarnation"))
  let #(_, model) =
    list.fold(
      pushed.transfer_with_metadata(1, "1:1", "recent", 10, data),
      #(channel, model),
      fn(acc, incoming) {
        let #(channel, changes) = session_channel.receive(acc.0, incoming)
        #(channel, list.fold(changes, acc.1, tui.apply_channel_update))
      },
    )
  model
}

pub fn a_successor_cut_retires_the_old_interrupt_without_an_idle_event_test() {
  let #(first, generator) = ids.mint_op(ids.generator(clock.fixed(1000), 1))
  let #(second, _) = ids.mint_op(generator)
  let before = captured(pushed.attached(), metadata(Some(first), []))
  let stopped =
    tui.Model(
      ..before,
      interrupt: Some(tui.Interrupt(
        "main",
        Some(ids.op_id_to_string(first)),
        None,
      )),
    )
  let same = captured(stopped, metadata(Some(first), []))
  assert same.interrupt == stopped.interrupt
    as "a still-current operation has not completed cancellation"
  let successor = captured(same, metadata(Some(second), []))
  assert successor.interrupt == None
    as "a queued successor must not inherit the old stop indicator"
}

pub fn a_credited_idle_cut_retires_the_interrupt_test() {
  let before =
    tui.Model(
      ..pushed.attached(),
      interrupt: Some(tui.Interrupt("main", Some("previous"), None)),
    )
  let after = captured(before, metadata(None, []))
  assert after.interrupt == None
    as "v2 snapshots settle cancellation without legacy phase events"
}

pub fn host_queue_identity_survives_equal_text_and_clears_after_drain_test() {
  let before =
    tui.Model(..pushed.attached(), queued: [
      tui.HeldPrompt("obsolete local guess"),
    ])
  let after =
    captured(
      before,
      metadata(None, [pending("2:1", "steer"), pending("1:1", "queue")]),
    )
  let assert Some(#(_, view)) = after.captured
    as "the credited metadata must reach the model"
  let assert Some(rows) = view.pending_inputs
    as "modern metadata carries an authoritative queue"
  assert list.map(rows, fn(row) { #(row.id, row.kind) })
    == [#("2:1", snapshot_view.Steer), #("1:1", snapshot_view.Queue)]
    as "equal text from distinct peers retains host identity and priority"
  assert after.queued == []
    as "a coherent host queue replaces stale local transcript guesses"

  let drained = captured(after, metadata(None, []))
  let assert Some(#(_, view)) = drained.captured
    as "the queue-only change must reach the model at the same durable cursor"
  assert view.pending_inputs == Some([])
    as "an empty authoritative queue clears both rows"
}
