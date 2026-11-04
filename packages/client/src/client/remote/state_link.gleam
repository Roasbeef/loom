//// The `Link` a state transfer drives, over an address (protocol-change/107).
////
//// `client/state_transfer` moves a state through three questions to a node: how
//// far has it got, take this piece, and give me the piece at this offset. It does
//// not know how a node is reached. A node that is a peer orchestrator is reached
//// at its orchestrator port, and a node that holds a checkout is reached at its
//// executor host, each with its own closed message type that carries the same
//// three questions. This module is the one place that maps the three onto either,
//// so the loops are written once and tested against a store.
////
//// Every question makes one exchange: a monitor on the service, the request, and
//// a wait that ends at the answer, at the service's death or at the deadline. An
//// exchange that ends any way but the answer is silence, `Error(Nil)`, which the
//// loops read as "ask again", never as a refusal and never as an empty store.

import client/remote/address.{type Address}
import client/remote/orchestrator_port
import client/remote/protocol.{type HostMessage}
import client/state_transfer.{type Link, Link}
import gleam/erlang/process.{type Subject}
import gleam/result

/// The link to the orchestrator port at `at`. Each question waits at most
/// `within_ms` for its answer.
///
/// ## Examples
///
/// ```gleam
/// // state_link.via_port(Address(node: peer, name: orchestrator_port.default()), 30_000)
/// ```
pub fn via_port(
  at: Address(orchestrator_port.Message),
  within_ms: Int,
) -> Link {
  Link(
    stage: fn(hash) {
      orchestrator_port.ask_state_stage(at, hash, within_ms)
      |> result.try(fn(answer) { result.replace_error(answer, Nil) })
    },
    piece: fn(piece) {
      orchestrator_port.send_state_piece(at, piece, within_ms)
    },
    fetch: fn(hash, offset) {
      orchestrator_port.ask_state_fetch(at, hash, offset, within_ms)
    },
  )
}

/// The link to the executor host at `at`. Each question waits at most
/// `within_ms` for its answer.
///
/// ## Examples
///
/// ```gleam
/// // state_link.via_host(Address(node: executor, name: address.default()), 30_000)
/// ```
pub fn via_host(at: Address(HostMessage(census)), within_ms: Int) -> Link {
  Link(
    stage: fn(hash) {
      exchange(at, fn(reply) { protocol.StateStatus(hash:, reply:) }, within_ms)
      |> result.try(fn(answer) { result.replace_error(answer, Nil) })
    },
    piece: fn(piece) {
      exchange(at, fn(reply) { protocol.StateChunk(piece:, reply:) }, within_ms)
    },
    fetch: fn(hash, offset) {
      exchange(
        at,
        fn(reply) { protocol.StateFetch(hash:, offset:, reply:) },
        within_ms,
      )
    },
  )
}

/// One request to the host and its reply. The monitor is taken before the request
/// is sent, so a node that is already gone ends the wait at once with its `DOWN`.
/// Demonitoring afterwards flushes a `DOWN` that arrived beside the reply.
fn exchange(
  at: Address(HostMessage(census)),
  request: fn(Subject(answer)) -> HostMessage(census),
  within_ms: Int,
) -> Result(answer, Nil) {
  let reply = process.new_subject()
  let watch = address.watch(at)
  address.deliver(at, request(reply))
  let heard =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(watch, fn(_down) { Error(Nil) })
    |> process.selector_receive(within_ms)
  process.demonitor_process(watch)

  // A wait that ran out is silence, as is a service that went away.
  case heard {
    Ok(answered) -> answered
    Error(Nil) -> Error(Nil)
  }
}
