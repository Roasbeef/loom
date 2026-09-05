//// A persistent terminal process driven through the shipped virtual loop.
////
//// Each driver creates its own model, inboxes, and real WebSocket connection.
//// The coordinator submits input and samples frames; it never receives or
//// fabricates gateway traffic. Between scripts the socket can keep sending
//// into the driver's ingress, selected by its actor between scripts.
//// Each selected message moves into a separate model inbox. That inbox has
//// no concurrent sender, so re-delivery cannot put a newer socket message
//// ahead of the message the actor already selected.
//// A sample is not a server barrier: the test must wait for the condition
//// it needs, under a real deadline, before asserting convergence.

import etui/backend
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None}
import gleam/result
import tui
import tui/connection
import tui/frame
import tui/virtual_backend
import tui/workspace
import weft/actor

/// Commands belong to one driver process, never to its socket's inbox.
pub opaque type Message {
  Play(events: List(backend.InputEvent), reply: Subject(Sample))
  Inbound(message: connection.Message)
  Stop
}

/// The last model and complete frame from a bounded input script.
pub type Sample {
  Sample(
    /// The real client model after the script's settling ticks.
    model: tui.Model,
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
  actor.new_with_initialiser(10_000, fn(subject) {
    let inbox = connection.new_inbox()
    let ingress = connection.new_inbox()
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_map(ingress, Inbound)
    let model =
      tui.new_model_with_clock(
        inbox,
        workspace.Context(path: "/test/workspace", branch: None),
        fn() { -10_000 },
      )
      |> tui.connect_remote(ingress, address, session, token)

    // Refuse a failed handshake instead of exercising preview-mode echoes.
    case model.peer {
      tui.Attached(_) ->
        actor.initialised(model)
        |> actor.selecting(selector)
        |> actor.returning(subject)
        |> Ok
      tui.Preview | tui.Replaying -> Error(model.notice)
    }
  })
  |> actor.on_message(handle)
  |> actor.on_shutdown(fn(model, _reason) { disconnect(model) })
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

fn handle(
  model: tui.Model,
  message: Message,
) -> actor.Next(tui.Model, Message) {
  case message {
    Stop -> actor.stop()

    // The actor must select the socket inbox between scripts, or its
    // unexpected-message handler discards real frames before a TUI tick.
    // Re-deliver the selected message through the virtual loop so decoding
    // and recording still happen at the shipped client's normal boundary.
    Inbound(message) -> {
      let run = run(model, [virtual_backend.Deliver(message)])
      actor.continue(run.final)
    }

    Play(events, reply) -> {
      let run = run(model, list.map(events, virtual_backend.Input))
      let drawn =
        list.last(run.frames)
        |> result.map(frame.buffer_to_text)
        |> result.unwrap("")
      process.send(reply, Sample(model: run.final, frame: drawn))
      actor.continue(run.final)
    }
  }
}

fn run(
  model: tui.Model,
  steps: List(virtual_backend.Step),
) -> virtual_backend.Run(tui.Model) {
  let script =
    virtual_backend.script(
      backend.TerminalSize(width: model.width, height: model.height),
      steps,
      model.inbox,
    )
  let assert Ok(run) = tui.run_script(model, script)
    as "the real virtual terminal loop must complete its input script"
  run
}

fn disconnect(model: tui.Model) -> Nil {
  case model.peer {
    tui.Attached(socket) -> connection.close(socket)
    tui.Preview | tui.Replaying -> Nil
  }
}
