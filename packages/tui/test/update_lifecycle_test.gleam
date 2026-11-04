//// The launch metadata is only a consistency check against an authenticated
//// ready endpoint. The replacement receives literal, sanitized child arguments.

import gleam/list
import gleam/option.{None, Some}
import host/endpoint
import host/launch_metadata
import tui/update/lifecycle

pub fn metadata_must_match_native_fence_and_epoch_test() {
  let fence = endpoint.Fence(41, "linux:birth", 100)
  let record = endpoint.Ready(fence, "127.0.0.1", 1234, "epoch", None)
  let metadata =
    launch_metadata.Record(fence, "epoch", None, launch_metadata.LocalOnly)
  assert lifecycle.matches(record, metadata)
  assert !lifecycle.matches(endpoint.Starting(fence), metadata)
  assert !lifecycle.matches(
    record,
    launch_metadata.Record(..metadata, epoch: "other"),
  )
  assert !lifecycle.matches(
    record,
    launch_metadata.Record(
      ..metadata,
      fence: endpoint.Fence(42, "linux:birth", 100),
    ),
  )
  assert !lifecycle.matches(
    record,
    launch_metadata.Record(
      ..metadata,
      fence: endpoint.Fence(41, "linux:other", 100),
    ),
  )
}

pub fn replacement_environment_clears_vm_flags_and_preserves_literal_tls_path_test() {
  let local = lifecycle.environment(launch_metadata.LocalOnly)
  assert list.contains(local, "ERL_FLAGS")
  assert list.contains(local, "ERL_AFLAGS")
  assert list.contains(local, "ERL_ZFLAGS")
  assert list.contains(local, "LOOM_DISTRIBUTION_OPTFILE")
  assert list.contains(local, "LOOM_DEBUG_ARGS_FILE")
  let tls = lifecycle.environment(launch_metadata.Tls("/private path/options"))
  assert list.append(local, ["LOOM_DISTRIBUTION_OPTFILE=/private path/options"])
    == tls
}

pub fn replacement_preserves_an_explicitly_absent_configuration_test() {
  let without = lifecycle.replacement_arguments("/state", "/no/loomd", None)
  assert without == ["--state-dir", "/state", "--config", ""]
  let with =
    lifecycle.replacement_arguments(
      "/state",
      "/no/loomd",
      Some("/path with spaces/config"),
    )
  assert with
    == ["--state-dir", "/state", "--config", "/path with spaces/config"]
}
