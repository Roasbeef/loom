//// The ledger node of `client_distribution_fixture_ffi`'s three-emulator
//// scenarios (protocol-change/086).
////
//// Each child emulator boots with the production TLS distribution flags,
//// starts the real `loom_ledger` process over the node's own ledger file, and
//// takes commands on stdin. The scenario then makes one node ahead and
//// connects the nodes in a chain, so a line reaches the far end only by being
//// relayed. The signature is the HMAC stand-in of `membership_fixture`, which
//// every child can rebuild without a key; the real ECDSA pair is covered by
//// `membership_signing_test`.

import client/ledger_service.{type Service}
import client/membership_entry
import client/membership_ledger
import client/membership_store
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import support/membership_fixture as fixture
import support/membership_log as history
import telemetry/log
import weft/poll

/// A running ledger node.
pub opaque type Node {
  Node(service: Service)
}

/// The lines every scenario shares, oldest first: genesis, `hub`, `laptop`
/// linked to `hub`, and a revoke of `laptop`. Index 0 is genesis, which every
/// node starts with, and the others are offered by index.
pub fn script() -> List(BitArray) {
  history.genesis()
  |> history.enroll("hub", [])
  |> history.enroll("laptop", ["hub"])
  |> history.revoke("laptop")
  |> history.lines
}

/// Opens the ledger file at `path` and starts the production service over it:
/// peers from the VM's distribution, the fixed name, the default tick.
pub fn start(path: String) -> Result(Node, String) {
  use opened <- result.try(
    membership_store.open(path, fixture.verifier())
    |> result.map_error(string.inspect),
  )
  let config =
    ledger_service.configuration(
      opened.store,
      opened.ledger,
      fixture.verifier(),
      [],
      log.discard(),
    )
  case ledger_service.start(config) {
    Ok(service) -> Ok(Node(service:))
    Error(error) -> Error(string.inspect(error))
  }
}

/// Offers line `index` of the script and reports the word for what came of it.
pub fn offer(node: Node, index: Int) -> Result(String, String) {
  let assert Ok(line) = list.drop(script(), index) |> list.first
    as "the script holds the line"
  case ledger_service.offer(node.service, line, 10_000) {
    Ok(ledger_service.Accepted(_)) -> Ok("accepted")
    Ok(ledger_service.AlreadyHeld) -> Ok("held")
    Ok(ledger_service.Behind(_)) -> Ok("behind")
    Ok(ledger_service.Refused(refusal:)) ->
      Error("refused: " <> membership_ledger.step(refusal))
    Ok(ledger_service.NotDurable(reason:)) -> Error("not durable: " <> reason)
    Error(ledger_service.Unreachable) -> Error("the service did not answer")
  }
}

/// Waits, within a bound, for the head to reach `seq`.
pub fn await(node: Node, seq: Int, within_ms: Int) -> Result(Nil, String) {
  let outcome =
    poll.until(within: within_ms, every: 50, attempt: fn() {
      case ledger_service.head(node.service, 5000) {
        Ok(head) if head.seq >= seq -> poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(ledger_service.Unreachable) -> poll.Fail("unreachable")
      }
    })
  case outcome {
    poll.Answered(Nil) -> Ok(Nil)
    poll.Failed(reason) -> Error(reason)
    poll.Expired -> Error("the head did not reach " <> int.to_string(seq))
  }
}

/// The names of the active members, comma separated, and the head sequence
/// number.
pub fn describe(node: Node) -> Result(String, String) {
  case ledger_service.status(node.service, 5000) {
    Ok(status) -> {
      let names =
        membership_ledger.members(status.ledger)
        |> list.map(fn(member) { member.name })
      let head = membership_ledger.head(status.ledger)
      Ok(
        "head "
        <> int.to_string(head.seq)
        <> " members "
        <> string.join(names, ",")
        <> " id "
        <> membership_entry.id_to_hex(head.id),
      )
    }
    Error(ledger_service.Unreachable) -> Error("the service did not answer")
  }
}
