//// The enforcement vocabulary is spelled twice: the Go helper emits tags
//// such as `seccomp-net` and `landlock:abi=5` in its hello features and
//// its `exec_exit` report, and `broker/exec` demands them by name. Nothing
//// in either build notices if one side renames a tag, and the failure it
//// would cause is the quiet kind — a layer the broker requires that the
//// helper never reports reads as a degraded jail on every run, or worse,
//// a tolerance that no longer matches anything.
////
//// This module is the notice, after the `protocol_version_test` precedent:
//// it reads the helper's non-test jail sources as text and asserts that
//// every tag the broker names occurs there as a quoted literal. It proves
//// "whatever Gleam names, Go spells somewhere", not per-platform emission;
//// the enforcement fixture and the real-helper tests prove that part
//// behaviourally. ADR-018 records why this pin was chosen over a
//// generated shared constants file.
////
//// The required tags are not listed here. They are collected by calling
//// `exec.required_layers_for` over both platforms with a policy that asks
//// for every optional layer, so a tag the broker starts requiring is pinned
//// without anyone remembering to add it. Only the tags that function never
//// returns — the hello features it reads and the skips it tolerates — are
//// listed by hand, below, with the line of `exec.gleam` that reads each.

import broker/exec
import broker/policy
import gleam/list
import gleam/option.{Some}
import gleam/string
import simplifile

// Where the Go jail sources live, relative to this package's directory
// (the test runner's working directory, see `scripts/test.sh`).
const go_jail_dir = "../sandbox/internal/jail"

// Tags the broker reads but `required_layers_for` never returns: the
// `degraded` hello feature (`degraded_helper`), and the one Darwin skip
// `PlatformEnforcement` tolerates besides the two resource rlimits, which
// the matrix already yields. `bwrap` and `seatbelt` are hello features too
// but are also layers, so the matrix covers them. If `exec.gleam` starts
// reading another feature or tolerating another skip, add it here.
const unlisted_tags = ["degraded", "darwin-process-lifecycle"]

// A policy that asks for every optional layer the matrix can require, so
// the collected set is the whole of it. Proxy rather than off networking
// would yield the same tag; either reaches the network arm.
fn maximal_policy() -> policy.SandboxPolicy {
  let base = policy.workspace_default("/work")
  policy.SandboxPolicy(
    ..base,
    network: policy.NetworkOff,
    limits: policy.Limits(
      ..base.limits,
      cpu_s: 1,
      mem_bytes: 1,
      pids: 1,
      fsize_bytes: 1,
    ),
  )
}

// Every tag the broker names, deduplicated.
fn broker_tags() -> List(String) {
  let policy = Some(maximal_policy())
  list.flatten([
    exec.required_layers_for(policy, "linux"),
    exec.required_layers_for(policy, "darwin"),
    unlisted_tags,
  ])
  |> list.unique
}

pub fn every_tag_the_broker_names_is_spelled_by_the_go_helper_test() {
  let #(sources, searched) = read_go_sources()
  let missing =
    broker_tags()
    |> list.filter(fn(tag) { !spelled(sources, tag) })

  assert missing == []
    as {
      "tags named by broker/exec but absent from the Go jail sources: "
      <> string.join(missing, ", ")
      <> " (searched: "
      <> string.join(searched, ", ")
      <> ")"
    }
}

pub fn the_prefixes_the_broker_parses_are_spelled_by_the_go_helper_test() {
  let #(sources, searched) = read_go_sources()

  // `skip:` is the constant the broker strips; `landlock:abi=` is the one
  // detail form `layer_tag` is documented against (it splits generically on
  // `:` and `=`, so the Go side must keep emitting a separator-bearing tag).
  let missing =
    [exec.skip_prefix, "landlock:abi="]
    |> list.filter(fn(prefix) { !string.contains(sources, "\"" <> prefix) })

  assert missing == []
    as {
      "prefixes parsed by broker/exec but absent from the Go jail sources: "
      <> string.join(missing, ", ")
      <> " (searched: "
      <> string.join(searched, ", ")
      <> ")"
    }
}

pub fn a_tag_the_go_helper_does_not_spell_is_reported_test() {
  assert !spelled("x := \"bwrap\"\n", "no-such-layer")
}

// Whether `tag` occurs in `sources` as the start of a quoted literal that
// ends at the tag or continues into its detail: `"seccomp-net"`,
// `"mounts:ro=%d"`, `"landlock:abi="`. A bare substring would let
// `rlimit-cpu` match inside a comment or a longer word; the opening quote
// is what makes it a spelling.
fn spelled(sources: String, tag: String) -> Bool {
  ["\"" <> tag <> "\"", "\"" <> tag <> ":", "\"" <> tag <> "="]
  |> list.any(string.contains(sources, _))
}

// The concatenated text of the non-test Go files in the jail directory,
// with the file names for the failure message.
fn read_go_sources() -> #(String, List(String)) {
  let assert Ok(entries) = simplifile.read_directory(go_jail_dir)
    as "the Go jail directory must be readable from the broker package"
  let files =
    entries
    |> list.filter(fn(name) {
      string.ends_with(name, ".go") && !string.ends_with(name, "_test.go")
    })
    |> list.sort(string.compare)
  assert files != [] as "the Go jail directory must hold non-test sources"

  let text =
    list.map(files, fn(name) {
      let assert Ok(source) = simplifile.read(go_jail_dir <> "/" <> name)
        as "every Go jail source must be readable"
      source
    })
  #(string.join(text, "\n"), list.map(files, fn(f) { go_jail_dir <> "/" <> f }))
}
