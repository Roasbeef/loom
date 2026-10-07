//// Direct writer and api coverage: committed-event publication through
//// the writer's subscriber seam, read routing, follow-up draining at a
//// may-finish checkpoint, awaiting a result the strand register has
//// since moved past, and the two blackboard write doors — including
//// `steer_marking`, which is a queue admission and a write-once claim in
//// one transaction. The last section is about what an admission reads
//// rather than what it writes: the pending queue is scanned only for
//// the admission that consumes it, so a corrupt queue payload refuses a
//// run and leaves every other strand's structural admission alone.

import core/clock
import core/ids
import core/json
import core/register
import core/tx.{DeleteRegister, SetRegister, Tx}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/system
import machine/operation
import machine/queue
import runtime/api
import runtime/effects
import runtime/hooks
import runtime/writer
import session/session
import support/fake
import support/harness
import support/internal/ffi_memory
import support/recorder
import weft
import weft/poll
import weft/registry as address

pub fn writer_publishes_committed_events_test() {
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
    as "the memory session must open"
  let events = process.new_subject()
  let assert Ok(namespace) = address.start() as "the namespace must start"
  let name = address.new_address(namespace)
  let assert Ok(started) =
    writer.start(
      writer.Options(session: sess, after_commit: fn(_) { Nil }, subscribers: [
        writer.Direct(events),
      ]),
      name,
    )
    as "the writer must start"
  let w = name
  let commit_tx =
    Tx(
      writes: [
        SetRegister(
          ns: register.FactCustom,
          key: "note",
          value: register.value(json.String("hello")),
        ),
      ],
      expected: [],
    )
  let assert Ok(_) = writer.commit(w, commit_tx) as "the commit must apply"
  // The event was published before the commit reply, so it is already
  // in our mailbox.
  let assert Ok(writer.Committed(ordinal: 1, ..)) =
    process.receive(events, within: 1000)
    as "the subscriber must see the first committed event"
  // A late subscriber sees subsequent commits.
  let late = process.new_subject()
  writer.subscribe(w, writer.Direct(late))
  let second_tx =
    Tx(
      writes: [
        SetRegister(
          ns: register.FactCustom,
          key: "note",
          value: register.value(json.String("again")),
        ),
      ],
      expected: [],
    )
  let assert Ok(_) = writer.commit(w, second_tx)
    as "the second commit must apply"
  let assert Ok(writer.Committed(ordinal: 2, ..)) =
    process.receive(late, within: 1000)
    as "the late subscriber must see the second committed event"
  // Reads route through the writer too.
  let assert Ok(Some(_)) = writer.get_register(w, register.FactCustom, "note")
    as "the read must find the committed register"
  process.send_exit(started.pid)
  assert address.stop(namespace) == Ok(Nil)
}

pub fn follow_up_is_drained_at_may_finish_test() {
  let rec = recorder.start()
  let first_started = process.new_subject()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(spec) {
        case fake.turn(spec) {
          0 -> {
            let release_first = process.new_subject()
            process.send(first_started, release_first)
            let assert Ok(Nil) = process.receive(release_first, within: 1000)
              as "the follow-up must be admitted before the first answer"
            fake.Reply(fake.answer("First", 3))
          }
          _ -> fake.Reply(fake.answer("Second", 4))
        }
      },
      fn(_run) {
        fake.ToolReply(text: "unused", is_error: False, terminate: False)
      },
    )
  let assert Ok(rt) =
    api.open(sess, eff, api.default_options(harness.configuration()))
    as "the session tree must boot"

  // A quiet admission can still run on a checkpoint poll. Hold the first
  // provider response until the follow-up is durable, rather than racing it.
  let assert Ok(op) = api.prompt(rt, [fake.user("Hello")])
    as "acceptance must succeed"
  let assert Ok(release_first) = process.receive(first_started, within: 1000)
    as "the first generation must be waiting"
  let assert Ok(_entry) = api.follow_up(rt, fake.user("One more thing"))
    as "follow-up admission must succeed"
  process.send(release_first, Nil)
  let assert Ok(outcome) = api.await_result(rt, op, within_ms: 5000)
    as "the run must complete"
  harness.assert_completed(outcome)
  // The follow-up waited for the may-finish boundary: it comes after the
  // first answer, and the run only finished after answering it.
  assert harness.final_projection(sess)
    == [
      "user:Hello",
      "assistant:stop:First",
      "user:One more thing",
      "assistant:stop:Second",
    ]
  harness.assert_placement_invariants(sess)
  process.kill(rt.tree.supervisor)
}

// A cache belongs to the immutable durable branch. A context hook belongs to
// one dispatch: its injected messages must neither enter the next cached
// projection nor prevent a moved leaf from reaching the next request.
pub fn cached_context_keeps_request_transforms_transient_test() {
  let rec = recorder.start()
  let contexts = process.new_subject()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let base =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(spec) {
        let assert effects.GenerationRequest(context:, ..) = spec
          as "the provider must receive a generation"
        process.send(contexts, list.map(context, harness.fingerprint))
        fake.Reply(fake.answer("Done", 3))
      },
      fn(_run) {
        fake.ToolReply(text: "unused", is_error: False, terminate: False)
      },
    )
  let request_hooks =
    hooks.new()
    |> hooks.with_context(fn(_op, messages) {
      let dispatch = recorder.bump(rec, "context-hook")
      list.append(messages, [fake.user("transient " <> int.to_string(dispatch))])
    })
    |> hooks.build
  let eff = effects.Effects(..base, hooks: request_hooks)
  let assert Ok(rt) =
    api.open(sess, eff, api.default_options(harness.configuration()))
    as "the session tree must boot"

  let assert Ok(first) = api.prompt(rt, [fake.user("One")])
    as "the first prompt must be admitted"
  let assert Ok(first_result) = api.await_result(rt, first, within_ms: 5000)
    as "the first run must finish"
  harness.assert_completed(first_result)
  let assert Ok(first_context) = process.receive(contexts, within: 1000)
    as "the first provider context must arrive"
  assert first_context == ["user:One", "user:transient 1"]

  // The same driver now extends its cached scan through the first answer and
  // the next prompt. Only the newly dispatched hook result joins that request.
  let assert Ok(second) = api.prompt(rt, [fake.user("Two")])
    as "the second prompt must be admitted"
  let assert Ok(second_result) = api.await_result(rt, second, within_ms: 5000)
    as "the second run must finish"
  harness.assert_completed(second_result)
  let assert Ok(second_context) = process.receive(contexts, within: 1000)
    as "the second provider context must arrive"
  assert second_context
    == ["user:One", "assistant:stop:Done", "user:Two", "user:transient 2"]
  assert harness.final_projection(sess)
    == ["user:One", "assistant:stop:Done", "user:Two", "assistant:stop:Done"]
  let assert Ok(Nil) = api.close(rt) as "the session tree must close cleanly"
}

pub fn await_result_survives_a_later_run_test() {
  // `strand.last_result` is one latest-wins register per strand, so a
  // second run overwrites the first's terminal record. A waiter keyed on
  // the first operation — a parent polling a fast child, say — must
  // still observe that operation's own result: the terminal transaction
  // records it operation-keyed, immune to the overwrite. Before that
  // record existed this await spun to timeout and returned `Error(Nil)`,
  // indistinguishable from "still running".
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(spec) {
        case fake.turn(spec) {
          0 -> fake.Reply(fake.answer("first answer", 3))
          _ -> fake.Reply(fake.answer("second answer", 4))
        }
      },
      fn(_run) {
        fake.ToolReply(text: "unused", is_error: False, terminate: False)
      },
    )
  let assert Ok(rt) =
    api.open(sess, eff, api.default_options(harness.configuration()))
    as "the session tree must boot"
  let assert Ok(first_op) = api.prompt(rt, [fake.user("one")])
    as "the first prompt must be accepted"
  let assert Ok(first) = api.await_result(rt, first_op, within_ms: 5000)
    as "the first run must complete"
  harness.assert_completed(first)
  // A second run lands and overwrites the strand's latest-wins register.
  let assert Ok(second_op) = api.prompt(rt, [fake.user("two")])
    as "the second prompt must be accepted"
  let assert Ok(second) = api.await_result(rt, second_op, within_ms: 5000)
    as "the second run must complete"
  harness.assert_completed(second)
  // The first operation's result is still observable, and is genuinely
  // the first operation's — not the latest one relabeled.
  let assert Ok(replayed) = api.await_result(rt, first_op, within_ms: 1000)
    as "the first operation's result must survive the second run"
  assert replayed == first
  process.kill(rt.tree.supervisor)
}

// --- the blackboard's two doors --------------------------------------------

// `put_fact` is last-write-wins and its docstring now says so. This is
// what that costs, stated as a test rather than left to be discovered:
// two writers reading the same cell and appending to it lose one of the
// two appends, silently and with both writes reporting success.
pub fn put_fact_is_last_write_wins_test() {
  let rt = fact_runtime()
  let assert Ok(Nil) = api.put_fact(rt, "review/findings", json.Array([]))
    as "the cell must seed"
  // Two readers, both reading before either writes — the ordinary shape
  // of two agents reporting into one cell.
  let assert Ok(Some(json.Array(first))) = api.fact(rt, "review/findings")
  let assert Ok(Some(json.Array(second))) = api.fact(rt, "review/findings")
  let assert Ok(Nil) =
    api.put_fact(
      rt,
      "review/findings",
      json.Array(list.append(first, [json.String("auth.gleam:42")])),
    )
  let assert Ok(Nil) =
    api.put_fact(
      rt,
      "review/findings",
      json.Array(list.append(second, [json.String("jail.gleam:7")])),
    )
  // One finding, not two. Nothing refused; the first append is simply
  // gone.
  let assert Ok(Some(json.Array(kept))) = api.fact(rt, "review/findings")
  assert kept == [json.String("jail.gleam:7")]
  process.kill(rt.tree.supervisor)
}

// The extension memory namespace is closed to the model's own door.
//
// `ext/<name>/<key>` cells are an installed extension's durable memory,
// written by the seam under a prefix the harness composes. The model
// reaches `put_fact` through the blackboard tool — which additionally
// pins every key under `agent/` — and `facts` through its listing, so
// both halves of the reservation are asserted here: a write is refused
// by name, and a listing does not carry a cell the harness wrote.
pub fn put_fact_refuses_the_extension_memory_prefix_test() {
  let rt = fact_runtime()
  let assert Error(api.ReservedFactKey(key: "ext/web-search/last")) =
    api.put_fact(rt, "ext/web-search/last", json.String("forged"))
    as "an extension's memory cell is not the model's to write"

  // Nor by the compare-and-set door, which is the same reservation read
  // from the other side.
  let assert Error(api.ReservedFactKey(key: "ext/web-search/last")) =
    api.put_fact_expecting(
      rt,
      "ext/web-search/last",
      json.String("forged"),
      expected: None,
    )
    as "the compare-and-set door is not a way into the namespace either"

  // And what the harness wrote there is not listed to a reader of the
  // ordinary blackboard.
  let assert Ok(Nil) =
    api.put_reserved_fact(rt, "ext/web-search/last", json.String("kept"))
    as "the harness door writes the same key"
  let assert Ok(listed) = api.facts(rt, prefix: None)
    as "the blackboard must list"
  assert !list.any(listed, fn(cell) { cell.0 == "ext/web-search/last" })
  process.kill(rt.tree.supervisor)
}

// A background job's durable record is closed to the model's own door.
//
// The `job/<id>` cell is the only evidence a background job exists: its
// state field is what a poll renders and what the restart sweep filters
// on. A model that could write here could mark its own job terminal, so
// the sweep skips a process that is still running and nothing ever reaps
// it — or hide a running job from the listing that is the only way anyone
// learns of one. Both halves of the reservation are asserted: the
// predicate names the prefix, and both write doors refuse it.
pub fn put_fact_refuses_the_job_prefix_test() {
  let rt = fact_runtime()
  assert api.reserved_fact_key("job/abc")
  assert api.reserved_fact_key(api.job_fact_prefix)
  assert !api.reserved_fact_key("agent/main/job")

  let assert Error(api.ReservedFactKey(key: "job/abc")) =
    api.put_fact(rt, "job/abc", json.String("forged"))
    as "a job record is not the model's to write"

  // Nor by the compare-and-set door, which is the same reservation read
  // from the other side.
  let assert Error(api.ReservedFactKey(key: "job/abc")) =
    api.put_fact_expecting(rt, "job/abc", json.String("forged"), expected: None)
    as "the compare-and-set door is not a way into the namespace either"

  // And what the harness wrote there is not listed to a reader of the
  // ordinary blackboard, so a job cannot be found — or renamed — through
  // the model's own view of the cells.
  let assert Ok(Nil) = api.put_reserved_fact(rt, "job/abc", json.String("kept"))
    as "the harness door writes the same key"
  let assert Ok(listed) = api.facts(rt, prefix: None)
    as "the blackboard must list"
  assert !list.any(listed, fn(cell) { cell.0 == "job/abc" })
  process.kill(rt.tree.supervisor)
}

// The advisor's two cells are closed to the model's own door.
//
// `advisor/feed/cursor` is the newest seq of the primary's branch the
// reviewer has been shown. A write of a large integer under it moves the
// reviewer past everything the primary will ever append, and the symptom
// is a session that is quietly unreviewed rather than an error anybody
// sees. The Agency blackboard already composes its keys from `agent/`
// and the caller's own strand name, so this is the second lock: forging
// a cursor takes two independent failures rather than one.
pub fn put_fact_refuses_the_advisor_prefix_test() {
  let rt = fact_runtime()
  assert api.reserved_fact_key("advisor/feed/cursor")
  assert api.reserved_fact_key(api.advisor_fact_prefix)
  assert !api.reserved_fact_key("agent/main/advisor")

  let assert Error(api.ReservedFactKey(key: "advisor/feed/cursor")) =
    api.put_fact(rt, "advisor/feed/cursor", json.Int(999_999))
    as "the feed cursor is not the model's to write"

  let assert Error(api.ReservedFactKey(key: "advisor/guard")) =
    api.put_fact_expecting(
      rt,
      "advisor/guard",
      json.String("forged"),
      expected: None,
    )
    as "the compare-and-set door is not a way into the namespace either"

  // And what the advisor actor wrote there is not listed to a reader of
  // the ordinary blackboard, so a model cannot find the cursor through
  // its own view of the cells either.
  let assert Ok(Nil) =
    api.put_reserved_fact(rt, "advisor/feed/cursor", json.Int(12))
    as "the harness door writes the same key"
  let assert Ok(listed) = api.facts(rt, prefix: None)
    as "the blackboard must list"
  assert !list.any(listed, fn(cell) { cell.0 == "advisor/feed/cursor" })
  process.kill(rt.tree.supervisor)
}

// The summarizer's labels are closed to the model's own door.
//
// A terminal draws `summary/<entry>/<block>` in place of a collapsed
// reasoning block, labelled as the summarizer's. A model that could write
// one would choose how the operator reads its own reasoning.
pub fn put_fact_refuses_the_summary_prefix_test() {
  let rt = fact_runtime()
  assert api.reserved_fact_key("summary/entry-1/0")
  assert api.reserved_fact_key(api.summary_fact_prefix)
  assert !api.reserved_fact_key("agent/main/summary")

  let assert Error(api.ReservedFactKey(key: "summary/entry-1/0")) =
    api.put_fact(rt, "summary/entry-1/0", json.String("forged"))
    as "a summary cell is not the model's to write"
  let assert Ok(Nil) =
    api.put_reserved_fact(rt, "summary/entry-1/0", json.String("written"))
    as "the harness door writes the same key"
  process.kill(rt.tree.supervisor)
}

// The goal loop's one cell is closed to the model's own door.
//
// `goal/state` is the session's persistent objective with its status
// and accounting (protocol 044). A forged write of a reset
// `tokens_used`, or of a `status` the model chose itself, is a model
// faking its own budget or waking itself in a loop — the same attack
// the advisor prefix stops, and the same two locks.
pub fn put_fact_refuses_the_goal_prefix_test() {
  let rt = fact_runtime()
  assert api.reserved_fact_key("goal/state")
  assert api.reserved_fact_key(api.goal_fact_prefix)
  assert !api.reserved_fact_key("agent/main/goal")

  let assert Error(api.ReservedFactKey(key: "goal/state")) =
    api.put_fact(rt, "goal/state", json.String("forged"))
    as "the goal cell is not the model's to write"

  // Nor by the compare-and-set door, which is the same reservation read
  // from the other side.
  let assert Error(api.ReservedFactKey(key: "goal/state")) =
    api.put_fact_expecting(
      rt,
      "goal/state",
      json.String("forged"),
      expected: None,
    )
    as "the compare-and-set door is not a way into the namespace either"

  // And what the advisor actor wrote there is not listed to a reader of
  // the ordinary blackboard, so a model cannot find the cell through
  // its own view of the cells either.
  let assert Ok(Nil) =
    api.put_reserved_fact(rt, "goal/state", json.String("kept"))
    as "the harness door writes the same key"
  let assert Ok(listed) = api.facts(rt, prefix: None)
    as "the blackboard must list"
  assert !list.any(listed, fn(cell) { cell.0 == "goal/state" })
  process.kill(rt.tree.supervisor)
}

// And the door that makes the concurrent case expressible: the same
// write with the seq it was read at asserted, so the loser is told it
// lost instead of never finding out.
pub fn put_fact_expecting_refuses_a_stale_write_test() {
  let rt = fact_runtime()
  let assert Ok(seeded) =
    api.put_fact_expecting(
      rt,
      "review/findings",
      json.Array([]),
      expected: None,
    )
    as "an absent cell is a legitimate expectation"
  // The same cell claimed twice from the same read: the first wins, the
  // second is refused with the key it lost on.
  let assert Ok(Some(api.FactCell(value: json.Array(items), seq:))) =
    api.fact_cell(rt, "review/findings")
  assert seq == seeded
  let assert Ok(_next) =
    api.put_fact_expecting(
      rt,
      "review/findings",
      json.Array(list.append(items, [json.String("auth.gleam:42")])),
      expected: Some(seq),
    )
  let assert Error(api.FactConflict(key: "review/findings")) =
    api.put_fact_expecting(
      rt,
      "review/findings",
      json.Array(list.append(items, [json.String("jail.gleam:7")])),
      expected: Some(seq),
    )
    as "a write from a stale read must be refused, not silently applied"
  // Re-read, re-decide, re-write: the whole point of being told.
  let assert Ok(Some(api.FactCell(value: json.Array(fresh), seq: moved))) =
    api.fact_cell(rt, "review/findings")
  let assert Ok(_final) =
    api.put_fact_expecting(
      rt,
      "review/findings",
      json.Array(list.append(fresh, [json.String("jail.gleam:7")])),
      expected: Some(moved),
    )
  let assert Ok(Some(json.Array(both))) = api.fact(rt, "review/findings")
  assert both == [json.String("auth.gleam:42"), json.String("jail.gleam:7")]
  // It is the same door, not a wider one: reserved keys are refused
  // here exactly as they are to `put_fact`.
  let assert Error(api.ReservedFactKey(key: "escalation/esc-1")) =
    api.put_fact_expecting(
      rt,
      "escalation/esc-1",
      json.String("forged"),
      expected: None,
    )
    as "the compare-and-set door is not a way past the reservations"
  process.kill(rt.tree.supervisor)
}

// --- steer_marking ---------------------------------------------------------

// The whole point of the door: the item and the claim are one commit, so
// there is no order in which a crash can leave one without the other.
pub fn steer_marking_queues_the_item_and_writes_the_mark_test() {
  let rt = marking_runtime()
  let assert Ok(op) = api.accept_quietly(rt, [fake.user("Hello")])
    as "acceptance must succeed"
  let assert Ok(_entry) =
    api.steer_marking(rt, fake.user("injected"), mark: claim("r"))
    as "the marked admission must land"
  assert steer_count(rt, op) == 1
  let assert Ok(Some(json.String("r"))) = api.fact(rt, mark_key("r"))
    as "the mark must be durable"
  process.kill(rt.tree.supervisor)
}

// The exactly-once property, at the level the property lives: a second
// claim on the same cell is refused *and queues nothing*. Without the
// `None` expectation the second admission would simply succeed, and an
// injector that re-derived the same decision after a restart would put a
// second copy of the same text into the conversation.
pub fn steer_marking_refuses_a_second_claim_on_the_same_mark_test() {
  let rt = marking_runtime()
  let assert Ok(op) = api.accept_quietly(rt, [fake.user("Hello")])
    as "acceptance must succeed"
  let assert Ok(_entry) =
    api.steer_marking(rt, fake.user("injected"), mark: claim("r"))
    as "the first claim must land"
  let assert Error(api.FactConflict(key:)) =
    api.steer_marking(rt, fake.user("injected again"), mark: claim("r"))
    as "a second claim on a taken mark must be refused"
  assert key == mark_key("r")
  // The refusal is a refusal of the whole transaction: one item on the
  // queue, not two.
  assert steer_count(rt, op) == 1
  process.kill(rt.tree.supervisor)
}

// A stale mark is not the seq race the admission ladder exists for, so
// it must not be retried into a `RaceLost` that names the wrong cause —
// and a *different* mark on the same run is admitted normally, which is
// what shows the refusal above was about the cell and not about the run.
pub fn steer_marking_admits_a_different_mark_on_the_same_run_test() {
  let rt = marking_runtime()
  let assert Ok(op) = api.accept_quietly(rt, [fake.user("Hello")])
    as "acceptance must succeed"
  let assert Ok(_first) =
    api.steer_marking(rt, fake.user("one"), mark: claim("first"))
    as "the first claim must land"
  let assert Ok(_second) =
    api.steer_marking(rt, fake.user("two"), mark: claim("second"))
    as "a claim on another cell must land"
  assert steer_count(rt, op) == 2
  process.kill(rt.tree.supervisor)
}

// The two write paths stay disjoint. This door writes reserved cells for
// harness code; an ordinary fact belongs to `put_fact`, and letting a
// caller reach one through the other would make the reservation
// decorative.
pub fn steer_marking_refuses_an_unreserved_key_test() {
  let rt = marking_runtime()
  let assert Ok(op) = api.accept_quietly(rt, [fake.user("Hello")])
    as "acceptance must succeed"
  let assert Error(api.UnreservedFactKey(key: "agent/main/note")) =
    api.steer_marking(
      rt,
      fake.user("injected"),
      mark: api.Mark(key: "agent/main/note", value: json.String("r")),
    )
    as "an unreserved mark must be refused"
  assert steer_count(rt, op) == 0
  process.kill(rt.tree.supervisor)
}

// An idle strand refuses the admission — and, because the mark rides in
// the same transaction, spends nothing. A claim that was written while
// its message was refused would be the worst of both: the injector would
// believe it had fired, and nothing would ever have been injected.
pub fn steer_marking_on_an_idle_strand_spends_no_claim_test() {
  let rt = marking_runtime()
  let assert Error(api.QueueRejected(reason: queue.NoActiveRun)) =
    api.steer_marking(rt, fake.user("injected"), mark: claim("r"))
    as "an idle strand has nothing to steer"
  let assert Ok(None) = api.fact(rt, mark_key("r"))
    as "a refused admission must leave the claim unspent"
  process.kill(rt.tree.supervisor)
}

// An admission reads the strand's current operation and then that
// operation's definition and state, three reads, while the terminal
// transaction clears the first and deletes the other two together. A run that
// finishes between the reads leaves an identity with nothing under it. That
// is a lost race, so the admission retries and then says `RaceLost`; it was
// once `ReadFailed`, which reads as a corrupt store and made a message sent as
// a run ended fail. The test leaves exactly that state, which the machine
// never leaves for longer than a read, and shows both doors classify it as a
// race and spend no claim.
pub fn an_operation_that_finished_between_the_reads_is_a_lost_race_test() {
  let rt = marking_runtime()
  let assert Ok(op) = api.accept_quietly(rt, [fake.user("Hello")])
    as "acceptance must succeed"
  let key = ids.op_id_to_string(op)
  let assert Ok(_) =
    writer.commit(
      rt.tree.writer,
      Tx(
        writes: [
          DeleteRegister(ns: register.OpMeta, key:),
          DeleteRegister(ns: register.OpState, key:),
        ],
        expected: [],
      ),
    )
    as "the terminal cleanup's deletions must land"
  let assert Error(api.RaceLost) = api.steer(rt, fake.user("late"))
    as "a steer that meets the stale identity is a lost race"
  let assert Error(api.RaceLost) =
    api.steer_marking(rt, fake.user("late"), mark: claim("late"))
    as "so is a marking steer"
  let assert Ok(None) = api.fact(rt, mark_key("late"))
    as "and it spends no claim"
  process.kill(rt.tree.supervisor)
}

// --- send_to_strand_marking -------------------------------------------

// Exactly-once on the fresh-run door: an idle strand's send takes the
// accept-quietly-marking path, and the mark lands in the same commit as
// the accepted run — the same guarantee `steer_marking` gives the steer
// door, applied to the door that had no marking equivalent before this.
pub fn send_to_strand_marking_starts_a_fresh_run_and_writes_the_mark_test() {
  let rt = marking_runtime()
  let assert Ok(api.Started(operation: _op)) =
    api.send_to_strand_marking(
      rt,
      to: "main",
      message: fake.user("wake up"),
      mark: claim("wake"),
    )
    as "an idle strand must accept a fresh run"
  let assert Ok(Some(json.String("wake"))) = api.fact(rt, mark_key("wake"))
    as "the mark must be durable"
  assert harness.final_projection(rt.session) == ["user:wake up"]
    as "the accepted run must actually hold the message"
  process.kill(rt.tree.supervisor)
}

// The exactly-once property traced through the real reconciliation: the
// first attempt opens the run, so the second attempt's `steer_marking`
// finds an *open* run rather than `NoActiveRun` and never falls back to
// `accept_quietly_marking` at all. It is the mark's own stale
// expectation on that steer commit — not a race against the strand —
// that refuses it, and the refusal is of the whole transaction, so no
// second copy of the message reaches the run's queue.
pub fn send_to_strand_marking_a_second_time_is_refused_and_does_not_double_start_test() {
  let rt = marking_runtime()
  let mark = claim("wake")
  let assert Ok(api.Started(operation: op)) =
    api.send_to_strand_marking(
      rt,
      to: "main",
      message: fake.user("wake up"),
      mark:,
    )
    as "the first attempt must start a fresh run"
  let assert Error(api.FactConflict(key:)) =
    api.send_to_strand_marking(
      rt,
      to: "main",
      message: fake.user("wake up again"),
      mark:,
    )
    as "the second attempt must meet the mark already spent, via a steer"
  assert key == mark_key("wake")
  assert steer_count(rt, op) == 0
    as "the refused transaction must not have queued a second copy"
  process.kill(rt.tree.supervisor)
}

// An already-open run steers exactly like a direct `steer_marking` call:
// the fresh-run fallback never triggers because `NoActiveRun` never
// fires, so this door behaves identically to the one it wraps whenever
// there is a run to steer onto.
pub fn send_to_strand_marking_steers_an_open_run_test() {
  let rt = marking_runtime()
  let assert Ok(op) = api.accept_quietly(rt, [fake.user("Hello")])
    as "acceptance must succeed"
  let assert Ok(api.Steered(entry: _)) =
    api.send_to_strand_marking(
      rt,
      to: "main",
      message: fake.user("also this"),
      mark: claim("wake"),
    )
    as "an open run must be steered, not accepted"
  assert steer_count(rt, op) == 1
  let assert Ok(Some(json.String("wake"))) = api.fact(rt, mark_key("wake"))
    as "the mark must be durable"
  process.kill(rt.tree.supervisor)
}

// `send_to_strand_marking` is its own entry point and carries its own
// reserved-key guard rather than trusting `accept_quietly_marking`, which
// has none (it trusts its own caller, like `accept_quietly`). A refused
// guard must leave the idle strand untouched.
pub fn send_to_strand_marking_refuses_an_unreserved_key_test() {
  let rt = marking_runtime()
  let assert Error(api.UnreservedFactKey(key: "agent/main/note")) =
    api.send_to_strand_marking(
      rt,
      to: "main",
      message: fake.user("wake up"),
      mark: api.Mark(key: "agent/main/note", value: json.String("wake")),
    )
    as "an unreserved mark must be refused"
  // Nothing was queued or started: the strand is still idle enough to
  // accept a fresh run cleanly.
  let assert Ok(_op) = api.accept_quietly(rt, [fake.user("Hello")])
    as "the guard must have refused before touching admission"
  process.kill(rt.tree.supervisor)
}

// `accept_quietly_marking` is a building block `send_to_strand_marking`
// calls, but it guards the same requirement itself rather than trusting
// its caller — a second caller added later must not be able to skip it.
pub fn accept_quietly_marking_refuses_an_unreserved_key_test() {
  let rt = marking_runtime()
  let assert Error(api.UnreservedFactKey(key: "agent/main/note")) =
    api.accept_quietly_marking(
      rt,
      [fake.user("Hello")],
      api.Mark(key: "agent/main/note", value: json.String("wake")),
    )
    as "an unreserved mark must be refused"
  let assert Ok(None) = api.fact(rt, "agent/main/note")
    as "a refused admission must leave the claim unspent"
  process.kill(rt.tree.supervisor)
}

fn mark_key(rule: String) -> String {
  api.rule_fact_prefix <> "fired/main/" <> rule
}

fn claim(rule: String) -> api.Mark {
  api.Mark(key: mark_key(rule), value: json.String(rule))
}

// How many steer items the operation's durable inbox holds.
fn steer_count(rt: api.Runtime, op: ids.OpId) -> Int {
  case session.op_state(rt.session, op) {
    Ok(Some(session.Cell(
      value: operation.RunState(inbox: operation.Inbox(steer:, ..), ..),
      ..,
    ))) -> list.length(steer)
    _ -> -1
  }
}

// A runtime whose provider never settles, so the run it accepts stays
// open for as long as the test needs one to steer.
fn marking_runtime() -> api.Runtime {
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

// A runtime with nothing driving it: these two are about the durable
// cell, not about a run.
fn fact_runtime() -> api.Runtime {
  fact_runtime_observed(fn(_) { Nil })
}

fn fact_runtime_observed(after_commit: fn(Int) -> Nil) -> api.Runtime {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(_spec) { fake.Reply(fake.answer("unused", 1)) },
      fn(_run) {
        fake.ToolReply(text: "unused", is_error: False, terminate: False)
      },
    )
  let assert Ok(rt) =
    api.open(
      sess,
      eff,
      api.Options(..api.default_options(harness.configuration()), after_commit:),
    )
    as "the session tree must boot"
  rt
}

/// Unobserved durable commitment still crashes a projected-handle caller.
///
/// ## Examples
///
/// ```gleam
/// // The writer is killed after storage commits but before it sends a reply.
/// ```
pub fn projected_fact_handle_does_not_retry_uncertain_commit_test() {
  let armed = recorder.start()
  let committed = process.new_subject()
  let release = process.new_subject()
  let rt =
    fact_runtime_observed(fn(_) {
      case recorder.read(armed, "armed") {
        0 -> Nil
        _ -> {
          process.send(committed, Nil)
          process.receive_forever(release)
        }
      }
    })
  let facts = api.fact_handle(rt)
  let assert Ok(writer) = address.lookup(rt.tree.writer)
    as "the writer must resolve before the uncertain commit"
  let assert Ok(old) = process.subject_owner(writer)
    as "the writer owns the reply process"
  let _ = recorder.bump(armed, "armed")
  let key = "client/directory_access"
  let caller =
    weft.new([
      fn() {
        api.put_reserved_fact_expecting_with(
          facts,
          key,
          json.String("durable"),
          expected: None,
        )
      },
    ])
    |> weft.deadline(2000)
    |> weft.start_detached
  let assert Ok(Nil) = process.receive(committed, within: 1000)
    as "storage must commit before the writer loses its reply"
  process.kill(old)
  let assert weft.PulledOutcome(weft.Crashed(0, _)) = weft.pull(caller, 1000)
    as "an uncertain commit crashes instead of returning or retrying"
  assert weft.pull(caller, 1000) == weft.AllDelivered

  // The replacement serves the durable value once. Reading cannot turn the
  // lost acknowledgement into a second commit or erase the first one.
  assert poll.until(within: 1000, every: 5, attempt: fn() {
      case address.lookup(rt.tree.writer) {
        Ok(current) if current != writer -> poll.Done(Nil)
        Ok(_) | Error(Nil) -> poll.Retry
      }
    })
    == poll.Answered(Nil)
  let assert Ok(Some(cell)) = api.fact_cell_with(facts, key)
    as "the unobserved write must remain durable"
  assert cell.value == json.String("durable")
  assert api.close(rt) == Ok(Nil)
}

/// A projected fact door preserves CAS and resolves replacement writers.
///
/// ## Examples
///
/// ```gleam
/// // Run with scripts/test.sh runtime --match projected_fact_handle.
/// ```
pub fn projected_fact_handle_survives_replacement_and_retirement_test() {
  let rt = fact_runtime()
  let facts = api.fact_handle(rt)
  let key = "client/directory_access"
  assert api.fact_cell_with(facts, key) == Ok(None)
  assert api.put_reserved_fact_expecting_with(
      facts,
      "review/ordinary",
      json.Null,
      expected: None,
    )
    == Error(api.UnreservedFactKey("review/ordinary"))
  let assert Ok(first) =
    api.put_reserved_fact_expecting_with(
      facts,
      key,
      json.String("first"),
      expected: None,
    )
    as "the absent reserved fact must be claimed"

  // Suspending restart custody creates a deterministic unbound interval.
  // The retained handle must refuse before sending, then resolve the new
  // incarnation rather than keeping its old subject or PID.
  let assert Ok(subject) = address.lookup(rt.tree.writer)
    as "the original writer must resolve"
  let assert Ok(old) = process.subject_owner(subject)
    as "the original writer owns its subject"
  system.suspend(rt.tree.supervisor)
  process.kill(old)
  assert poll.until(within: 1000, every: 5, attempt: fn() {
      case address.lookup(rt.tree.writer) {
        Error(Nil) -> poll.Done(Nil)
        Ok(_) -> poll.Retry
      }
    })
    == poll.Answered(Nil)
  assert api.fact_cell_with(facts, key) == Error(api.RuntimeUnavailable)
  assert api.put_reserved_fact_expecting_with(
      facts,
      key,
      json.String("gap"),
      expected: Some(first),
    )
    == Error(api.RuntimeUnavailable)
  system.resume(rt.tree.supervisor)
  assert poll.until(within: 1000, every: 5, attempt: fn() {
      case address.lookup(rt.tree.writer) {
        Error(Nil) -> poll.Retry
        Ok(subject) ->
          case process.subject_owner(subject) {
            Ok(pid) if pid != old -> poll.Done(Nil)
            Ok(_) | Error(Nil) -> poll.Retry
          }
      }
    })
    == poll.Answered(Nil)

  assert api.fact_cell_with(facts, key)
    == Ok(Some(api.FactCell(json.String("first"), first)))
  let assert Ok(second) =
    api.put_reserved_fact_expecting_with(
      facts,
      key,
      json.String("second"),
      expected: Some(first),
    )
    as "the retained capability must write through the replacement"
  assert second > first
  assert api.put_reserved_fact_expecting_with(
      facts,
      key,
      json.String("stale"),
      expected: Some(first),
    )
    == Error(api.FactConflict(key))
  assert api.put_reserved_fact_expecting_with(
      facts,
      key,
      json.String("absent"),
      expected: None,
    )
    == Error(api.FactConflict(key))
  assert api.fact_cell_with(facts, key)
    == Ok(Some(api.FactCell(json.String("second"), second)))
  assert api.fact_cell(rt, key) == api.fact_cell_with(facts, key)
  assert api.close(rt) == Ok(Nil)
  assert api.fact_cell_with(facts, key) == Error(api.RuntimeUnavailable)
  assert api.put_reserved_fact_expecting_with(
      facts,
      key,
      json.Null,
      expected: Some(second),
    )
    == Error(api.RuntimeUnavailable)

  // A new session namespace cannot revive a retired capability. Use the
  // fresh cell's current sequence for the old handle's write attempt, so a
  // stale-sequence refusal could not hide accidental routing to the new writer.
  let fresh = fact_runtime()
  let fresh_facts = api.fact_handle(fresh)
  assert fresh.tree.writer != rt.tree.writer
  assert api.fact_cell_with(fresh_facts, key) == Ok(None)
  let assert Ok(fresh_seq) =
    api.put_reserved_fact_expecting_with(
      fresh_facts,
      key,
      json.String("fresh"),
      expected: None,
    )
    as "the fresh capability must commit through its independent writer"
  assert api.fact_cell_with(facts, key) == Error(api.RuntimeUnavailable)
  assert api.put_reserved_fact_expecting_with(
      facts,
      key,
      json.String("retired handle write"),
      expected: Some(fresh_seq),
    )
    == Error(api.RuntimeUnavailable)
  assert api.fact_cell_with(fresh_facts, key)
    == Ok(Some(api.FactCell(json.String("fresh"), fresh_seq)))
  assert api.close(fresh) == Ok(Nil)
}

// The reserved side of the same compare-and-set, which is what lets a
// harness component mint a record under its own prefix exactly once: the
// second writer through the check-then-write gap is told it lost rather
// than silently overwriting the first (issue #162).
pub fn put_reserved_fact_expecting_claims_a_cell_once_test() {
  let rt = fact_runtime()
  let key = "schedule/config/main/poll"
  let assert Ok(_seq) =
    api.put_reserved_fact_expecting(
      rt,
      key,
      json.String("first"),
      expected: None,
    )
    as "an absent reserved cell is a legitimate expectation"
  let assert Error(api.FactConflict(key: conflicted)) =
    api.put_reserved_fact_expecting(
      rt,
      key,
      json.String("second"),
      expected: None,
    )
    as "a second claim against the same absent expectation must lose"
  assert conflicted == key
  let assert Ok(Some(json.String("first"))) = api.fact(rt, key)

  // Disjoint from the unreserved door: an ordinary key is refused here
  // exactly as a reserved one is refused to `put_fact_expecting`.
  let assert Error(api.UnreservedFactKey(key: "review/findings")) =
    api.put_reserved_fact_expecting(
      rt,
      "review/findings",
      json.Null,
      expected: None,
    )
  process.kill(rt.tree.supervisor)
}

// The set form of the same retirement: everything under one prefix, in
// one transaction, and nothing outside it. The neighbour here shares a
// string prefix with the target (`hb` and `hb-2`), which is the mistake
// this door hands to its caller — a prefix is a path, and the namespace's
// owner is the only party that knows where its segments end.
pub fn delete_reserved_prefix_removes_exactly_the_prefix_test() {
  let rt = fact_runtime()
  let marks = ["schedule/fired/main/hb/0", "schedule/fired/main/hb/60"]
  let neighbour = "schedule/fired/main/hb-2/0"
  let assert Ok(Nil) = api.put_reserved_fact(rt, neighbour, json.Null)
    as "the neighbour must be writable"
  list.each(marks, fn(key) {
    let assert Ok(Nil) = api.put_reserved_fact(rt, key, json.Null)
      as "each mark must be writable"
    Nil
  })

  assert api.delete_reserved_prefix(rt, prefix: "schedule/fired/main/hb/")
    == Ok(2)
  let assert Ok([]) = api.reserved_facts(rt, prefix: "schedule/fired/main/hb/")
    as "every cell under the prefix must be gone"
  let assert Ok(Some(json.Null)) = api.fact(rt, neighbour)
    as "a similarly named neighbour must survive"

  // Nothing under the prefix is success and commits nothing: the count
  // is the only observation left to make afterwards.
  assert api.delete_reserved_prefix(rt, prefix: "schedule/fired/main/hb/")
    == Ok(0)

  // Unreserved prefixes are refused here exactly as they are to every
  // other door on this side of the reservation, so this can never become
  // a bulk delete over the model-writable blackboard.
  assert api.delete_reserved_prefix(rt, prefix: "review/")
    == Error(api.UnreservedFactKey(key: "review/"))
  process.kill(rt.tree.supervisor)
}

// Retiring a reserved record leaves nothing behind for a prefix scan to
// read and discard, and frees the key to be claimed afresh (issue #164).
pub fn delete_reserved_fact_removes_the_cell_test() {
  let rt = fact_runtime()
  let key = "schedule/config/main/poll"
  let assert Ok(Nil) = api.put_reserved_fact(rt, key, json.String("live"))
  let assert Ok(Nil) = api.delete_reserved_fact(rt, key)
  let assert Ok(None) = api.fact(rt, key) as "a deleted cell reads as absent"
  let assert Ok([]) = api.reserved_facts(rt, prefix: "schedule/config/")
    as "a deleted cell leaves no tombstone under its prefix"

  // Already absent: the intent is met, so this is not an error.
  let assert Ok(Nil) = api.delete_reserved_fact(rt, key)

  // The key is free again, which is what a cancel-then-recreate needs.
  let assert Ok(_seq) =
    api.put_reserved_fact_expecting(
      rt,
      key,
      json.String("again"),
      expected: None,
    )
  let assert Error(api.UnreservedFactKey(key: "review/findings")) =
    api.delete_reserved_fact(rt, "review/findings")
  process.kill(rt.tree.supervisor)
}

// --- the queue read's blast radius -----------------------------------------

// `pending.entry` registers are keyed by entry id alone, with no strand
// in the key, so the admission path's queue read is a session-wide scan
// and one undecodable payload spoils the whole of it. Only a run
// consumes the queue — `accept_run` places the captured next-run items
// from those payloads — so a compaction or a navigation that read it
// would refuse on another strand's corruption over a value it never
// looks at (issue #70).
pub fn a_corrupt_queue_payload_only_refuses_a_run_admission_test() {
  let rt = answering_runtime()

  // One driven run, so the tree has an entry for the sibling strand to
  // fork at and `main` is idle again by the time the assertions run.
  let assert Ok(op) = api.prompt(rt, [fake.user("Hello")])
    as "the first prompt must be accepted"
  let assert Ok(outcome) = api.await_result(rt, op, within_ms: 5000)
    as "the run must complete"
  harness.assert_completed(outcome)
  let assert Ok(Some(anchor)) = api.leaf(rt)
    as "the completed run must leave a leaf to fork at"
  let assert Ok(Nil) =
    api.create_idle_strand(
      rt,
      named: "sub:1",
      configuration: harness.configuration(),
      at: Some(anchor),
    )
    as "the sibling strand must seed"

  // A queue payload no decoder can read. Nothing in the register names
  // the strand it belongs to, which is exactly why the read's failure
  // used to travel.
  let assert Ok(_committed) =
    writer.commit(
      rt.tree.writer,
      Tx(
        writes: [
          SetRegister(
            ns: register.PendingEntry,
            key: "corrupt-pending-item",
            value: register.value(json.String("not a pending entry")),
          ),
        ],
        expected: [],
      ),
    )
    as "the corrupt queue payload must land"

  // The run admission is the one that consumes the queue, so it must
  // still refuse rather than place a next-run item it cannot read.
  let assert Error(api.ReadFailed(reason: _)) =
    api.accept_quietly(rt, [fake.user("Again")])
    as "a run admission must still report the corrupt payload"

  // The sibling's navigation never reads the queue, and so is not the
  // corruption's business. Before the read was scoped this returned
  // `ReadFailed` too.
  let assert Ok(_navigation) =
    api.navigate(
      api.on_strand(rt, "sub:1"),
      to: None,
      summarize: False,
      label: None,
      custom_instructions: None,
      preparation: None,
    )
    as "a structural admission must not fail on another strand's queue"
  process.kill(rt.tree.supervisor)
}

// A runtime whose provider answers whatever it is asked, so a run
// accepted here reaches a terminal result and leaves the strand idle.
fn answering_runtime() -> api.Runtime {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(_spec) { fake.Reply(fake.answer("answered", 3)) },
      fn(_run) {
        fake.ToolReply(text: "unused", is_error: False, terminate: False)
      },
    )
  let assert Ok(rt) =
    api.open(sess, eff, api.default_options(harness.configuration()))
    as "the session tree must boot"
  rt
}

/// Writer subscribers belong to one restart specification, not every child.
/// Compare real started supervisors so the test covers OTP's stored inputs.
pub fn supervisor_restart_inputs_do_not_multiply_writer_options_test() {
  let small = supervisor_words_with_subscribers(0)
  let large = supervisor_words_with_subscribers(4096)
  let subscriber = writer.Direct(process.new_subject())
  let marker_words = ffi_memory.flat_words(list.repeat(subscriber, 4096))

  // OTP retains both the initial specifications and the active child map.
  // Only the writer entry in each may own this subscriber list.
  assert large - small >= marker_words
  assert large - small == marker_words * 2
}

fn supervisor_words_with_subscribers(count: Int) -> Int {
  let rec = recorder.start()
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
    as "the copy-size fixture must open"
  let eff =
    fake.effects(
      rec,
      clock.fixed(at: 1000),
      [],
      fn(_) { fake.Reply(fake.answer("done", 1)) },
      fn(_) {
        fake.ToolReply(text: "unused", is_error: False, terminate: False)
      },
    )
  let options = api.default_options(harness.configuration())
  let assert Ok(rt) =
    api.open(
      sess,
      eff,
      api.Options(
        ..options,
        subscribers: list.repeat(writer.Direct(process.new_subject()), count),
      ),
    )
    as "the measured supervisor must start"
  let words = ffi_memory.flat_words(ffi_memory.state(rt.tree.supervisor, 1000))
  let assert Ok(Nil) = api.close(rt) as "the measured tree must close"
  words
}
