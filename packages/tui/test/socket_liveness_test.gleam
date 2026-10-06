//// The host reads whether the adopted socket is alive; the step does not.
////
//// An attempt adopts its socket when the attachment job ends, and only if
//// the socket's actor is still alive. Before phase 3 of issue #530 the step
//// read that itself, the last process read left in it. Now the host reads
//// it when it hands the job's end to the attempt (`runtime.hold`), and the
//// attempt adopts or fails on the answer it was given. These tests pin
//// both halves with a stand-in socket whose owner process the test
//// controls: a socket that died before the host received the end fails the
//// attempt, and a socket that dies after the host received it, but before
//// the step, is still adopted, which a step that read the process itself
//// could not do.

import etui/backend
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{None}
import gleam/string
import session_view/snapshot
import tui
import tui/attachment
import tui/connection
import tui/job
import tui/model as tui_model
import tui/runtime
import tui/view_set
import tui/workspace
import tui_test/pushed
import weft

pub fn a_socket_dead_before_the_end_arrives_fails_the_attempt_test() {
  let #(owner, socket) = owned_socket()
  let #(captured, key) = captured_attempt(socket)
  stop(owner)

  let ended =
    runtime.hold(
      captured,
      job.AttachArrived(key, job.Settled(weft.AllDelivered)),
    )
  let settled = tui.update(backend.Tick, ended)

  assert !attachment.busy(settled.view.candidate)
  assert settled.shared.session != "A"
    as "a socket with no live actor is never adopted"
  assert list.any(settled.shared.transcript, fn(line) {
    string.contains(line.text, "the websocket actor exited before adoption")
  })
    as "the attempt fails with the reason the host read"
}

pub fn a_socket_that_dies_after_the_end_arrives_is_still_adopted_test() {
  let #(owner, socket) = owned_socket()
  let #(captured, key) = captured_attempt(socket)

  let ended =
    runtime.hold(
      captured,
      job.AttachArrived(key, job.Settled(weft.AllDelivered)),
    )
  stop(owner)
  let adopted = tui.update(backend.Tick, ended)

  assert !attachment.busy(adopted.view.candidate)
  assert adopted.shared.session == "A"
    as "the step adopts on the answer the host read, and reads no process"
}

// An attempt whose worker has published `socket` and whose first tick has
// captured the initial cut, which is the state in which the job's end
// decides adoption.
fn captured_attempt(
  socket: connection.Connection,
) -> #(tui_model.Model, job.Key) {
  let #(model, key) =
    tui_model.allocate_job(tui.new_model(
      connection.new_inbox(),
      workspace.Context("test", None),
    ))
  let frames = connection.new_inbox()
  list.each(pushed.transfer(1, "1:1", "recent", 10), process.send(frames, _))
  let prepared =
    job.Prepared(
      socket:,
      expected: snapshot.Expected("A", "epoch", "incarnation"),
      workspace: workspace.Context("test", None),
      session_name: "Session A",
      creation_key: None,
      acknowledgement: process.new_subject(),
      frames:,
    )
  let model =
    tui_model.Model(
      ..model,
      view: view_set.candidate(model.view, attachment.opening(key, None)),
    )
    |> runtime.hold(job.AttachArrived(key, job.Published(prepared)))
  let captured = tui.update(backend.Tick, model)
  assert attachment.busy(captured.view.candidate)
    as "premise: the attempt captured and waits for its job's end"
  #(captured, key)
}

// A stand-in socket whose actor is a process the test can stop. The socket
// handle names a subject that process owns, and liveness is read from the
// subject's owner.
fn owned_socket() -> #(Pid, connection.Connection) {
  let reply = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let own: Subject(Dynamic) = process.new_subject()
      process.send(reply, own)
      process.sleep_forever()
    })
  let assert Ok(own) = process.receive(reply, 1000)
    as "the owner process hands over its subject"
  #(owner, socket_on(own))
}

fn stop(owner: Pid) -> Nil {
  let monitor = process.monitor(owner)
  process.kill(owner)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
    as "the owner process is gone before the test goes on"
  Nil
}

@external(erlang, "effects_test_ffi", "socket_on")
fn socket_on(owner: Subject(Dynamic)) -> connection.Connection
