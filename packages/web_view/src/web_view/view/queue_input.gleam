//// A held message's inline editor, local to one operator page.
////
//// Excerpts are never editable documents. Opening asks the shared lane for
//// complete text, and saving compares the fetched revision. The browser owns
//// unsaved keystrokes in an uncontrolled textarea; server patches never echo
//// a value over them. A refused or uncertain save keeps that editor mounted.
//// Queue identity and namespace fence every request against attachment drift.

import gleam/dynamic/decode
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import session_view/model.{type Shared, Shared} as session_model
import session_view/outbound
import session_view/protocol
import session_view/queue_request
import session_view/queued_input
import session_view/session_channel
import session_view/snapshot_view
import session_view/surfaces
import session_view/transcript_lines
import web_view/view/live

/// One page's selected input and its full-document lifecycle.
pub type State {
  /// No input is selected.
  Closed

  /// Complete text is being fetched for this exact row and attachment.
  Loading(
    /// The exact server-rendered input selected for reading.
    row: snapshot_view.PendingInput,
    /// Attachment identity that must still own the read.
    owner: String,
    /// Stable daemon queue namespace, independent of reconnects.
    namespace: String,
  )

  /// Full text remains mounted until acknowledgement or explicit cancellation.
  Editing(
    /// The row identity and revision fetched for this editor.
    row: snapshot_view.PendingInput,
    /// Attachment that fetched this document.
    owner: String,
    /// Namespace which cannot be rebound after restart.
    namespace: String,
    /// Full authoritative text and retained attachment count.
    document: queued_input.Document,
    /// Last submitted text; unsent browser keystrokes stay in the DOM.
    text: String,
    /// Whether the fetched revision can be submitted again.
    delivery: Delivery,
    /// Status or refusal shown without replacing the draft.
    message: String,
  )
}

/// Whether another mutation may use the fetched revision.
pub type Delivery {
  /// The fetched revision has not been submitted.
  Ready

  /// The lane owns a mutation whose outcome is still pending.
  Saving

  /// The mutation may have committed; another save requires a new read.
  Unknown
}

/// Controls carry server-owned identities; only replacement text comes from the browser.
pub type Action {
  /// Fetch the complete document behind this drawn row.
  Open(row: snapshot_view.PendingInput)

  /// Close the editor and abandon any outstanding read.
  Cancel

  /// Replace the selected full document's text at its fetched revision.
  Save(text: String)

  /// Withdraw exactly the drawn revision from its queue.
  Remove(row: snapshot_view.PendingInput)
}

/// Applies a local action through the existing session lane.
///
/// ## Examples
///
/// ```gleam
/// // queue_input.act(state, shared, queue_input.Cancel)
/// ```
pub fn act(
  state: State,
  shared: Shared(s, r, a, b),
  action: Action,
) -> #(State, Shared(s, r, a, b)) {
  case action, state {
    Cancel, Editing(delivery: Saving, ..) -> #(state, shared)
    Cancel, _ -> #(Closed, Shared(..shared, queue_request: queue_request.new()))
    Open(row), Closed -> {
      // Verify queue availability before opening row input.
      case
        current(shared, row)
        && available(
          shared,
          session_model.queue_owner(shared),
          session_model.queue_namespace(shared),
        )
      {
        False -> #(state, shared)
        True -> {
          let owner = session_model.queue_owner(shared)
          let namespace = session_model.queue_namespace(shared)
          let request =
            queue_request.State(
              Some(queue_request.Fetch(owner, namespace, row.strand, row.id)),
              None,
              None,
            )
          #(
            Loading(row, owner, namespace),
            surfaces.service_queue_read(
              Shared(..shared, queue_request: request),
            ),
          )
        }
      }
    }
    Save(text), Editing(row, owner, namespace, document, _, Ready, _) -> {
      case
        available(shared, owner, namespace)
        && current(shared, row)
        && string.byte_size(text) <= 32_000
      {
        False -> #(
          Editing(
            row,
            owner,
            namespace,
            document,
            text,
            Ready,
            "Queue changed or command lane is busy; draft retained. Cancel and reopen to refresh.",
          ),
          shared,
        )
        True -> #(
          Editing(row, owner, namespace, document, text, Saving, "Saving…"),
          outbound.send_frame(
            shared,
            protocol.edit_queued_input(shared.next_id, document, text),
          ),
        )
      }
    }
    Remove(row), Closed -> {
      case
        current(shared, row)
        && available(
          shared,
          session_model.queue_owner(shared),
          session_model.queue_namespace(shared),
        )
      {
        False -> #(state, shared)
        True -> #(
          state,
          outbound.send_frame(
            shared,
            protocol.remove_queued_input(
              shared.next_id,
              row.strand,
              row.id,
              row.revision,
            ),
          ),
        )
      }
    }
    _, _ -> #(state, shared)
  }
}

/// Current helper.
fn current(
  shared: Shared(s, r, a, b),
  row: snapshot_view.PendingInput,
) -> Bool {
  session_model.presentation(shared)
  |> transcript_lines.held_inputs
  |> option.unwrap([])
  |> list.any(fn(item) {
    item.id == row.id
    && item.strand == row.strand
    && item.revision == row.revision
    && item.editing == snapshot_view.Editable
  })
}

/// Available helper.
fn available(
  shared: Shared(s, r, a, b),
  owner: String,
  namespace: String,
) -> Bool {
  case shared.channel {
    Some(channel) ->
      session_channel.mutation_available(channel)
      && session_model.queue_owner(shared) == owner
      && session_model.queue_namespace(shared) == namespace
    None -> False
  }
}

/// Adopts only the full reply matching the selected attachment and input.
///
/// ## Examples
///
/// ```gleam
/// // queue_input.notice(state, queue_request.Saved)
/// ```
pub fn notice(state: State, notice: queue_request.Notice) -> State {
  case state, notice {
    Loading(row, owner, namespace),
      queue_request.Received(got_owner, got_namespace, document)
      if owner == got_owner
      && namespace == got_namespace
      && row.id == document.id
      && row.strand == document.strand
    ->
      Editing(
        snapshot_view.PendingInput(..row, revision: document.revision),
        owner,
        namespace,
        document,
        document.text,
        Ready,
        "",
      )
    Loading(..), queue_request.Refused(_)
    | Loading(..), queue_request.Dropped(_)
    -> Closed
    Editing(..), queue_request.Saved -> Closed
    Editing(delivery: Unknown, ..), queue_request.Refused(_)
    | Editing(delivery: Unknown, ..), queue_request.Dropped(_)
    -> state
    Editing(row, owner, namespace, document, text, _, _),
      queue_request.Refused(reason)
    | Editing(row, owner, namespace, document, text, _, _),
      queue_request.Dropped(reason)
    -> Editing(row, owner, namespace, document, text, Ready, reason)
    Editing(row, owner, namespace, document, text, _, _), queue_request.Unknown
    ->
      Editing(
        row,
        owner,
        namespace,
        document,
        text,
        Unknown,
        "Outcome unknown; draft retained. Copy this text before reloading the page, then reopen the queued message to check its current revision.",
      )
    _, _ -> state
  }
}

/// Keeps a selected draft reachable even when its queue row has drained.
///
/// ## Examples
///
/// ```gleam
/// // queue_input.retain(state, rows)
/// ```
pub fn retain(state: State, rows: List(live.Row)) -> List(live.Row) {
  case state {
    Closed -> rows
    Loading(row, ..) | Editing(row, ..) -> {
      case
        list.any(rows, fn(item) {
          case item {
            live.Pending(input) ->
              input.id == row.id && input.strand == row.strand
            _ -> False
          }
        })
      {
        True -> rows
        False -> list.append(rows, [live.Pending(row)])
      }
    }
  }
}

/// Renders real labelled controls and an uncontrolled multiline editor.
///
/// ## Examples
///
/// ```gleam
/// // queue_input.view(state, input, component.QueueAction)
/// ```
pub fn view(
  state: State,
  row: snapshot_view.PendingInput,
  send: fn(Action) -> m,
) -> Element(m) {
  // Dispatch on view state.
  let content = case state {
    Loading(selected, ..)
      if selected.id == row.id && selected.strand == row.strand
    -> [
      html.p([attribute.role("status")], [
        html.text("Loading complete queued message…"),
      ]),
      button("Cancel", Cancel, send),
    ]
    Editing(selected, _, _, document, text, delivery, message)
      if selected.id == row.id && selected.strand == row.strand
    -> [
      html.form(
        [
          attribute.class("queue-editor"),
          event.on("submit", submitted(send)) |> event.prevent_default,
        ],
        [
          element.element(
            "textarea",
            [
              attribute.name("text"),
              attribute.aria_label("Edit queued message"),
              attribute.attribute("rows", "5"),
              attribute.attribute("maxlength", "32000"),
            ],
            [html.text(text)],
          ),
          html.p([attribute.class("held-mark")], [
            html.text(case document.attachment_count {
              0 -> "Attachments and queue position are preserved."
              _ -> "Attached images and queue position are preserved."
            }),
          ]),
          html.div([attribute.class("queue-actions")], [
            html.button(
              [attribute.type_("submit"), attribute.disabled(delivery != Ready)],
              [html.text("Save")],
            ),
            html.button(
              [
                attribute.type_("button"),
                attribute.disabled(delivery == Saving),
                event.on_click(send(Cancel)),
              ],
              [html.text("Cancel")],
            ),
          ]),
          html.p([attribute.class("held-mark"), attribute.role("status")], [
            html.text(message),
          ]),
        ],
      ),
    ]
    _ -> [
      html.p([attribute.class("held-text")], [html.text(row.text)]),
      html.div([attribute.class("queue-actions")], case row.editing, state {
        snapshot_view.Editable, Closed -> [
          button("Edit", Open(row), send),
          button("Remove", Remove(row), send),
        ]
        _, _ -> []
      }),
    ]
  }

  html.div(
    [attribute.class("held")],
    list.append(content, [
      html.p([attribute.class("held-mark")], [
        html.text(transcript_lines.held_words(row.kind)),
      ]),
    ]),
  )
}

fn button(label: String, action: Action, send: fn(Action) -> m) -> Element(m) {
  html.button([attribute.type_("button"), event.on_click(send(action))], [
    html.text(label),
  ])
}

/// Submitted helper.
fn submitted(send: fn(Action) -> m) -> decode.Decoder(m) {
  use fields <- decode.subfield(
    ["detail", "formData"],
    decode.list({
      use name <- decode.field(0, decode.string)
      use text <- decode.field(1, decode.string)
      decode.success(#(name, text))
    }),
  )

  // Dispatch on submitted state.
  case fields {
    [#("text", text)] ->
      case string.byte_size(text) <= 32_000 {
        True -> decode.success(send(Save(text)))
        False -> decode.failure(send(Cancel), "bounded text")
      }
    _ -> decode.failure(send(Cancel), "one bounded queued message text field")
  }
}
