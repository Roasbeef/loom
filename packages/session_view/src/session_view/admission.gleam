//// Files what a host received into the session's buffers, and reduces none
//// of it.
////
//// A host receives a conversation socket's frames and a replay's recorded
//// events before each step, and the reducers take them from two buffers in
//// the shared record at fixed points: the connection inbox (`Shared.inbox`)
//// and the replay inbox (`Shared.replay_inbox`). Filing into those two
//// buffers is session work, so it is here, over the shared record alone,
//// and a second host can call it with its own sources. What else a host
//// files, the terminal's waiting attachment attempt and its background
//// jobs' replies, is the host's (`tui/admission`).
////
//// Filing never reduces and never drops a frame for a reason of capacity;
//// the bound on what one step holds is the host's to keep. A frame is
//// refused for one reason only: its source is not the adopted inbox's. An
//// adoption replaces the inbox whole, so such a frame came from a socket
//// the record no longer reads, and no message from a replaced inbox may
//// reach the reducer after the swap (the protocol model's S2). The host
//// decides what a refused frame is: the terminal offers it to its waiting
//// attempt, and a host with no attempt drops it.

import session_view/attempt
import session_view/connection_event
import session_view/inbox
import session_view/model.{type Shared}
import session_view/shared_set

/// Files a frame into the adopted connection inbox when it was read from
/// that inbox's source, and refuses it otherwise.
///
/// This is the session half of filing a frame, over the shared record
/// alone. A refusal is not a drop: the terminal then offers the frame to
/// its waiting attachment attempt (`tui/admission`), and only a frame
/// neither of them reads is dropped. A host with no provisional attempt
/// drops a refused frame, because it came from a socket the record no
/// longer reads (the protocol model's S2).
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(shared) = admission.file_frame(shared, source, message)
/// ```
@internal
pub fn file_frame(
  shared: Shared(socket, recorder, source, replay_source),
  source: source,
  message: connection_event.Message,
) -> Result(Shared(socket, recorder, source, replay_source), Nil) {
  case source == inbox.source(shared.inbox) {
    True -> Ok(shared_set.inbox(shared, inbox.push(shared.inbox, message)))
    False -> Error(Nil)
  }
}

/// Files one recorded attempt event into the replay inbox, over the shared
/// record alone.
///
/// Every replayed event is filed, whatever the peer: the replay drain takes
/// one per tick and drops what arrives outside a replay, so filing needs no
/// check of its own.
///
/// ## Examples
///
/// ```gleam
/// let shared = admission.file_replayed(shared, event)
/// ```
@internal
pub fn file_replayed(
  shared: Shared(socket, recorder, source, replay_source),
  event: attempt.Event,
) -> Shared(socket, recorder, source, replay_source) {
  shared_set.replay_inbox(shared, inbox.push(shared.replay_inbox, event))
}
