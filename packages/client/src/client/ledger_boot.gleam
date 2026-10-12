//// Starting distribution for a daemon, with the membership ledger first when
//// the configuration has one (protocol-change/086).
////
//// `client/ledger_service` takes a store and a verifier. A daemon has neither:
//// it has the `[distribution]` table, which names a ledger file and the `ca`
//// file whose certificate signed it. This module is the step between them. It
//// builds the verifier from the `ca` file, opens and replays the ledger, checks
//// that the genesis entry names that same certificate and that this node is an
//// active member, and starts the process. Every failure is a sentence for the
//// operator naming the key to look at, because the daemon refuses to start on
//// it and the operator is reading a terminal.
////
//// ## Why the ledger starts before distribution
////
//// In ledger mode the verify callback refuses every handshake until the pin
//// table exists (`ledger_unavailable`). If distribution started first, the
//// listener would be open while the table was not, and the first peer to
//// connect in that window would be refused for a reason that is no one's
//// fault. So the order is fixed: the ledger process starts and publishes the
//// table, then distribution starts, and only then does the node begin to dial.
//// The window does not exist, and no test has to prove that it fails closed.
////
//// The process needs no distribution to start. A monitor of node changes is
//// valid on a VM that is not yet distributed, and it hears every node that
//// connects after `net_kernel` starts. Distribution is up before `begin_trust`
//// sets the allow list, so a peer can connect, and a pull can apply an entry,
//// in that interval. That is harmless: the observer of `client/ledger_trust`
//// also grows the allow list on every `Extended`, so a name the entry added is
//// allowed whether `begin_trust` or the entry got there first.
////
//// ## Flow
////
//// 1. `start` takes the configuration and calls `start_with` with the
////    production observer. A table with no ledger key only starts
////    distribution, exactly as before.
//// 2. With a ledger, `open_service` reads and verifies the file, requires this
////    node to be an active member, and starts the process with the observer of
////    `client/ledger_trust`, which publishes the table before it returns.
//// 3. `own_cluster` reads this node's directory standing from the ledger.
////    `distribution.start` begins TLS distribution in live mode, visible for a
////    node the ledger seats in the session directory and hidden otherwise.
//// 4. `begin_trust` adds the members this node is linked to to the allow list,
////    and tells the process to dial.

import client/distribution
import client/ledger_reference
import client/ledger_service.{type Observer, type Service}
import client/ledger_trust
import client/membership_entry
import client/membership_ledger
import client/membership_store
import gleam/option.{type Option, None, Some}
import gleam/result
import telemetry/field
import telemetry/log.{type Logger}

/// What a daemon holds after its distribution is up.
pub type Booted {
  Booted(
    /// The local boot, which resolves a peer name to a node.
    membership: distribution.Membership,
    /// The ledger process, when the configuration names a ledger. The control
    /// commands of a later slice read and extend the ledger through it.
    ledger: Option(Service),
  )
}

/// Starts distribution, with the ledger process before it when the
/// configuration names a ledger. The process is linked to the caller and lives
/// as long as it does. On an `Error` the daemon does not start, and the
/// process it may have started goes with it.
///
/// With a ledger, whether this node is a directory member is the ledger's
/// answer and not the caller's: the node starts visible, as a member must, when
/// its entry gives it a `voter` or `learner` standing, and hidden otherwise. A
/// `Member` cluster passed with a ledger is refused, because it would be a
/// second source for the members (protocol-change/086, phase 3).
///
/// ## Examples
///
/// ```gleam
/// ledger_boot.start(config, distribution.NotMember, logger)
/// // -> Ok(Booted(membership:, ledger: Some(service)))
/// ```
pub fn start(
  config: distribution.Config,
  cluster: distribution.Cluster,
  logger: Logger,
) -> Result(Booted, String) {
  let local = distribution.local_node(config)
  start_with(config, cluster, [ledger_trust.observer(local, logger)], logger)
}

/// The same start with the observers of the ledger process given by the
/// caller, in place of `ledger_trust.observer`. A test uses it to put a hook in
/// front of the production observer, so that it can hold the process between
/// two steps and order a handshake against them.
///
/// ## Examples
///
/// ```gleam
/// ledger_boot.start_with(config, distribution.NotMember, [hook, trust], logger)
/// ```
pub fn start_with(
  config: distribution.Config,
  cluster: distribution.Cluster,
  observers: List(Observer),
  logger: Logger,
) -> Result(Booted, String) {
  case distribution.ledger_path(config) {
    None ->
      distribution.start(config, cluster)
      |> result.map(Booted(_, None))
      |> result.map_error(distribution.describe)
    Some(path) -> {
      use Nil <- result.try(case cluster {
        distribution.NotMember -> Ok(Nil)
        distribution.Member(..) ->
          Error(
            "[directory] cannot be combined with [distribution] ledger: the "
            <> "directory's members are the ledger's members whose standing is "
            <> "voter or learner, so remove the [directory] table",
          )
      })
      let local = distribution.local_node(config)
      use service <- result.try(open_service(
        path,
        distribution.credential_files(config).ca,
        local,
        observers,
        logger,
      ))
      use own <- result.try(own_cluster(service, local))
      use membership <- result.try(
        distribution.start(config, own)
        |> result.map_error(distribution.describe),
      )
      use Nil <- result.try(begin_trust(service, membership, local))
      Ok(Booted(membership:, ledger: Some(service)))
    }
  }
}

// Whether this node starts as a member of the session directory, from the
// ledger the process holds. The list of members is empty because a ledger node
// learns them from the table it publishes, and `distribution` reads the table
// for the link of every connection it makes.
fn own_cluster(
  service: Service,
  local: String,
) -> Result(distribution.Cluster, String) {
  use status <- result.map(
    ledger_service.status(service, 5000)
    |> result.replace_error("the ledger process did not answer"),
  )
  case membership_ledger.member_at(status.ledger, local) {
    Ok(own) if own.directory != membership_entry.NotInDirectory ->
      distribution.Member(members: [])
    _ -> distribution.NotMember
  }
}

// The second half of the start, once distribution is up. The allow list is set
// from the ledger the process holds, and the process is told to dial. Reading
// the ledger back from the process, and not keeping the one opened earlier, is
// what keeps this correct if a later change lets a line arrive before this.
fn begin_trust(
  service: Service,
  membership: distribution.Membership,
  local: String,
) -> Result(Nil, String) {
  use status <- result.try(
    ledger_service.status(service, 5000)
    |> result.replace_error("the ledger process did not answer"),
  )
  use Nil <- result.try(
    ledger_trust.allow_members(status.ledger, local)
    |> result.replace_error("net_kernel refused the ledger's member names"),
  )
  ledger_service.enable_dialing(
    service,
    ledger_trust.dialing(membership, local),
  )
  Ok(Nil)
}

/// Starts the ledger process for the ledger file at `path`, signed by the
/// certificate in the PEM file `ca`, for the node named `local`. The observers
/// have seen the loaded ledger before this returns, so with the observer of
/// `client/ledger_trust` the pin table is published by then.
///
/// A ledger that does not verify, that was signed by another authority than the
/// `ca` file's, that cannot be read, or in which `local` is not an active
/// member is an `Error` that says which.
///
/// ## Examples
///
/// ```gleam
/// ledger_boot.open_service(path, "/etc/loom/ca.pem", "loom@a.example", [trust], logger)
/// ```
pub fn open_service(
  path: String,
  ca: String,
  local: String,
  observers: List(Observer),
  logger: Logger,
) -> Result(Service, String) {
  use loaded <- result.try(ledger_reference.load(path, ca, local))
  case loaded.tail {
    membership_store.Clean -> Nil
    membership_store.Repaired(bytes:) ->
      log.warn(logger, "ledger.tail_repaired", [field.count("bytes", bytes)])
  }
  ledger_service.configuration(
    loaded.store,
    loaded.ledger,
    loaded.verifier,
    observers,
    logger,
  )
  |> ledger_service.start
  |> result.map_error(fn(error) {
    "the ledger process did not start: " <> error.reason
  })
}
