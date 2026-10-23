//// The orchestrator's wrapper decides whether a candidate may be checked.
//// The checks take a candidate and no catalogue, so the identity comparison
//// that used to sit inside them is the wrapper's alone, and these tests hold it
//// there.

import broker/broker
import broker/exec
import broker/policy
import client/codemode
import client/evolution/evaluate
import client/evolution/machine/local
import client/evolution/record
import client/evolution/record_test
import client/evolution/store
import client/extension/hosts
import client/extension/memory as extension_memory
import client/internal/ffi_os
import core/clock
import core/ids
import gleam/int
import gleam/option.{Some}
import gleeunit/should
import support/evolution as fixture
import telemetry/log
import tools/directory_access
import tools/tool
import weft/registry as address

// A catalogue holding one candidate, then reopened under another evaluator
// identity, which is what a host upgrade between proposal and check looks like.
fn reopened_under_new_identity() -> #(store.Store, record.Candidate) {
  let root =
    "build/test_db/evolution-local-check-"
    <> int.to_string(ffi_os.system_time_ms())
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
    <> "/catalogue"
  let candidate =
    record.identified(
      record.Candidate(
        ..record_test.candidate(),
        files: fixture.extension(1),
        test_entry: Some("evolution_check"),
      ),
    )
  let at = clock.fixed(at: 1_700_000_000_000)
  let assert Ok(original) =
    store.open(root, store.Owner, candidate.identity, at)
    as "the catalogue opens under the candidate's identity"
  store.propose(original, candidate) |> should.equal(Ok(candidate))
  let upgraded =
    record.Identity(..candidate.identity, evaluator: "evaluator-v2")
  let assert Ok(reopened) = store.open(root, store.Owner, upgraded, at)
    as "the same catalogue reopens under the new identity"
  #(reopened, candidate)
}

// A machine whose plane cannot open: reaching `open` at all is the failure, and
// it is answered with a refusal distinct from `Changed`.
fn unopenable() -> local.Config {
  let assert Ok(idle) =
    broker.start(
      broker.BrokerConfig(
        entropy: fn(bytes) { <<0:size(bytes)-unit(8)>> },
        clock: clock.fixed(at: 0),
        checkout: fn() { Error(exec.AllBusy(size: 0)) },
        checkin: fn(_helper) { Nil },
      ),
    )
    as "the broker must start"
  let assert Ok(namespace) = address.start()
    as "the address namespace must start"
  let #(op_id, _) = ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 5))
  local.Config(
    host: codemode.default_config(
      broker: idle,
      clock: clock.fixed(at: 0),
      workspace: "/work",
      toolchain: codemode.toolchain(
        gleam_path: "/opt/gleam/bin/gleam",
        erl_path: "/usr/lib/erlang/bin/erl",
        seed_root: "/opt/loom/codemode-seed",
      ),
    ),
    base: policy.workspace_default("/work"),
    at: hosts.Coordinates(
      origin: hosts.ToolCall,
      op_id:,
      step_id: "step-1",
      strand: "main",
      workspace: "/work",
      base_policy: policy.workspace_default("/work"),
      demand: exec.BestEffort,
      env: [],
    ),
    memory: extension_memory.shut("no session"),
    secrets: fn(_name) { Error(Nil) },
    namespace:,
    scratch: "/nonexistent/scratch",
    logger: log.discard(),
    open: fn(_policy) { Error(store.Unavailable("the plane must not open")) },
  )
}

fn a_ctx() -> tool.Ctx {
  let workspace = "/nonexistent/loom-local-check-test"
  let #(op_id, _) = ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 7))
  tool.Ctx(
    directory_access: directory_access.none(),
    workspace:,
    strand: "main",
    op_id:,
    step_id: "step-1",
    source_index: 0,
    base_policy: policy.workspace_default(workspace),
    grants: [],
    demand: exec.BestEffort,
    env: [],
    clock: clock.fixed(at: 0),
    filesystem: tool.FileSystem(
      read: fn(path) { Error(tool.FsNotFound(path:)) },
      write: fn(path, _bytes) { Error(tool.FsNotFound(path:)) },
      create_directory_all: fn(path) { Error(tool.FsNotFound(path:)) },
      is_file: fn(_path) { Ok(False) },
      read_link: fn(_path) { Ok(tool.LinkMissing) },
      rename: fn(from, _to) { Error(tool.FsNotFound(path: from)) },
    ),
    blob_root: workspace <> "/.blobs",
    clear_call: fn(_spec, _events) { Error(broker.BrokerUnavailable) },
    raise_refusal: tool.no_raise(),
    observe_output: tool.ignore_output(),
  )
}

pub fn evaluate_candidate_refuses_a_candidate_from_another_identity_test() {
  let #(catalogue, candidate) = reopened_under_new_identity()

  // The candidate is still readable, so only the identity comparison can
  // refuse it, and it must do so before the check opens a plane.
  store.read_candidate(catalogue, candidate.id) |> should.equal(Ok(candidate))
  evaluate.current(catalogue, candidate) |> should.equal(Error(store.Changed))
  local.evaluate_candidate(unopenable(), a_ctx(), catalogue, candidate.id)
  |> should.equal(Error(store.Changed))
}
