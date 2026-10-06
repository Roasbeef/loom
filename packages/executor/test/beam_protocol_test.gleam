//// Closed byte tests pin authority, generation, capacity class and aggregate bounds.

import core/ids
import executor/remote/compile_wire
import executor/remote/identity
import executor/remote/internal/beam_protocol as protocol
import executor/remote/launch_wire
import executor/remote/wire
import executor/remote/workspace_journal as journal
import executor/remote/workspace_transfer as transfer
import gleam/list

fn scope(epoch: Int) -> identity.Scope {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "fixture UUID"
  let assert Ok(workspace) = identity.workspace_id("checkout")
    as "fixture workspace"
  let assert Ok(executor) = identity.executor_id("executor")
    as "fixture executor"
  let assert Ok(epoch) = identity.epoch(epoch) as "fixture epoch"
  identity.scope(session, workspace, executor, epoch, epoch)
}

fn binding() -> protocol.Binding {
  protocol.Binding("owner", "executor", 1, scope(1))
}

pub fn canonical_header_exact_scope_generation_and_closed_routes_test() {
  let assert Ok(digest) = identity.digest(<<1:size(256)>>) as "fixture digest"
  let routes = [
    protocol.Native(protocol.Data),
    protocol.Native(protocol.Control),
    protocol.NativeCommand(protocol.Data),
    protocol.NativeCommand(protocol.Control),
    protocol.Workspace(protocol.Submit),
    protocol.Workspace(protocol.Query),
    protocol.Workspace(protocol.Acknowledge(digest)),
    protocol.Compile(compile_wire.ChallengeRequest),
    protocol.Compile(compile_wire.Submit(<<1:size(256)>>, 2000)),
    protocol.Compile(compile_wire.Query),
    protocol.Compile(compile_wire.Cancel),
    protocol.Compile(compile_wire.Acknowledge(digest)),
    protocol.Launch(launch_wire.ChallengeRequest),
    protocol.Launch(launch_wire.PlaceToken(<<1:size(256)>>, 2000)),
    protocol.Launch(launch_wire.Query),
    protocol.Launch(launch_wire.Cancel),
    protocol.Launch(launch_wire.Acknowledge(digest)),
    protocol.Launch(launch_wire.RefuseBeforeNative),
  ]
  list.each(routes, fn(route) {
    let assert Ok(bytes) = protocol.header(binding(), route) as "closed header"
    assert protocol.decode_header(binding(), bytes) == Ok(route)
    assert protocol.decode_header(
        protocol.Binding(..binding(), generation: 2),
        bytes,
      )
      == Error(Nil)
    assert protocol.decode_header(
        protocol.Binding(..binding(), scope: scope(2)),
        bytes,
      )
      == Error(Nil)
    assert protocol.decode_header(
        protocol.Binding(..binding(), owner: "other"),
        bytes,
      )
      == Error(Nil)
    assert protocol.decode_header(binding(), <<bytes:bits, 0>>) == Error(Nil)
  })
  assert protocol.decode_header(binding(), <<2, 0, 1>>) == Error(Nil)
  assert protocol.header(
      binding(),
      protocol.Compile(compile_wire.Submit(<<>>, 100)),
    )
    == Error(Nil)
}

pub fn lane_cannot_turn_first_admission_into_control_test() {
  assert protocol.route_lane(protocol.Compile(compile_wire.ChallengeRequest))
    == protocol.Data
  assert protocol.route_lane(
      protocol.Compile(compile_wire.Submit(<<0:size(256)>>, 1)),
    )
    == protocol.Data
  assert protocol.route_lane(protocol.Compile(compile_wire.Cancel))
    == protocol.Control
  assert protocol.route_lane(protocol.Workspace(protocol.Submit))
    == protocol.Data
  assert protocol.route_lane(protocol.Workspace(protocol.Query))
    == protocol.Control
  assert protocol.lane(wire.Rejected(1)) == Error(Nil)
}

pub fn aggregate_is_refused_before_first_content_chunk_test() {
  let native = protocol.Native(protocol.Data)
  let workspace = protocol.Workspace(protocol.Submit)
  assert protocol.receiver(native, transfer.Invocation, <<
      "LWC",
      1,
      0,
      262_145:32,
      0:size(256),
    >>)
    == Error(Nil)
  assert protocol.receiver(native, transfer.Invocation, <<
      "LWC",
      1,
      0,
      0:32,
      0:size(256),
    >>)
    == Error(Nil)
  assert protocol.receiver(workspace, transfer.Invocation, <<
      "LWC",
      1,
      0,
      9_437_185:32,
      0:size(256),
    >>)
    == Error(Nil)
  assert protocol.receiver(workspace, transfer.Completion, <<
      "LWC",
      1,
      1,
      33_554_433:32,
      0:size(256),
    >>)
    == Error(Nil)
  assert protocol.receiver(
      protocol.Compile(compile_wire.Query),
      transfer.Completion,
      <<"LWC", 1, 1, 524_301:32, 0:size(256)>>,
    )
    == Error(Nil)
}

pub fn statuses_are_closed_and_do_not_accept_trailing_bytes_test() {
  list.each(
    [
      journal.Accepted,
      journal.Unknown,
      journal.Finished(<<1, 2, 3>>),
      journal.Acknowledged(<<1:size(256)>>),
      journal.Cancelled,
    ],
    fn(status) {
      assert protocol.decode_status(protocol.status(status)) == Ok(status)
    },
  )
  assert protocol.decode_status(<<1, 0, 0>>) == Error(Nil)
  assert protocol.decode_status(<<1, 5>>) == Error(Nil)
}

// Route five remains unavailable until an independently checked stream bind exists.
pub fn launch_route_four_is_finite_and_route_five_is_reserved_test() {
  assert protocol.route_lane(protocol.Launch(launch_wire.ChallengeRequest))
    == protocol.Data
  assert protocol.route_lane(
      protocol.Launch(launch_wire.PlaceToken(<<1:size(256)>>, 1)),
    )
    == protocol.Data
  assert protocol.route_lane(protocol.Launch(launch_wire.RefuseBeforeNative))
    == protocol.Control
  assert protocol.route_lane(protocol.Launch(launch_wire.Query))
    == protocol.Control
  let assert Ok(bytes) =
    protocol.header(binding(), protocol.Launch(launch_wire.Query))
    as "finite route four encodes"
  let assert <<1, 4, rest:bytes>> = bytes as "Launch uses its new route"
  assert protocol.decode_header(binding(), <<1, 5, rest:bits>>) == Error(Nil)
}
