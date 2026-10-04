//// Workspace quota regressions use actual SQLite with the existing named queries.
////
//// These checks pin configured limit persistence, full result reservation before
//// effects and strict identity comparison. Large content enters only the typed
//// workspace doors; ordinary Payload keeps its original two-MiB ceiling.

import core/clock
import core/ids
import core/remote_tool
import gleam/bit_array
import gleam/option.{None}
import gleam/result
import gleam/string
import storage/owner_custody as custody
import support/fixtures

fn session() {
  ids.mint_session(ids.generator(clock.fixed(1000), 97)).0
}

fn id(n: Int) {
  ids.mint_entry(ids.generator(clock.fixed(2000), n)).0
}

fn origin(n: Int) {
  let assert Ok(origin) =
    remote_tool.system_child(session(), "workspace-administration", n)
    as "System child has no fake ToolKey."
  origin
}

fn limits(bytes: Int, payload: Int) {
  let assert Ok(limits) = custody.limits(4, 32, bytes, payload)
    as "Workspace store configuration fits hard limits."
  limits
}

pub fn configured_small_quota_and_metadata_cannot_be_automatically_upgraded_test() {
  let directory = fixtures.scratch("owner-workspace-fixed-quota")
  let small = limits(1_048_576, 4096)
  let large = limits(1_048_576, 33_554_432)
  let path = directory <> "/owner.db"
  let assert Ok(store) = custody.open(path, session(), small)
    as "Actual journal binds configured quota."
  let oversized = string.repeat("x", 4097) |> bit_array.from_string
  assert custody.workspace_request(small, oversized) == Error(custody.Capacity)
  assert custody.workspace_completion(small, oversized)
    == Error(custody.Capacity)
  let assert Ok(request) = custody.workspace_request(large, oversized)
    as "Larger constructor cannot bypass the store's smaller persisted ceiling."
  assert custody.admit_workspace_child(store, origin(0), id(1), request)
    == Error(custody.Capacity)
  assert custody.child(store, origin(0)) == Error(custody.Missing)
  assert custody.close(store) == Ok(Nil)
  assert custody.open(path, session(), large) == Error(custody.Conflict)
  let assert Ok(store) = custody.open(path, session(), small)
    as "Original metadata remains intact."
  assert custody.close(store) == Ok(Nil)
}

pub fn full_configured_result_allowance_is_reserved_before_effects_test() {
  let directory = fixtures.scratch("owner-workspace-full-capacity")
  let quota = 33_554_432
  let limits = limits(quota, quota)
  let assert Ok(store) =
    custody.open(directory <> "/owner.db", session(), limits)
    as "Aggregate quota deliberately cannot hold one full result plus request."
  let assert Ok(request) = custody.workspace_request(limits, <<1>>)
    as "Request is small; future receipt dominates capacity."
  assert custody.admit_workspace_child(store, origin(0), id(1), request)
    == Error(custody.Capacity)
  assert custody.child(store, origin(0)) == Error(custody.Missing)
  assert custody.close(store) == Ok(Nil)
}

pub fn native_payload_stays_bounded_and_workspace_identity_stays_exact_test() {
  let directory = fixtures.scratch("owner-workspace-native-separation")
  let limits = limits(134_217_728, 33_554_432)
  let assert Ok(store) =
    custody.open(directory <> "/owner.db", session(), limits)
    as "Larger configured store opens without enlarging native entry limits."
  let bytes = string.repeat("x", 2_097_153) |> bit_array.from_string
  assert custody.payload(limits, bytes) == Error(custody.Capacity)
  let assert Ok(request) = custody.workspace_request(limits, bytes)
    as "Typed workspace request permits content above native ceiling."
  assert custody.admit_workspace_child(store, origin(0), id(1), request)
    == Ok(Nil)
  assert custody.admit_workspace_child(store, origin(0), id(2), request)
    == Error(custody.Conflict)
  let assert Ok(changed) = custody.workspace_request(limits, <<2>>)
    as "Changed request is independently bounded."
  assert custody.admit_workspace_child(store, origin(0), id(1), changed)
    == Error(custody.Conflict)
  let assert Ok(completion) = custody.workspace_completion(limits, <<3>>)
    as "Exact receipt is bounded."
  assert custody.receive_workspace_child(store, origin(0), id(2), completion)
    == Error(custody.Conflict)
  let assert Ok(#(reserved, stored, None)) = custody.child(store, origin(0))
    as "Wrong ID leaves original bytes and empty receipt."
  assert #(reserved, custody.bytes(stored)) == #(id(1), bytes)
  assert custody.cancel_child(store, origin(0)) == Ok(Nil)
  assert custody.receive_workspace_child(store, origin(0), id(1), completion)
    == Error(custody.Frozen)
  assert custody.child(store, origin(0)) |> result.is_ok
  assert custody.close(store) == Ok(Nil)
}

pub fn semantic_and_aggregate_hard_bounds_are_exact_test() {
  let limits = limits(268_435_456, 33_554_432)
  assert custody.limits(4, 32, 268_435_457, 33_554_432) |> result.is_error
  assert custody.limits(4, 32, 268_435_456, 33_554_433) |> result.is_error
  let exact = <<0:size(9_437_184 * 8)>>
  assert custody.workspace_request(limits, exact) |> result.is_ok
  assert custody.workspace_request(limits, <<exact:bits, 0>>)
    == Error(custody.Capacity)
  assert custody.workspace_request(limits, <<0:size(1)>>) |> result.is_error
  assert custody.workspace_completion(limits, <<0:size(33_554_432 * 8)>>)
    |> result.is_ok
  assert custody.workspace_completion(limits, <<0:size(33_554_433 * 8)>>)
    == Error(custody.Capacity)
}
