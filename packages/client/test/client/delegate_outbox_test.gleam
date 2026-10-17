//// What a delegate session owes its parent, and the pass that sends it
//// (protocol-change/084, phase 2).
////
//// The rows are read back out of the session store after a restart by a drainer
//// that has only them to go on, so the codec is pinned both ways. The pass runs
//// against a real runtime and a laptop played by closures, so what is asserted is
//// what the session stored and what the laptop was asked, which is all the
//// guarantees are about: a row settles on an answer and never on age, a laptop
//// that is not connected is never dialed, and a glance is sent once.

import client/delegate_drain
import client/delegate_outbox.{type Mail, Mail}
import client/internal/ffi_os
import client/peer_outbox_drain
import client/remote_mail
import client/remote_spawn
import core/clock
import core/glance
import core/ids
import core/json
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None}
import runtime/api
import runtime/lineage
import simplifile
import support/notes_session
import telemetry/log
import tools/agent.{type Handle}

fn an_op(seed: Int) -> ids.OpId {
  let #(op, _generator) = ids.mint_op(ids.generator(clock.fixed(at: 0), seed:))
  op
}

fn a_child() -> Handle {
  agent.Handle(strand: "sub:^main/build-0123456789abcdef", operation: an_op(4))
}

fn a_row(id: String, state: delegate_outbox.State) -> Mail {
  Mail(
    id:,
    parent_strand: "main",
    child: a_child(),
    text: "all done: " <> id,
    state:,
  )
}

fn link() -> delegate_outbox.SpawnerLink {
  delegate_outbox.SpawnerLink(
    parent_session: "0198c0de-0000-7000-8000-000000000001",
    spawner: "laptop",
    node: "laptop@100.64.0.5",
  )
}

// A runtime on a private database file.
fn session(label: String) -> api.Runtime {
  let assert Ok(here) = simplifile.current_directory()
    as "locate the test workspace"
  let root =
    here
    <> "/build/delegate-outbox-"
    <> label
    <> "-"
    <> int.to_string(erlang_unique())
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "create the session directory"
  notes_session.open(root <> "/session.db", clock.fixed(1000)).runtime
}

// A path no earlier run used: the unique integer restarts with the VM, and a
// session file keeps its lease for thirty seconds after the run that held it.
fn erlang_unique() -> Int {
  ffi_os.system_time_ms() * 1000 + ffi_os.unique_positive_integer()
}

// --- the codec ----------------------------------------------------------------

pub fn a_mail_row_round_trips_in_every_state_test() {
  list.each(
    [
      delegate_outbox.Pending,
      delegate_outbox.Answered(remote_mail.Delivered),
      delegate_outbox.Answered(remote_mail.Declined(reason: "no run open")),
      delegate_outbox.Refused(reason: "the parent session has no record"),
    ],
    fn(state) {
      let row = a_row("7b1c", state)
      assert delegate_outbox.decode_mail(delegate_outbox.encode_mail(row))
        == Ok(row)
    },
  )
}

pub fn a_mail_row_that_does_not_decode_is_named_not_crashed_on_test() {
  assert delegate_outbox.decode_mail(json.Null)
    == Error("expected a mail row, got null")
  assert delegate_outbox.decode_mail(json.Object([])) == Error("missing `id`")
  let broken =
    json.Object([
      #("id", json.String("a")),
      #("parent", json.String("main")),
      #("child", json.String("c")),
      #("operation", json.String("not an operation")),
      #("text", json.String("t")),
    ])
  assert delegate_outbox.decode_mail(broken)
    == Error("expected `operation` to be an operation id")
  assert delegate_outbox.mail_key("7b1c") == "delegate/outbox/mail/7b1c"
}

// --- the rows -----------------------------------------------------------------

pub fn a_queued_row_is_written_once_and_a_replay_finds_it_test() {
  let runtime = session("queue")
  let row = a_row("7b1c", delegate_outbox.Pending)
  assert delegate_outbox.queue_mail(runtime, row) == Ok(Nil)
  assert delegate_outbox.queue_mail(runtime, row) == Ok(Nil)
  assert delegate_outbox.mail_rows(runtime)
    == Ok([#(delegate_outbox.mail_key("7b1c"), row)])

  // The same id with other text is another message under a spent id.
  assert delegate_outbox.queue_mail(runtime, Mail(..row, text: "different"))
    == Error("the message id was already used for a different message")
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_message_longer_than_a_message_may_be_is_refused_test() {
  let runtime = session("long")
  let long = Mail(..a_row("big", delegate_outbox.Pending), text: padded())
  assert delegate_outbox.queue_mail(runtime, long)
    == Error("the message is longer than a message may be")
  assert delegate_outbox.mail_rows(runtime) == Ok([])
  let assert Ok(Nil) = api.close(runtime)
}

fn padded() -> String {
  list.repeat("x", delegate_outbox.max_text_bytes + 1)
  |> list.fold("", fn(a, b) { a <> b })
}

// --- the pass -----------------------------------------------------------------

type Heard {
  Mailed(parent: remote_spawn.Parent, child: Handle, id: String, text: String)
  Glanced(parent: remote_spawn.Parent, child: Handle, at: Int)
}

// A laptop that is connected or not, answers each mail with `answer`, and
// reports everything it is asked.
fn laptop(
  connected connected: Bool,
  mail answer: fn(String) ->
    Result(Result(remote_mail.Receipt, remote_mail.ChildRefusal), Nil),
  progress progressed: Result(Result(Nil, remote_mail.ChildRefusal), Nil),
  heard heard: Subject(Heard),
) -> delegate_outbox.Laptop {
  delegate_outbox.Laptop(
    connected: fn() { connected },
    mail: fn(parent, child, id, text) {
      process.send(heard, Mailed(parent:, child:, id:, text:))
      answer(id)
    },
    progress: fn(parent, child, seen) {
      process.send(heard, Glanced(parent:, child:, at: seen.at))
      progressed
    },
  )
}

fn pass(
  runtime: api.Runtime,
  running running: Bool,
  laptop laptop: delegate_outbox.Laptop,
) -> peer_outbox_drain.Backlog {
  delegate_drain.pass(
    fn() { Ok(runtime) },
    fn() { running },
    link(),
    laptop,
    log.discard(),
  )()
}

fn owed() -> peer_outbox_drain.Backlog {
  peer_outbox_drain.Owed(peer_outbox_drain.Quick)
}

fn states(runtime: api.Runtime) -> List(delegate_outbox.State) {
  let assert Ok(rows) = delegate_outbox.mail_rows(runtime)
  list.map(rows, fn(row) { { row.1 }.state })
}

fn delivered(_id: String) {
  Ok(Ok(remote_mail.Delivered))
}

fn nothing_said() -> Result(Result(Nil, remote_mail.ChildRefusal), Nil) {
  Ok(Ok(Nil))
}

pub fn a_disconnected_laptop_is_never_asked_and_the_row_stays_owed_test() {
  let runtime = session("away")
  let assert Ok(Nil) =
    delegate_outbox.queue_mail(runtime, a_row("m1", delegate_outbox.Pending))
  let heard = process.new_subject()
  let away =
    laptop(connected: False, mail: delivered, progress: nothing_said(), heard:)
  assert pass(runtime, running: False, laptop: away) == owed()
  assert process.receive(heard, 0) == Error(Nil)
  assert states(runtime) == [delegate_outbox.Pending]
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_connected_laptop_that_answers_settles_the_row_and_the_pass_clears_test() {
  let runtime = session("answers")
  let assert Ok(Nil) =
    delegate_outbox.queue_mail(runtime, a_row("m1", delegate_outbox.Pending))
  let heard = process.new_subject()
  let up =
    laptop(connected: True, mail: delivered, progress: nothing_said(), heard:)
  assert pass(runtime, running: False, laptop: up) == peer_outbox_drain.Clear
  let assert Ok(Mailed(parent:, child:, id: "m1", text:)) =
    process.receive(heard, 0)
  assert parent
    == remote_spawn.Parent(session: link().parent_session, strand: "main")
  assert child == a_child()
  assert text == "all done: m1"
  assert states(runtime) == [delegate_outbox.Answered(remote_mail.Delivered)]

  // A settled row is not sent again, and stays.
  assert pass(runtime, running: False, laptop: up) == peer_outbox_drain.Clear
  assert process.receive(heard, 0) == Error(Nil)
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_declined_receipt_is_recorded_on_the_row_for_the_child_to_read_test() {
  let runtime = session("declined")
  let assert Ok(Nil) =
    delegate_outbox.queue_mail(runtime, a_row("m1", delegate_outbox.Pending))
  let declined = remote_mail.Declined(reason: "the parent has no run open")
  let heard = process.new_subject()
  let up =
    laptop(
      connected: True,
      mail: fn(_) { Ok(Ok(declined)) },
      progress: nothing_said(),
      heard:,
    )
  assert pass(runtime, running: False, laptop: up) == peer_outbox_drain.Clear
  assert states(runtime) == [delegate_outbox.Answered(declined)]
  let assert Ok(Nil) = api.close(runtime)
}

pub fn silence_leaves_every_row_pending_and_ends_the_pass_test() {
  let runtime = session("silent")
  let assert Ok(Nil) =
    delegate_outbox.queue_mail(runtime, a_row("m1", delegate_outbox.Pending))
  let assert Ok(Nil) =
    delegate_outbox.queue_mail(runtime, a_row("m2", delegate_outbox.Pending))
  let heard = process.new_subject()
  let quiet =
    laptop(
      connected: True,
      mail: fn(_) { Error(Nil) },
      progress: nothing_said(),
      heard:,
    )
  assert pass(runtime, running: False, laptop: quiet) == owed()

  // One attempt only: a laptop that did not answer the first is not asked the
  // second in the same pass, and a row never settles by age.
  let assert Ok(Mailed(..)) = process.receive(heard, 0)
  assert process.receive(heard, 0) == Error(Nil)
  assert states(runtime) == [delegate_outbox.Pending, delegate_outbox.Pending]
  let assert Ok(Nil) = api.close(runtime)
}

pub fn only_a_closed_parent_session_is_asked_again_test() {
  let runtime = session("refusals")
  let assert Ok(Nil) =
    delegate_outbox.queue_mail(runtime, a_row("m1", delegate_outbox.Pending))
  let assert Ok(Nil) =
    delegate_outbox.queue_mail(runtime, a_row("m2", delegate_outbox.Pending))
  let heard = process.new_subject()

  // The first is for a parent that is closed, the second for a child the laptop
  // has no record of.
  let up =
    laptop(
      connected: True,
      mail: fn(id) {
        case id {
          "m1" -> Ok(Error(remote_mail.ParentSessionNotOpen))
          _ -> Ok(Error(remote_mail.UnknownChild))
        }
      },
      progress: nothing_said(),
      heard:,
    )
  assert pass(runtime, running: False, laptop: up) == owed()
  assert states(runtime)
    == [
      delegate_outbox.Pending,
      delegate_outbox.Refused(remote_mail.describe_refusal(
        remote_mail.UnknownChild,
      )),
    ]
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_busy_laptop_leaves_the_row_pending_but_a_store_failure_settles_it_test() {
  let runtime = session("busy")
  let assert Ok(Nil) =
    delegate_outbox.queue_mail(runtime, a_row("m1", delegate_outbox.Pending))
  let assert Ok(Nil) =
    delegate_outbox.queue_mail(runtime, a_row("m2", delegate_outbox.Pending))
  let heard = process.new_subject()
  let up =
    laptop(
      connected: True,
      mail: fn(id) {
        case id {
          "m1" -> Ok(Error(remote_mail.Busy(reason: "holder not up")))
          _ ->
            Ok(
              Error(remote_mail.StoreFailure(
                reason: "id reused with other text",
              )),
            )
        }
      },
      progress: nothing_said(),
      heard:,
    )
  assert pass(runtime, running: False, laptop: up) == owed()
  let assert [delegate_outbox.Pending, delegate_outbox.Refused(..)] =
    states(runtime)
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_running_child_keeps_the_pass_owed_with_nothing_to_send_test() {
  let runtime = session("running")
  let heard = process.new_subject()
  let up =
    laptop(connected: True, mail: delivered, progress: nothing_said(), heard:)
  assert pass(runtime, running: True, laptop: up) == owed()
  assert pass(runtime, running: False, laptop: up) == peer_outbox_drain.Clear
  let assert Ok(Nil) = api.close(runtime)
}

// A child's lineage cell, and the glance of its current operation.
fn child_with_glance(runtime: api.Runtime, at: Int) -> Handle {
  let child = a_child()
  let assert Ok(Nil) =
    api.put_reserved_fact(
      runtime,
      lineage.register_key(child.strand),
      lineage.encode(lineage.Lineage(
        strand: child.strand,
        parent: "^main",
        depth: 1,
        minted_by: lineage.CallSite(
          operation: an_op(1),
          step_id: "step",
          source_index: 0,
        ),
        brief: child.operation,
        tools: [],
        default_within_ms: None,
        deadline: None,
        detached: True,
        reaped: False,
        orchestrator: None,
      )),
    )
  glance_at(runtime, child, at)
  child
}

fn glance_at(runtime: api.Runtime, child: Handle, at: Int) -> Nil {
  let assert Ok(Nil) =
    api.put_reserved_fact(
      runtime,
      glance.key(child.strand),
      glance.encode(glance.Glance(
        operation: ids.op_id_to_string(child.operation),
        title: "build",
        summary: "compiling",
        at:,
        tokens: 10,
      )),
    )
  Nil
}

pub fn the_newest_glance_is_sent_once_and_again_only_when_newer_test() {
  let runtime = session("progress")
  let child = child_with_glance(runtime, 1000)
  let heard = process.new_subject()
  let up =
    laptop(connected: True, mail: delivered, progress: nothing_said(), heard:)

  // The pass is owed after it, because nothing rings the drainer for the next
  // glance while the child runs.
  assert pass(runtime, running: True, laptop: up) == owed()
  let assert Ok(Glanced(parent:, child: sent, at: 1000)) =
    process.receive(heard, 0)
  assert parent.strand == "main"
  assert sent == child

  // The acknowledged glance is not sent again.
  let _ = pass(runtime, running: True, laptop: up)
  assert process.receive(heard, 0) == Error(Nil)

  // A newer one is.
  glance_at(runtime, child, 2500)
  let _ = pass(runtime, running: True, laptop: up)
  let assert Ok(Glanced(at: 2500, ..)) = process.receive(heard, 0)
  let assert Ok(Nil) = api.close(runtime)
}

pub fn an_unanswered_glance_is_not_acknowledged_and_a_disconnected_laptop_gets_none_test() {
  let runtime = session("progress-silent")
  let _child = child_with_glance(runtime, 1000)
  let heard = process.new_subject()
  let away =
    laptop(connected: False, mail: delivered, progress: nothing_said(), heard:)
  assert pass(runtime, running: True, laptop: away) == owed()
  assert process.receive(heard, 0) == Error(Nil)

  // The laptop is connected but does not answer: the glance stays unsent.
  let silent =
    laptop(connected: True, mail: delivered, progress: Error(Nil), heard:)
  assert pass(runtime, running: True, laptop: silent) == owed()
  let assert Ok(Glanced(at: 1000, ..)) = process.receive(heard, 0)
  assert pass(runtime, running: True, laptop: silent) == owed()
  let assert Ok(Glanced(at: 1000, ..)) = process.receive(heard, 0)
  let assert Ok(Nil) = api.close(runtime)
}

pub fn the_sessions_own_main_strand_is_not_a_child_whose_glance_is_sent_test() {
  let runtime = session("main")
  glance_at(runtime, agent.Handle(strand: "main", operation: an_op(2)), 5000)
  let heard = process.new_subject()
  let up =
    laptop(connected: True, mail: delivered, progress: nothing_said(), heard:)
  assert pass(runtime, running: False, laptop: up) == peer_outbox_drain.Clear
  assert process.receive(heard, 0) == Error(Nil)
  let assert Ok(Nil) = api.close(runtime)
}
