//// Bus semantics: typed per-session topic delivery, isolation, legal
//// loss, and the writer-bridge seam.

import core/ids.{type Seq}
import events/bus.{Committed, EntryAdded, Published}
import gleam/erlang/process
import support/fixtures

/// Receives one published bus event or fails the receive.
fn receive_published(timeout: Int) -> Result(bus.Published, Nil) {
  process.new_selector()
  |> bus.select_published(fn(published) { published })
  |> process.selector_receive(timeout)
}

pub fn publish_subscribe_roundtrip_test() {
  let bus = bus.start()
  let session = "bus-roundtrip"
  bus.subscribe(bus, session:, topic: bus.Commits)
  let event = Committed(seqs: [4, 5], ts: 42)
  bus.publish(bus, session:, event:)
  assert receive_published(500) == Ok(Published(session:, event:))
  bus.unsubscribe(bus, session:, topic: bus.Commits)
}

pub fn topic_isolation_test() {
  let bus = bus.start()
  let session = "bus-topic-isolation"
  bus.subscribe(bus, session:, topic: bus.Commits)
  // An event on another topic of the same session is not delivered.
  let #(id, _ctx) = fixtures.mint(fixtures.new_ctx())
  bus.publish(bus, session:, event: EntryAdded(id:, seq: 1))
  assert receive_published(50) == Error(Nil)
  // The subscribed topic still works.
  let event = Committed(seqs: [1], ts: 1)
  bus.publish(bus, session:, event:)
  assert receive_published(500) == Ok(Published(session:, event:))
  bus.unsubscribe(bus, session:, topic: bus.Commits)
}

pub fn session_isolation_test() {
  let bus = bus.start()
  bus.subscribe(bus, session: "bus-session-a", topic: bus.Commits)
  bus.publish(bus, session: "bus-session-b", event: Committed(seqs: [1], ts: 1))
  assert receive_published(50) == Error(Nil)
  bus.unsubscribe(bus, session: "bus-session-a", topic: bus.Commits)
}

pub fn subscribe_all_receives_every_topic_once_test() {
  let bus = bus.start()
  let session = "bus-subscribe-all"
  bus.subscribe_all(bus, session:)
  let event = Committed(seqs: [9], ts: 9)
  bus.publish(bus, session:, event:)
  // Delivered exactly once even though we are in all six groups.
  assert receive_published(500) == Ok(Published(session:, event:))
  assert receive_published(50) == Error(Nil)
}

pub fn publish_without_subscribers_is_legal_test() {
  let bus = bus.start()
  // Events are hints: loss (here, total) is legal and publish is a
  // fire-and-forget Nil either way.
  assert bus.publish(
      bus,
      session: "bus-nobody-listening",
      event: Committed(seqs: [1], ts: 1),
    )
    == Nil
}

pub fn subscriber_count_test() {
  let bus = bus.start()
  let session = "bus-subscriber-count"
  assert bus.subscriber_count(bus, session:, topic: bus.Commits) == 0
  bus.subscribe(bus, session:, topic: bus.Commits)
  assert bus.subscriber_count(bus, session:, topic: bus.Commits) == 1
  bus.unsubscribe(bus, session:, topic: bus.Commits)
  assert bus.subscriber_count(bus, session:, topic: bus.Commits) == 0
}

pub fn topic_of_covers_every_event_test() {
  let #(id, ctx) = fixtures.mint(fixtures.new_ctx())
  let #(usage_id, ctx) = fixtures.mint_usage(ctx)
  let #(op, _ctx) = fixtures.mint_op(ctx)
  assert bus.topic_of(EntryAdded(id:, seq: 1)) == bus.Entries
  assert bus.topic_of(bus.OpTransition(op:, phase: "settling"))
    == bus.Operations
  assert bus.topic_of(bus.UsageAdded(id: usage_id, seq: 2)) == bus.Usage
  assert bus.topic_of(bus.StrandResult(strand: "main")) == bus.Strands
  assert bus.topic_of(bus.Escalation(op:, description: "network widen"))
    == bus.Escalations
  assert bus.topic_of(Committed(seqs: [], ts: 0)) == bus.Commits
}

/// The writer adoption seam: anything subscription-shaped can be mapped
/// onto the bus. Here the incoming events are the same tuple shape the
/// runtime StorageWriter publishes (`ordinal`, `seqs`, `ts`).
pub fn bridge_republishes_mapped_events_test() {
  let bus = bus.start()
  let session = "bus-bridge"
  bus.subscribe(bus, session:, topic: bus.Commits)
  let assert Ok(started) =
    bus.bridge(bus, session:, map: fn(incoming: #(Int, List(Seq), Int)) {
      let #(_ordinal, seqs, ts) = incoming
      Committed(seqs:, ts:)
    })
  process.send(started.data, #(1, [7, 8], 99))
  assert receive_published(500)
    == Ok(Published(session:, event: Committed(seqs: [7, 8], ts: 99)))
  bus.unsubscribe(bus, session:, topic: bus.Commits)
}
