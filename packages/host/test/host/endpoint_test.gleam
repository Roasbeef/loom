//// Endpoint identity and replacement rules are tested independently of sockets.
//// Each filesystem fixture is private and every native operation has the host
//// boundary's fixed deadline; no test waits for an arbitrary process to exit.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import host/build_identity
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
  let identity = build_identity.Identity("0.1.0", "4c266dde")
  let records = [
    endpoint.Starting(fence),
    endpoint.Ready(fence, "127.0.0.1", 1234, "epoch", None),
    endpoint.Ready(fence, "::1", 65_535, "another-epoch", Some(identity)),
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
  assert endpoint.address(endpoint.Ready(fence, "::1", 1234, "epoch", None))
    == Ok("ws://[::1]:1234/v2/control")
}

// Issue #392: a record written by an older install carries no build
// identity. It must still DECODE — a launcher that could not read an old
// daemon's record could not report that the daemon is old, which is the
// whole point — and it must read as an unknown identity rather than a
// malformed record. The version-2 shape is the mirror: both identity
// fields are required, so one missing is malformed, not merely unknown.
pub fn endpoint_build_identity_is_optional_and_versioned_test() {
  let fence = endpoint.Fence(123, "darwin:birth", 1234)
  let identity = build_identity.Identity("0.2.0", "abcdef12")

  // A version-one ready record: identity absent, and the schema says so.
  let v1 =
    endpoint.encode(endpoint.Ready(fence, "127.0.0.1", 1234, "epoch", None))
  assert string.contains(v1, "\"version\":1")
  assert endpoint.decode(v1)
    == Ok(endpoint.Ready(fence, "127.0.0.1", 1234, "epoch", None))

  // A version-two record names its build, and round-trips it.
  let v2 =
    endpoint.encode(endpoint.Ready(
      fence,
      "127.0.0.1",
      1234,
      "epoch",
      Some(identity),
    ))
  assert string.contains(v2, "\"version\":2")
  assert endpoint.decode(v2)
    == Ok(endpoint.Ready(fence, "127.0.0.1", 1234, "epoch", Some(identity)))

  // A version-two record missing either identity field is malformed.
  let missing_commit = string.replace(v2, ",\"build_commit\":\"abcdef12\"", "")
  assert missing_commit != v2
  let assert Error(_) = endpoint.decode(missing_commit)
  let missing_version = string.replace(v2, ",\"build_version\":\"0.2.0\"", "")
  assert missing_version != v2
  let assert Error(_) = endpoint.decode(missing_version)

  // A version-two record with an EMPTY identity value is malformed too:
  // an empty version is not a build, and admitting it would let a caller
  // compare against a build that never existed.
  let empty_version = string.replace(v2, "\"0.2.0\"", "\"\"")
  let assert Error(_) = endpoint.decode(empty_version)
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
  assert endpoint.publish_ready(paths, own, "127.0.0.1", 4242, "epoch", None)
    == Ok(Nil)
  let assert Error(_) = endpoint.claim(paths, own)
    as "a still-live VM cannot start another root from a Ready record"
  assert endpoint.availability(paths)
    == Ok(
      endpoint.Occupied(endpoint.Ready(own, "127.0.0.1", 4242, "epoch", None)),
    )
  assert endpoint.load(paths)
    == Ok(Some(endpoint.Ready(own, "127.0.0.1", 4242, "epoch", None)))
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
    endpoint.publish_ready(paths, former, "127.0.0.1", 4242, "old", None)
    as "an obsolete reservation cannot overwrite its replacement"
  assert endpoint.load(paths) == Ok(Some(endpoint.Starting(own)))
  assert simplifile.delete(paths.root) == Ok(Nil)
}
