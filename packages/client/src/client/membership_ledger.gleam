//// The membership ledger as a pure fold: which nodes a deployment trusts, and
//// the pin table each node's TLS verify callback will read.
////
//// A distributed deployment trusts the nodes its signed, append-only ledger
//// names (protocol-change/086). Every node holds a copy, applies entries as it
//// learns them, and derives the same state from the same prefix. This module
//// is that derivation and nothing else. It owns no file, no process and no
//// key. The caller reads lines, hands them in with a verifier, and acts on the
//// answer: it appends the line to disk, publishes the pin table and drops the
//// connections of removed nodes. That split keeps every rule here a function
//// of the entries, so it can be tested by replaying logs and mutating them,
//// without a socket or a certificate.
////
//// ## The state is the applied prefix
////
//// A `Ledger` is the fold of entries `0..n`: the active members by name, the
//// set of every name ever enrolled, the head, and the identity of each applied
//// entry. It is immutable. A refused entry returns an error and the caller
//// keeps the `Ledger` it had, which is how a fork leaves a node's state
//// unchanged. Nothing hides a half-applied entry, because there is no
//// mutation to leave half done.
////
//// ## Flow
////
//// 1. `begin` reads the genesis line and starts a ledger, or `replay` does
////    that and applies a whole file.
//// 2. `accept` is the acceptance procedure of protocol-change/086 for one line
////    against a ledger: `membership_entry.read` runs steps 1 through 3, then
////    `apply` runs steps 4 through 7.
//// 3. `apply` classifies the entry against the head. At or below the head it
////    is a duplicate or a fork, above head plus one it is a gap, and at head
////    plus one `extend` checks the chain and `fold` applies it.
//// 4. `fold` enforces the per-kind rules: the entry cap, then `upsert` or
////    `revoke_member`. It returns the next `Ledger`.
//// 5. `pin_table` derives the table one node reads from the active members,
////    and `lookup_pin` and `lookup_node` read it.
//// 6. A signer's tool calls `check` before it signs, which runs the same fold
////    over an unsigned entry.
////
//// Steps 8 through 10 of the procedure (the durable append, the publish and
//// the disconnects) are effects, and they belong to the caller. The order
//// matters there and is stated in protocol-change/086: the append precedes the
//// publish.
////
//// ## Refusals
////
//// An entry that cannot be applied returns a `Refusal` whose `step` is the word
//// the control protocol reports: `malformed`, `bad_signature`,
//// `unsupported_format`, `fork`, `chain` or `invalid`. A duplicate of an entry
//// already applied and a gap above the head are not refusals; `apply` reports
//// them as outcomes, so the caller can ignore the first and ask for the entries
//// between for the second.

import client/distribution_plan.{type Role}
import client/membership_entry.{
  type DirectoryStanding, type Entry, type EntryId, type Member,
  type SignedEntry, type Verifier, Genesis, Member, NotInDirectory, Revoke,
  Upsert,
}
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/order
import gleam/result
import gleam/set.{type Set}
import gleam/string

/// The most entries a ledger may hold. A deployment that reaches it has made
/// thousands of changes and provisions again, which is the compaction.
pub const max_entries = 10_000

/// The most members that may be active at once.
pub const max_active = 64

/// The most member names a ledger may ever enroll. The atom a node creates is
/// the member's `node`, not its name, and re-upserting a name with a new node is
/// legal, so this does not bound the atoms: `max_entries` does.
pub const max_names = 256

/// The newest applied entry: its sequence number and identity.
pub type Head {
  Head(
    /// The sequence number, 0 for a ledger that holds only genesis.
    seq: Int,
    /// The identity of that entry.
    id: EntryId,
  )
}

/// The fold of an applied prefix of the log. Opaque, so the only way to hold
/// one is to start from a genesis entry and apply entries to it.
pub opaque type Ledger {
  Ledger(
    deployment: String,
    authority: BitArray,
    head: Head,
    applied: Dict(Int, EntryId),
    members: Dict(String, Member),
    ever: Set(String),
  )
}

/// A rule of the fold that an entry broke. The fold reports the first it
/// finds: the entry cap, then for a member entry the node, the pin, the links
/// and the two bounds, and for a revoke the name.
pub type Rule {
  /// The first entry of a ledger is not a genesis at sequence 0 with a zero
  /// `prev`.
  FirstEntryNotGenesis

  /// A genesis entry after the first.
  GenesisNotFirst

  /// The entry would be the 10,001st.
  LedgerFull

  /// The `node` of a member entry is the node of another active member.
  NodeInUse(node: String)

  /// The `pin` of a member entry is the pin of another active member.
  PinInUse

  /// A link names a member that is not active, or the member itself.
  UnknownLink(name: String)

  /// The entry would leave more than `max_active` members active.
  TooManyActive

  /// The entry would enroll more than `max_names` distinct names.
  TooManyNames

  /// A revoke names a member that is not active.
  NotActive(name: String)
}

/// Why an entry was refused. Each variant has a step word for the control
/// protocol and the status report.
pub type Refusal {
  /// The line did not become an entry: steps 1 through 3.
  Unreadable(error: membership_entry.ReadError)

  /// A different signed entry is already applied at this sequence number.
  /// The state is unchanged, and both identities are kept for the report.
  Fork(
    /// The sequence number both entries claim.
    seq: Int,
    /// The identity of the entry this ledger applied.
    ours: EntryId,
    /// The identity of the entry refused.
    theirs: EntryId,
  )

  /// The entry is next in sequence and its `prev` is not the head's identity.
  Chain

  /// The entry follows the chain and breaks a rule of the fold.
  Invalid(rule: Rule)
}

/// The step word of a refusal.
///
/// ## Examples
///
/// ```gleam
/// assert membership_ledger.step(membership_ledger.Chain) == "chain"
/// ```
pub fn step(refusal: Refusal) -> String {
  case refusal {
    Unreadable(error:) -> membership_entry.read_error_word(error)
    Fork(..) -> "fork"
    Chain -> "chain"
    Invalid(_) -> "invalid"
  }
}

/// What applying a readable entry came to, when it was not refused.
pub type Outcome {
  /// The entry extended the chain. The ledger is the new state, and the entry
  /// is what the caller appends to its file.
  Applied(ledger: Ledger, entry: SignedEntry)

  /// The ledger already holds this entry. Nothing changes and nothing is
  /// reported as a refusal.
  Duplicate

  /// The entry is more than one past the head. It is ignored, and `head` says
  /// where to pull from.
  Gap(head: Head)
}

// --- starting and replaying --------------------------------------------------

/// Reads the genesis line and starts a ledger from it.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(ledger) = membership_ledger.begin(genesis_line, verifier)
/// ```
pub fn begin(line: BitArray, verifier: Verifier) -> Result(Ledger, Refusal) {
  use signed <- result.try(
    membership_entry.read(line, verifier) |> result.map_error(Unreadable),
  )
  start(signed)
}

/// Starts a ledger from an entry already read.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(ledger) = membership_ledger.start(signed_genesis)
/// ```
pub fn start(signed: SignedEntry) -> Result(Ledger, Refusal) {
  let entry = signed.entry
  case entry.kind {
    Genesis(deployment:, authority:) -> {
      let at_origin =
        entry.seq == 0 && entry.prev == membership_entry.genesis_prev()
      use <- bool.guard(
        when: !at_origin,
        return: Error(Invalid(FirstEntryNotGenesis)),
      )
      let head = Head(seq: 0, id: signed.id)
      Ok(Ledger(
        deployment:,
        authority:,
        head:,
        applied: dict.from_list([#(0, signed.id)]),
        members: dict.new(),
        ever: set.new(),
      ))
    }

    Upsert(_) | Revoke(..) -> Error(Invalid(FirstEntryNotGenesis))
  }
}

/// Where a file replay stopped.
pub type ReplayError {
  ReplayError(
    /// The zero-based index of the line that failed.
    index: Int,
    /// Why it failed. A line that is a duplicate or a gap in a file is reported
    /// as `Chain`, because a stored ledger holds each sequence number once, in
    /// order.
    refusal: Refusal,
  )
}

/// Applies a whole file's lines in order: the first as genesis and each other
/// line through `accept`. It is the boot path, and it equals applying the same
/// lines one at a time.
///
/// ## Examples
///
/// ```gleam
/// membership_ledger.replay([genesis_line, member_line], verifier)
/// // -> Ok(ledger)
/// ```
pub fn replay(
  lines: List(BitArray),
  verifier: Verifier,
) -> Result(Ledger, ReplayError) {
  case lines {
    [] -> Error(ReplayError(index: 0, refusal: Invalid(FirstEntryNotGenesis)))
    [first, ..rest] -> {
      use ledger <- result.try(
        begin(first, verifier)
        |> result.map_error(fn(refusal) { ReplayError(index: 0, refusal:) }),
      )
      replay_loop(ledger, rest, 1, verifier)
    }
  }
}

fn replay_loop(
  ledger: Ledger,
  lines: List(BitArray),
  index: Int,
  verifier: Verifier,
) -> Result(Ledger, ReplayError) {
  case lines {
    [] -> Ok(ledger)
    [line, ..rest] ->
      case accept(ledger, line, verifier) {
        Ok(Applied(ledger: next, ..)) ->
          replay_loop(next, rest, index + 1, verifier)
        Ok(Duplicate) | Ok(Gap(_)) -> Error(ReplayError(index:, refusal: Chain))
        Error(refusal) -> Error(ReplayError(index:, refusal:))
      }
  }
}

// --- accepting an entry ------------------------------------------------------

/// The acceptance procedure of protocol-change/086 for one line, steps 1
/// through 7. It stops at the first failure and never changes the ledger it is
/// given.
///
/// ## Examples
///
/// ```gleam
/// case membership_ledger.accept(ledger, line, verifier) {
///   Ok(Applied(ledger: next, entry:)) -> append_then_publish(next, entry)
///   Ok(Duplicate) -> Nil
///   Ok(Gap(head)) -> pull_after(head)
///   Error(refusal) -> record(refusal)
/// }
/// ```
pub fn accept(
  ledger: Ledger,
  line: BitArray,
  verifier: Verifier,
) -> Result(Outcome, Refusal) {
  use signed <- result.try(
    membership_entry.read(line, verifier) |> result.map_error(Unreadable),
  )
  apply(ledger, signed)
}

/// Steps 4 through 7 for an entry already read: duplicate or fork, gap, chain
/// and the fold.
///
/// ## Examples
///
/// ```gleam
/// membership_ledger.apply(ledger, signed) // -> Ok(Applied(next, signed))
/// ```
pub fn apply(ledger: Ledger, signed: SignedEntry) -> Result(Outcome, Refusal) {
  let entry = signed.entry
  case int.compare(entry.seq, ledger.head.seq + 1) {
    order.Lt -> already_held(ledger, signed)
    order.Gt -> Ok(Gap(head: ledger.head))
    order.Eq -> {
      use next <- result.try(extend(ledger, entry, signed.id))
      Ok(Applied(ledger: next, entry: signed))
    }
  }
}

// An entry at or below the head: the same entry again is a duplicate, and a
// different one at the same sequence number is a fork. The applied identities
// are kept for exactly this comparison.
fn already_held(
  ledger: Ledger,
  signed: SignedEntry,
) -> Result(Outcome, Refusal) {
  let seq = signed.entry.seq
  case dict.get(ledger.applied, seq) {
    Ok(ours) if ours == signed.id -> Ok(Duplicate)
    Ok(ours) -> Error(Fork(seq:, ours:, theirs: signed.id))
    Error(Nil) -> Error(Chain)
  }
}

fn extend(
  ledger: Ledger,
  entry: Entry,
  id: EntryId,
) -> Result(Ledger, Refusal) {
  use <- bool.guard(when: entry.prev != ledger.head.id, return: Error(Chain))
  fold(ledger, entry, id)
}

/// What a signer's tool runs before it signs: the entry must decode to itself,
/// extend the head and satisfy the fold. A signer that skips it can produce a
/// line every node refuses.
///
/// ## Examples
///
/// ```gleam
/// membership_ledger.check(ledger, entry) // -> Ok(ledger_after)
/// ```
pub fn check(ledger: Ledger, entry: Entry) -> Result(Ledger, Refusal) {
  let body = membership_entry.encode_body(entry)
  use decoded <- result.try(
    membership_entry.decode_body(body) |> result.map_error(Unreadable),
  )
  use <- bool.guard(
    when: decoded != entry || entry.seq != ledger.head.seq + 1,
    return: Error(Chain),
  )
  extend(ledger, entry, membership_entry.id_of_body(body))
}

// --- the fold ----------------------------------------------------------------

// The entry is next in sequence and follows the head. The cap is checked
// first so a full ledger refuses every kind alike.
fn fold(ledger: Ledger, entry: Entry, id: EntryId) -> Result(Ledger, Refusal) {
  use <- bool.guard(
    when: entry.seq >= max_entries,
    return: Error(Invalid(LedgerFull)),
  )
  use #(members, ever) <- result.try(
    apply_kind(ledger, entry.kind) |> result.map_error(Invalid),
  )
  Ok(
    Ledger(
      ..ledger,
      head: Head(seq: entry.seq, id:),
      applied: dict.insert(ledger.applied, entry.seq, id),
      members:,
      ever:,
    ),
  )
}

fn apply_kind(
  ledger: Ledger,
  kind: membership_entry.Kind,
) -> Result(#(Dict(String, Member), Set(String)), Rule) {
  case kind {
    Genesis(..) -> Error(GenesisNotFirst)
    Upsert(member:) -> upsert(ledger, member)
    Revoke(name:, ..) -> revoke_member(ledger, name)
  }
}

// A member entry is an upsert keyed by name. Re-enrolling a revoked name is an
// ordinary upsert, since a revoked name is simply not active.
fn upsert(
  ledger: Ledger,
  member: Member,
) -> Result(#(Dict(String, Member), Set(String)), Rule) {
  let others = dict.delete(ledger.members, member.name)
  let rivals = dict.values(others)
  use <- bool.guard(
    when: list.any(rivals, fn(other) { other.node == member.node }),
    return: Error(NodeInUse(member.node)),
  )
  use <- bool.guard(
    when: list.any(rivals, fn(other) { other.pin == member.pin }),
    return: Error(PinInUse),
  )
  use Nil <- result.try(
    list.try_each(member.links, fn(link) {
      case dict.has_key(others, link) {
        True -> Ok(Nil)
        False -> Error(UnknownLink(link))
      }
    }),
  )

  // The two bounds are checked after the entry's own fields, so an entry that
  // is wrong in itself is reported as that and not as a capacity problem.
  let ever = set.insert(ledger.ever, member.name)
  use <- bool.guard(
    when: dict.size(others) >= max_active,
    return: Error(TooManyActive),
  )
  use <- bool.guard(
    when: set.size(ever) > max_names,
    return: Error(TooManyNames),
  )
  Ok(#(dict.insert(others, member.name, member), ever))
}

// A revoke removes the member and, with it, every edge that named it. The
// edges are dropped here because a name that is enrolled again later is a new
// member, and a link made to its previous holder must not return with it.
fn revoke_member(
  ledger: Ledger,
  name: String,
) -> Result(#(Dict(String, Member), Set(String)), Rule) {
  use <- bool.guard(
    when: !dict.has_key(ledger.members, name),
    return: Error(NotActive(name)),
  )
  let remaining =
    dict.delete(ledger.members, name)
    |> dict.map_values(fn(_, member) {
      Member(
        ..member,
        links: list.filter(member.links, fn(link) { link != name }),
      )
    })
  Ok(#(remaining, ledger.ever))
}

// --- reading the state -------------------------------------------------------

/// The deployment id the genesis entry named.
///
/// ## Examples
///
/// ```gleam
/// membership_ledger.deployment(ledger) // -> "3f9c.."
/// ```
pub fn deployment(ledger: Ledger) -> String {
  ledger.deployment
}

/// The SHA-256 of the authority certificate the genesis entry named. A node
/// compares it with the pin of its own `ca` file and refuses a ledger that
/// does not belong to it.
///
/// ## Examples
///
/// ```gleam
/// assert membership_ledger.authority(ledger) == ffi_pki.pin(ca_pem)
/// ```
pub fn authority(ledger: Ledger) -> BitArray {
  ledger.authority
}

/// The newest applied entry.
///
/// ## Examples
///
/// ```gleam
/// membership_ledger.head(ledger).seq // -> 9
/// ```
pub fn head(ledger: Ledger) -> Head {
  ledger.head
}

/// The active members, ordered by name.
///
/// ## Examples
///
/// ```gleam
/// list.map(membership_ledger.members(ledger), fn(member) { member.name })
/// // -> ["devbox", "hub"]
/// ```
pub fn members(ledger: Ledger) -> List(Member) {
  dict.values(ledger.members)
  |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
}

/// One active member by name.
///
/// ## Examples
///
/// ```gleam
/// membership_ledger.member(ledger, "hub") // -> Ok(Member(name: "hub", ..))
/// ```
pub fn member(ledger: Ledger, name: String) -> Result(Member, Nil) {
  dict.get(ledger.members, name)
}

/// The active member that answers to this Erlang node name. Node names are
/// unique among active members, so there is at most one. A node finds its own
/// plan name this way, since its configuration holds the node and not the name.
///
/// ## Examples
///
/// ```gleam
/// membership_ledger.member_at(ledger, "loom@hub.example")
/// // -> Ok(Member(name: "hub", ..))
/// ```
pub fn member_at(ledger: Ledger, node: String) -> Result(Member, Nil) {
  dict.values(ledger.members)
  |> list.find(fn(member) { member.node == node })
}

/// Whether a node's own name is enrolled, revoked or unknown to the ledger.
pub type Enrollment {
  /// The name is an active member.
  Enrolled(member: Member)

  /// The name was enrolled and has been revoked. The node stops its
  /// distribution.
  Revoked

  /// No entry names it. The node does not start distribution.
  NotEnrolled
}

/// The standing of a node name in the ledger.
///
/// ## Examples
///
/// ```gleam
/// assert membership_ledger.enrollment(ledger, "nobody")
///   == membership_ledger.NotEnrolled
/// ```
pub fn enrollment(ledger: Ledger, name: String) -> Enrollment {
  case dict.get(ledger.members, name) {
    Ok(member) -> Enrolled(member:)
    Error(Nil) ->
      case set.contains(ledger.ever, name) {
        True -> Revoked
        False -> NotEnrolled
      }
  }
}

// --- the pin table -----------------------------------------------------------

/// A peer a node may accept: the member a pin belongs to.
pub type Peer {
  Peer(
    /// The plan name.
    name: String,
    /// The Erlang node name its certificate must present.
    node: String,
    /// What the peer does.
    role: Role,
    /// Whether the peer is a member of the session directory.
    directory: DirectoryStanding,
  )
}

/// The peers one node accepts, as a function of the applied prefix. It maps
/// each linked member's pin to that member, and each member's node name to its
/// pin. Two nodes that applied the same entries hold equal tables for equal
/// names, and a table compares equal with `==`.
pub opaque type PinTable {
  PinTable(by_pin: Dict(BitArray, Peer), pin_of: Dict(String, BitArray))
}

/// The table of the node named `name`. It holds the pin of each active member
/// other than `name` that is linked to it: `name` lists the member, the member
/// lists `name`, or both are in the session directory. A name that is not an
/// active member has an empty table, and `enrollment` says why.
///
/// ## Examples
///
/// ```gleam
/// let table = membership_ledger.pin_table(ledger, "laptop")
/// membership_ledger.lookup_pin(table, hub_pin) // -> Ok(Peer(name: "hub", ..))
/// ```
pub fn pin_table(ledger: Ledger, name: String) -> PinTable {
  case dict.get(ledger.members, name) {
    Error(Nil) -> PinTable(by_pin: dict.new(), pin_of: dict.new())
    Ok(own) -> {
      let peers =
        dict.values(ledger.members)
        |> list.filter(fn(other) { other.name != name && linked(own, other) })
      PinTable(
        by_pin: dict.from_list(
          list.map(peers, fn(peer) { #(peer.pin, peer_of(peer)) }),
        ),
        pin_of: dict.from_list(
          list.map(peers, fn(peer) { #(peer.node, peer.pin) }),
        ),
      )
    }
  }
}

fn peer_of(member: Member) -> Peer {
  Peer(
    name: member.name,
    node: member.node,
    role: member.role,
    directory: member.directory,
  )
}

// Two members are linked when either lists the other, or when both belong to
// the session directory, because Ra needs every member able to reach every
// other.
fn linked(a: Member, b: Member) -> Bool {
  list.contains(a.links, b.name)
  || list.contains(b.links, a.name)
  || { a.directory != NotInDirectory && b.directory != NotInDirectory }
}

/// The table of the node whose Erlang node name is `node`, for a caller that
/// holds the node and not the plan name. A node that is not an active member
/// has the empty table, which refuses every peer.
///
/// ## Examples
///
/// ```gleam
/// membership_ledger.node_table(ledger, "loom@laptop.example")
/// ```
pub fn node_table(ledger: Ledger, node: String) -> PinTable {
  case member_at(ledger, node) {
    Ok(own) -> pin_table(ledger, own.name)
    Error(Nil) -> PinTable(by_pin: dict.new(), pin_of: dict.new())
  }
}

/// The peer a leaf certificate's pin names, which the verify callback then
/// compares with the certificate's node-name subject alternative name.
///
/// ## Examples
///
/// ```gleam
/// membership_ledger.lookup_pin(table, <<0:size(256)>>) // -> Error(Nil)
/// ```
pub fn lookup_pin(table: PinTable, pin: BitArray) -> Result(Peer, Nil) {
  dict.get(table.by_pin, pin)
}

/// The pin of the peer with this Erlang node name.
///
/// ## Examples
///
/// ```gleam
/// membership_ledger.lookup_node(table, "loom@hub.example") // -> Ok(<<..>>)
/// ```
pub fn lookup_node(table: PinTable, node: String) -> Result(BitArray, Nil) {
  dict.get(table.pin_of, node)
}

/// The peers of a table, ordered by name.
///
/// ## Examples
///
/// ```gleam
/// list.map(membership_ledger.peers(table), fn(peer) { peer.name })
/// // -> ["hub"]
/// ```
pub fn peers(table: PinTable) -> List(Peer) {
  dict.values(table.by_pin)
  |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
}

/// Whether the table accepts no peer.
///
/// ## Examples
///
/// ```gleam
/// assert membership_ledger.is_empty(membership_ledger.pin_table(ledger, "nobody"))
/// ```
pub fn is_empty(table: PinTable) -> Bool {
  dict.is_empty(table.by_pin)
}
