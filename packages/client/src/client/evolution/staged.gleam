//// A staged extension generation: everything a prepared jailed version needs
//// that does not belong to the orchestrator.
////
//// Staging an approved extension starts a dedicated effect plane, compiles the
//// candidate, launches its satellite and declares its tools. Those pieces are
//// all a machine owns, and none of them depends on the session's catalogue or
//// on the session's hook bus. This module names that value so the machine can
//// hand it to whichever side keeps the orchestrator's half: today
//// `machine/local.generation_of` starts the bus and the approval and identity
//// checks over it, and an executor holding a `Staged` can serve the same value
//// without any of them.
////
//// The types sit in their own module because `stateful` produces them and
//// `machine/local` consumes them while importing `stateful` itself, so
//// defining them in either would close an import cycle.
////
//// The value carries no catalogue, no `live` type and no hook bus. A refusal
//// from the catalogue (an unapproved or changed selection) is the
//// orchestrator's to raise before and after it, never the machine's.

import client/evolution/record
import client/evolution/retirement
import client/evolution/store
import client/extension/hooks
import core/json
import core/msgpack
import gleam/option.{type Option}
import tools/tool

/// One prepared version, its callable tools and its native cleanup witness.
pub type Staged {
  Staged(
    /// The extension's manifest name; hook refusals are attributed to it.
    name: String,
    /// The exact catalogue selection this version implements.
    selection: record.Selection,
    /// The declared tools, whose `run` closures call into the satellite.
    tools: List(tool.Tool),
    /// The hook events the manifest declared. The bus skips any other event
    /// before it calls the satellite.
    events: List(String),
    /// Fires one hook event at the satellite: event, arguments and a deadline
    /// in milliseconds. The extension's name is fixed by this value.
    invoke: fn(String, msgpack.MsgPackValue, Int) ->
      Result(msgpack.MsgPackValue, hooks.HookFailure),
    /// A bounded census of the dedicated plane, plus live status when the
    /// generation opted into in-place upgrade.
    inventory: fn() -> Result(json.JsonValue, String),
    /// Stops the satellite host, then closes the plane. A failure carries the
    /// continuation that remains.
    retire: retirement.Task,
    /// Present when the extension's live contract admits an in-place upgrade.
    upgrade: Option(Upgrade),
  )
}

/// The in-place upgrade path of a stateful generation.
pub type Upgrade {
  Upgrade(
    /// Compiles and prepares the candidate for the selection into the slot the
    /// running version does not occupy. The caller has already checked that
    /// the selection is approved, so this only reads the candidate it is given.
    prepare: fn(record.Selection, record.Candidate) ->
      Result(PreparedStaged, store.Refusal),
  )
}

/// A prepared successor awaiting the central generation-fenced selection.
pub type PreparedStaged {
  PreparedStaged(
    /// The successor shares the predecessor's host and plane, so its `retire`
    /// is the predecessor's.
    successor: Staged,
    /// Publishes or reconciles the exact committed transition receipt.
    publish: fn() -> Result(Nil, store.Refusal),
    /// Compensates an unpublished transition and resumes the old callbacks.
    abort: fn() -> Result(Nil, store.Refusal),
  )
}
