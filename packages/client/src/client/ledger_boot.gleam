//// Starting the ledger process for a daemon that configures a ledger
//// (protocol-change/086).
////
//// `client/ledger_service` takes a store and a verifier. A daemon has neither:
//// it has the `[distribution]` table, which names a ledger file and the `ca`
//// file whose certificate signed it. This module is the step between them. It
//// builds the verifier from the `ca` file, opens and replays the ledger, checks
//// that the genesis entry names that same certificate, and starts the process.
//// Every failure is a sentence for the operator naming the key to look at,
//// because the daemon refuses to start on it and the operator is reading a
//// terminal.
////
//// A daemon whose table has no `ledger` key gets `None` and starts exactly as
//// it did before the ledger existed.

import client/distribution
import client/ledger_service.{type Service}
import client/membership_ledger
import client/membership_signing
import client/membership_store
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import simplifile
import telemetry/field
import telemetry/log.{type Logger}

/// Starts the ledger process for the configured ledger, or does nothing when
/// the configuration names none. The process is linked to the caller.
///
/// A ledger that does not verify, that was signed by another authority than the
/// `ca` file's, or that cannot be read is an `Error` that says which.
///
/// ## Examples
///
/// ```gleam
/// ledger_boot.start(config, logger) // -> Ok(Some(service))
/// ```
pub fn start(
  config: distribution.Config,
  logger: Logger,
) -> Result(Option(Service), String) {
  case distribution.ledger_path(config) {
    None -> Ok(None)
    Some(path) ->
      start_at(path, distribution.credential_files(config).ca, logger)
  }
}

/// Starts the process for the ledger file at `path`, signed by the certificate
/// in the PEM file `ca`.
///
/// ## Examples
///
/// ```gleam
/// ledger_boot.start_at("/home/me/.loom/ledger.log", "/etc/loom/ca.pem", logger)
/// ```
pub fn start_at(
  path: String,
  ca: String,
  logger: Logger,
) -> Result(Option(Service), String) {
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
  case opened.tail {
    membership_store.Clean -> Nil
    membership_store.Repaired(bytes:) ->
      log.warn(logger, "ledger.tail_repaired", [field.count("bytes", bytes)])
  }
  ledger_service.configuration(
    opened.store,
    opened.ledger,
    verifier,
    [],
    logger,
  )
  |> ledger_service.start
  |> result.map(Some)
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
