//// The first ledger of a deployment: the genesis entry and one `member` entry
//// per node of a plan, signed by the authority that issued their certificates.
////
//// `provision` mints certificates for every node of a plan and used to hand
//// each node a list of the pins of its peers. In ledger mode
//// (protocol-change/086) it hands each node the signed ledger instead, and
//// this module writes it. It is pure: the certificates, the signer and the
//// clock are arguments, so a test builds a ledger without a key store or a
//// clock and `distribution_provision` supplies the real ones.
////
//// ## The ledger says what the peer list said
////
//// A node's pin table is derived from the ledger (`membership_ledger.pin_table`)
//// and a node's peers in a static deployment come from the plan
//// (`distribution_plan.peers`). The two have to agree, or switching a
//// deployment to a ledger would change who trusts whom without anyone saying
//// so. This module makes them agree by construction. Each member lists in its
//// `links` the plan peers that were enrolled before it, because the fold
//// accepts a link only to a member that is already active. A link is symmetric
//// in the pin table, so listing each plan edge once, on the later of its two
//// ends, gives both ends the pin of the other. Members of the plan's directory
//// get the standing `voter`, so two of them are linked by the pin table's own
//// rule exactly as the plan links them; every other node is `none`, which is
//// what a laptop defaults to (design note, open question 11).
////
//// ## Order of work
////
//// 1. `build` signs the genesis entry, which names the authority certificate
////    by its pin and starts a `Ledger`.
//// 2. `enroll` is run once per plan node in plan order. It builds the node's
////    `member` entry from the plan, pre-flights it with
////    `membership_ledger.check` (the fold a node will run, so a plan that
////    breaks a rule of the ledger fails here by name), signs it, and moves
////    on with the checked ledger.
//// 3. `build` replays the finished lines against a verifier made from the
////    authority certificate. That proves the key that signed is the key of the
////    certificate the nodes will hold as their `ca`, and the ledger it
////    returns is the replay's, not the one built along the way.

import client/distribution_plan.{type Node, type Plan}
import client/membership_entry.{
  type Entry, type SignedEntry, type Signer, Entry, Member, NotInDirectory,
  Upsert, Voter,
}
import client/membership_ledger.{type Ledger}
import client/membership_signing
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}

/// A plan node together with the pin of the leaf certificate minted for it.
pub type Pinned {
  Pinned(
    /// The node as the plan wrote it.
    node: Node,
    /// The SHA-256 of the DER of its certificate, 32 bytes.
    pin: BitArray,
  )
}

/// What signs the entries and what they say about the deployment.
pub type Authority {
  Authority(
    /// PEM of the authority certificate that issued the node certificates.
    certificate: String,
    /// Signs the bytes of an entry with the authority key.
    sign: Signer,
    /// The signer's clock as `YYYY-MM-DDTHH:MM:SSZ`, written into every
    /// entry. See `time_text`.
    time: String,
    /// 32 lowercase hex characters, random, naming the deployment.
    deployment: String,
  )
}

/// A finished ledger.
pub type Built {
  Built(
    /// The lines of the file in order, the genesis first. They carry no
    /// trailing newline, which `file_text` adds.
    lines: List(String),
    /// The fold of those lines.
    ledger: Ledger,
  )
}

/// The text of a ledger file for lines: each line followed by a newline,
/// which is what makes a line complete (a last line without one is a write
/// that did not finish).
///
/// ## Examples
///
/// ```gleam
/// assert membership_provision.file_text(["a", "b"]) == "a\nb\n"
/// ```
pub fn file_text(lines: List(String)) -> String {
  string.concat(list.map(lines, fn(line) { line <> "\n" }))
}

/// A timestamp as the ledger writes one: UTC to the second, with no fraction.
///
/// ## Examples
///
/// ```gleam
/// assert membership_provision.time_text(timestamp.from_unix_seconds(0))
///   == "1970-01-01T00:00:00Z"
/// ```
pub fn time_text(time: Timestamp) -> String {
  let #(seconds, _) = timestamp.to_unix_seconds_and_nanoseconds(time)
  timestamp.to_rfc3339(
    timestamp.from_unix_seconds(seconds),
    calendar.utc_offset,
  )
}

/// Builds and signs the genesis entry and one member entry per node, in plan
/// order, and returns the file's lines with the ledger they fold to.
///
/// `pinned` holds one entry for each node of the plan, in plan order.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(Built(lines:, ledger:)) =
///   membership_provision.build(plan, pinned, authority)
/// ```
pub fn build(
  plan: Plan,
  pinned: List(Pinned),
  authority: Authority,
) -> Result(Built, String) {
  let unreadable = "the authority certificate is not readable"
  use pin <- result.try(
    membership_signing.authority_pin(authority.certificate)
    |> result.replace_error(unreadable),
  )
  use verify <- result.try(
    membership_signing.verifier(authority.certificate)
    |> result.replace_error(unreadable),
  )
  use start <- result.try(genesis(authority, pin))
  use finished <- result.try(
    list.try_fold(pinned, start, fn(state, member) {
      enroll(state, plan, authority, member)
    }),
  )
  let lines = list.reverse(finished.lines)

  // The replay is the proof that the lines verify under the certificate and
  // not only under the key that signed them. It is also the ledger a node
  // will hold, so it is the one returned.
  use ledger <- result.try(
    membership_ledger.replay(lines, verify)
    |> result.map_error(fn(failure) {
      "the ledger just written is refused at line "
      <> int.to_string(failure.index + 1)
      <> ", step "
      <> membership_ledger.step(failure.refusal)
    }),
  )
  use text <- result.try(
    list.try_map(lines, bit_array.to_string)
    |> result.replace_error("a ledger line is not text"),
  )
  Ok(Built(lines: text, ledger:))
}

// The ledger so far and the lines that made it, newest first, with the names
// already enrolled, which are the only names a later entry may link to.
type State {
  State(ledger: Ledger, lines: List(BitArray), enrolled: List(String))
}

/// Creates and signs the first ledger entry for a new deployment.
fn genesis(authority: Authority, pin: BitArray) -> Result(State, String) {
  let entry =
    Entry(
      seq: 0,
      prev: membership_entry.genesis_prev(),
      time: authority.time,
      kind: membership_entry.Genesis(
        deployment: authority.deployment,
        authority: pin,
      ),
    )
  use signed <- result.try(sign(entry, authority.sign))
  use ledger <- result.try(
    membership_ledger.start(signed)
    |> result.replace_error("the genesis entry is refused by the ledger"),
  )
  Ok(State(ledger:, lines: [membership_entry.line(signed)], enrolled: []))
}

/// Adds this node to a ledger and prepares its signed enrollment.
fn enroll(
  state: State,
  plan: Plan,
  authority: Authority,
  member: Pinned,
) -> Result(State, String) {
  let head = membership_ledger.head(state.ledger)
  let entry =
    Entry(
      seq: head.seq + 1,
      prev: head.id,
      time: authority.time,
      kind: Upsert(member_of(plan, member, state.enrolled)),
    )
  use ledger <- result.try(
    membership_ledger.check(state.ledger, entry)
    |> result.map_error(fn(refusal) {
      member.node.name
      <> " breaks a rule of the ledger at step "
      <> membership_ledger.step(refusal)
    }),
  )
  use signed <- result.try(sign(entry, authority.sign))
  Ok(
    State(
      ledger:,
      lines: [membership_entry.line(signed), ..state.lines],
      enrolled: [member.node.name, ..state.enrolled],
    ),
  )
}

/// Resolves the ledger member matching the local node identity.
fn member_of(
  plan: Plan,
  member: Pinned,
  enrolled: List(String),
) -> membership_entry.Member {
  let node = member.node
  let links =
    distribution_plan.peers(plan, node)
    |> list.map(fn(peer) { peer.name })
    |> list.filter(list.contains(enrolled, _))

  // Only directory-enabled peers participate in the membership network.
  let directory = case distribution_plan.in_directory(plan, node) {
    True -> Voter
    False -> NotInDirectory
  }

  Member(
    name: node.name,
    node: node.erlang_node,
    host: node.host,
    listen_port: node.listen_port,
    role: node.role,
    directory:,
    links:,
    pin: member.pin,
  )
}

/// Validates an entry against the ledger before signing it.
fn sign(entry: Entry, signer: Signer) -> Result(SignedEntry, String) {
  membership_entry.seal(entry, signer)
  |> result.map_error(fn(error) {
    case error {
      membership_entry.SigningFailed -> "the authority key could not sign"
      membership_entry.TooLarge ->
        "an entry is larger than a reader accepts; shorten the plan's names"
    }
  })
}
