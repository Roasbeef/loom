//// The transport seam between the language-server client actor and its
//// server: write one framed message out, receive raw bytes and the close as
//// messages, tear the peer down.
////
//// `lsp/client` is written against `Transport` alone. The seam is the one
//// place a server's process comes to exist, and for LSP that place is the
//// jail: `client/lsp/jail` builds a `Transport` over the broker's exec, and
//// `test/support/fake_server` builds one over an in-process peer. Nothing in
//// this package opens a port or spawns a process. That is why `Transport`
//// has a single variant. `gleam_mcp/transport` also has an unjailed
//// `PortTransport`, and `lsp/client` had to refuse it at `start`. Here the
//// type cannot say it, so no wiring mistake can run a server on the
//// harness's own host (Rule Zero), and the refusal path is gone with it.
////
//// The module is the channel half of the transport that Loom's own
//// `packages/mcp` carried before the MCP client moved into `gleam_mcp`
//// (commit `89247eb29`), kept to the types the LSP client uses.
////
//// ## Flow
////
//// `lsp/client` creates a `Subject(TransportEvent)` inside the actor
//// process and passes it to the `connect` function. `connect` returns a
//// `Connection`: the actor writes through `send` and requests teardown
//// through `close`. The peer delivers `TransportData` chunks to the subject
//// as bytes arrive, at whatever boundary the pipe chose, and delivers
//// `TransportClosed` exactly once when the wire is gone. No event follows
//// the close.

import gleam/erlang/process.{type Subject}

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
  Connection(send: fn(String) -> Result(Nil, Nil), close: fn() -> Nil)
}

/// How the client actor reaches its language server.
pub type Transport {
  /// A peer reached through messages. `connect` runs in the actor's process
  /// during startup. It receives the subject on which the actor takes
  /// inbound `TransportEvent`s, and returns the connection the actor will
  /// write through. Running it in the actor's process is what lets a peer
  /// that owns a port or a monitor address its messages to the actor.
  ChannelTransport(connect: fn(Subject(TransportEvent)) -> Connection)
}
