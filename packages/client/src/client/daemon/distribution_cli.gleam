//// The operator command that provisions trusted distribution.
////
//// The daemon starts distribution only on a VM booted with TLS distribution
//// flags and an options file, and the VM is booted before any Gleam code
//// runs. So the options file has to exist before the daemon does. This
//// command renders it from the same `[distribution]` table the daemon will
//// read, using the same function the daemon uses to check it at startup, so
//// the two cannot disagree. The `bin/loomd` launcher then adds the boot flags
//// when `LOOM_DISTRIBUTION_OPTFILE` names the file.
////
//// The file holds credential paths and public pins and no secret. It is
//// written with mode 0600 anyway, because the daemon refuses an options file
//// that other users can write.

import client/distribution
import client/internal/ffi_os
import gleam/io
import gleam/option.{None, Some}
import gleam/result
import host/bootstrap
import simplifile

/// Complete help for the distribution operator command.
pub const usage =
  "usage: loomd distribution options CONFIG OUTPUT\n\nRenders the TLS distribution options file for the [distribution] table of CONFIG into OUTPUT (mode 0600). Then start the daemon through bin/loomd with LOOM_DISTRIBUTION_OPTFILE set to OUTPUT and the same CONFIG, which adds -proto_dist inet_tls and -ssl_dist_optfile to ERL_FLAGS.\n\nExample:\n  loomd distribution options ~/.loom/loom.toml ~/.loom/distribution.options\n  LOOM_DISTRIBUTION_OPTFILE=~/.loom/distribution.options bin/loomd --config ~/.loom/loom.toml"

/// Renders the options file and exits nonzero with a one-line reason when it
/// cannot.
///
/// ## Examples
///
/// ```gleam
/// // loomd distribution options ~/.loom/loom.toml ~/.loom/distribution.options
/// ```
pub fn main(arguments: List(String)) -> Nil {
  case write_options(arguments) {
    Ok(Nil) -> Nil
    Error(reason) -> {
      io.println_error("loomd: " <> reason)
      ffi_os.halt(1)
    }
  }
}

/// Writes the options file for `options CONFIG OUTPUT`.
///
/// ## Examples
///
/// ```gleam
/// assert result.is_error(distribution_cli.write_options(["options"]))
/// ```
pub fn write_options(arguments: List(String)) -> Result(Nil, String) {
  case arguments {
    ["options", config, output] -> {
      use config <- result.try(bootstrap.absolute_path(config))
      use output <- result.try(bootstrap.absolute_path(output))
      use text <- result.try(
        simplifile.read(config)
        |> result.map_error(fn(error) {
          config <> " is unreadable: " <> simplifile.describe_error(error)
        }),
      )
      use found <- result.try(
        distribution.parse(text)
        |> result.map_error(fn(reason) { config <> ": " <> reason }),
      )
      use settings <- result.try(case found {
        Some(settings) -> Ok(settings)
        None -> Error(config <> " has no [distribution] table")
      })
      use Nil <- result.try(
        simplifile.write(output, distribution.tls_options(settings))
        |> result.map_error(fn(error) {
          output <> " is unwritable: " <> simplifile.describe_error(error)
        }),
      )
      simplifile.set_permissions_octal(output, 0o600)
      |> result.map_error(fn(error) {
        output
        <> " cannot be made private: "
        <> simplifile.describe_error(error)
      })
    }
    _ -> Error(usage)
  }
}
