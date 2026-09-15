//// Private staging and publication reuse the installer shipped with this
//// client. Downloaded releases supply only verified files; their scripts do
//// not decide where or how an existing installation is replaced.

import gleam/bit_array
import gleam/bool
import gleam/erlang/application
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import host/bootstrap as host
import simplifile
import tui/internal/ffi_terminal
import tui/update/archive
import tui/update/manifest

/// Creates an exclusive private staging directory inside an existing parent.
///
/// ## Examples
///
/// ```gleam
/// // files.staging("/home/me/.local/lib/loom")
/// ```
pub fn staging(parent: String) -> Result(String, String) {
  let path =
    parent
    <> "/.update-"
    <> int.to_string(host.current_process_id())
    <> "-"
    <> int.to_string(host.system_time_ms())
  use Nil <- result.try(
    simplifile.create_directory(path)
    |> result.map_error(fn(_) {
      "cannot create exclusive update staging directory"
    }),
  )
  use Nil <- result.try(host.ensure_private_directory(path))
  Ok(path)
}

/// Reads exactly the expected compressed bytes, verifies them and stages data.
///
/// The destination must be a fresh private directory. Directories and files
/// are written before aliases, so no link can redirect a write. The archive
/// reader has already checked every ancestor and alias target.
///
/// ## Examples
///
/// ```gleam
/// // files.unpack(download, artifact, private_destination)
/// ```
pub fn unpack(
  path: String,
  artifact: manifest.Artifact,
  destination: String,
) -> Result(Nil, String) {
  use bytes <- result.try(host.read_bounded(path, artifact.size))
  let digest = host.sha256(bytes) |> bit_array.base16_encode |> string.lowercase
  use <- bool.guard(
    bit_array.byte_size(bytes) != artifact.size || digest != artifact.sha256,
    Error("release archive size or SHA-256 differs from manifest"),
  )
  use entries <- result.try(archive.decode(bytes, artifact.root))
  use Nil <- result.try(
    simplifile.create_directory_all(destination)
    |> result.map_error(fn(_) { "cannot create release staging tree" }),
  )
  use _ <- result.try(
    list.try_map(entries, fn(entry) {
      case entry {
        archive.Directory(path) ->
          simplifile.create_directory_all(destination <> "/" <> path)
        archive.File(path, bytes, mode) -> {
          use Nil <- result.try(simplifile.write_bits(
            destination <> "/" <> path,
            bytes,
          ))
          simplifile.set_permissions_octal(
            destination <> "/" <> path,
            case mode {
              archive.Data -> 0o644
              archive.Executable -> 0o755
            },
          )
        }
        archive.Alias(_, _) -> Ok(Nil)
      }
      |> result.map_error(fn(_) { "cannot stage release files" })
    }),
  )
  use _ <- result.try(
    list.try_map(entries, fn(entry) {
      case entry {
        archive.Directory(_) | archive.File(_, _, _) -> Ok(Nil)
        archive.Alias(path, target) ->
          simplifile.create_symlink(target, destination <> "/" <> path)
          |> result.map_error(fn(_) { "cannot stage release alias" })
      }
    }),
  )
  Ok(Nil)
}

/// Publishes immutable release trees through this client's trusted installer.
///
/// ## Examples
///
/// ```gleam
/// // files.publish(stage, "/home/me/.local", "bundled")
/// ```
pub fn publish(
  stage: String,
  prefix: String,
  client: String,
) -> Result(Nil, String) {
  use private <- result.try(
    application.priv_directory("tui")
    |> result.map_error(fn(_) { "this client lacks its trusted installer" }),
  )
  use bash <- result.try(host.find_executable("bash"))
  use env <- result.try(host.find_executable("env"))
  run(env, [
    "LOOM_INSTALL_SOURCE=" <> stage,
    "PREFIX=" <> prefix,
    "LOOM_CLIENT=" <> client,
    bash,
    private <> "/install.sh",
  ])
}

/// Executes a trusted utility with literal arguments and visible diagnostics.
///
/// ## Examples
///
/// ```gleam
/// // files.run("/usr/bin/gpgv", ["--version"])
/// ```
pub fn run(executable: String, arguments: List(String)) -> Result(Nil, String) {
  use status <- result.try(ffi_terminal.run_forwarding(executable, arguments))
  case status {
    0 -> Ok(Nil)
    status -> Error(executable <> " exited " <> int.to_string(status))
  }
}
