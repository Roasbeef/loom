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
  let session = bus.unidentified_key(name: "bus-roundtrip")
  bus.subscribe(bus, session:, topic: bus.Commits)
  let event = Committed(seqs: [4, 5], ts: 42)
  bus.publish(bus, session:, event:)
  assert receive_published(500) == Ok(Published(session:, event:))
  bus.unsubscribe(bus, session:, topic: bus.Commits)
}

pub fn topic_isolation_test() {
  let bus = bus.start()
  let session = bus.unidentified_key(name: "bus-topic-isolation")
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
  bus.subscribe(
    bus,
    session: bus.unidentified_key(name: "bus-session-a"),
    topic: bus.Commits,
  )
  bus.publish(
    bus,
    session: bus.unidentified_key(name: "bus-session-b"),
    event: Committed(seqs: [1], ts: 1),
  )
  assert receive_published(50) == Error(Nil)
  bus.unsubscribe(
    bus,
    session: bus.unidentified_key(name: "bus-session-a"),
    topic: bus.Commits,
  )
}

pub fn subscribe_all_receives_every_topic_once_test() {
  let bus = bus.start()
  let session = bus.unidentified_key(name: "bus-subscribe-all")
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
      session: bus.unidentified_key(name: "bus-nobody-listening"),
      event: Committed(seqs: [1], ts: 1),
    )
    == Nil
}

/// EV-sub-idempotent: `pg` counts multiplicity (two joins from one pid
/// are two memberships), so without a guard a second `subscribe` would
/// double-deliver and one `unsubscribe` would leave a membership behind.
/// `subscribe` must dedup per `{session, topic, pid}`.
pub fn double_subscribe_delivers_once_test() {
  let bus = bus.start()
  let session = bus.unidentified_key(name: "bus-double-subscribe")
  bus.subscribe(bus, session:, topic: bus.Commits)
  bus.subscribe(bus, session:, topic: bus.Commits)
  assert bus.subscriber_count(bus, session:, topic: bus.Commits) == 1
  let event = Committed(seqs: [1], ts: 1)
  bus.publish(bus, session:, event:)
  assert receive_published(500) == Ok(Published(session:, event:))
  // A second delivery of the same event would arrive here if the double
  // join were live; there must be none.
  assert receive_published(50) == Error(Nil)
  // One unsubscribe now fully undoes the one membership subscribe left.
  bus.unsubscribe(bus, session:, topic: bus.Commits)
  assert bus.subscriber_count(bus, session:, topic: bus.Commits) == 0
}

/// EV-bridge-sup: `bridge` is `actor.start`, which links the new actor
/// to its caller like every OTP start. The mapping closure is
/// caller-supplied and runs inside the bridge actor, so a closure that
/// crashes must not take its starter down with it. A separate "host"
/// process starts the bridge (so the link under test is the bridge's,
/// not gleeunit's own test process), triggers the crash, then proves it
/// is still alive by answering a ping afterward.
pub fn bridge_crash_does_not_kill_starter_test() {
  let bus = bus.start()
  let session = bus.unidentified_key(name: "bus-bridge-crash")
  // A subject can only be received on by the process that created it, so
  // the host creates its own ping subject and hands it back over
  // `ready_relay` rather than the test handing one in.
  let ready_relay = process.new_subject()
  let _host =
    process.spawn_unlinked(fn() {
      let assert Ok(started) =
        bus.bridge(bus, session:, map: fn(_incoming: Int) -> bus.Event {
          panic as "a caller-supplied mapping closure may crash"
        })
      let ping = process.new_subject()
      process.send(ready_relay, #(started.data, ping))
      // Stay alive to answer a ping after the bridge has (maybe)
      // crashed — that is the property under test.
      let assert Ok(reply) = process.receive(ping, 2000)
      process.send(reply, True)
    })
  let assert Ok(#(bridge_subject, ping)) = process.receive(ready_relay, 500)
  process.send(bridge_subject, 1)
  // Give the crash time to propagate before checking survival.
  process.sleep(100)
  let pong = process.new_subject()
  process.send(ping, pong)
  assert process.receive(pong, 500) == Ok(True)
}

pub fn subscriber_count_test() {
  let bus = bus.start()
  let session = bus.unidentified_key(name: "bus-subscriber-count")
  assert bus.subscriber_count(bus, session:, topic: bus.Commits) == 0
  bus.subscribe(bus, session:, topic: bus.Commits)
  assert bus.subscriber_count(bus, session:, topic: bus.Commits) == 1
  bus.unsubscribe(bus, session:, topic: bus.Commits)
  assert bus.subscriber_count(bus, session:, topic: bus.Commits) == 0
}

/// The two key spaces are disjoint by construction: an unidentified
/// caller cannot land on an identified session's group however it picks
/// its name, which is the whole reason the string form survived
/// `protocol-change/008`.
pub fn identified_and_unidentified_keys_never_collide_test() {
  let bus = bus.start()
  let #(id, _ctx) = fixtures.mint_session(fixtures.new_ctx())
  let identified = bus.key(of: id)
  // The most adversarial name available: the id's own canonical text,
  // and then the rendered key itself.
  let impersonator = bus.unidentified_key(name: ids.session_id_to_string(id))
  let echoed = bus.unidentified_key(name: bus.key_to_string(identified))
  bus.subscribe(bus, session: identified, topic: bus.Commits)
  bus.publish(bus, session: impersonator, event: Committed(seqs: [1], ts: 1))
  bus.publish(bus, session: echoed, event: Committed(seqs: [2], ts: 2))
  assert receive_published(50) == Error(Nil)
  // The identified key's own publish still arrives.
  let event = Committed(seqs: [3], ts: 3)
  bus.publish(bus, session: identified, event:)
  assert receive_published(500) == Ok(Published(session: identified, event:))
  bus.unsubscribe(bus, session: identified, topic: bus.Commits)
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
  let session = bus.unidentified_key(name: "bus-bridge")
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
