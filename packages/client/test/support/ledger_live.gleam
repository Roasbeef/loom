//// The nodes of the live-ledger scenarios (protocol-change/086): a deployment
//// whose trust comes from a signed ledger and nothing else, run across real
//// emulators with the production TLS flags.
////
//// Two halves live here. The parent half builds a ledger from the facts of
//// real certificates, signed with the real authority key, so a node verifies
//// it with the verifier a daemon builds from its `ca` file. The node half is
//// what a child emulator runs: the daemon's own `ledger_boot.start`, which
//// starts the ledger process, publishes the pin table and starts distribution
//// in that order, and then a few commands the parent sends over stdin.
////
//// One node can be started with a hook in front of the production observer.
//// The hook holds the ledger process in the middle of applying an entry, and
//// the node publishes the table itself and leaves the disconnect to the
//// node-up check, so that a scenario can order a real handshake against the
//// publish and prove that the node-up check alone ends the connection.

import client/distribution
import client/distribution_plan.{type Role}
import client/internal/ffi_nodes
import client/ledger_boot
import client/ledger_control
import client/ledger_service.{type Observer}
import client/ledger_trust
import client/membership_entry.{
  type Kind, type SignedEntry, Genesis, Member, NotInDirectory, Revoke, Upsert,
}
import client/membership_ledger
import client/membership_signing
import core/json
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import support/membership_fixture as fixture
import telemetry/log
import weft/poll

// --- the parent: a ledger built from real certificates ------------------------

/// One entry after the genesis.
pub type Step {
  /// Enrolls a member whose certificate hashes to `pin`.
  Enroll(
    name: String,
    node: String,
    pin: BitArray,
    role: Role,
    links: List(String),
  )

  /// Revokes the member of that name.
  Retire(name: String)
}

/// The lines of a ledger: a genesis naming `authority_certificate`, then the
/// steps, each signed with `authority_key`.
pub fn script(
  authority_key: String,
  authority_certificate: String,
  steps: List(Step),
) -> Result(List(BitArray), String) {
  use sign <- result.try(
    membership_signing.signer(authority_key)
    |> result.replace_error("the authority key does not sign"),
  )
  use pin <- result.try(
    membership_signing.authority_pin(authority_certificate)
    |> result.replace_error("the authority certificate has no pin"),
  )
  let genesis =
    fixture.entry(
      0,
      membership_entry.genesis_prev(),
      Genesis(deployment: fixture.deployment, authority: pin),
    )
  use sealed <- result.try(
    membership_entry.seal(genesis, sign)
    |> result.replace_error("the genesis did not seal"),
  )
  seal_steps(steps, sign, [sealed])
  |> result.map(fn(entries) { list.reverse(entries) |> list.map(line_of) })
}

fn line_of(entry: SignedEntry) -> BitArray {
  membership_entry.line(entry)
}

fn seal_steps(
  steps: List(Step),
  sign: membership_entry.Signer,
  sealed: List(SignedEntry),
) -> Result(List(SignedEntry), String) {
  case steps, sealed {
    [], _ | _, [] -> Ok(sealed)
    [step, ..rest], [last, ..] -> {
      let entry = fixture.entry(last.entry.seq + 1, last.id, kind_of(step))
      use next <- result.try(
        membership_entry.seal(entry, sign)
        |> result.replace_error("an entry did not seal"),
      )
      seal_steps(rest, sign, [next, ..sealed])
    }
  }
}

fn kind_of(step: Step) -> Kind {
  case step {
    Enroll(name:, node:, pin:, role:, links:) ->
      Upsert(Member(
        name:,
        node:,
        host: "127.0.0.1",
        listen_port: None,
        role:,
        directory: NotInDirectory,
        links:,
        pin:,
      ))
    Retire(name:) -> Revoke(name:, pin: <<0:size(256)>>, reason: "lost")
  }
}

// --- a child: the daemon's boot, and commands --------------------------------

/// How a node's ledger process is observed.
pub type Observation {
  /// The production observer of `client/ledger_trust`.
  Production

  /// A hook that holds the ledger process in front of the publish, then the
  /// production publish without its disconnects, then the production node-up
  /// check. `Held` is how a scenario orders a handshake between the two.
  Held

  /// The production publish without its disconnects, and the production
  /// node-up check. The node never drops a connection because of an entry, so
  /// a scenario sees which other node does.
  Unswept
}

/// A running node.
pub opaque type Node {
  Node(
    local: String,
    booted: ledger_boot.Booted,
    blocked: Subject(Subject(Nil)),
  )
}

/// Starts the daemon's own boot for this configuration. The ledger process
/// starts first and publishes the table, distribution starts after it, and the
/// node is ready to be commanded.
pub fn boot(
  config: distribution.Config,
  observation: Observation,
) -> Result(Node, String) {
  let local = distribution.local_node(config)
  let blocked = process.new_subject()
  let observers = case observation {
    Production -> [ledger_trust.observer(local, log.discard())]
    Held -> [holding(blocked), publishing_only(local)]
    Unswept -> [publishing_only(local)]
  }
  use booted <- result.map(ledger_boot.start_with(
    config,
    distribution.NotMember,
    observers,
    log.discard(),
  ))
  Node(local:, booted:, blocked:)
}

// Holds the ledger process when an entry is applied: it tells the node the
// subject that lets it go and waits for a word on it. The subject is made in
// the ledger process, which is the only one that can receive on it.
fn holding(blocked: Subject(Subject(Nil))) -> Observer {
  fn(observation) {
    case observation {
      ledger_service.Extended(..) -> {
        let release = process.new_subject()
        process.send(blocked, release)
        process.receive_forever(release)
      }
      ledger_service.Loaded(..) | ledger_service.Connected(..) -> Nil
    }
  }
}

// The production observer for everything except the disconnects that follow an
// entry: the table is published, and a node-up is judged, but a connection that
// already exists is not swept. What ends a connection is then the node-up check
// alone.
fn publishing_only(local: String) -> Observer {
  let production = ledger_trust.observer(local, log.discard())
  fn(observation) {
    case observation {
      ledger_service.Extended(ledger:, ..) ->
        ledger_trust.publish(ledger, local)
      ledger_service.Loaded(..) | ledger_service.Connected(..) ->
        production(observation)
    }
  }
}

/// Waits for the hook to hold the ledger process and returns a function that
/// lets it go.
pub fn await_held(node: Node, within_ms: Int) -> Result(fn() -> Nil, String) {
  case process.receive(node.blocked, within_ms) {
    Ok(release) -> Ok(fn() { process.send(release, Nil) })
    Error(Nil) -> Error("the ledger process was not held")
  }
}

/// Connects to a member by its node name through the production path, and
/// reports the word for what came of it: `connected`, `refused` when the
/// handshake or the name check failed, or `not_linked` when the pin table does
/// not list the name.
pub fn connect(node: Node, name: String) -> String {
  case distribution.peer(node.booted.membership, name) {
    Error(_) -> "not_linked"
    Ok(peer) ->
      case distribution.connect(peer, 15_000) {
        Ok(Nil) -> "connected"
        Error(_) -> "refused"
      }
  }
}

/// Offers line `index` of `lines` to the ledger process, and reports the word
/// for the answer.
pub fn offer(
  node: Node,
  lines: List(BitArray),
  index: Int,
) -> Result(String, String) {
  use service <- result.try(option.to_result(
    node.booted.ledger,
    "the node runs no ledger",
  ))
  use line <- result.try(
    list.drop(lines, index)
    |> list.first
    |> result.replace_error("no such line in the script"),
  )
  case ledger_service.offer(service, line, 30_000) {
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
pub fn await_head(node: Node, seq: Int, within_ms: Int) -> Result(Nil, String) {
  use service <- result.try(option.to_result(
    node.booted.ledger,
    "the node runs no ledger",
  ))
  poll.until(within: within_ms, every: 50, attempt: fn() {
    case ledger_service.head(service, 5000) {
      Ok(head) if head.seq >= seq -> poll.Done(Nil)
      Ok(_) -> poll.Retry
      Error(ledger_service.Unreachable) -> poll.Fail("unreachable")
    }
  })
  |> outcome("the head did not reach " <> int.to_string(seq))
}

/// The names of the nodes this node is connected to, sorted.
pub fn connected(_node: Node) -> List(String) {
  ffi_nodes.connected()
  |> list.map(ffi_nodes.name)
  |> list.sort(string.compare)
}

/// Waits, within a bound, until the connected nodes are exactly `names`.
pub fn await_connected(
  node: Node,
  names: List(String),
  within_ms: Int,
) -> Result(Nil, String) {
  let wanted = list.sort(names, string.compare)
  poll.until(within: within_ms, every: 50, attempt: fn() {
    case connected(node) == wanted {
      True -> poll.Done(Nil)
      False -> poll.Retry
    }
  })
  |> outcome("the connected nodes did not become " <> string.join(wanted, ","))
}

fn outcome(
  result: poll.Outcome(Nil, String),
  expired: String,
) -> Result(Nil, String) {
  case result {
    poll.Answered(Nil) -> Ok(Nil)
    poll.Failed(reason) -> Error(reason)
    poll.Expired -> Error(expired)
  }
}

/// The head sequence number and the active members' names, comma separated.
pub fn describe(node: Node) -> Result(String, String) {
  use service <- result.try(option.to_result(
    node.booted.ledger,
    "the node runs no ledger",
  ))
  case ledger_service.status(service, 5000) {
    Ok(status) -> {
      let names =
        membership_ledger.members(status.ledger)
        |> list.map(fn(member) { member.name })
      Ok(
        "head "
        <> int.to_string(membership_ledger.head(status.ledger).seq)
        <> " members "
        <> string.join(names, ","),
      )
    }
    Error(ledger_service.Unreachable) -> Error("the service did not answer")
  }
}

/// This node's own name.
pub fn name(node: Node) -> String {
  node.local
}

/// Runs one `ledger.*` control command against this node's ledger process, as
/// the daemon's control socket does, and answers one line of JSON: the reply
/// body under `ok`, or the refusal under `error`. A scenario's operator reaches
/// the node through it, so the operator commands run against a node that is
/// really in the middle of a TLS deployment. `body` is the request body.
pub fn control(node: Node, command: String, body: String) -> String {
  let answer = {
    use service <- result.try(option.to_result(
      node.booted.ledger,
      "the node runs no ledger",
    ))
    use handle <- result.try(ledger_control.handle(service, node.local))
    use fields <- result.try(case json.parse(body) {
      Ok(json.Object(fields)) -> Ok(fields)
      _ -> Error("the request body is not an object")
    })
    case command {
      "ledger.status" ->
        ledger_control.status(handle) |> result.map_error(failure_text)
      "ledger.entries" ->
        case list.key_find(fields, "after"), list.key_find(fields, "limit") {
          Ok(json.Int(after)), Ok(json.Int(limit)) ->
            ledger_control.entries(handle, after, limit)
            |> result.map_error(failure_text)
          _, _ -> Error("after and limit are required")
        }
      "ledger.append" ->
        case list.key_find(fields, "lines") {
          Ok(json.Array(items)) -> {
            let lines =
              list.filter_map(items, fn(item) {
                case item {
                  json.String(line) -> Ok(line)
                  _ -> Error(Nil)
                }
              })
            ledger_control.append(handle, lines)
            |> result.map_error(failure_text)
          }
          _ -> Error("lines are required")
        }
      _ -> Error("unsupported control command")
    }
  }
  case answer {
    Ok(reply) -> json.to_string(json.Object([#("ok", reply)]))
    Error(reason) ->
      json.to_string(json.Object([#("error", json.String(reason))]))
  }
}

fn failure_text(failure: ledger_control.Failure) -> String {
  case failure {
    ledger_control.Invalid(step:) -> "ledger_invalid: " <> step
    ledger_control.Unavailable(reason:) -> reason
  }
}
