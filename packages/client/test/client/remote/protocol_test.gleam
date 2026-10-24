//// The remote vocabulary's own functions: the sentence for a refusal, and the
//// coordinates an evolution call carries.

import broker/broker
import broker/exec
import broker/policy
import client/remote/protocol
import client/wiring
import core/clock
import core/ids
import tools/directory_access
import tools/fs
import tools/tool

fn a_ctx(strand: String, grants: List(policy.Grant)) -> tool.Ctx {
  let workspace = "/nonexistent/loom-protocol-test"
  let #(op_id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 7))
  tool.Ctx(
    directory_access: directory_access.Access(
      readable: ["/srv/data"],
      writable: [],
    ),
    workspace:,
    strand:,
    op_id:,
    step_id: "turn-3:tools",
    source_index: 2,
    base_policy: policy.workspace_default(workspace),
    grants:,
    demand: exec.BestEffort,
    env: [#("SECRET", "never crosses")],
    clock: clock.fixed(at: 0),
    filesystem: fs.real_filesystem(),
    blob_root: workspace <> "/.blobs",
    clear_call: fn(_spec, _events) { Error(broker.BrokerUnavailable) },
    raise_refusal: tool.no_raise(),
    observe_output: tool.ignore_output(),
  )
}

pub fn the_coordinates_of_a_door_call_carry_its_identity_and_authority_test() {
  let grants = [policy.GrantReadableRoot("/srv/data")]
  let ctx = a_ctx("main", [])

  // The authority is the stored one the caller read, standing network grants
  // included, and is carried as given.
  let stored = wiring.Authority(access: ctx.directory_access, standing: grants)
  let coordinates = protocol.coordinates_of("session-1", ctx, stored)

  // The key is the door call's own: the session the caller names, then the
  // operation, step and source index the driver minted.
  assert coordinates.key
    == protocol.Key(
      session: "session-1",
      op: ids.op_id_to_string(ctx.op_id),
      step: "turn-3:tools",
      source_index: 2,
    )
  assert coordinates.strand == "main"

  // Nothing else crosses. The workspace, the base policy, the environment and
  // the closures are not part of the coordinates, because the executor
  // supplies its own.
  assert coordinates.authority == stored
}

pub fn the_coordinates_follow_the_strand_and_the_named_session_test() {
  let none = wiring.Authority(access: directory_access.none(), standing: [])
  let first = protocol.coordinates_of("s", a_ctx("main", []), none)
  let other = protocol.coordinates_of("s", a_ctx("helper", []), none)
  assert first.strand == "main"
  assert other.strand == "helper"
  assert first.key == other.key
  assert protocol.coordinates_of("t", a_ctx("main", []), none).key.session
    == "t"
}

pub fn every_new_refusal_has_a_sentence_test() {
  assert protocol.describe(protocol.UnknownHandle)
    == "the executor holds no generation with that handle"
  assert protocol.describe(protocol.AlreadyPublished)
    == "the executor already published that successor, so it cannot be aborted"
  assert protocol.describe(protocol.StaleGeneration(serving: 4))
    == "the executor already serves generation 4 of this selection"
  assert protocol.describe(protocol.NoEvolution(reason: "no toolchain"))
    == "the executor cannot build evolution candidates for this session: no toolchain"
}
