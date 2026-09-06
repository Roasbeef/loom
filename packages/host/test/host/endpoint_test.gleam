//// Endpoint identity and replacement rules are tested independently of sockets.
//// Each filesystem fixture is private and every native operation has the host
//// boundary's fixed deadline; no test waits for an arbitrary process to exit.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import host/endpoint
import simplifile

fn fixture(name) {
  let assert Ok(paths) =
    endpoint.paths(
      "build/endpoint-"
      <> name
      <> "-"
      <> int.to_string(bootstrap.system_time_ms()),
    )
    as "private endpoint fixture is canonical"
  paths
}

fn own() {
  let assert Ok(fence) = endpoint.observe(bootstrap.current_process_id())
    as "the containing test VM has an observable native identity"
  fence
}

pub fn endpoint_codec_round_trips_and_rejects_identity_ambiguity_test() {
  let fence = endpoint.Fence(123, "darwin:birth", 1234)
  let records = [
    endpoint.Starting(fence),
    endpoint.Ready(fence, "127.0.0.1", 1234, "epoch"),
    endpoint.Ready(fence, "::1", 65_535, "another-epoch"),
  ]
  list.each(records, fn(record) {
    assert endpoint.decode(endpoint.encode(record)) == Ok(record)
  })
  let valid = endpoint.encode(endpoint.Starting(fence))
  list.each(
    [
      "{}",
      "[]",
      valid <> "x",
      string.repeat(" ", 4097),
      string.replace(valid, "\"version\":1", "\"version\":2"),
      string.replace(valid, "\"protocol\":2", "\"protocol\":1"),
      string.replace(valid, "\"pid\":123", "\"pid\":0"),
      string.replace(valid, "\"pid\":123", "\"pid\":123,\"pid\":124"),
      string.replace(valid, "darwin:birth", ""),
      string.replace(valid, "\"status\":\"starting\"", "\"status\":\"unknown\""),
    ],
    fn(text) {
      let assert Error(_) = endpoint.decode(text)
        as "invalid or ambiguous identity cannot authorize replacement"
    },
  )
  assert endpoint.address(endpoint.Ready(fence, "::1", 1234, "epoch"))
    == Ok("ws://[::1]:1234/v2/control")
}

pub fn endpoint_missing_catalogue_and_malformed_record_fail_closed_test() {
  let paths = fixture("missing")
  assert endpoint.load(paths) == Ok(None)
  assert endpoint.availability(paths) == Ok(endpoint.Vacant)
  assert bootstrap.atomic_write_private(paths.catalogue, "existing") == Ok(Nil)
  let assert Error(reason) = endpoint.availability(paths)
    as "catalogue presence without a native fence requires operator recovery"
  assert string.contains(reason, "establish")
  assert bootstrap.atomic_write_private(paths.record, "{}") == Ok(Nil)
  let assert Error(_) = endpoint.availability(paths)
    as "a malformed present record is never treated as absent"
  assert simplifile.delete(paths.root) == Ok(Nil)
}

pub fn endpoint_own_starting_adopts_but_ready_vm_cannot_restart_test() {
  let paths = fixture("adopt")
  let own = own()
  assert endpoint.claim(paths, own) == Ok(own)
  assert endpoint.claim(
      paths,
      endpoint.Fence(..own, started_at_ms: own.started_at_ms + 1),
    )
    == Ok(own)
  assert endpoint.publish_ready(paths, own, "127.0.0.1", 4242, "epoch")
    == Ok(Nil)
  let assert Error(_) = endpoint.claim(paths, own)
    as "a still-live VM cannot start another root from a Ready record"
  assert endpoint.availability(paths)
    == Ok(endpoint.Occupied(endpoint.Ready(own, "127.0.0.1", 4242, "epoch")))
  assert endpoint.load(paths)
    == Ok(Some(endpoint.Ready(own, "127.0.0.1", 4242, "epoch")))
  assert simplifile.delete(paths.root) == Ok(Nil)
}

pub fn endpoint_reused_pid_birth_is_replaceable_and_publication_is_fenced_test() {
  let paths = fixture("reused")
  let own = own()
  let former = endpoint.Fence(..own, birth: "different-process-birth")
  assert endpoint.write(paths, endpoint.Starting(former)) == Ok(Nil)
  assert endpoint.availability(paths) == Ok(endpoint.Vacant)
  assert endpoint.claim(paths, own) == Ok(own)
  let assert Error(_) =
    endpoint.publish_ready(paths, former, "127.0.0.1", 4242, "old")
    as "an obsolete reservation cannot overwrite its replacement"
  assert endpoint.load(paths) == Ok(Some(endpoint.Starting(own)))
  assert simplifile.delete(paths.root) == Ok(Nil)
}
