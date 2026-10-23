//// New compiled BEAM fixtures and deterministic migration overlap barriers.

import client/upgrade/source
import client/upgrade/state as abi
import core/json
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{type Pid}
import gleam/string

@external(erlang, "harness_upgrade_ffi", "compile_fixture")
fn compile_fixture(
  slot: String,
  version: String,
  mode: String,
  observer: Pid,
) -> Result(BitArray, String)

@external(erlang, "harness_upgrade_ffi", "queued")
pub fn queued(pid: Pid, key: String) -> Bool

pub fn artifact(
  slot: abi.Slot,
  version: String,
  mode: String,
  observer: Pid,
) -> source.Artifact {
  let label = case slot {
    abi.SlotA -> "a"
    abi.SlotB -> "b"
    abi.Builtin -> "builtin"
  }
  let module = "loom_scratch_" <> label
  let assert Ok(bytes) = compile_fixture(label, version, mode, observer)
    as "trusted fixture compiles new BEAM bytes"
  let document =
    json.Object([
      #("schema", json.Int(1)),
      #("repository", json.String("Roasbeef/loom")),
      #("release", json.String("fixture")),
      #("component", json.String("scratch")),
      #("module", json.String(module)),
      #("version", json.String(version)),
      #("state_version", json.String("v1")),
      #("boundary", json.String("loom.scratch.v1")),
      #("size", json.Int(bit_array.byte_size(bytes))),
      #("sha256", json.String(source.digest(bytes))),
      #("accepts", json.Array([json.String("v1")])),
    ])
  let manifest = <<json.to_string(document):utf8>>
  let assert Ok(artifact) =
    source.resolve_on("fixture", source.digest(manifest), fn(url, limit) {
      let value = case string.ends_with(url, "/harness-scratch.json") {
        True -> manifest
        False -> bytes
      }
      case bit_array.byte_size(value) <= limit {
        True -> Ok(value)
        False -> Error("fixture exceeds byte budget")
      }
    })
    as "fixture bytes pass production origin, manifest and digest policy"
  artifact
}

pub fn paused() -> Pid {
  let selector =
    process.new_selector()
    |> process.select_record(
      atom.create("harness_migration_paused"),
      1,
      fn(fields) { fields },
    )
  let assert Ok(fields) = process.selector_receive(selector, 1000)
    as "newly loaded migration announces its pause"
  // The fixture sends exactly a local pid in its one-field record.
  let assert Ok(worker) = pid_field(fields)
    as "the pause record contains a migration worker pid"
  worker
}

@external(erlang, "harness_upgrade_ffi", "paused_pid")
fn pid_field(fields: Dynamic) -> Result(Pid, Nil)

@external(erlang, "harness_upgrade_ffi", "continue_worker")
pub fn continue_worker(worker: Pid) -> Nil

/// Counts target monitors so cancellation can witness custodian retirement.
@external(erlang, "harness_upgrade_ffi", "monitor_count")
pub fn monitor_count(pid: Pid) -> Int

/// Pause the global slot owner to exercise delayed admission acknowledgements.
/// ## Examples
/// `pause_slots()` returns the exact process to resume after queue observation.
@external(erlang, "harness_upgrade_ffi", "pause_slots")
pub fn pause_slots() -> Pid

/// Pause one known test actor at the scheduler boundary.
/// ## Examples
/// `pause(target)` delays its ordinary messages without consuming them.
@external(erlang, "harness_upgrade_ffi", "pause_pid")
pub fn pause(pid: Pid) -> Nil

/// Resume one scheduler-paused test actor.
/// ## Examples
/// `resume(target)` preserves the queued message ordering.
@external(erlang, "harness_upgrade_ffi", "resume_pid")
pub fn resume(pid: Pid) -> Nil

/// Count an exact fixed control message kind in a paused test actor's mailbox.
/// ## Examples
/// `queued_controls(slot_owner, "confirm")` observes retries after timeout.
@external(erlang, "harness_upgrade_ffi", "queued_controls")
pub fn queued_controls(pid: Pid, kind: String) -> Int
