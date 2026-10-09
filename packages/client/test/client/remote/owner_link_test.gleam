//// The executor's owner link over a cut link, in one VM.
////
//// A typed-service background program ends on its first failed receive, so
//// the link must wait out a cut for the calls that are safe to send again and
//// deny the others at once (protocol-change/078, "A link cut and the program's
//// owner-bound calls"). A cut is reproduced without a second node: the link is
//// pointed at a subject whose owner is a pid of a node this VM is not connected
//// to, so every monitor of it fires `noconnection` at once and every send to it
//// is dropped, which is what an executor sees while its orchestrator is
//// unreachable. Re-pointing the link at a live port is the link coming back.

import broker/framing
import client/owner_services.{type OwnerCapCall}
import client/remote/owner_link
import client/remote/protocol.{type OwnerMessage}
import core/clock
import core/msgpack
import gleam/dynamic
import gleam/erlang/process.{type Subject}
import gleam/string
import support/internal/ffi_proc
import support/remote_fixtures as fixtures
import weft/poll

// A port subject whose owner is on a node nobody is connected to.
fn cut_port() -> Subject(OwnerMessage) {
  process.unsafely_create_subject(ffi_proc.remote_pid(), dynamic.nil())
}

// A live owner port that answers every capability call with `answer`.
fn live_port(answer: framing.CapOutcome) -> Subject(OwnerMessage) {
  let handed = process.new_subject()
  let _owner =
    process.spawn_unlinked(fn() {
      let inbox = process.new_subject()
      process.send(handed, inbox)
      serve_forever(inbox, answer)
    })
  let assert Ok(inbox) = process.receive(handed, 1000) as "the live port starts"
  inbox
}

fn serve_forever(
  inbox: Subject(OwnerMessage),
  answer: framing.CapOutcome,
) -> Nil {
  case process.receive_forever(inbox) {
    protocol.Capability(call: _, reply:) -> process.send(reply, Ok(answer))
    _other -> Nil
  }
  serve_forever(inbox, answer)
}

fn call(cap: String, within_ms: Int) -> OwnerCapCall {
  owner_services.OwnerCapCall(
    ..fixtures.capability_call(),
    step_id: "async/ab12",
    cap:,
    args: msgpack.MapValue([
      #(msgpack.StringValue("after"), msgpack.IntValue(0)),
      #(msgpack.StringValue("within_ms"), msgpack.IntValue(within_ms)),
    ]),
  )
}

fn capability(link: owner_link.Link) {
  owner_link.services(link, clock.fixed(at: 0)).capability
}

fn now() -> Int {
  poll.monotonic().now()
}

pub fn a_receive_waits_out_a_cut_and_reads_the_input_after_it_test() {
  let assert Ok(link) = owner_link.start(cut_port()) as "the link starts"
  let input = framing.CapOk(msgpack.StringValue("the next input"))

  // The orchestrator comes back after a while; the link is re-pointed at a
  // port that answers, as a reconnect or a rebound attach leaves it.
  let _repair =
    process.spawn_unlinked(fn() {
      process.sleep(300)
      owner_link.replace(link, live_port(input))
    })
  let started = now()
  assert capability(link)(call("execution.receive_enveloped", 5000))
    == Ok(input)
  assert now() - started >= 250
}

pub fn a_receive_whose_wait_runs_out_in_a_cut_hears_no_input_test() {
  let assert Ok(link) = owner_link.start(cut_port()) as "the link starts"

  // Nothing was delivered while the link was down, so the honest answer is
  // the timed-out receive, which a serving loop answers by asking again.
  assert capability(link)(call("execution.receive", 200))
    == Ok(framing.CapOk(msgpack.NilValue))
}

pub fn progress_waits_out_a_cut_too_test() {
  let assert Ok(link) = owner_link.start(cut_port()) as "the link starts"
  let observed = framing.CapOk(msgpack.IntValue(1))
  let _repair =
    process.spawn_unlinked(fn() {
      process.sleep(200)
      owner_link.replace(link, live_port(observed))
    })
  assert capability(link)(call("execution.progress", 0)) == Ok(observed)
}

pub fn a_call_that_could_act_twice_is_denied_at_once_in_a_cut_test() {
  let assert Ok(link) = owner_link.start(cut_port()) as "the link starts"
  let started = now()
  let assert Error(denial) = capability(link)(call("strand.spawn", 5000))
    as "a spawn is never sent twice"
  assert denial.code == owner_link.unavailable_code
  assert now() - started < 1000
}

pub fn a_port_that_is_gone_is_denied_at_once_even_for_a_receive_test() {
  // A port whose process exited on this node is gone, not cut off: the
  // session closed, and no wait brings it back.
  let gone = live_port(framing.CapOk(msgpack.NilValue))
  let assert Ok(owner) = process.subject_owner(gone) as "the port has an owner"
  process.kill(owner)
  let assert Ok(link) = owner_link.start(gone) as "the link starts"
  let started = now()
  let assert Error(denial) =
    capability(link)(call("execution.receive_enveloped", 5000))
    as "a gone port is denied"
  assert denial.code == owner_link.unavailable_code
  assert now() - started < 1000
}

pub fn a_launch_whose_answer_never_came_names_the_handle_test() {
  let assert Ok(link) = owner_link.start(cut_port()) as "the link starts"
  let terms = fixtures.execution_terms()
  let assert Error(text) =
    owner_link.services(link, clock.fixed(at: 0)).launch_execution(terms)
    as "an unanswered launch fails"
  assert string.contains(text, fixtures.handle_of(terms))
}

pub fn a_receive_waits_no_longer_than_the_owner_would_let_it_test() {
  // The owner refuses a receive that asks to wait more than thirty seconds, so
  // waiting out a cut for longer would end at the satellite's call timeout
  // with an error rather than "no input yet".
  assert owner_link.link_cut_wait_ms(call("execution.receive", 10_000_000))
    == owner_services.max_receive_wait_ms
  assert owner_link.link_cut_wait_ms(call("execution.receive_enveloped", 5000))
    == 5000
  assert owner_link.link_cut_wait_ms(call("execution.receive", -1)) == 0
  assert owner_link.link_cut_wait_ms(call("strand.spawn", 5000)) == 0
}
