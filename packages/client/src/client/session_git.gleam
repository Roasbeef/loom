//// The first activation owns the Git baseline before the runtime can execute.
////
//// This module commits through the unopened runtime's storage handle, just as
//// session identity initialization does. Later activations only read that fact;
//// failures and legacy sessions never acquire a misleading replacement HEAD.

import client/worktree_diff
import core/json
import core/register
import core/tx
import gleam/bool
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import session/session
import storage/storage

/// The host-owned baseline, protected by the reserved session fact prefix.
pub const key = "session/git-start"

/// Reads or initializes the baseline before the runtime writer is started.
///
/// The supplied probe is called only for a new session without a pinned prompt.
/// Store failures refuse boot rather than allowing work before the baseline is
/// durable. Git failures are values and do not refuse model work.
///
/// ## Examples
///
/// ```gleam
/// // session_git.prepare(opened, id, workspace, fn() { probe(wiring) })
/// ```
pub fn prepare(
  opened: session.Session,
  identity: String,
  workspace: String,
  probe: fn() -> worktree_diff.Start,
) -> Result(worktree_diff.Start, String) {
  use existing <- result.try(
    storage.get_register(opened.store, register.FactCustom, key)
    |> result.map_error(string.inspect),
  )
  case existing {
    Some(cell) -> decode(cell.value.payload, identity, workspace)
    None -> initialize(opened, identity, workspace, probe)
  }
}

fn initialize(opened: session.Session, identity, workspace, probe) {
  use prompt <- result.try(
    storage.get_register(opened.store, register.FactCustom, "prompt/system")
    |> result.map_error(string.inspect),
  )
  let start = case prompt {
    Some(_) ->
      worktree_diff.Unavailable("Session starting revision was not recorded")
    None -> probe()
  }
  use _ <- result.try(
    storage.commit(
      opened.store,
      tx.Tx(
        writes: [
          tx.SetRegister(
            register.FactCustom,
            key,
            register.value(encode(start, identity, workspace)),
          ),
        ],
        expected: [tx.Expect(register.FactCustom, key, None)],
      ),
    )
    |> result.map_error(string.inspect),
  )
  Ok(start)
}

fn encode(start, identity, workspace) {
  let #(kind, value) = case start {
    worktree_diff.Revision(revision) -> #("revision", revision)
    worktree_diff.Empty -> #("empty", "")
    worktree_diff.Unavailable(reason) -> #("unavailable", reason)
  }
  json.Object([
    #("session", json.String(identity)),
    #("workspace", json.String(workspace)),
    #("kind", json.String(kind)),
    #("value", json.String(value)),
  ])
}

fn decode(value, identity, workspace) {
  use fields <- result.try(case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("Invalid session Git baseline")
  })
  use owner <- result.try(text(fields, "session"))
  use directory <- result.try(text(fields, "workspace"))
  use kind <- result.try(text(fields, "kind"))
  use value <- result.try(text(fields, "value"))
  use <- bool.guard(
    owner != identity || directory != workspace,
    Ok(worktree_diff.Unavailable(
      "Session starting revision belongs to another session or workspace",
    )),
  )
  case kind {
    "revision" -> {
      let valid =
        { string.byte_size(value) == 40 || string.byte_size(value) == 64 }
        && list.all(string.to_graphemes(value), fn(c) {
          string.contains("0123456789abcdef", c)
        })
      case valid {
        True -> Ok(worktree_diff.Revision(value))
        False -> Error("Invalid session Git revision")
      }
    }
    "empty" if value == "" -> Ok(worktree_diff.Empty)
    "unavailable" -> Ok(worktree_diff.Unavailable(value))
    _ -> Error("Invalid session Git baseline kind")
  }
}

fn text(fields, name) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> Ok(value)
    _ -> Error("Invalid session Git baseline field: " <> name)
  }
}
