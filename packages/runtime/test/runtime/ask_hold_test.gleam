//// An idle strand with an open ask is not woken by an automatic input
//// (protocol-change/119, the 2026-11-23 addendum): `send_to_strand` holds the
//// message as a durable next-run item, the next run places it ahead of its own
//// prompt, a steer onto an open run is untouched, and a mark spends in the
//// same commit as the hold.

import core/attention.{
  Alternative, Anchor, Ask, AskOpen, Confirm, Header, Plain, Question,
}
import core/clock
import core/ids
import core/json
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import machine/queue
import runtime/api
import runtime/effects
import session/session
import simplifile
import support/fake
import support/harness
import support/recorder

fn operation() -> ids.OpId {
  let #(id, _) = ids.mint_op(ids.generator(clock.fixed(at: 5), seed: 9))
  id
}

fn ask(
  id: String,
  strand: String,
  routing: attention.Routing,
) -> attention.Ask {
  Ask(
    header: Header(
      id:,
      created_at: 1,
      routing:,
      anchor: Anchor(operation: operation(), step_id: "s", source_index: 0),
      strand:,
      parents: [],
    ),
    why: None,
    questions: [
      Question("q1", "Retry?", Confirm, []),
      Question("q2", "Branch?", attention.Choice, [
        Alternative("a", None, Plain),
        Alternative("b", None, Plain),
      ]),
    ],
    state: AskOpen,
  )
}

fn record(rt: api.Runtime, ask: attention.Ask) -> Nil {
  let assert Ok(Nil) =
    api.put_reserved_fact(
      rt,
      attention.ask_key(ask.header.id),
      attention.encode_ask(ask),
    )
    as "the ask record must be written"
  Nil
}

// A runtime whose provider never settles, so a run the test opens stays open.
fn runtime() -> api.Runtime {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(_spec) { fake.Hang },
      fn(_run) {
        fake.ToolReply(text: "unused", is_error: False, terminate: False)
      },
    )
  let assert Ok(rt) =
    api.open(sess, eff, api.default_options(harness.configuration()))
    as "the session tree must boot"
  rt
}

fn claim(name: String) -> api.Mark {
  api.Mark(key: "rule/fired/main/" <> name, value: json.String(name))
}

pub fn an_idle_strand_with_an_open_ask_holds_the_message_test() {
  let rt = runtime()
  record(rt, ask("ask-0000000001", "main", attention.ToOwner))

  let assert Ok(api.Held(entry: _)) =
    api.send_to_strand(rt, to: "main", message: fake.user("nudge"))
    as "the message must be held, not started"
  assert harness.final_projection(rt.session) == []
    as "no run opened, so nothing reached the transcript"

  // The owner's own message opens the run, and the held item rides in first.
  let assert Ok(_op) = api.accept_quietly(rt, [fake.user("answer")])
    as "the owner's message must start a run"
  assert harness.final_projection(rt.session) == ["user:nudge", "user:answer"]
    as "the held message is placed ahead of the prompt that woke the strand"
  process.kill(rt.tree.supervisor)
}

pub fn held_messages_keep_their_order_test() {
  let rt = runtime()
  record(rt, ask("ask-0000000001", "main", attention.ToOwner))
  let assert Ok(api.Held(..)) =
    api.send_to_strand(rt, to: "main", message: fake.user("first"))
  let assert Ok(api.Held(..)) =
    api.send_to_strand(rt, to: "main", message: fake.user("second"))
  let assert Ok(_op) = api.accept_quietly(rt, [fake.user("answer")])

  assert harness.final_projection(rt.session)
    == ["user:first", "user:second", "user:answer"]
  process.kill(rt.tree.supervisor)
}

pub fn an_ask_that_does_not_wait_on_the_owner_here_holds_nothing_test() {
  let rt = runtime()
  record(rt, ask("ask-0000000001", "sub:1", attention.ToOwner))
  record(rt, ask("ask-0000000002", "main", attention.ToStrand("sub:1")))

  let assert Ok(api.Started(operation: _)) =
    api.send_to_strand(rt, to: "main", message: fake.user("wake up"))
    as "another strand's ask and an ask to a strand do not hold main"
  process.kill(rt.tree.supervisor)
}

pub fn an_open_run_is_steered_not_held_test() {
  let rt = runtime()
  record(rt, ask("ask-0000000001", "main", attention.ToOwner))
  let assert Ok(_op) = api.accept_quietly(rt, [fake.user("Hello")])

  let assert Ok(api.Steered(entry: _)) =
    api.send_to_strand(rt, to: "main", message: fake.user("also this"))
    as "a run already open reads its steers, ask or no ask"
  process.kill(rt.tree.supervisor)
}

pub fn a_mark_spends_in_the_commit_that_holds_test() {
  let rt = runtime()
  record(rt, ask("ask-0000000001", "main", attention.ToOwner))
  let mark = claim("tick")

  let assert Ok(api.Held(..)) =
    api.send_to_strand_marking(
      rt,
      to: "main",
      message: fake.user("tick"),
      mark:,
    )
  let assert Ok(Some(json.String("tick"))) = api.fact(rt, mark.key)
    as "the claim is spent when the message is held"
  let assert Error(api.FactConflict(key:)) =
    api.send_to_strand_marking(
      rt,
      to: "main",
      message: fake.user("tick again"),
      mark:,
    )
    as "a second fire of the same claim is refused, held or not"
  assert key == mark.key

  let assert Ok(_op) = api.accept_quietly(rt, [fake.user("answer")])
  assert harness.final_projection(rt.session) == ["user:tick", "user:answer"]
  process.kill(rt.tree.supervisor)
}

pub fn the_held_queue_is_bounded_test() {
  let rt = runtime()
  record(rt, ask("ask-0000000001", "main", attention.ToOwner))

  list.each(list.repeat(Nil, api.next_run_limit), fn(_) {
    let assert Ok(api.Held(..)) =
      api.send_to_strand(rt, to: "main", message: fake.user("again"))
    Nil
  })
  let assert Error(api.QueueRejected(reason: queue.NextRunFull(limit:))) =
    api.send_to_strand(rt, to: "main", message: fake.user("one too many"))
    as "the queue refuses past its limit and writes nothing"
  assert limit == api.next_run_limit
  assert int.to_string(limit) == "16"
  process.kill(rt.tree.supervisor)
}

pub fn open_owner_asks_reads_the_addressed_strands_asks_test() {
  let rt = runtime()
  record(rt, ask("ask-0000000001", "main", attention.ToOwner))
  record(rt, ask("ask-0000000002", "sub:1", attention.ToOwner))

  let assert Ok([held]) = api.open_owner_asks(rt)
  assert held.header.id == "ask-0000000001"
  let assert Ok([other]) = api.open_owner_asks(api.on_strand(rt, "sub:1"))
  assert other.header.id == "ask-0000000002"
  process.kill(rt.tree.supervisor)
}

fn fresh_path(name: String) -> String {
  let _ = simplifile.create_directory_all("build/test_db")
  let path = "build/test_db/" <> name <> ".db"
  let _ = simplifile.delete(path)
  let _ = simplifile.delete(path <> "-wal")
  let _ = simplifile.delete(path <> "-shm")
  path
}

// Each incarnation reads its own clock, as a restarted daemon does, so the
// ids it mints cannot repeat the first one's.
fn hanging_effects(from: Int) -> effects.Effects {
  fake.effects(
    recorder.start(),
    clock.stepping(from:, by: 25),
    [],
    fn(_spec) { fake.Hang },
    fn(_run) {
      fake.ToolReply(text: "unused", is_error: False, terminate: False)
    },
  )
}

// The hold is a durable register write, so a daemon that stops with a message
// held places it when the reopened session's next run starts.
pub fn a_held_message_survives_a_restart_test() {
  let path = fresh_path("ask_hold_restart")
  let assert Ok(first) =
    session.open_sqlite(
      path:,
      owner: "writer-1",
      lease_ttl_ms: 30_000,
      clock: clock.stepping(from: 1_000_000, by: 7),
    )
    as "the fresh sqlite session must open"
  let options = api.default_options(harness.configuration())
  let assert Ok(rt) = api.open(first, hanging_effects(2_000_000), options)
    as "the session tree must boot"
  record(rt, ask("ask-0000000001", "main", attention.ToOwner))
  let assert Ok(api.Held(..)) =
    api.send_to_strand(rt, to: "main", message: fake.user("held across"))
    as "the message must be held"
  let assert Ok(Nil) = api.close(rt) as "the first runtime must close"

  let assert Ok(second) =
    session.open_sqlite(
      path:,
      owner: "writer-2",
      lease_ttl_ms: 30_000,
      clock: clock.stepping(from: 9_000_000, by: 7),
    )
    as "the session must reopen from the file"
  let assert Ok(rt2) = api.open(second, hanging_effects(10_000_000), options)
    as "the reopened tree must boot"
  assert harness.final_projection(second) == []
    as "the reopened strand is still idle and the item is not yet placed"
  let assert Ok(api.Held(..)) =
    api.send_to_strand(rt2, to: "main", message: fake.user("after restart"))
    as "the ask is still open, so a later send is held too"

  let assert Ok(_op) = api.accept_quietly(rt2, [fake.user("answer")])
  assert harness.final_projection(second)
    == ["user:held across", "user:after restart", "user:answer"]
    as "both held messages are delivered, in order, ahead of the answer"
  process.kill(rt2.tree.supervisor)
}
