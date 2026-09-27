//// A persistent terminal process driven through the shipped virtual loop.
////
//// Each driver creates its own model, inboxes, and real WebSocket connection.
//// The coordinator submits input and samples frames; it never receives or
//// fabricates gateway traffic. Between scripts the socket can keep sending
//// into terminal-owned inboxes, selected by its actor between scripts.
//// An already selected event is reduced directly before later queued traffic;
//// requeueing it into a concurrently written inbox could reverse wire order.
////
//// The actor selects on the mailboxes, which never return what the shipped
//// loop's runtime already received into the model's inboxes. Those held
//// messages are older than anything selected, so they are reduced first:
//// here for the connection inbox, and inside `attachment.accept` for the
//// candidate's frames.
////
//// It also selects every running job's messages, the attachment's
//// `Prepared` and outcomes among them, because an actor discards a message
//// its selector does not match. A selected message goes to `runtime.hold`,
//// exactly as one the runtime received would, and the settling ticks of the
//// next run take it from its slot. The candidate's frames inbox is known
//// only once its `Prepared` has been admitted, so a frame that reaches the
//// actor before that is discarded; before the lane subscribes the socket
//// sends only `Connected`, which the lane ignores.
////
//// A sample is not a server barrier: the test must wait for the condition
//// it needs, under a real deadline, before asserting convergence.

import etui/backend
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import tui
import tui/attachment
import tui/buffered
import tui/connection
import tui/frame
import tui/inbound
import tui/interaction
import tui/job
import tui/job_runner
import tui/model as tui_model
import tui/runtime
import tui/session_channel
import tui/virtual_backend
import tui/workspace
import weft/actor

/// Commands belong to one driver process, never to its socket's inbox.
pub opaque type Message {
  Play(events: List(backend.InputEvent), reply: Subject(Sample))
  Inbound(message: connection.Message)
  Candidate(message: connection.Message)
  Job(arrival: job.Arrival)
  Stop
}

type Driver {
  Driver(model: tui_model.Model, commands: Subject(Message))
}

/// The last model and complete frame from a bounded input script.
pub type Sample {
  Sample(
    /// The real client model after the script's settling ticks.
    model: tui_model.Model,
    /// The last rendered terminal grid, for assertions and diagnostics.
    frame: String,
  )
}

/// Starts an independent terminal and its real connection.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(driver) = tui_driver.start(address, token, "session")
/// ```
pub fn start(
  address: String,
  token: String,
  session: String,
) -> actor.StartResult(Subject(Message)) {
  start_recorded(address, token, session, "")
}

/// Starts the real post-launch recording path before any prepared frame is read.
///
/// ## Examples
///
/// ```gleam
/// // tui_driver.start_recorded(address, token, session, path)
/// ```
pub fn start_recorded(
  address: String,
  token: String,
  session: String,
  path: String,
) -> actor.StartResult(Subject(Message)) {
  actor.new_with_initialiser(10_000, fn(subject) {
    let inbox = connection.new_inbox()
    let model =
      tui.new_model_with_clock(
        inbox,
        workspace.Context(path: "/test/workspace", branch: None),
        fn() { -10_000 },
      )
      |> tui.connect_remote(inbox, address, session, token)
      |> tui.with_recording(path)

    // Refuse a failed handshake instead of exercising preview-mode echoes.
    case attachment.busy(model.candidate), model.peer, model.control_request {
      True, _, _ | False, tui_model.Attached(_), _ | _, _, Some(_) ->
        actor.initialised(Driver(model, subject))
        |> actor.selecting(selector(Driver(model, subject)))
        |> actor.returning(subject)
        |> Ok
      False, tui_model.Preview, None
      | False, tui_model.Replaying, None
      | False, tui_model.Disconnected, None
      -> Error(model.notice)
    }
  })
  |> actor.on_message(handle)
  |> actor.on_shutdown(fn(driver, _reason) { disconnect(driver.model) })
  |> actor.start
}

/// Applies terminal input and returns the last frame through the real loop.
///
/// An empty list samples pending gateway traffic without typing anything.
///
/// ## Examples
///
/// ```gleam
/// let snapshot = tui_driver.play(driver.data, [])
/// ```
pub fn play(
  driver: Subject(Message),
  events: List(backend.InputEvent),
) -> Sample {
  actor.call(driver, 5000, Play(events, _))
}

/// Requests a normal driver shutdown, including its socket close.
///
/// ## Examples
///
/// ```gleam
/// tui_driver.stop(driver.data)
/// ```
pub fn stop(driver: Subject(Message)) -> Nil {
  process.send(driver, Stop)
}

fn handle(driver: Driver, message: Message) -> actor.Next(Driver, Message) {
  let model = driver.model
  case message {
    Stop -> actor.stop()

    // The actor must select the socket inbox between scripts, or its
    // unexpected-message handler discards real frames before a TUI tick.
    // Re-deliver the selected message through the virtual loop so decoding
    // and recording still happen at the shipped client's normal boundary.
    // Each is applied outside `tui.update`, so the model is stamped first,
    // as `update` would: a reducer reads the time from the stamp, and the
    // driver may have idled since the last script.
    Inbound(message) -> {
      let model = runtime.stamp(model)
      let model =
        reduce_held(model)
        |> inbound.accept_connection_message(message)
      let run = run(model, [])
      continue(Driver(..driver, model: run.final))
    }
    Candidate(message) -> {
      let model = runtime.stamp(model)
      let run = run(interaction.accept_candidate_frame(model, message), [])
      continue(Driver(..driver, model: run.final))
    }
    Job(arrival) -> {
      let model = runtime.hold(runtime.stamp(model), arrival)
      let run = run(model, [])
      continue(Driver(..driver, model: run.final))
    }

    Play(events, reply) -> {
      let run = run(model, list.map(events, virtual_backend.Input))
      let drawn =
        list.last(run.frames)
        |> result.map(frame.buffer_to_text)
        |> result.unwrap("")
      process.send(reply, Sample(model: run.final, frame: drawn))
      continue(Driver(..driver, model: run.final))
    }
  }
}

fn selector(driver: Driver) {
  process.new_selector()
  |> process.select(driver.commands)
  |> process.select_map(buffered.sender(driver.model.inbox), Inbound)
  |> fn(selector) {
    attachment.select(driver.model.candidate, selector, Candidate)
  }
  |> process.merge_selector(process.map_selector(
    job_runner.selector(driver.model.running),
    Job,
  ))
}

// Reduces what the last script's runtime received and its steps left in the
// connection inbox. It takes only held messages and reads no mailbox: the
// message the actor just selected is newer than all of them and older than
// everything still queued, so it must go between the two.
fn reduce_held(model: tui_model.Model) -> tui_model.Model {
  case buffered.take(model.inbox) {
    #(_, Error(Nil)) -> model
    #(inbox, Ok(held)) ->
      tui_model.Model(..model, inbox:)
      |> inbound.accept_connection_message(held)
      |> reduce_held
  }
}

fn continue(driver: Driver) {
  actor.continue(driver) |> actor.with_selector(selector(driver))
}

fn run(
  model: tui_model.Model,
  steps: List(virtual_backend.Step),
) -> virtual_backend.Run(tui_model.Model) {
  let script =
    virtual_backend.script(
      backend.TerminalSize(width: model.width, height: model.height),
      steps,
      buffered.sender(model.inbox),
    )
  let assert Ok(run) = tui.run_script(model, script)
    as "the real virtual terminal loop must complete its input script"
  run
}

fn disconnect(model: tui_model.Model) -> Nil {
  let _ =
    runtime.flush(tui_model.emit_attachment(
      model,
      attachment.Abandon(model.candidate),
    ))
  case model.channel {
    Some(channel) -> {
      let #(_, outputs) =
        session_channel.take_outputs(session_channel.close(channel))
      list.each(outputs, session_channel.perform)
    }
    None ->
      case model.peer {
        tui_model.Attached(socket) -> connection.close(socket)
        tui_model.Preview | tui_model.Replaying | tui_model.Disconnected -> Nil
      }
  }
}
