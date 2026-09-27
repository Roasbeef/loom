//// Queued input is edited from a complete authoritative document, never from
//// the queue's display excerpt. Identity and revision stay attached to the
//// draft so a stale or already admitted item cannot become a new submission.
//// The terminal owns this state; the existing session channel owns delivery.

import etui/widgets/textarea
import gleam/option.{type Option, None, Some}
import tui/queued_input.{type Document}

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

/// A read is deferred until the existing channel finishes its mutation.
pub type Fetch {
  Fetch(
    /// Original attachment whose queue was selected.
    owner: String,
    /// Stable queue namespace; a reconnect changes only the connection identity.
    namespace: String,
    /// Selected queue strand.
    strand: String,
    /// Selected opaque queue identity.
    id: String,
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
    /// Read waiting for a free conversation command lane.
    fetch: Option(Fetch),
    /// The issued read whose reply alone can replace the draft.
    awaiting: Option(Fetch),
    /// Actual lane request ID for a correlated refusal.
    request_id: Option(Int),
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
    None,
    None,
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

/// Admits only a full response for the exact outstanding queue read.
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
  case state.awaiting {
    Some(Fetch(owner: expected, namespace: expected_namespace, strand:, id:))
      if expected == owner
      && expected_namespace == namespace
      && strand == document.strand
      && id == document.id
    -> reconcile(state, owner, namespace, document)
    Some(_) | None -> state
  }
}

fn reconcile(
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
        awaiting: None,
        request_id: None,
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
        awaiting: None,
        request_id: None,
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
///
/// ## Examples
///
/// ```gleam
/// queue_editor.refused(queue_editor.new(), "revision changed")
/// ```
pub fn refused(state: State, reason: String) -> State {
  State(
    ..state,
    fetch: None,
    awaiting: None,
    request_id: None,
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
