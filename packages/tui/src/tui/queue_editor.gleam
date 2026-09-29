//// Queued input is edited from a complete authoritative document, never from
//// the queue's display excerpt. Identity and revision stay attached to the
//// draft so a stale or already admitted item cannot become a new submission.
//// The terminal owns this state; the existing session channel owns delivery.
//// The requests the editor has on that channel, the wanted read, the issued
//// read and the last request ID, are session state and live in
//// `tui/queue_request`, held by `Shared`; this module holds only the editor.

import etui/widgets/textarea
import gleam/option.{type Option, None, Some}
import session_view/queue_request
import session_view/queued_input.{type Document}

/// Whether the queue inspector or a retained draft is visible.
pub type Surface {
  /// Ordinary conversation and composer own input.
  Closed

  /// Queue metadata owns selection.
  Inspector

  /// The full draft owns the multiline editor.
  Editor
}

/// A sent replacement has one outcome; uncertainty forbids another mutation.
pub type Delivery {
  /// A fetched revision is available for one save.
  Editable

  /// The channel owns a replacement awaiting its acknowledgement.
  Saving

  /// The reply was lost; only an explicit authoritative read can reconcile it.
  Unknown
}

/// The owner is the authenticated attachment which fetched this revision.
pub type Draft {
  Draft(
    /// Complete original server value and compare-and-swap revision.
    document: Document,
    /// Attachment identity, including server epoch and incarnation.
    owner: String,
    /// Stable queue namespace; a reconnect changes only the connection identity.
    namespace: String,
    /// Separate from the ordinary composer and its image attachments.
    input: textarea.TextAreaState,
    /// Whether another save can be issued.
    delivery: Delivery,
  )
}

/// Persistent draft custody is independent of whether the modal is open.
pub type State {
  State(
    /// Current input surface.
    surface: Surface,
    /// Selected inspector row, clamped against each fresh view.
    selected: Int,
    /// Independent offset into the selected captured excerpt.
    preview_scroll: Int,
    /// A draft survives refusal, disconnect, and closing the modal.
    draft: Option(Draft),
    /// A concise explanation of the current editing boundary.
    message: String,
  )
}

/// Starts without taking ownership of the ordinary composer.
///
/// ## Examples
///
/// ```gleam
/// queue_editor.new()
/// ```
pub fn new() -> State {
  State(
    Closed,
    0,
    0,
    None,
    "Captured queue · complete text requires an editable item",
  )
}

/// Opens the inspector, retaining a prior draft for explicit reconciliation.
///
/// ## Examples
///
/// ```gleam
/// queue_editor.open(queue_editor.new())
/// ```
pub fn open(state: State) -> State {
  State(..state, surface: Inspector, message: case state.draft {
    Some(_) ->
      "Retained draft available · e resumes editing · selection remains captured queue"
    None -> "Captured queue · Enter fetches complete text for editable items"
  })
}

/// Fills the editor from a queued-input document that
/// `queue_request.receive` admitted as the answer to the outstanding read.
/// An uncertain draft stays intact when the authoritative value differs.
///
/// ## Examples
///
/// ```gleam
/// // queue_editor.receive(state, owner, namespace, document)
/// ```
pub fn receive(
  state: State,
  owner: String,
  namespace: String,
  document: Document,
) -> State {
  case state.draft {
    Some(draft)
      if draft.namespace == namespace
      && draft.document.id == document.id
      && draft.document.strand == document.strand
    -> {
      let current = textarea.value(draft.input) == document.text
      State(
        ..state,
        surface: Editor,
        message: case current {
          True ->
            "Authoritative queue contains this draft; Esc retains it, Ctrl+s can save further edits"
          False ->
            "Authoritative text differs; draft retained. Review it before Ctrl+s replaces the fetched revision"
        },
        draft: Some(
          Draft(..draft, document:, owner:, namespace:, delivery: Editable),
        ),
      )
    }
    Some(_) | None ->
      State(
        ..state,
        surface: Editor,
        draft: Some(Draft(
          document,
          owner,
          namespace,
          textarea.state_from_string(document.text),
          Editable,
        )),
        message: "Ctrl+s: save · Enter: newline · Esc: back · images remain attached",
      )
  }
}

/// Locks a retained draft when delivery loses its acknowledgement.
///
/// ## Examples
///
/// ```gleam
/// queue_editor.unknown(queue_editor.new())
/// ```
pub fn unknown(state: State) -> State {
  State(
    ..state,
    draft: option.map(state.draft, fn(draft) {
      Draft(..draft, delivery: Unknown)
    }),
    message: "Save outcome unknown; draft retained. Ctrl+r explicitly refetches before another save",
  )
}

/// Keeps text editable after a definite server refusal, never re-enqueueing it.
/// The caller also returns `Shared.queue_request` to `queue_request.new()`,
/// since a refusal ends every queue request in flight.
///
/// ## Examples
///
/// ```gleam
/// queue_editor.refused(queue_editor.new(), "revision changed")
/// ```
pub fn refused(state: State, reason: String) -> State {
  State(
    ..state,
    message: case state.draft {
      Some(Draft(delivery: Unknown, ..)) ->
        "Save outcome unknown; "
        <> reason
        <> "; Ctrl+r explicitly refetches before another save"
      Some(_) | None -> reason
    },
    draft: option.map(state.draft, fn(draft) {
      Draft(..draft, delivery: case draft.delivery {
        Unknown -> Unknown
        Editable | Saving -> Editable
      })
    }),
  )
}

/// Shows one thing the lane did with the editor's requests.
///
/// The functions over `Shared` that send frames and service the queued-input
/// read record a `queue_request.Notice` rather than write the editor, and
/// the terminal applies each here, in the order they were recorded, at the
/// point of the call that recorded it. A refusal is `refused`; a dropped
/// read replaces only the message. A received document fills the draft.
///
/// ## Examples
///
/// ```gleam
/// queue_editor.show(queue_editor.new(), queue_request.Refused("closed"))
/// ```
pub fn show(state: State, notice: queue_request.Notice) -> State {
  case notice {
    queue_request.Refused(reason:) -> refused(state, reason)
    queue_request.Dropped(message:) -> State(..state, message:)
    queue_request.Received(owner:, namespace:, document:) ->
      receive(state, owner, namespace, document)
    queue_request.Saved -> new()
    queue_request.Unknown -> unknown(state)
  }
}
