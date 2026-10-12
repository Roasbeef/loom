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
//// connects after `net_kernel` starts. No peer can reach the process before
//// distribution is up, and the daemon holds no handle on it until this module
//// returns, so nothing can extend the ledger between the table it published
//// and the allow list this module sets afterwards.
////
//// ## Flow
////
//// 1. `start` with no `ledger` key only starts distribution, exactly as before.
//// 2. With one, `open_service` reads and verifies the file, requires this node
////    to be an active member, and starts the process with the observer of
////    `client/ledger_trust`, which publishes the table before `start` returns.
//// 3. `distribution.start` begins TLS distribution in live mode.
//// 4. The members this node is linked to are added to the allow list, and the
////    process is told to dial.

import client/distribution
import client/ledger_service.{type Service}
import client/ledger_trust
import client/membership_ledger
import client/membership_signing
import client/membership_store
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import simplifile
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
/// A directory member (`Member`) cannot use a ledger yet: the ledger would have
/// to derive the directory's members, which is a later phase of 086.
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
            "[directory] cannot be combined with [distribution] ledger yet: "
            <> "the directory's members come from [directory] members, and "
            <> "deriving them from the ledger is a later phase of "
            <> "protocol-change/086",
          )
      })
      let local = distribution.local_node(config)
      use service <- result.try(open_service(
        path,
        distribution.credential_files(config).ca,
        local,
        logger,
      ))
      use membership <- result.try(
        distribution.start(config, cluster)
        |> result.map_error(distribution.describe),
      )
      use Nil <- result.try(begin_trust(service, membership, local))
      Ok(Booted(membership:, ledger: Some(service)))
    }
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
/// certificate in the PEM file `ca`, for the node named `local`. The observer
/// of `client/ledger_trust` publishes the pin table before this returns.
///
/// A ledger that does not verify, that was signed by another authority than the
/// `ca` file's, that cannot be read, or in which `local` is not an active
/// member is an `Error` that says which.
///
/// ## Examples
///
/// ```gleam
/// ledger_boot.open_service("/home/me/.loom/ledger.log", "/etc/loom/ca.pem", "loom@a.example", logger)
/// ```
pub fn open_service(
  path: String,
  ca: String,
  local: String,
  logger: Logger,
) -> Result(Service, String) {
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
        <> ": it was never enrolled or it has been revoked. Install a bundle "
        <> "that enrolls it, or correct distribution.node",
      )
  })
  case opened.tail {
    membership_store.Clean -> Nil
    membership_store.Repaired(bytes:) ->
      log.warn(logger, "ledger.tail_repaired", [field.count("bytes", bytes)])
  }
  ledger_service.configuration(
    opened.store,
    opened.ledger,
    verifier,
    [ledger_trust.observer(local, logger)],
    logger,
  )
  |> ledger_service.start
  |> result.map_error(fn(error) {
    "the ledger process did not start: " <> error.reason
  })
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
