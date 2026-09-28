//// The queue editor's traffic on the session lane: the one queued-input read
//// waiting for a free lane, the read the lane has issued, and the request ID
//// the lane gave the last queue command it sent.
////
//// This is the half of the queue editor that a second host of the session
//// would need, because it correlates the lane's replies and refusals with
//// the request that caused them. The editor itself, meaning the fetched draft
//// in its etui text area, the inspector's selection and the surface, is the
//// terminal's and stays in `tui/queue_editor`. The split keeps this module
//// free of etui so that it can sit in `Shared` (`tui/session_model`) and
//// later move into `session_view` with it
//// (`docs/design-notes/step-extraction.md`, section 5, S3b′).

import gleam/option.{type Option, None, Some}
import session_view/queued_input.{type Document}

/// One queued-input read, named by the attachment and queue it was selected
/// from, so a reply for another attachment or queue cannot fill the editor.
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

/// The queue editor's requests on the lane. `Shared.queue_request` holds it,
/// because the lane's replies are folded into it by the session's reducers.
pub type State {
  State(
    /// Read waiting for a free conversation command lane.
    fetch: Option(Fetch),
    /// The issued read whose reply alone can replace the draft.
    awaiting: Option(Fetch),
    /// Actual lane request ID for a correlated refusal.
    request_id: Option(Int),
  )
}

/// Something the lane did with the editor's requests, or brought back for
/// them, that the editor has to show, recorded by a function over `Shared`
/// and shown by the host that owns an editor.
///
/// The functions that send frames, service the queued-input read and apply
/// its reply take the shared record alone, so they cannot write the editor's
/// draft, message or delivery lock themselves. They append a notice to
/// `Shared.queue_notices` instead, and the terminal's `tui_model.hold_shared`
/// hands each one to `queue_editor.show` after the call that recorded it.
pub type Notice {
  /// The lane refused to send a frame, for `reason`. Any frame counts, as it
  /// did when the refusal wrote the editor directly: a save waiting on the
  /// lane is unlocked, and the editor shows the reason.
  Refused(reason: String)

  /// A wanted read was dropped before it was sent, because the attachment
  /// changed or there is no live one. The editor shows `message` and keeps
  /// its draft as it is.
  Dropped(message: String)

  /// The queued-input document answering the read this client issued
  /// arrived, for the attachment `owner` and the queue `namespace`. The
  /// editor fills its draft from it, as `queue_editor.receive` decides.
  Received(owner: String, namespace: String, document: Document)
}

/// Starts with no read wanted, none issued and no request to correlate. A
/// refusal of a queue command, a lost lane and an acknowledged save each
/// return the requests to this state.
///
/// ## Examples
///
/// ```gleam
/// queue_request.new()
/// ```
pub fn new() -> State {
  State(fetch: None, awaiting: None, request_id: None)
}

/// Admits only a full response for the exact outstanding queue read, and
/// settles that read. `Error(Nil)` means the document answers no read this
/// client issued, so the editor must not take it.
///
/// ## Examples
///
/// ```gleam
/// // queue_request.receive(state, owner, namespace, document)
/// ```
pub fn receive(
  state: State,
  owner: String,
  namespace: String,
  document: Document,
) -> Result(State, Nil) {
  case state.awaiting {
    Some(Fetch(owner: expected, namespace: expected_namespace, strand:, id:))
      if expected == owner
      && expected_namespace == namespace
      && strand == document.strand
      && id == document.id
    -> Ok(State(..state, awaiting: None, request_id: None))
    Some(_) | None -> Error(Nil)
  }
}
