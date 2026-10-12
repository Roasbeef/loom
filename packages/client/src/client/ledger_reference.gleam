//// Reading a node's ledger from its `[distribution]` table, for the daemon's
//// start, and checking the tables that name a peer against it.
////
//// A node in ledger mode (protocol-change/086) has no `[[distribution.peers]]`
//// list. The nodes it trusts are in the ledger file. The daemon's start opens
//// the ledger and starts the process that owns it (`client/ledger_boot`). The
//// `[executors.<name>]`, `[orchestrators.<name>]`, `[spawners.<name>]` and
//// `[directory]` tables name a peer by node, and in static mode each node is
//// checked against the pinned list when the table is parsed.
////
//// ## Parsing never reads the ledger
////
//// Those tables are parsed on every session create, open and profile switch
//// (`client/catalog`), and a ledger changes while a daemon runs. If parsing
//// read the ledger, every session open would verify every signature in the
//// file again, and one `revoke` would make every session open fail for as long
//// as a table still named the revoked member. So in ledger mode `peers`
//// answers `Ledgered`, and a table checks the shape of its rows (names, keys,
//// types) and nothing about which nodes are members.
////
//// ## The daemon checks the rows once, at start
////
//// `audit` takes the ledger the ledger process holds and the node of every row,
//// and sorts them into three. A node that is an active member this node is
//// linked to is fine. A node that some member entry named and that is no longer
//// an active linked member is accepted as inert: its row stays in the file, the
//// daemon logs a warning naming the row and the reason, and a call to it fails
//// at call time, because peer resolution in live mode (`distribution.peer`)
//// answers only for names in the current pin table. A node that no entry ever
//// named is refused with a sentence for the operator: it is a typo, or a
//// configuration written for another deployment. This is the ruling of
//// protocol-change/086 on a row that names a revoked member, "a warning and an
//// inert row", and it is what keeps `revoke` from being an event that takes a
//// daemon's sessions down.
////
//// A table is not audited again while the daemon runs. A row that was live at
//// start and is revoked later is inert from the moment the entry is applied,
//// for the same reason, and the next start logs the warning.
////
//// ## Executor names
////
//// An orchestrator in ledger mode gets an `[executors.<name>]` row for each
//// executor it is linked to without the operator writing one
//// (`client/ledger_rows`), so a pool or a spawner may list an executor by a
//// name that no table of the file defines. The name is a reference like a node
//// is, and `audit_names` judges it the same way: a name nobody ever gave is
//// refused, a name that was a member and is no longer an active linked executor
//// is inert, and the rest are fine. In static mode a pool and a spawner still
//// need a written row, which their parsers check.
////
//// ## Why `load` reads the file
////
//// Opening the ledger also cuts a final line with no newline from the file
//// (`membership_store.open`). That is the repair the ledger process makes at
//// its own start, and `load` is called only from that start, so the repair
//// never races a second reader.

import client/distribution.{type Config}
import client/distribution_plan
import client/membership_entry.{type Verifier}
import client/membership_ledger.{type Ledger}
import client/membership_signing
import client/membership_store.{type Store}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import simplifile

/// A ledger file opened and checked against the node that reads it.
pub type Loaded {
  Loaded(
    /// The file, ready to append to.
    store: Store,
    /// The fold of every line in the file.
    ledger: Ledger,
    /// The verifier built from the `ca` file, which the process keeps.
    verifier: Verifier,
    /// Whether the end of the file had to be repaired.
    tail: membership_store.Tail,
  )
}

/// Opens the ledger file at `path`, signed by the certificate in the PEM file
/// `ca`, for the node named `local`.
///
/// A ledger that does not verify, that was signed by another authority than the
/// `ca` file's, that cannot be read, or in which `local` is not an active
/// member is an `Error` that says which. The sentences name the key to look
/// at, because the reader is an operator at a terminal.
///
/// ## Examples
///
/// ```gleam
/// ledger_reference.load(path, "/etc/loom/ca.pem", "loom@a.example")
/// // -> Ok(Loaded(store:, ledger:, verifier:, tail: Clean))
/// ```
pub fn load(path: String, ca: String, local: String) -> Result(Loaded, String) {
  use pem <- result.try(
    simplifile.read(ca)
    |> result.map_error(fn(_) { "distribution.ca could not be read: " <> ca }),
  )
  use verifier <- result.try(
    membership_signing.verifier(pem)
    |> result.replace_error("distribution.ca does not hold a certificate"),
  )
  use opened <- result.try(
    membership_store.open(path, verifier)
    |> result.map_error(describe_open(path, _)),
  )
  use pin <- result.try(
    membership_signing.authority_pin(pem)
    |> result.replace_error("distribution.ca does not hold a certificate"),
  )
  use Nil <- result.try(case membership_ledger.authority(opened.ledger) == pin {
    True -> Ok(Nil)
    False ->
      Error(
        "distribution.ledger names an authority other than the certificate in "
        <> "distribution.ca: "
        <> path,
      )
  })
  use Nil <- result.try(case membership_ledger.member_at(opened.ledger, local) {
    Ok(_) -> Ok(Nil)
    Error(Nil) ->
      Error(
        "distribution.node "
        <> local
        <> " is not an active member of the ledger "
        <> path
        <> ": it was never enrolled or it has been revoked. On the operator's "
        <> "machine, run `loom distribution enroll` for it and install the "
        <> "bundle it writes here with `loom distribution install --force` (a "
        <> "re-enrolled name gets a new certificate), or correct "
        <> "distribution.node. (`import` needs a running daemon, which this "
        <> "node cannot be until it is enrolled.)",
      )
  })
  Ok(Loaded(
    store: opened.store,
    ledger: opened.ledger,
    verifier:,
    tail: opened.tail,
  ))
}

/// What another table of the configuration may name, as far as parsing it can
/// tell.
pub type Peers {
  /// Static mode: exactly these nodes, the `[[distribution.peers]]` rows. A
  /// table is refused at parse time if it names any other node.
  Pinned(nodes: List(String))

  /// Ledger mode: the members change while the daemon runs, so a table is
  /// checked for shape only. The daemon compares its rows with the ledger once,
  /// at start (`audit`).
  Ledgered
}

/// The nodes a table may name, for the document's `[distribution]` table. This
/// reads no file.
///
/// ## Examples
///
/// ```gleam
/// ledger_reference.peers(config) // -> Pinned(["executor@10.0.0.2"])
/// ```
pub fn peers(config: Config) -> Peers {
  case distribution.ledger_path(config) {
    None -> Pinned(distribution.peer_nodes(config))
    Some(_) -> Ledgered
  }
}

/// Whether a table may name this node. Everything passes in ledger mode, where
/// `audit` makes the judgement.
///
/// ## Examples
///
/// ```gleam
/// assert ledger_reference.accepts(Pinned(["a@10.0.0.2"]), "a@10.0.0.2")
/// assert ledger_reference.accepts(Ledgered, "anything@10.0.0.9")
/// ```
pub fn accepts(peers: Peers, node: String) -> Bool {
  case peers {
    Pinned(nodes:) -> list.contains(nodes, node)
    Ledgered -> True
  }
}

/// One row of a table that names a node: where it is written, for the
/// operator, and the node it names.
pub type Row {
  Row(
    /// The key as the operator wrote it, such as `executors.devbox.node`.
    key: String,
    /// The Erlang node name the row names.
    node: String,
  )
}

/// A row the ledger does not currently support, which the daemon starts with.
pub type Inert {
  Inert(
    /// The row.
    row: Row,
    /// Why no call through it can succeed, in a sentence.
    reason: String,
  )
}

// What the ledger says about the node a row names.
type Standing {
  // An active member in this node's pin table.
  Linked

  // An active member this node is not linked to.
  NotLinked

  // Named by a member entry, and not an active member now.
  Departed

  // The node this table belongs to.
  Itself

  // Named by no entry.
  Unknown
}

/// Checks the rows of the four tables against the ledger the node runs on, for
/// the node named `local`, and returns the rows that are inert. `path` is the
/// ledger file, named in the sentence that refuses a row.
///
/// The first row that names a node no entry ever named, or this node itself, is
/// an `Error`. Rows are taken in the order given, so the caller's order is the
/// order of the refusal.
///
/// ## Examples
///
/// ```gleam
/// ledger_reference.audit(ledger, "loom@a.example", path, [
///   Row("executors.devbox.node", "loom@devbox.example"),
/// ])
/// // -> Ok([])
/// ```
pub fn audit(
  ledger: Ledger,
  local: String,
  path: String,
  rows: List(Row),
) -> Result(List(Inert), String) {
  let table = membership_ledger.node_table(ledger, local)
  use inert <- result.map(
    list.try_fold(rows, [], fn(inert, row) {
      case standing(ledger, table, local, row.node) {
        Linked -> Ok(inert)
        NotLinked ->
          Ok([
            Inert(
              row:,
              reason: "it is an active member of the ledger that this node is "
                <> "not linked to, so no connection to it is accepted",
            ),
            ..inert
          ])
        Departed ->
          Ok([
            Inert(
              row:,
              reason: "a member entry named it and it is no longer an active "
                <> "member, so calls to it fail",
            ),
            ..inert
          ])
        Itself ->
          Error(
            row.key
            <> " "
            <> row.node
            <> " is this node itself, which is not a peer of itself",
          )
        Unknown ->
          Error(
            row.key
            <> " "
            <> row.node
            <> " names a node that no entry of the ledger "
            <> path
            <> " has ever named: correct the node name, or enroll that node "
            <> "with `loom distribution enroll`",
          )
      }
    }),
  )
  list.reverse(inert)
}

/// One reference to an executor by name, in a table that is not an executor row:
/// a pool lists executors by name, and a spawner's placement names one. The key
/// is where the operator wrote it, such as `pools.builders.executors`.
pub type NameRow {
  NameRow(
    /// The key as the operator wrote it.
    key: String,
    /// The executor name the key lists.
    name: String,
  )
}

/// A name reference the ledger does not currently support, which the daemon
/// starts with.
pub type InertName {
  InertName(
    /// The reference.
    row: NameRow,
    /// Why no creation through it can succeed, in a sentence.
    reason: String,
  )
}

/// Checks the executor names that pools and spawners list against the ledger,
/// for the node named `local`, and returns the references that are inert.
/// `written` is the names of the executor rows the operator wrote, which a
/// reference may name without the ledger knowing them.
///
/// An executor row can be derived from the ledger (`client/ledger_rows`), so a
/// pool may name an executor that no `[executors.<name>]` table defines. The
/// rule is the one `audit` applies to a node. A name that no row and no entry
/// ever gave is an `Error`, because it is a typo or a file written for another
/// deployment. A name that was a member and is not an active linked executor
/// now is inert, and the daemon starts: the pool skips it, as it skips an
/// executor that is down. A name that the ledger enrolled as an orchestrator is
/// an `Error`, since it can never be a row of the executors table.
///
/// ## Examples
///
/// ```gleam
/// ledger_reference.audit_names(ledger, "loom@hub.example", "ledger.log", [], [
///   NameRow("pools.builders.executors", "box"),
/// ])
/// // -> Ok([])
/// ```
pub fn audit_names(
  ledger: Ledger,
  local: String,
  path: String,
  written: List(String),
  rows: List(NameRow),
) -> Result(List(InertName), String) {
  let table = membership_ledger.node_table(ledger, local)
  use inert <- result.map(
    list.try_fold(rows, [], fn(inert, row) {
      case list.contains(written, row.name) {
        True -> Ok(inert)
        False ->
          case membership_ledger.enrollment(ledger, row.name) {
            membership_ledger.Enrolled(member:) ->
              named_member(inert, row, member, table)
            membership_ledger.Revoked ->
              Ok([
                InertName(
                  row:,
                  reason: "the ledger enrolled it and then revoked it, so it "
                    <> "is skipped",
                ),
                ..inert
              ])
            membership_ledger.NotEnrolled ->
              Error(
                row.key
                <> " names "
                <> row.name
                <> ", which is neither an [executors.<name>] row nor a member "
                <> "of the ledger "
                <> path
                <> ": correct the name, or enroll that executor with `loom "
                <> "distribution enroll`",
              )
          }
      }
    }),
  )
  list.reverse(inert)
}

// A reference to a name that is an active member: an executor this node is
// linked to is fine, an executor it is not linked to is inert, and anything
// else cannot be an executor row.
fn named_member(
  inert: List(InertName),
  row: NameRow,
  member: membership_entry.Member,
  table: membership_ledger.PinTable,
) -> Result(List(InertName), String) {
  case member.role, membership_ledger.lookup_node(table, member.node) {
    distribution_plan.Executor, Ok(_) -> Ok(inert)
    distribution_plan.Executor, Error(Nil) ->
      Ok([
        InertName(
          row:,
          reason: "it is an executor that this node is not linked to, so it "
            <> "has no row",
        ),
        ..inert
      ])
    distribution_plan.Orchestrator, _ ->
      Error(
        row.key
        <> " names "
        <> row.name
        <> ", which the ledger enrolled as an orchestrator and not an executor",
      )
  }
}

fn standing(
  ledger: Ledger,
  table: membership_ledger.PinTable,
  local: String,
  node: String,
) -> Standing {
  case node == local, membership_ledger.lookup_node(table, node) {
    True, _ -> Itself
    False, Ok(_) -> Linked
    False, Error(Nil) ->
      case membership_ledger.member_at(ledger, node) {
        Ok(_) -> NotLinked
        Error(Nil) ->
          case membership_ledger.ever_named(ledger, node) {
            True -> Departed
            False -> Unknown
          }
      }
  }
}

fn describe_open(path: String, error: membership_store.OpenError) -> String {
  let place = "distribution.ledger " <> path
  case error {
    membership_store.Unreadable(reason:) ->
      place <> " could not be read: " <> reason
    membership_store.NoGenesis -> place <> " holds no complete entry"
    membership_store.Corrupt(line:, refusal:) ->
      place
      <> " is not a valid ledger: line "
      <> int.to_string(line)
      <> " was refused at step "
      <> membership_ledger.step(refusal)
    membership_store.RepairFailed(reason:) ->
      place
      <> " ends in an unfinished line that could not be removed: "
      <> reason
  }
}
