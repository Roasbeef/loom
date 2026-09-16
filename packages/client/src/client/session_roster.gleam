//// Fix the session's tool surface before any recovered strand can run.
////
//// The catalogue stores the request, including inheritance, for retry
//// equality. This reserved fact stores its resolved meaning. Keeping them
//// separate prevents a daemon default change from invalidating a pinned
//// prompt or rewriting a child's deliberately narrowed active tool list.

import client/catalog
import client/codemode
import client/daemon/protocol
import core/json
import core/register
import core/tx
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import session/session
import storage/storage

/// The reserved identity of the session's resolved tool surface.
pub const key = "session/tool-roster"

/// The roster and seam choice resolved before the runtime starts.
pub type Surface {
  Surface(
    /// Which built-in definitions the registry includes.
    roster: catalog.Roster,
    /// Which code-mode capability boundaries this session serves.
    seams: codemode.Seams,
  )
}

/// Reuses a durable surface or initializes it while boot owns the store alone.
/// Legacy inherited sessions use Full, the only pre-feature roster. The
/// caller supplies its seam resolver so explicit operator choices survive.
///
/// ## Examples
///
/// ```gleam
/// // session_roster.prepare(opened, requested, configured, resolve_seams)
/// ```
pub fn prepare(
  opened: session.Session,
  requested: protocol.RosterRequest,
  configured: catalog.Roster,
  resolve_seams: fn(catalog.Roster) -> Result(codemode.Seams, String),
) -> Result(Surface, String) {
  use stored <- result.try(
    storage.get_register(opened.store, register.FactCustom, key)
    |> result.map_error(string.inspect),
  )
  case stored {
    Some(cell) -> decode(cell.value.payload)
    None -> initialize(opened, requested, configured, resolve_seams)
  }
}

fn initialize(
  opened: session.Session,
  requested: protocol.RosterRequest,
  configured: catalog.Roster,
  resolve_seams: fn(catalog.Roster) -> Result(codemode.Seams, String),
) {
  use primary <- result.try(
    storage.get_register(opened.store, register.StrandConfig, "main")
    |> result.map_error(string.inspect),
  )
  use prompt <- result.try(
    storage.get_register(opened.store, register.FactCustom, "prompt/system")
    |> result.map_error(string.inspect),
  )
  let roster = case requested, primary, prompt {
    protocol.InheritRoster, Some(_), _ | protocol.InheritRoster, _, Some(_) ->
      catalog.Full
    _, _, _ -> configured
  }
  use seams <- result.try(resolve_seams(roster))
  let surface = Surface(roster:, seams:)
  use _ <- result.try(
    storage.commit(
      opened.store,
      tx.Tx(
        writes: [
          tx.SetRegister(
            register.FactCustom,
            key,
            register.value(encode(surface)),
          ),
        ],
        expected: [tx.Expect(register.FactCustom, key, None)],
      ),
    )
    |> result.map_error(string.inspect),
  )
  Ok(surface)
}

fn encode(surface: Surface) {
  json.Object([
    #(
      "roster",
      json.String(case surface.roster {
        catalog.Full -> "full"
        catalog.Minimal -> "minimal"
      }),
    ),
    #(
      "seams",
      json.String(case surface.seams {
        codemode.WorkspaceOnly -> "workspace"
        codemode.OrchestrationOnly -> "orchestration"
        codemode.BothSeams -> "both"
      }),
    ),
  ])
}

fn decode(value) {
  use fields <- result.try(case value {
    json.Object([a, b]) -> Ok([a, b])
    _ -> Error("Invalid session tool-roster fact")
  })
  use roster <- result.try(case list.key_find(fields, "roster") {
    Ok(json.String("full")) -> Ok(catalog.Full)
    Ok(json.String("minimal")) -> Ok(catalog.Minimal)
    _ -> Error("Invalid session tool roster")
  })
  use seams <- result.try(case list.key_find(fields, "seams") {
    Ok(json.String("workspace")) -> Ok(codemode.WorkspaceOnly)
    Ok(json.String("orchestration")) -> Ok(codemode.OrchestrationOnly)
    Ok(json.String("both")) -> Ok(codemode.BothSeams)
    _ -> Error("Invalid session tool seams")
  })
  Ok(Surface(roster:, seams:))
}
