//// What one conversation connection can tell its reader, as plain data.
////
//// The events are separate from `tui/connection`, which opens, writes and
//// closes the socket, because the code that consumes them does not touch a
//// socket. The session lane reduces them, an attempt records them, and a
//// replay decodes them from a file. None of that needs the transport, so
//// none of it should import the module that owns one. The transport maps
//// the websocket's own events into these at the socket's reader, and every
//// consumer sees only this type.

/// One connection lifecycle message for the process that reads the socket.
pub type Message {
  /// The socket actor completed its handshake and can accept commands.
  Connected

  /// A text frame arrived from the gateway.
  Incoming(
    /// The undecoded wire payload.
    text: String,
  )

  /// The peer or local actor closed the websocket.
  Closed(
    /// The backend's diagnostic close reason.
    reason: String,
  )

  /// The transport reported an I/O violation.
  NetworkFault(
    /// The backend's diagnostic failure reason.
    reason: String,
  )
}
