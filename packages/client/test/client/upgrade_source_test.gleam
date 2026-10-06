//// Artifact authority refuses arbitrary core paths, modules and mismatched bytes.

import client/upgrade/source
import core/json
import gleam/bit_array
import gleam/string
import gleeunit/should

fn document(
  module: String,
  boundary: String,
  size: Int,
  digest: String,
) -> BitArray {
  <<
    json.to_string(
      json.Object([
        #("schema", json.Int(1)),
        #("repository", json.String("Roasbeef/loom")),
        #("release", json.String("reviewed")),
        #("component", json.String("scratch")),
        #("module", json.String(module)),
        #("version", json.String("v2")),
        #("state_version", json.String("v1")),
        #("boundary", json.String(boundary)),
        #("size", json.Int(size)),
        #("sha256", json.String(digest)),
        #("accepts", json.Array([json.String("v1")])),
      ]),
    ):utf8,
  >>
}

pub fn arbitrary_release_paths_are_refused_before_fetch_test() -> Nil {
  let called = fn(_url, _limit) {
    panic as "invalid origins must not reach acquisition"
  }
  source.resolve_on("/tmp/core.beam", string.repeat("a", 64), called)
  |> should.be_error
  source.resolve_on("https://attacker/core", string.repeat("a", 64), called)
  |> should.be_error
  source.resolve_on("candidate-id", "", called) |> should.be_error
  Nil
}

pub fn exact_manifest_and_artifact_digests_are_both_required_test() -> Nil {
  let bytes = <<"reviewed":utf8>>
  let metadata =
    document(
      "loom_scratch_a",
      "loom.scratch.v1",
      bit_array.byte_size(bytes),
      source.digest(bytes),
    )
  let fetch = fn(url, _limit) {
    case string.ends_with(url, ".json") {
      True -> Ok(metadata)
      False -> Ok(<<"different":utf8>>)
    }
  }
  source.resolve_on("reviewed", string.repeat("a", 64), fetch)
  |> should.be_error
  source.resolve_on("reviewed", source.digest(metadata), fetch)
  |> should.be_error
  Nil
}

pub fn undeclared_core_modules_and_incompatible_boundaries_are_refused_test() -> Nil {
  let bytes = <<"reviewed":utf8>>
  let wrong_module =
    document("client@gateway", "loom.scratch.v1", 8, source.digest(bytes))
  source.resolve_on("reviewed", source.digest(wrong_module), fn(_, _) {
    Ok(wrong_module)
  })
  |> should.be_error
  let wrong_boundary =
    document("loom_scratch_a", "another-wire-v2", 8, source.digest(bytes))
  source.resolve_on("reviewed", source.digest(wrong_boundary), fn(_, _) {
    Ok(wrong_boundary)
  })
  |> should.be_error
  let oversized =
    document(
      "loom_scratch_a",
      "loom.scratch.v1",
      1_048_577,
      source.digest(bytes),
    )
  source.resolve_on("reviewed", source.digest(oversized), fn(_, _) {
    Ok(oversized)
  })
  |> should.be_error
  Nil
}
