//// The directory members of `client_distribution_fixture_ffi`'s three-emulator
//// scenarios (protocol-change/080).
////
//// Each child emulator boots with the production TLS distribution flags as a
//// directory member and calls into this module. One member bootstraps the
//// cluster the way `loomd directory bootstrap` does; the others start the real
//// member actor, which joins them as non-voters that Ra promotes once they
//// have caught up. The scenario then writes past a snapshot while one member
//// is gone with its directory deleted, and checks that the member comes back,
//// is promoted, and reads what was written.

import client/directory/member
import client/directory/store
import client/distribution
import client/internal/ffi_khepri
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/node.{type Node}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import telemetry/log
import weft/poll

@external(erlang, "erlang", "disconnect_node")
fn disconnect_node(node: Node) -> Bool

/// Creates a one-member store in `directory` and marks it joined, as the
/// bootstrap command does after its checks.
pub fn bootstrap(directory: String) -> Result(Nil, String) {
  use Nil <- result.try(store.start_system(directory))
  use Nil <- result.try(store.boot(30_000))
  store.mark_joined(directory)
}

/// Starts the real member actor, which keeps the links and joins.
pub fn member(
  directory: String,
  members: List(String),
  local: String,
  membership: distribution.Membership,
) -> Result(member.Member, String) {
  member.start(member.Config(
    directory:,
    members:,
    local:,
    membership:,
    logger: log.discard(),
  ))
}

/// Waits until this member's store has joined and Ra counts it as a voter.
pub fn await_voter(
  handle: member.Member,
  local: String,
) -> Result(Nil, String) {
  let outcome =
    poll.until(within: 90_000, every: 100, attempt: fn() {
      let status = member.status(handle)
      case status.joining, status.ra {
        member.Joined, Ok(store.Membership(members:, ..)) ->
          case list.key_find(members, local) {
            Ok(ffi_khepri.Voter) -> poll.Done(Nil)
            Ok(ffi_khepri.NonVoter) | Error(Nil) -> poll.Retry
          }
        _, _ -> poll.Retry
      }
    })
  case outcome {
    poll.Answered(Nil) -> Ok(Nil)
    poll.Failed(reason) -> Error(reason)
    poll.Expired -> Error("the member did not become a voter in time")
  }
}

/// Writes `count` payloads of `bytes` bytes under test paths, ending with a
/// counter that holds `count`. Khepri asks Ra for a snapshot once the commands
/// since the last one add up to 20 MiB in their external format, and no sooner
/// than ten seconds after its last request.
pub fn write_bulk(count: Int, bytes: Int) -> Result(Nil, String) {
  let filler = bit_array.from_string(string.repeat("x", bytes))
  use Nil <- result.try(bulk(1, count, filler))
  ffi_khepri.put(["test", "counter"], count, 5000)
  |> result.replace_error("the counter write failed")
}

/// Writes `count` payloads of `bytes` bytes and leaves the counter alone.
pub fn write_padding(count: Int, bytes: Int) -> Result(Nil, String) {
  bulk(1, count, bit_array.from_string(string.repeat("x", bytes)))
}

fn bulk(index: Int, count: Int, filler: BitArray) -> Result(Nil, String) {
  case index > count {
    True -> Ok(Nil)
    False -> {
      use Nil <- result.try(
        ffi_khepri.put(
          ["test", "bulk", int.to_string(index % 64)],
          filler,
          5000,
        )
        |> result.replace_error(
          "bulk write " <> int.to_string(index) <> " failed",
        ),
      )
      bulk(index + 1, count, filler)
    }
  }
}

/// The counter `write_bulk` left, read from this member's own copy once it has
/// caught up with the leader.
pub fn counter() -> Result(Int, String) {
  case ffi_khepri.consistent(["test", "counter"], 5000, 5000) {
    Ok(Some(value)) ->
      decode.run(value, decode.int)
      |> result.replace_error("the counter is not a number")
    Ok(None) -> Error("the counter is absent")
    Error(_) -> Error("the counter could not be read")
  }
}

/// The log index of this member's latest snapshot.
pub fn snapshot_index() -> Int {
  store.snapshot_index()
}

/// Whether the store answers on another member.
pub fn running_on(node: Node) -> Bool {
  store.running_on(node)
}

/// Cuts this node's connection to another and waits for the member actor to
/// make it again, visible.
pub fn cut_and_relink(other: Node) -> Result(Nil, String) {
  let _cut = disconnect_node(other)
  let outcome =
    poll.until(within: 20_000, every: 100, attempt: fn() {
      case list.contains(node.visible(), other) {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
  case outcome {
    poll.Answered(Nil) -> Ok(Nil)
    poll.Failed(reason) -> Error(reason)
    poll.Expired -> Error("the link keeper did not reconnect in time")
  }
}
