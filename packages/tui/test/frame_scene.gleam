//// Whole terminal frames built from durable entries, for tests and for
//// review renders.
////
//// A render test that paints one widget onto a blank buffer shows the
//// widget, not the screen a person sees: the header, the transcript, the
//// composer and the agent strip around it are what make a layout read as
//// finished or not. This module builds a model the way an attached session
//// does — a list of conversation entries goes through the shipped capture
//// decoder and the terminal's own channel update — and paints the full
//// frame at a given size through `render.render_frame`. A test asserts on
//// the result; a review run writes it out with its colour
//// (`write_styled`) for a person or a design critic to look at.
////
//// Entries are numbered by the caller: `n` is both the durable sequence and
//// the seed of the entry's identity, so a scene reads in the order it is
//// written and a call and its result can be paired by hand.

import core/clock
import core/codec as core_codec
import core/entry
import core/ids
import core/json
import core/message
import core/register
import etui/backend
import etui/buffer.{type Buffer}
import etui/geometry
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/codec
import machine/strand
import session_view/model as session_model
import session_view/session_channel
import session_view/snapshot
import session_view/snapshot_view
import simplifile
import tui
import tui/connection
import tui/inbound
import tui/model as tui_model
import tui/render
import tui/workspace

/// How a tool call ended, for `result`.
pub type Ending {
  /// The tool returned its output.
  Succeeded

  /// The tool returned an error.
  Errored
}

/// A terminal model on a fixed clock, before any session is attached.
///
/// ## Examples
///
/// ```gleam
/// let model = frame_scene.model()
/// ```
pub fn model() -> tui_model.Model {
  tui.new_model_with_clock(
    connection.new_inbox(),
    workspace.Context("/Users/operator/code/pi-gui", Some("main")),
    fn() { 0 },
  )
}

/// Attaches `entries`, oldest first, as main's whole retained history.
///
/// The entries go through `snapshot_view.decode` and the terminal's own
/// `Captured` update, so the transcript they draw is the one an attached
/// session would draw, folds and collapses included.
///
/// ## Examples
///
/// ```gleam
/// let model =
///   frame_scene.attach(frame_scene.model(), "fix readme badge", [
///     frame_scene.user(1, "Fix the badge"),
///   ])
/// ```
pub fn attach(
  base: tui_model.Model,
  session: String,
  entries: List(entry.Entry),
) -> tui_model.Model {
  let entries = chained(entries)
  let leaf = case list.last(entries) {
    Ok(last) -> ids.entry_id_to_string(last.id)
    Error(Nil) -> ""
  }
  let cells = [
    cell(
      register.StrandConfig,
      "main",
      1,
      codec.encode_configuration(
        strand.StrandConfiguration(
          strand.ModelIdentity("baseten", "moonshotai/Kimi-K3"),
          strand.ThinkingLow,
          ["fs_read"],
        ),
      ),
    ),
    cell(register.StrandLeaf, "main", 2, json.String(leaf)),
    cell(
      register.StrandState,
      "main",
      2,
      codec.encode_strand_state(strand.StrandState(None, [])),
    ),
  ]
  let metadata =
    json.Object([
      #("cells", json.Array(cells)),
      #("message_count", json.Int(list.length(entries))),
      #("usage", core_codec.encode_usage(base.shared.usage)),
      #(
        "host_run_settings",
        json.Object([
          #("queue_mode", json.String("one_at_a_time")),
          #("tool_execution", json.String("parallel")),
          #("origin", json.Null),
        ]),
      ),
      #("peers", json.Array([])),
      #("pending_inputs", json.Array([])),
    ])
  let captured =
    snapshot.Captured(
      snapshot.Attachment(
        snapshot.Expected(session, "scene", "scene"),
        "scene",
        message.Origin("operator", "Operator"),
        snapshot.Owner,
      ),
      list.length(entries) + 10,
      metadata,
      snapshot.Window(
        entries
          |> list.map(fn(value) { snapshot.Loaded(value, 0) })
          |> list.reverse,
        0,
        None,
      ),
      None,
    )
  let assert Ok(view) = snapshot_view.decode(captured)
    as "a scene must pass the shipped capture decoder"
  tui_model.Model(
    ..base,
    shared: session_model.Shared(
      ..base.shared,
      session:,
      strands: [],
      transcript: [],
      current_model: "moonshotai/Kimi-K3",
      // The demo model's own notice describes the demo, not the scene, and
      // an attached session would have replaced it.
      notice: "",
      // A scene's clock is UTC, so a message heading shows the time it was
      // admitted in every zone a test or a render runs in.
      clock_offset: Some(0),
    ),
  )
  |> inbound.apply_channel_update(session_channel.Captured(
    captured,
    view,
    session_channel.Requested,
  ))
}

// Each entry's parent is the entry before it in the scene, which is the
// branch the transcript walks back from main's leaf. Numbering may skip, so
// the link is made here rather than from `n - 1`.
fn chained(entries: List(entry.Entry)) -> List(entry.Entry) {
  let #(linked, _) =
    list.fold(entries, #([], None), fn(acc, value) {
      let #(linked, parent) = acc
      let value = case value {
        entry.MessageEntry(..) -> entry.MessageEntry(..value, parent:)
        entry.CompactionEntry(..) -> entry.CompactionEntry(..value, parent:)
        entry.BranchSummaryEntry(..) ->
          entry.BranchSummaryEntry(..value, parent:)
        entry.CustomEntry(..) -> entry.CustomEntry(..value, parent:)
      }
      #([value, ..linked], Some(value.id))
    })
  list.reverse(linked)
}

fn cell(
  namespace: register.RegisterNs,
  key: String,
  seq: Int,
  value: json.JsonValue,
) -> json.JsonValue {
  json.Object([
    #("namespace", json.String(register.ns_to_string(namespace))),
    #("key", json.String(key)),
    #("seq", json.Int(seq)),
    #("value", value),
  ])
}

/// The durable identity of entry `n`.
///
/// ## Examples
///
/// ```gleam
/// let first = frame_scene.entry_id(1)
/// ```
pub fn entry_id(n: Int) -> ids.EntryId {
  ids.mint_entry(ids.generator(clock.fixed(n), n)).0
}

// An entry with no parent yet; `attach` links the scene into one branch.
fn record(n: Int, value: message.AgentMessage) -> entry.Entry {
  entry.MessageEntry(entry_id(n), None, n, n * 1000, value, False)
}

/// A prompt the operator typed.
///
/// ## Examples
///
/// ```gleam
/// let prompt = frame_scene.user(1, "Review the herdr update")
/// ```
pub fn user(n: Int, text: String) -> entry.Entry {
  record(n, message.UserMessage([message.UserText(text, None)], n, None))
}

/// A message another agent sent, admitted with `origin`: a peer session's
/// (`message.PeerOrigin`) or a sibling strand's (`message.StrandOrigin`).
/// The origin is what the transcript draws its heading from, so a scene
/// that wants a forged heading writes one into `text` instead.
///
/// ## Examples
///
/// ```gleam
/// let asked =
///   frame_scene.received(4, "Does it hold?", message.PeerOrigin("01a07d74", "main"))
/// ```
pub fn received(n: Int, text: String, origin: message.Origin) -> entry.Entry {
  record(
    n,
    message.UserMessage([message.UserText(text, None)], n, Some(origin)),
  )
}

/// An assistant response: its prose, then any calls (`call`).
///
/// ## Examples
///
/// ```gleam
/// let reply = frame_scene.assistant(2, "Reading the file.", [])
/// ```
pub fn assistant(
  n: Int,
  text: String,
  calls: List(message.AssistantBlock),
) -> entry.Entry {
  let prose = case text {
    "" -> []
    text -> [message.AssistantText(text, None)]
  }
  response(n, list.append(prose, calls), message.Stop, None)
}

/// A response the provider failed, drawn as its error row, as each retry of
/// a rate-limited request is.
///
/// ## Examples
///
/// ```gleam
/// let failed = frame_scene.provider_error(3, "provider returned http 429")
/// ```
pub fn provider_error(n: Int, text: String) -> entry.Entry {
  response(n, [], message.Errored, Some(text))
}

fn response(
  n: Int,
  content: List(message.AssistantBlock),
  stop: message.StopReason,
  error: option.Option(String),
) -> entry.Entry {
  record(
    n,
    message.AssistantMessage(
      content,
      "scene",
      "baseten",
      "moonshotai/Kimi-K3",
      None,
      None,
      None,
      model().shared.usage,
      stop,
      None,
      error,
      None,
      None,
      n * 1000,
    ),
  )
}

/// One tool call inside an assistant response.
///
/// ## Examples
///
/// ```gleam
/// let wait = frame_scene.call("c1", "agent_wait", [#("handles", json.Array([]))])
/// ```
pub fn call(
  id: String,
  name: String,
  arguments: List(#(String, json.JsonValue)),
) -> message.AssistantBlock {
  message.AssistantToolCall(message.ToolCall(
    id,
    name,
    json.Object(arguments),
    None,
    None,
  ))
}

/// The result answering call `id`.
///
/// ## Examples
///
/// ```gleam
/// let done = frame_scene.result(3, "c1", "fs_read", "ok", frame_scene.Succeeded)
/// ```
pub fn result(
  n: Int,
  id: String,
  name: String,
  text: String,
  ending: Ending,
) -> entry.Entry {
  record(
    n,
    message.ToolResultMessage(
      id,
      name,
      [message.ToolResultText(text, None)],
      None,
      None,
      None,
      ending == Errored,
      n * 1000,
    ),
  )
}

/// The result answering call `id`, with the structured `details` a tool
/// attaches beside its text, as `code_mode` does for its status and value.
///
/// ## Examples
///
/// ```gleam
/// let ran =
///   frame_scene.result_with(
///     3,
///     "c1",
///     "code_mode",
///     "ok",
///     json.Object([#("status", json.String("completed"))]),
///     frame_scene.Succeeded,
///   )
/// ```
pub fn result_with(
  n: Int,
  id: String,
  name: String,
  text: String,
  details: json.JsonValue,
  ending: Ending,
) -> entry.Entry {
  record(
    n,
    message.ToolResultMessage(
      id,
      name,
      [message.ToolResultText(text, None)],
      Some(details),
      None,
      None,
      ending == Errored,
      n * 1000,
    ),
  )
}

/// The result answering call `id` with `images`, each a media type and its
/// base64 bytes, as `fs_read` returns an image file.
///
/// ## Examples
///
/// ```gleam
/// let read = frame_scene.result_images(3, "r1", "fs_read", [#("image/png", data)])
/// ```
pub fn result_images(
  n: Int,
  id: String,
  name: String,
  images: List(#(String, String)),
) -> entry.Entry {
  record(
    n,
    message.ToolResultMessage(
      id,
      name,
      list.map(images, fn(image) {
        message.ToolResultImage(data: image.1, mime_type: image.0)
      }),
      None,
      None,
      None,
      False,
      n * 1000,
    ),
  )
}

/// The result answering `agent_send` call `id`, as the tool writes it:
/// `delivery` is `"steered"` when the message joined the recipient's open
/// run and `"started"` when it started one.
///
/// ## Examples
///
/// ```gleam
/// let admitted = frame_scene.delivered(5, "c2", "steered")
/// ```
pub fn delivered(n: Int, id: String, delivery: String) -> entry.Entry {
  record(
    n,
    message.ToolResultMessage(
      id,
      "agent_send",
      [message.ToolResultText("delivered", None)],
      Some(json.Object([#("delivery", json.String(delivery))])),
      None,
      None,
      False,
      n * 1000,
    ),
  )
}

/// The full frame the terminal paints for `model` at this size.
///
/// The model is resized first, as the terminal's own resize event would,
/// and the frame is painted afresh rather than read from a cache.
///
/// ## Examples
///
/// ```gleam
/// let frame = frame_scene.screen(frame_scene.model(), 120, 40)
/// ```
pub fn screen(model: tui_model.Model, width: Int, height: Int) -> Buffer {
  let model = tui.update(backend.Resize(width, height), model)
  let #(painted, _) =
    render.render_frame(model, geometry.rect_new(0, 0, width, height))
  painted
}

/// Writes a frame with its colour, one ANSI line per row, so a review
/// script can turn it into a picture.
///
/// ## Examples
///
/// ```gleam
/// // frame_scene.write_styled(frame, "/path/to/review/fixes-120.ansi")
/// ```
pub fn write_styled(frame: Buffer, path: String) -> Result(Nil, String) {
  simplifile.write(path, string.join(buffer.to_ansi_lines(frame), "\n"))
  |> result_text
}

fn result_text(
  outcome: Result(Nil, simplifile.FileError),
) -> Result(Nil, String) {
  case outcome {
    Ok(Nil) -> Ok(Nil)
    Error(error) -> Error(simplifile.describe_error(error))
  }
}
