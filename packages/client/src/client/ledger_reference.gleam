//// Reading a node's ledger from its `[distribution]` table, for the daemon's
//// start and for the tables that name a peer.
////
//// A node in ledger mode (protocol-change/086) has no `[[distribution.peers]]`
//// list. The nodes it trusts are in the ledger file, and two readers need
//// them. The daemon's start opens the ledger and starts the process that owns
//// it (`client/ledger_boot`). The `[executors.<name>]`,
//// `[orchestrators.<name>]`, `[spawners.<name>]` and `[directory]` tables name
//// a peer by node and used to check the name against the pinned list, so in
//// ledger mode they check it against the ledger. This module is the one place
//// that turns the table into an opened, verified ledger, so the two readers
//// cannot disagree about what the file says or how a failure is worded.
////
//// ## Which nodes a table may name
////
//// The nodes in this node's pin table: the active members it is linked to.
//// That is the meaning the pinned list had, "a node this one trusts and can
//// connect to", and it is what `install` already holds a `/2` bundle to
//// (`distribution_bundle.decode`). A member that is active and not linked to
//// this node is refused, as a node that was never pinned is refused in static
//// mode. A member that has been revoked is no longer in the table, so a table
//// that still names it is refused until the operator edits the file. The
//// ledger's 086 text asks for a warning and an inert row for that case; this
//// build refuses instead, because a row that does nothing is a failure the
//// operator would find later than a refusal at start.
////
//// ## Why this reads the file
////
//// Parsing a table is otherwise pure. Here it opens the ledger, which also
//// cuts a final line with no newline from the file (`membership_store.open`).
//// That is the repair the ledger process makes at its own start, and the
//// tables are parsed before it runs, so the two never race.

import client/distribution.{type Config}
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

/// The node names another table of the configuration may reference: the
/// configured peers in static mode, and in ledger mode the nodes of the
/// members this node is linked to.
///
/// ## Examples
///
/// ```gleam
/// ledger_reference.nodes(config) // -> Ok(["executor@10.0.0.2"])
/// ```
pub fn nodes(config: Config) -> Result(List(String), String) {
  case distribution.ledger_path(config) {
    None -> Ok(distribution.peer_nodes(config))
    Some(path) -> {
      use loaded <- result.try(load(
        path,
        distribution.credential_files(config).ca,
        distribution.local_node(config),
      ))
      Ok(
        membership_ledger.node_table(
          loaded.ledger,
          distribution.local_node(config),
        )
        |> membership_ledger.peers
        |> list.map(fn(peer) { peer.node }),
      )
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
