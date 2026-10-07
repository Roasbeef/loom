//// Exact configuration consent crosses one fixed host-owned file boundary.
////
//// A proposal observes the trusted real path, base bytes and one literal hunk.
//// Validation never writes. Approved edits acquire the existing kernel file
//// lock before rereading the base, so two daemon sessions cannot both replace
//// one observation. The atomic private writer preserves complete documents;
//// a refresh confirms publication without changing an active operation's pin.
//// An unrelated editor must still own its filesystem save: it does not take
//// Loom's lock, so the final base check is optimistic with respect to editors.

import client/config_reload
import gleam/bit_array
import gleam/bool
import gleam/erlang/process
import gleam/option.{type Option}
import gleam/result
import gleam/string
import host/bootstrap
import simplifile
import tools/blob
import tools/configuration
import weft

/// The sibling lock has a fixed name and is protected with its config file.
///
/// ## Examples
///
/// ```gleam
/// assert config_edit.lock_path("/home/operator/loom.toml")
///   == "/home/operator/loom.toml.loom-edit.lock"
/// ```
pub fn lock_path(path: String) -> String {
  path <> ".loom-edit.lock"
}

/// Establishes the stable lock before a session publishes its sandbox policy.
///
/// Read-only configurations remain usable when lock creation is unavailable;
/// assembly retains this error to disable edits for that session.
///
/// ## Examples
///
/// ```gleam
/// // config_edit.prepare(Some("/home/operator/loom.toml"))
/// ```
@internal
pub fn prepare(path: Option(String)) -> Result(Nil, String) {
  case path {
    option.None -> Ok(Nil)
    option.Some(path) -> {
      let lock = lock_path(path)
      case simplifile.link_info(lock) {
        Error(simplifile.Enoent) -> {
          // Preparation needs the inode, not exclusive edit custody. A second
          // session may observe creation while the first still holds its lock.
          case bootstrap.try_launch_lock(lock) {
            Ok(held) -> bootstrap.release_launch_lock(held)
            Error(_) -> Nil
          }
          regular_lock(lock)
          |> result.replace_error(
            "Configuration editing is unavailable: its stable file lock could not be prepared. Restart after making the configuration directory writable.",
          )
        }
        Ok(_) | Error(_) -> regular_lock(lock)
      }
    }
  }
}

fn regular_lock(path: String) -> Result(Nil, String) {
  use info <- result.try(
    simplifile.link_info(path)
    |> result.replace_error("The configuration lock could not be inspected."),
  )
  use <- bool.guard(
    simplifile.file_info_type(info) != simplifile.File,
    Error("The configuration lock must be a regular file, never a symlink."),
  )
  unchanged_path(path)
}

/// Binds inspection and exact edits to the explicitly selected real path.
///
/// `validate` is the complete configuration decoder, without effectful secret
/// resolution. `refresh` belongs to the resident holder, not a model callback.
///
/// ## Examples
///
/// ```gleam
/// // config_edit.door(path, validate, refresh)
/// ```
pub fn door(
  path: Option(String),
  validate: fn(String) -> Result(Nil, String),
  refresh: fn() -> Result(List(String), String),
) -> configuration.Door {
  configuration.Door(
    read: fn() {
      use path <- result.try(selected(path))
      read(path)
    },
    validate: fn(edit) {
      use path <- result.try(selected(path))
      use candidate <- result.try(candidate(path, edit))
      validate_bounded(validate, candidate)
    },
    apply: fn(edit) {
      use path <- result.try(selected(path))
      apply(path, edit, validate, refresh)
    },
  )
}

fn selected(path: Option(String)) -> Result(String, String) {
  option.to_result(
    path,
    "No configuration file was selected. Start the daemon with --config pointing to your loom.toml before proposing edits.",
  )
}

fn read(path: String) -> Result(configuration.Document, String) {
  use Nil <- result.try(unchanged_path(path))
  use text <- result.try(
    config_reload.read(path)
    |> result.replace_error(
      "The selected configuration is unreadable or exceeds 1 MiB.",
    ),
  )
  Ok(configuration.Document(
    path,
    blob.ref_for(bit_array.from_string(text)),
    text,
  ))
}

fn unchanged_path(path: String) -> Result(Nil, String) {
  use resolved <- result.try(bootstrap.canonical_path(path))
  case resolved == path {
    True -> Ok(Nil)
    False ->
      Error(
        "The selected configuration path changed its target; restart before editing it.",
      )
  }
}

fn candidate(path: String, edit: configuration.Edit) -> Result(String, String) {
  use <- bool.guard(
    edit.path != path,
    Error("Only the explicitly selected configuration file can be edited."),
  )
  use before <- result.try(read(path))
  use <- bool.guard(
    before.digest != edit.digest,
    Error(
      "Configuration changed since inspection; read it again and propose a fresh edit.",
    ),
  )
  use after <- result.try(case edit.old {
    "" -> Ok(before.text <> edit.new)
    old -> {
      case string.split(before.text, old) {
        [head, tail] -> Ok(head <> edit.new <> tail)
        _ ->
          Error(
            "old must match exactly once; read the configuration and choose a unique anchor.",
          )
      }
    }
  })
  use <- bool.guard(
    after == before.text
      || string.byte_size(after) > config_reload.max_file_bytes,
    Error("The edit must change the document and remain within 1 MiB."),
  )
  Ok(after)
}

fn validate_bounded(validate, text) -> Result(Nil, String) {
  case
    weft.new([fn() { validate(text) }])
    |> weft.deadline(1000)
    |> weft.cancel_when_exits(process.self())
    |> weft.start
  {
    [weft.Completed(value:, ..)] -> Ok(value)
    [weft.Failed(error:, ..)] -> Error("Configuration is invalid: " <> error)
    [weft.Crashed(..)]
    | [weft.Abandoned(..)]
    | [weft.NeverStarted(..)]
    | [weft.DrainProofLost(..)]
    | [weft.CancellationUnconfirmed(..)]
    | []
    | [_, _, ..] ->
      Error("Configuration validation did not complete within its deadline.")
  }
}

fn apply(path, edit, validate, refresh) -> Result(String, String) {
  let lock = lock_path(path)
  use Nil <- result.try(case simplifile.link_info(lock) {
    Error(simplifile.Enoent) -> Ok(Nil)
    Error(_) -> Error("The configuration lock could not be inspected.")
    Ok(info) -> {
      case simplifile.file_info_type(info) {
        simplifile.File -> unchanged_path(lock)
        _ ->
          Error(
            "The configuration lock must be a regular file, never a symlink.",
          )
      }
    }
  })
  use held <- result.try(
    bootstrap.try_launch_lock(lock)
    |> result.replace_error(
      "Another configuration edit holds the file lock; make a fresh proposal after it completes.",
    ),
  )

  // All exits below release the kernel holder. Never unlink its file: replacing
  // a lock inode could let another session acquire a different lock for this path.
  let saved = {
    use after <- result.try(candidate(path, edit))
    use Nil <- result.try(validate_bounded(validate, after))
    use current <- result.try(candidate(path, edit))
    use <- bool.guard(
      current != after,
      Error("Configuration changed during validation; propose a fresh edit."),
    )
    use Nil <- result.try(bootstrap.atomic_write_private(path, after))
    case refresh() {
      Ok([]) ->
        Ok(
          "Configuration saved and reloaded. Active operations retain their captured settings; subsequent operations use the new revision.",
        )
      Ok(sections) ->
        Ok(
          "Configuration saved and reloaded. Restart required for: "
          <> string.join(sections, ", ")
          <> ". Active operations retain their captured settings.",
        )
      Error(_) ->
        Ok(
          "Configuration saved. Reload confirmation is unavailable; the watcher will retry observation. Inspect the file before proposing another edit.",
        )
    }
  }
  bootstrap.release_launch_lock(held)
  saved
}
