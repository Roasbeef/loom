//// Closed Launch metadata keeps canonical history separate from token placement.

import broker/enrollment
import broker/exec
import broker/policy
import codemode/compile
import codemode/service_input as input
import codemode/service_resources as resources
import core/command
import core/ids
import core/json
import core/msgpack as mp
import core/remote_tool
import core/workspace as cw
import executor/remote/identity
import executor/remote/launch_completion as completion
import executor/remote/launch_service
import executor/remote/launch_wire as wire
import executor/remote/resource_journal as j
import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

pub fn launch_input_full_key_canonical_and_placement_boundaries_test() {
  let original = launched(compiled("pub fn main() { Nil }", 3).key, 5)
  let assert Ok(bytes) = wire.encode_input(enrolled(), original)
    as "canonical Launch input encodes"
  assert wire.decode_input(enrolled(), bytes) == Ok(original)
  assert wire.decode_input(enrolled(), <<bytes:bits, 0>>) == Error(wire.Invalid)
  assert wire.decode_input(enrolled(), <<0xffffffff:32>>) == Error(wire.Invalid)
  let producer = compiled("pub fn main() { Nil }", 3)
  assert wire.encode_input(enrolled(), producer) == Error(wire.Invalid)
  let token = <<7:size(256)>>
  let assert Ok(placed) = wire.encode_placement(enrolled(), original, token)
    as "closed placement includes its exact token"
  assert placed == <<token:bits, bytes:bits>>
  assert wire.decode_placement(enrolled(), placed) == Ok(#(original, token))
  assert wire.decode_input(enrolled(), placed) == Error(wire.Invalid)
  assert wire.decode_placement(enrolled(), <<token:bits, bytes:bits, 0>>)
    == Error(wire.Invalid)
  assert wire.encode_placement(enrolled(), original, <<7>>)
    == Error(wire.Invalid)
}

pub fn closed_launch_controls_reject_wrong_namespace_and_budget_test() {
  let assert Ok(digest) = identity.digest(<<1:size(256)>>) as "receipt digest"
  let commands = [
    wire.ChallengeRequest,
    wire.PlaceToken(<<2:size(256)>>, 1000),
    wire.Query,
    wire.Cancel,
    wire.Acknowledge(digest),
    wire.RefuseBeforeNative,
  ]
  list.each(commands, fn(command) {
    let assert Ok(bytes) = wire.encode_command(command)
      as "closed Launch command"
    assert wire.decode_command(bytes) == Ok(command)
    assert wire.decode_command(<<bytes:bits, 0>>) == Error(wire.Invalid)
  })
  assert wire.decode_command(<<"LCQ", 1, 2>>) == Error(wire.Invalid)
  assert wire.encode_command(wire.PlaceToken(<<2:size(256)>>, 0))
    == Error(wire.Invalid)
  assert wire.decode_command(<<"LLQ", 1, 1, 2:size(256), 86_400_001:32>>)
    == Error(wire.Invalid)
}

pub fn launch_history_checks_exact_key_and_never_contains_token_test() {
  let original = launched(compiled("pub fn main() { Nil }", 3).key, 5)
  let answer = Ok(launch_service.Observed(j.Reserved, j.LaunchPending))
  let assert Ok(#(metadata, None)) = wire.encode_reply(original.key, answer)
    as "actual pending answer encodes without completion"
  assert wire.decode_reply(enrolled(), original, metadata, None)
    == Ok(wire.Observed(j.Reserved, wire.Pending))
  assert wire.decode_reply(
      enrolled(),
      compiled("pub fn main() { Nil }", 3),
      metadata,
      None,
    )
    == Error(wire.Invalid)
  let original_enrollment = enrolled()
  let facts = enrollment.native_facts(original_enrollment)
  let assert Ok(other_scope) =
    cw.scope_from_fields(
      "00000000-0000-7000-8000-000000000001",
      "checkout",
      "linux",
      3,
      7,
    )
    as "changed original authority epoch"
  let assert Ok(other_enrollment) =
    enrollment.new(
      enrollment.NativeFacts(..facts, scope: other_scope),
      enrollment.code_mode_facts(original_enrollment),
      hash("b"),
      hash("c"),
    )
    as "different trusted scope"
  assert wire.decode_reply(other_enrollment, original, metadata, None)
    == Error(wire.Invalid)
  let other = launched(compiled("pub fn main() { Nil }", 3).key, 6)
  assert wire.decode_reply(enrolled(), other, metadata, None)
    == Error(wire.Invalid)
  assert wire.decode_reply(enrolled(), original, <<metadata:bits, 0>>, None)
    == Error(wire.Invalid)
  let assert Ok(#(refusal, None)) =
    wire.encode_reply(original.key, Error(launch_service.Invalid))
    as "actual refusal is closed metadata"
  assert wire.decode_reply(enrolled(), original, refusal, None)
    == Error(wire.Refused)
}

fn scope() -> cw.Scope {
  let assert Ok(scope) =
    cw.scope_from_fields(
      "00000000-0000-7000-8000-000000000001",
      "checkout",
      "linux",
      2,
      7,
    )
    as "Full original scope."
  scope
}

fn hash(c: String) -> String {
  string.repeat(c, 64)
}

fn base() -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    writable_roots: ["/work", "/alloc"],
    readable_roots: ["/tc", "/seed", "/work"],
    protected: ["/work/.git"],
    network: policy.NetworkOff,
    limits: policy.Limits(11, 12, 13, 14, 15, 16),
    env_allow: ["PATH", "HOME"],
    scratch: policy.ScratchTmpfs,
    mounts: [
      policy.Mount("/tc", policy.MountReadOnly, policy.MountRequired),
      policy.Mount("/seed", policy.MountReadOnly, policy.MountOptional),
    ],
  )
}

fn enrolled() -> enrollment.SessionEnrollment {
  let assert Ok(enrolled) =
    enrollment.new(
      enrollment.NativeFacts(scope(), ["/"], base(), exec.PlatformEnforcement),
      enrollment.CodeModeFacts(
        "/work",
        "/alloc/build",
        "/alloc/channel",
        "/tc/bin/gleam",
        "/tc/bin/erl",
        "/seed",
        ["/tc"],
        base().mounts,
        "/tc/bin",
      ),
      hash("b"),
      hash("c"),
    )
    as "Exact isolated trusted enrollment."
  enrolled
}

fn id(number: Int) -> ids.EntryId {
  let assert Ok(id) =
    ids.parse_entry_id(
      "00000000-0000-7000-8000-"
      <> string.pad_start(int.to_string(number), 12, "0"),
    )
    as "Original UUID."
  id
}

fn parent(
  step: String,
  index: Int,
  digest: String,
  result: Int,
) -> remote_tool.ToolKey {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "Session UUID."
  let assert Ok(operation) =
    ids.parse_op_id("00000000-0000-7000-8000-000000000002")
    as "Operation UUID."
  let assert Ok(parent) =
    remote_tool.key(session, operation, step, index, digest, id(result))
    as "Complete original managed parent."
  parent
}

fn key(
  role: command.ServiceRole,
  step: String,
  number: Int,
  parent: remote_tool.ToolKey,
  body: BitArray,
) -> command.ServiceKey {
  let assert Ok(step) = cw.step(step) as "Physical coordinate."
  let digest = string.lowercase(bit_array.base16_encode(j.digest(body)))
  let assert Ok(key) =
    command.service_key(
      parent,
      role,
      scope(),
      remote_tool.operation(parent),
      step,
      id(number),
      digest,
      hash("b"),
      hash("c"),
    )
    as "Digest-linked complete service key."
  key
}

fn compiled(source: String, number: Int) -> j.Input {
  let assert Ok(decoded) =
    input.compile_input(
      enrolled(),
      input.WorkspaceProgram,
      source,
      [],
      compile.default_dependencies(),
      base(),
      180_000,
    )
    as "Canonical compile input."
  let body = input.encode_compile(decoded)
  j.Input(
    key(
      command.CompileService,
      "physical:build",
      number,
      parent("parent", 3, hash("a"), 4),
      body,
    ),
    body,
  )
}

fn launched(producer: command.ServiceKey, number: Int) -> j.Input {
  let #(scope, operation, step) = command.coordinates(producer)
  let #(digest, _, contract) = command.digests(producer)
  let artifact =
    compile.ExecutorArtifact(
      scope,
      operation,
      step,
      ids.entry_id_to_string(command.request_id(producer)),
      digest,
      "issued-artifact",
      contract,
      compile.entry_module,
      "sha256-" <> hash("e"),
    )
  let assert Ok(decoded) =
    input.launch_input(
      enrolled(),
      producer,
      artifact,
      [],
      cw.root(),
      base(),
      hash("d"),
    )
    as "Canonical launch body, without successful artifact proof."
  let body = input.encode_launch(decoded)
  j.Input(
    key(
      command.LaunchService,
      "physical:run",
      number,
      command.parent(producer),
      body,
    ),
    body,
  )
}

// Historical Ready and retained bytes establish no Connection or local COMMIT.
pub fn launch_ready_and_completion_digest_are_checked_as_history_test() {
  let producer = compiled("pub fn main() { Nil }", 3)
  let original = launched(producer.key, 5)
  let assert Ok(paths) = enrollment.launch_paths(enrolled(), original.key)
    as "original channel locations"
  let assert Ok(locations) =
    resources.admit_launch_resources(
      enrolled(),
      original.key,
      producer.key,
      paths.0,
      paths.1,
      paths.2,
    )
    as "original Launch and producer keys"
  let ready = resources.LaunchReady(locations)
  let assert Ok(#(metadata, None)) =
    wire.encode_reply(
      original.key,
      Ok(launch_service.Observed(j.Prepared(ready), j.LaunchPending)),
    )
    as "historical Launch Ready encodes"
  assert wire.decode_reply(enrolled(), original, metadata, None)
    == Ok(wire.Observed(j.Prepared(ready), wire.Pending))
  let alternate = compiled("pub fn main() { 1 }", 7)
  assert command.parent(alternate.key) == command.parent(producer.key)
  let assert Ok(other_locations) =
    resources.admit_launch_resources(
      enrolled(),
      original.key,
      alternate.key,
      paths.0,
      paths.1,
      paths.2,
    )
    as "same parent and enrollment do not prove the actual producer"
  let assert Ok(#(wrong_producer, None)) =
    wire.encode_reply(
      original.key,
      Ok(launch_service.Observed(
        j.Prepared(resources.LaunchReady(other_locations)),
        j.LaunchPending,
      )),
    )
    as "historical bytes name an alternate actual producer"
  assert wire.decode_reply(enrolled(), original, wrong_producer, None)
    == Error(wire.Invalid)
  let assert Ok(build_path) = enrollment.compile_path(enrolled(), producer.key)
    as "original compile locations"
  let assert Ok(build) =
    resources.admit_compile_locations(enrolled(), producer.key, build_path)
    as "compile Ready is separately typed"
  let assert Ok(#(wrong, None)) =
    wire.encode_reply(
      original.key,
      Ok(launch_service.Observed(
        j.Prepared(resources.CompileReady(build)),
        j.LaunchPending,
      )),
    )
    as "hostile wrong-role historical bytes"
  assert wire.decode_reply(enrolled(), original, wrong, None)
    == Error(wire.Invalid)
  let assert Ok(closed) =
    completion.refused_before_native(
      enrolled(),
      original.key,
      "definite refusal",
    )
    as "closed before-native evidence"
  let assert Ok(bytes) = completion.encode(closed)
    as "canonical completion bytes"
  let digest_bytes = crypto.hash(crypto.Sha256, bytes)
  let assert Ok(digest) = identity.digest(digest_bytes) as "actual outer digest"
  let metadata = history_metadata(original.key, digest_bytes)
  assert wire.decode_reply(enrolled(), original, metadata, Some(bytes))
    == Ok(wire.Observed(
      j.Reserved,
      wire.Retained(closed, bytes, digest, j.ReceiptPending),
    ))
  assert wire.decode_reply(
      enrolled(),
      original,
      history_metadata(original.key, <<0:size(256)>>),
      Some(bytes),
    )
    == Error(wire.Invalid)
  assert wire.decode_reply(
      enrolled(),
      original,
      metadata,
      Some(<<bytes:bits, 0>>),
    )
    == Error(wire.Invalid)
  assert wire.decode_reply(enrolled(), original, metadata, None)
    == Error(wire.Invalid)
}

fn history_metadata(key: command.ServiceKey, digest: BitArray) -> BitArray {
  let assert Ok(bytes) =
    mp.encode(
      mp.ArrayValue([
        mp.IntValue(1),
        mp.StringValue("loom.remote.launch/1"),
        mp.StringValue(command.encode_service(key) |> json.to_string),
        mp.ArrayValue([
          mp.IntValue(1),
          mp.ArrayValue([mp.IntValue(0)]),
          mp.ArrayValue([mp.IntValue(1), mp.IntValue(0), mp.BinaryValue(digest)]),
        ]),
      ]),
    )
    as "closed retained completion metadata encodes"
  bytes
}
