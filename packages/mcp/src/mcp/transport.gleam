//// The transport seam between the MCP client actor and its server
//// process: send a framed line out, receive raw bytes and the close as
//// messages, tear the peer down.
////
//// The seam is deliberate. `mcp/client` is written against `Transport`
//// alone, so the decision of *how* a server process comes to exist —
//// and in particular whether it is spawned inside a jail through the
//// `loom-exec` helper — can change without rewriting the actor.
//// `PortTransport` is the mechanism: a child OS process on an Erlang
//// port, stdin/stdout as the wire. **Who gets to spawn a real server
//// binary is the harness wiring's decision, made elsewhere**; an
//// unjailed spawn here is the production primitive, not the final
//// security posture. Whether an MCP server should run inside a jail at
//// all is an open decision rather than a deferred implementation — it
//// is recorded as such in `docs/next.md`, and this seam is where the
//// answer would attach.
////
//// The child's stderr is deliberately **not** merged into stdout:
//// `stderr_to_stdout` would interleave the server's diagnostics into
//// the newline-delimited JSON-RPC stream and corrupt framing. Instead
//// stderr is inherited from the BEAM, so server diagnostics land on the
//// harness's own stderr; capturing them is later work.
////
//// The other variant, `ChannelTransport`, is the test seam: an
//// in-process peer receives the connect, sees every outbound line, and
//// delivers inbound bytes and the close through the same messages the
//// port does — so every client behaviour is provable without an OS
//// process.

import gleam/bit_array
import gleam/bool
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}
import mcp/internal/ffi_port

/// How to start a server as a child OS process: an executable path and
/// argv — never a shell string, so nothing here is shell-interpretable —
/// plus explicit environment additions and an optional working
/// directory.
///
/// Constructor invariants: none beyond the types. `env` carries concrete
/// `#(name, value)` pairs only; resolving a secret out of the harness's
/// own environment (the `api_key_env` indirection) is harness wiring's
/// job, not this record's.
pub type Spawn {
  Spawn(
    executable: String,
    args: List(String),
    env: List(#(String, String)),
    directory: Option(String),
  )
}

/// A spawn of `executable` with `args`, no extra environment, inheriting
/// the BEAM's working directory. Extend with `with_env` / `in_directory`.
///
/// ## Examples
///
/// ```gleam
/// // transport.spawn("/usr/bin/some-mcp-server", ["--stdio"])
/// ```
///
pub fn spawn(executable: String, args: List(String)) -> Spawn {
  Spawn(executable:, args:, env: [], directory: None)
}

/// Adds concrete environment pairs to a spawn.
///
/// ## Examples
///
/// ```gleam
/// // transport.spawn("/bin/server", []) |> transport.with_env([#("MODE", "quiet")])
/// ```
///
pub fn with_env(spawn: Spawn, env: List(#(String, String))) -> Spawn {
  Spawn(..spawn, env:)
}

/// Sets the child's working directory.
///
/// ## Examples
///
/// ```gleam
/// // transport.spawn("/bin/server", []) |> transport.in_directory("/work")
/// ```
///
pub fn in_directory(spawn: Spawn, directory: String) -> Spawn {
  Spawn(..spawn, directory: Some(directory))
}

/// One inbound event from the transport, as the client actor sees it.
pub type TransportEvent {
  /// A chunk of the server's stdout: raw bytes at whatever boundary the
  /// pipe (or a test peer) delivered — not yet lines, not yet UTF-8.
  TransportData(bytes: BitArray)
  /// The wire is gone: the server exited, or a test peer closed it. No
  /// event follows this one.
  TransportClosed(reason: String)
}

/// The open half of the seam: write one framed line, and tear the peer
/// down. `close` is idempotent; for a port peer it closes the child's
/// stdin (the stdio transport's shutdown signal) and then SIGKILLs the
/// child as belt-and-braces, matching the v1 posture of a client that
/// never restarts what it owns.
pub type Connection {
  Connection(send: fn(String) -> Result(Nil, Nil), close: fn() -> Nil)
}

/// How the client actor reaches its MCP server. A seam: production
/// injects `PortTransport`; tests inject `ChannelTransport` and drive
/// the same actor in-process.
pub type Transport {
  /// A real child process, spawned as an Erlang port owned by the actor
  /// (ports deliver their messages to the process that opened them,
  /// which is why this is a spawn spec rather than an open port).
  PortTransport(spawn: Spawn)
  /// An in-process peer. `connect` runs in the actor's process during
  /// startup: it receives the subject on which the actor takes inbound
  /// `TransportEvent`s and returns the connection the actor will write
  /// through.
  ChannelTransport(connect: fn(Subject(TransportEvent)) -> Connection)
}

/// Opens a transport from inside the client actor's own process,
/// returning the connection and the selector extended with whatever the
/// transport needs. `inbound` is the subject a channel peer delivers
/// events to (the caller's `base` selector must already map it); a port
/// peer bypasses it and delivers through the returned selector directly,
/// mapped by the same `wrap`.
///
/// Must run in the process that will select — the port case opens the
/// port there, because port messages go to the opener.
///
/// The error is a worded reason carrying the spawn failure's own cause,
/// so a caller can tell an absent executable (`"…: enoent"`) from a port
/// that could not be opened for any other cause.
///
/// ## Examples
///
/// ```gleam
/// // transport.open(config.transport, inbound, base, FromTransport)
/// ```
///
pub fn open(
  transport: Transport,
  inbound: Subject(TransportEvent),
  base: process.Selector(msg),
  wrap: fn(TransportEvent) -> msg,
) -> Result(#(Connection, process.Selector(msg)), String) {
  case transport {
    ChannelTransport(connect:) -> Ok(#(connect(inbound), base))
    PortTransport(spawn:) ->
      case
        ffi_port.open_stdio(
          spawn.executable,
          spawn.args,
          spawn.env,
          spawn.directory,
        )
      {
        // The FFI's own reason travels: "enoent" for an absent
        // executable is what tells a caller — the port tests included —
        // that the host lacks the binary rather than that the spawn
        // itself is broken.
        Error(reason) ->
          Error("mcp server process could not be spawned: " <> reason)
        Ok(opened) -> {
          let os_pid = option.from_result(ffi_port.port_os_pid(opened))
          let selector =
            process.select_record(
              base,
              tag: opened,
              fields: 1,
              mapping: fn(message) { wrap(port_transport_event(message)) },
            )
          let connection =
            Connection(
              send: fn(line) { ffi_port.port_send(opened, line) },
              close: fn() {
                ffi_port.close_port(opened)
                case os_pid {
                  Some(pid) -> ffi_port.kill_os_process(pid)
                  None -> Nil
                }
              },
            )
          Ok(#(connection, selector))
        }
      }
  }
}

// Normalizes one raw port message into the seam's event vocabulary. A
// message that is not a recognised port shape reads as an empty chunk,
// which the framing layer ignores — harmless by construction.
fn port_transport_event(message: Dynamic) -> TransportEvent {
  case ffi_port.port_event(message) {
    ffi_port.PortBytes(data:) -> TransportData(bytes: data)
    ffi_port.PortClosed(status:) ->
      TransportClosed(
        reason: "mcp server exited with status " <> int.to_string(status),
      )
    ffi_port.PortJunk -> TransportData(bytes: <<>>)
  }
}

/// How many bytes of an incomplete trailing UTF-8 sequence `utf8_prefix`
/// will hold back for the next chunk: a UTF-8 character is at most four
/// bytes, so a truncated one leaves at most three behind.
pub const max_held_tail_bytes = 3

/// Splits a byte chunk into its longest valid-UTF-8 prefix and the held
/// remainder. The pipe delivers chunks at arbitrary boundaries, so a
/// multi-byte character can arrive cut in half; the caller prepends the
/// returned tail (at most `max_held_tail_bytes` bytes) to the next
/// chunk. `Error(Nil)` means the bytes are not UTF-8 at all — not a
/// truncated character but a hostile or non-text stream, which the
/// client treats as transport-fatal.
///
/// Total: every input settles as a split or as `Error(Nil)`.
///
/// ## Examples
///
/// ```gleam
/// assert transport.utf8_prefix(<<"ab":utf8>>) == Ok(#("ab", <<>>))
/// ```
///
/// ```gleam
/// // "é" is <<0xc3, 0xa9>>; a chunk ending mid-character holds the lead byte.
/// assert transport.utf8_prefix(<<"a":utf8, 0xc3>>) == Ok(#("a", <<0xc3>>))
/// ```
///
pub fn utf8_prefix(bytes: BitArray) -> Result(#(String, BitArray), Nil) {
  case bit_array.to_string(bytes) {
    Ok(text) -> Ok(#(text, <<>>))
    Error(Nil) -> split_holding(bytes, 1)
  }
}

// Retries the split holding `drop` trailing bytes back, up to the longest
// truncated character. Invalid bytes anywhere but a truncated tail fail
// every retry and settle as Error(Nil).
fn split_holding(
  bytes: BitArray,
  drop: Int,
) -> Result(#(String, BitArray), Nil) {
  use <- bool.guard(when: drop > max_held_tail_bytes, return: Error(Nil))
  let size = bit_array.byte_size(bytes)
  case drop >= size {
    True -> held_tail("", bytes)
    False ->
      case bit_array.slice(bytes, 0, size - drop) {
        Error(Nil) -> Error(Nil)
        Ok(prefix) ->
          case
            bit_array.to_string(prefix),
            bit_array.slice(bytes, size - drop, drop)
          {
            Ok(text), Ok(tail) -> held_tail(text, tail)
            Ok(_), Error(Nil) -> Error(Nil)
            Error(Nil), _ -> split_holding(bytes, drop + 1)
          }
      }
  }
}

// Holds a tail only when more bytes could still complete it. A tail that
// can never decode — a non-lead first byte, or continuations the lead
// does not declare — used to be held until the next chunk arrived, so a
// garbage-then-silence peer read as healthy; it fails now instead.
fn held_tail(text: String, tail: BitArray) -> Result(#(String, BitArray), Nil) {
  case plausible_truncation(tail) {
    True -> Ok(#(text, tail))
    False -> Error(Nil)
  }
}

// Whether `tail` could be a prefix of a multi-byte UTF-8 character: a
// lead byte declaring strictly more bytes than are held, followed only
// by continuation bytes. Deliberately an over-approximation: it does not
// check the second-byte ranges that rule out overlongs and surrogates
// (0xE0/0xED/0xF0/0xF4 leads), so those four corners are held one extra
// chunk and die on the next arrival — bounded at three bytes, with
// in-flight calls still expiring on their own deadlines. Exactness there
// would buy one chunk of earlier failure in a case only a hostile peer
// produces.
fn plausible_truncation(tail: BitArray) -> Bool {
  case tail {
    <<>> -> True
    <<lead, rest:bytes>> ->
      declared_length(lead) > bit_array.byte_size(tail) && continuations(rest)
    _ -> False
  }
}

// How many bytes a UTF-8 lead byte declares; 0 for a byte that can
// never begin a multi-byte character (ASCII would have decoded already,
// and 0xC0/0xC1/0xF5+ are not legal leads at all).
fn declared_length(lead: Int) -> Int {
  case
    lead >= 0xc2 && lead <= 0xdf,
    lead >= 0xe0 && lead <= 0xef,
    lead >= 0xf0 && lead <= 0xf4
  {
    True, _, _ -> 2
    _, True, _ -> 3
    _, _, True -> 4
    False, False, False -> 0
  }
}

fn continuations(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<byte, rest:bytes>> -> byte >= 0x80 && byte <= 0xbf && continuations(rest)
    _ -> False
  }
}
