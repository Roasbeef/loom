//// The transport seam between the language-server client actor and its
//// server: write one framed message out, receive raw bytes and the close as
//// messages, tear the peer down.
////
//// `lsp/client` is written against two trusted local channel variants. Neither
//// variant opens an unjailed server; the actual broker/native attachment belongs
//// to its caller. Ordinary `ChannelTransport` retains its existing callbacks and
//// events. `ConsumedChannelTransport` installs one original local `Session` in
//// the checked window owner, selecting Registered parser and state bounds.
////
//// The ordinary client passes `Subject(TransportEvent)` to `connect` inside its
//// actor. Its `Connection` writes framed messages and requests teardown; the peer
//// sends raw `TransportData` and the original `TransportClosed` event. The
//// consumed connect instead runs in the original window owner and receives an
//// opaque producer `Sink`. Its physical feed must wait for actual input credit,
//// while close requests original cancellation without waiting on client output.
//// The original helper session adapter supplies those trusted callbacks later.
////
//// Consumed output carries a one-shot owner-checked grant. Stdout becomes consumed
//// after framing, total JSON parsing and bounded state updates; stderr enters the
//// private 8 KiB ring. Local close events establish attachment closure only.
//// Executor/native retirement and durable lease association remain independent.

import gleam/erlang/process.{type Subject}
import lsp/internal/consumed_channel

/// One inbound event from the transport, as the client actor sees it.
pub type TransportEvent {
  /// A chunk of the server's output: raw bytes at whatever boundary the pipe
  /// (or a test peer) delivered, not yet framed and not yet UTF-8.
  TransportData(bytes: BitArray)

  /// The wire is gone: the server exited, or a test peer closed it. No event
  /// follows this one.
  TransportClosed(reason: String)
}

/// The open half of the seam: write one framed message, and tear the peer
/// down. `send` answers `Error(Nil)` when the wire is already closed. `close`
/// requests termination and the actor keeps waiting for `TransportClosed`,
/// so a peer that ignores the request is still observed to be gone, or not,
/// by the same event.
pub type Connection {
  Connection(
    /// Writes one framed message through the installed local channel.
    send: fn(String) -> Result(Nil, Nil),
    /// Requests original peer teardown; its close event remains independent.
    close: fn() -> Nil,
  )
}

/// How the client actor reaches its language server.
pub type Transport {
  /// A peer reached through messages. `connect` runs in the actor's process
  /// during startup. It receives the subject on which the actor takes
  /// inbound `TransportEvent`s, and returns the connection the actor will
  /// write through. Running it in the actor's process is what lets a peer
  /// that owns a port or a monitor address its messages to the actor.
  ChannelTransport(connect: fn(Subject(TransportEvent)) -> Connection)

  /// Original trusted local consumed attachment. Its client profile bounds
  /// JSON nodes and retained state, and its writer acknowledges admission only.
  ConsumedChannelTransport(
    /// Installs the actual original trusted session in its window owner.
    connect: fn(consumed_channel.Sink) ->
      Result(consumed_channel.Session, String),
  )
}
