//// The staged launcher checks the same distribution configuration and native
//// boot conditions as the daemon without starting the ledger or its listener.
//// The check is an observation: the actual daemon repeats it during startup.

import client/catalog
import client/daemon/main as daemon
import client/distribution
import client/internal/ffi_os
import gleam/dict
import gleam/io
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile
import tom

/// Runs the internal validation command and reports a bounded failure.
///
/// ## Examples
///
/// ```gleam
/// // launch_preflight.main(["tls", "/private/loom.toml"])
/// ```
pub fn main(arguments: List(String)) -> Nil {
  // A failed check must leave a nonzero receipt for the updater.
  case check(arguments) {
    Ok(Nil) -> Nil
    Error(reason) -> {
      io.println_error("loomd launch preflight: " <> reason)
      ffi_os.halt(1)
    }
  }
}

/// Parses the requested configuration and checks its distribution startup.
fn check(arguments: List(String)) -> Result(Nil, String) {
  // Only the internal forms select the expected mode and source.
  case arguments {
    ["local"] -> check_local()
    ["local", path] -> {
      use #(document, text) <- result.try(read_document(path))
      use Nil <- result.try(daemon.validate_launch_document(document, path))
      use Nil <- result.try(local_profile(document, text))
      use configured <- result.try(distribution.from_document(document))

      // A local replacement must not silently discard configured distribution.
      case configured {
        None -> check_local()
        Some(_) -> Error("configuration requires distribution")
      }
    }
    ["tls", path] -> {
      use #(document, _) <- result.try(read_document(path))
      use Nil <- result.try(daemon.validate_launch_document(document, path))
      use cluster <- result.try(daemon.validate_launch_distribution(
        document,
        path,
      ))
      use configured <- result.try(distribution.from_document(document))

      // A TLS replacement requires distribution settings in this file.
      case configured {
        None -> Error("configuration has no distribution settings")
        Some(config) ->
          distribution.validate(config, cluster)
          |> result.map_error(distribution.describe)
      }
    }
    _ -> Error("invalid launch preflight arguments")
  }
}

/// Loads the same TOML shape the daemon will parse at startup.
fn read_document(path: String) {
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(error) {
      "cannot read configuration: " <> string.inspect(error)
    }),
  )
  tom.parse(text)
  |> result.map(fn(document) { #(document, text) })
  |> result.map_error(fn(error) {
    "invalid configuration: " <> string.inspect(error)
  })
}

/// Refuses a local launch when any conflicting VM distribution flags remain.
fn check_local() {
  case distribution.launch_setting() {
    Ok(None) -> Ok(Nil)
    Ok(Some(_)) | Error(Nil) ->
      Error("local launch has conflicting distribution flags")
  }
}

/// A local profiling launch starts a named VM before the daemon entry point.
fn local_profile(
  document: dict.Dict(String, tom.Toml),
  text: String,
) -> Result(Nil, String) {
  case dict.get(document, "daemon") {
    Ok(tom.Table(fields)) ->
      case dict.get(fields, "profile") {
        Ok(tom.Bool(True)) ->
          case catalog.parse(text) {
            Ok(_) ->
              Error("local launch cannot reproduce daemon.profile = true")
            Error(_) -> Ok(Nil)
          }
        Ok(_) | Error(_) -> Ok(Nil)
      }
    Ok(_) | Error(_) -> Ok(Nil)
  }
}
