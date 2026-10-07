//// Launch history preserves closed node evidence without live channel authority.
////
//// These controls vary original identity, native verdict, diagnostic bytes and
//// nested/raw framing independently. A settled zero exit never becomes program
//// success or cleanup, and refusal retains only historical bounded diagnostics.

import broker/broker
import broker/dispatch
import broker/enrollment
import broker/exec
import broker/policy
import codemode/compile
import codemode/enforcement
import core/bounded_msgpack
import core/command
import core/ids
import core/json_wire
import core/msgpack as mp
import core/remote_tool
import core/workspace
import executor/remote/compile_completion
import executor/remote/identity
import executor/remote/journal_codec
import executor/remote/launch_completion as completion
import executor/remote/native
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string

fn scope(epoch: Int) -> workspace.Scope {
  let assert Ok(value) =
    workspace.scope_from_fields(
      "00000000-0000-7000-8000-000000000001",
      "checkout",
      "linux",
      epoch,
      7,
    )
    as "Scope retains the original session and both epochs."
  value
}

fn host_mounts() -> List(policy.Mount) {
  [
    policy.Mount("/tc", policy.MountReadOnly, policy.MountRequired),
    policy.Mount("/seed", policy.MountReadOnly, policy.MountOptional),
  ]
}

fn native() -> enrollment.NativeFacts {
  enrollment.NativeFacts(
    scope(2),
    ["/"],
    policy.SandboxPolicy(
      writable_roots: ["/work", "/alloc"],
      readable_roots: ["/tc", "/seed", "/work"],
      protected: ["/work/.git"],
      network: policy.NetworkProxy(["*.example.org"], "127.0.0.1:443"),
      limits: policy.Limits(11, 12, 13, 14, 15, 16),
      env_allow: ["PATH", "HOME"],
      scratch: policy.ScratchTmpfs,
      mounts: host_mounts(),
    ),
    exec.PlatformEnforcement,
  )
}

fn code() -> enrollment.CodeModeFacts {
  enrollment.CodeModeFacts(
    "/work",
    "/alloc/build",
    "/alloc/channel",
    "/tc/bin/gleam",
    "/tc/bin/erl",
    "/seed",
    ["/tc"],
    host_mounts(),
    "/tc/bin",
  )
}

fn make(
  native: enrollment.NativeFacts,
  code: enrollment.CodeModeFacts,
) -> Result(enrollment.SessionEnrollment, enrollment.Error) {
  enrollment.new(native, code, string.repeat("b", 64), string.repeat("c", 64))
}

fn enrolled() -> enrollment.SessionEnrollment {
  let assert Ok(value) = make(native(), code())
    as "The exact isolated configuration validates."
  value
}

fn parent(
  step: String,
  index: Int,
  arguments: String,
  result: String,
) -> remote_tool.ToolKey {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "Valid session."
  let assert Ok(operation) =
    ids.parse_op_id("00000000-0000-7000-8000-000000000002")
    as "Valid operation."
  let assert Ok(entry) = ids.parse_entry_id(result) as "Valid reserved result."
  let assert Ok(key) =
    remote_tool.key(session, operation, step, index, arguments, entry)
    as "Complete parent."
  key
}

fn original_parent() -> remote_tool.ToolKey {
  parent(
    "parent",
    3,
    string.repeat("a", 64),
    "00000000-0000-7000-8000-000000000004",
  )
}

fn service(
  role: command.ServiceRole,
  scope: workspace.Scope,
  registration: String,
  contract: String,
  parent: remote_tool.ToolKey,
) -> command.ServiceKey {
  let assert Ok(step) =
    workspace.step(case role {
      command.CompileService -> "physical:build"
      command.LaunchService -> "physical:run"
    })
    as "Different physical steps validate."
  let assert Ok(id) =
    ids.parse_entry_id(case role {
      command.CompileService -> "00000000-0000-7000-8000-000000000003"
      command.LaunchService -> "00000000-0000-7000-8000-000000000005"
    })
    as "Distinct original service UUIDs."
  let input = case role {
    command.CompileService -> string.repeat("d", 64)
    command.LaunchService -> string.repeat("e", 64)
  }
  let assert Ok(value) =
    command.service_key(
      parent,
      role,
      scope,
      remote_tool.operation(parent),
      step,
      id,
      input,
      registration,
      contract,
    )
    as "Complete service."
  value
}

fn key(role: command.ServiceRole) -> command.ServiceKey {
  service(
    role,
    scope(2),
    string.repeat("b", 64),
    string.repeat("c", 64),
    original_parent(),
  )
}

fn native_scope(scope: workspace.Scope) -> identity.Scope {
  let #(session, binding) = workspace.scope_fields(scope)
  let #(selector, workspace_epoch, session_epoch) =
    workspace.binding_fields(binding)
  let #(executor, workspace) = workspace.selector_fields(selector)
  let assert Ok(workspace) = identity.workspace_id(workspace)
    as "Valid workspace."
  let assert Ok(executor) = identity.executor_id(executor) as "Valid executor."
  let assert Ok(session_epoch) = identity.epoch(session_epoch)
    as "Valid session epoch."
  let assert Ok(workspace_epoch) = identity.epoch(workspace_epoch)
    as "Valid workspace epoch."
  identity.scope(session, workspace, executor, session_epoch, workspace_epoch)
}

fn child() -> identity.RequestKey {
  let assert Ok(request) =
    identity.request_id("00000000-0000-7000-8000-000000000009")
    as "Native UUID is independently reserved."
  identity.request_key(
    native_scope(scope(2)),
    remote_tool.operation(original_parent()),
    request,
  )
}

fn digest() -> identity.Digest {
  let assert Ok(value) = identity.digest(<<17:size(256)>>)
    as "Full native Prepared digest."
  value
}

fn exit() -> exec.ExecResult {
  exec.ExecResult(
    0,
    0,
    100,
    200,
    True,
    False,
    ["seatbelt", "skip:rlimit_as: platform"],
    False,
    99,
    False,
    False,
  )
}

fn terminal(result: exec.ExecResult) -> BitArray {
  let assert Ok(bytes) = native.encode_terminal(dispatch.Completed(result))
    as "A canonical complete native terminal encodes."
  bytes
}

fn settled() -> completion.LaunchCompletion {
  let assert Ok(saved) =
    completion.settled_native(
      enrolled(),
      key(command.LaunchService),
      child(),
      digest(),
      terminal(exit()),
    )
    as "Exact enrolled native settlement admits."
  saved
}

fn refused(reason: String) -> completion.LaunchCompletion {
  let assert Ok(saved) =
    completion.refused_before_native(
      enrolled(),
      key(command.LaunchService),
      reason,
    )
    as "Bounded historical refusal admits."
  saved
}

fn encode(saved: completion.LaunchCompletion) -> BitArray {
  let assert Ok(bytes) = completion.encode(saved)
    as "Checked completion encodes."
  bytes
}

fn value() -> mp.MsgPackValue {
  let assert Ok(value) = mp.decode(encode(settled()))
    as "Canonical fixture decodes."
  value
}

fn decode(
  value: mp.MsgPackValue,
) -> Result(completion.LaunchCompletion, completion.Error) {
  let assert Ok(bytes) = mp.encode(value) as "Raw test value encodes."
  completion.decode(enrolled(), key(command.LaunchService), bytes)
}

pub fn refusal_keeps_only_full_original_reason_and_fixed_unreported_test() {
  let saved = refused("clearance refused after Ready")
  assert completion.original(saved) == key(command.LaunchService)
  assert completion.observation(saved)
    == completion.RefusedBeforeNative("clearance refused after Ready")
  assert completion.native_association(saved) == None
  assert completion.enforcement_report(saved)
    == enforcement.Unreported(completion.before_native_reason)
  assert completion.decode(
      enrolled(),
      key(command.LaunchService),
      encode(saved),
    )
    == Ok(saved)

  let assert Ok(raw) = mp.decode(encode(saved))
    as "Closed historical frame decodes."
  assert raw
    == mp.ArrayValue([
      mp.IntValue(1),
      mp.StringValue("loom.remote.launch-completion/1"),
      json_wire.of_json(command.encode_service(key(command.LaunchService))),
      mp.ArrayValue([
        mp.IntValue(0),
        mp.StringValue("clearance refused after Ready"),
      ]),
    ])
}

pub fn native_verdicts_settle_without_program_or_cleanup_inference_test() {
  list.each(
    [
      exit(),
      exec.ExecResult(..exit(), cancelled: True),
      exec.ExecResult(..exit(), timed_out: True),
      exec.ExecResult(..exit(), signal: 15),
      exec.ExecResult(..exit(), code: 2, degraded: True),
    ],
    fn(exit) {
      let bytes = terminal(exit)
      let assert Ok(saved) =
        completion.settled_native(
          enrolled(),
          key(command.LaunchService),
          child(),
          digest(),
          bytes,
        )
        as "Every native exit is historical settlement."
      assert completion.observation(saved) == completion.NativeSettled
      assert completion.enforcement_report(saved)
        == enforcement.of_call(broker.CallExited(exit))
      assert completion.native_association(saved)
        == Some(completion.NativeAssociation(child(), digest(), bytes))
      assert completion.decode(
          enrolled(),
          key(command.LaunchService),
          encode(saved),
        )
        == Ok(saved)
    },
  )
  list.each(
    [
      exec.RefusedByHelper("landlock", "refused"),
      exec.ChannelClosed(137),
      exec.ProtocolViolation("bad frame"),
    ],
    fn(failure) {
      let assert Ok(bytes) = native.encode_terminal(dispatch.Failed(failure))
        as "Native failure encodes."
      let assert Ok(saved) =
        completion.settled_native(
          enrolled(),
          key(command.LaunchService),
          child(),
          digest(),
          bytes,
        )
        as "Helper failure is settlement, not before-native refusal."
      assert completion.observation(saved) == completion.NativeSettled
      assert completion.enforcement_report(saved)
        == enforcement.of_call(broker.CallFailed(failure))
      assert completion.decode(
          enrolled(),
          key(command.LaunchService),
          encode(saved),
        )
        == Ok(saved)
    },
  )
}

pub fn roles_and_codec_domains_are_not_interchangeable_test() {
  assert completion.refused_before_native(
      enrolled(),
      key(command.CompileService),
      "refused",
    )
    == Error(completion.Mismatch)
  assert completion.settled_native(
      enrolled(),
      key(command.CompileService),
      child(),
      digest(),
      terminal(exit()),
    )
    == Error(completion.Mismatch)
  let assert Ok(compiled) =
    compile_completion.failed_before_native(
      enrolled(),
      key(command.CompileService),
      compile.BuildUnavailable("refused"),
    )
    as "Independent Compile history admits."
  let assert Ok(compile_bytes) = compile_completion.encode(compiled)
    as "Compile history encodes."
  assert completion.decode(
      enrolled(),
      key(command.LaunchService),
      compile_bytes,
    )
    == Error(completion.Invalid)
  assert compile_completion.decode(
      enrolled(),
      key(command.CompileService),
      encode(refused("refused")),
    )
    == Error(compile_completion.Invalid)

  let assert mp.ArrayValue([version, domain, _, outcome]) = value()
    as "Closed Launch envelope."
  assert decode(
      mp.ArrayValue([
        version,
        domain,
        json_wire.of_json(command.encode_service(key(command.CompileService))),
        outcome,
      ]),
    )
    == Error(completion.Mismatch)
}

pub fn all_scope_and_enrollment_fields_are_pinned_test() {
  list.each(
    [
      #("00000000-0000-7000-8000-000000000011", "checkout", "linux", 2, 7),
      #("00000000-0000-7000-8000-000000000001", "other", "linux", 2, 7),
      #("00000000-0000-7000-8000-000000000001", "checkout", "other", 2, 7),
      #("00000000-0000-7000-8000-000000000001", "checkout", "linux", 3, 7),
      #("00000000-0000-7000-8000-000000000001", "checkout", "linux", 2, 8),
    ],
    fn(fields) {
      let assert Ok(scope) =
        workspace.scope_from_fields(
          fields.0,
          fields.1,
          fields.2,
          fields.3,
          fields.4,
        )
        as "Substituted scope validates."
      let assert Ok(session) = ids.parse_session_id(fields.0)
        as "Substituted session validates."
      let base = original_parent()
      let assert Ok(parent) =
        remote_tool.key(
          session,
          remote_tool.operation(base),
          "parent",
          3,
          string.repeat("a", 64),
          remote_tool.result_entry(base),
        )
        as "Parent binds substituted session."
      let changed =
        service(
          command.LaunchService,
          scope,
          string.repeat("b", 64),
          string.repeat("c", 64),
          parent,
        )
      assert completion.refused_before_native(enrolled(), changed, "refused")
        == Error(completion.Mismatch)
      assert completion.decode(enrolled(), changed, encode(settled()))
        == Error(completion.Mismatch)
      assert completion.settled_native(
          enrolled(),
          key(command.LaunchService),
          identity.request_key(
            native_scope(scope),
            remote_tool.operation(base),
            native_request(),
          ),
          digest(),
          terminal(exit()),
        )
        == Error(completion.Mismatch)
    },
  )
  list.each(
    [
      #(string.repeat("f", 64), string.repeat("c", 64)),
      #(string.repeat("b", 64), string.repeat("f", 64)),
    ],
    fn(digests) {
      let changed =
        service(
          command.LaunchService,
          scope(2),
          digests.0,
          digests.1,
          original_parent(),
        )
      assert completion.refused_before_native(enrolled(), changed, "refused")
        == Error(completion.Mismatch)
      assert completion.decode(enrolled(), changed, encode(settled()))
        == Error(completion.Mismatch)
    },
  )
}

fn native_request() -> identity.RequestId {
  let assert Ok(id) =
    identity.request_id("00000000-0000-7000-8000-000000000009")
    as "Native request validates."
  id
}

pub fn complete_parent_and_service_fields_are_pinned_test() {
  list.each(
    [
      parent(
        "other",
        3,
        string.repeat("a", 64),
        "00000000-0000-7000-8000-000000000004",
      ),
      parent(
        "parent",
        4,
        string.repeat("a", 64),
        "00000000-0000-7000-8000-000000000004",
      ),
      parent(
        "parent",
        3,
        string.repeat("f", 64),
        "00000000-0000-7000-8000-000000000004",
      ),
      parent(
        "parent",
        3,
        string.repeat("a", 64),
        "00000000-0000-7000-8000-000000000014",
      ),
    ],
    fn(parent) {
      let changed =
        service(
          command.LaunchService,
          scope(2),
          string.repeat("b", 64),
          string.repeat("c", 64),
          parent,
        )
      assert completion.decode(enrolled(), changed, encode(settled()))
        == Error(completion.Mismatch)
    },
  )
  let original = key(command.LaunchService)
  let #(scope, operation, step) = command.coordinates(original)
  let assert Ok(other_step) = workspace.step("other")
    as "Substituted step validates."
  let assert Ok(other_id) =
    ids.parse_entry_id("00000000-0000-7000-8000-000000000015")
    as "Substituted UUID validates."
  list.each(
    [
      #(step, command.request_id(original), string.repeat("f", 64)),
      #(other_step, command.request_id(original), string.repeat("e", 64)),
      #(step, other_id, string.repeat("e", 64)),
    ],
    fn(fields) {
      let assert Ok(changed) =
        command.service_key(
          original_parent(),
          command.LaunchService,
          scope,
          operation,
          fields.0,
          fields.1,
          fields.2,
          string.repeat("b", 64),
          string.repeat("c", 64),
        )
        as "Substituted full original validates."
      assert completion.decode(enrolled(), changed, encode(settled()))
        == Error(completion.Mismatch)
    },
  )
  let assert Ok(operation) =
    ids.parse_op_id("00000000-0000-7000-8000-000000000022")
    as "Other native operation validates."
  let foreign =
    identity.request_key(native_scope(scope), operation, native_request())
  assert completion.settled_native(
      enrolled(),
      original,
      foreign,
      digest(),
      terminal(exit()),
    )
    == Error(completion.Mismatch)
}

pub fn association_preserves_independent_uuid_prepared_digest_and_terminal_test() {
  let assert Ok(request) =
    identity.request_id("00000000-0000-7000-8000-000000000019")
    as "Independent UUID validates."
  let child =
    identity.request_key(
      native_scope(scope(2)),
      remote_tool.operation(original_parent()),
      request,
    )
  let assert Ok(digest) = identity.digest(<<18:size(256)>>)
    as "Independent Prepared digest validates."
  let bytes = terminal(exec.ExecResult(..exit(), wall_ms: 101, degraded: True))
  let assert Ok(saved) =
    completion.settled_native(
      enrolled(),
      key(command.LaunchService),
      child,
      digest,
      bytes,
    )
    as "No confusion between terminal hash and Prepared digest."
  assert completion.native_association(saved)
    == Some(completion.NativeAssociation(child, digest, bytes))
  assert completion.decode(
      enrolled(),
      key(command.LaunchService),
      encode(saved),
    )
    == Ok(saved)
  assert encode(saved) != encode(settled())
}

pub fn diagnostic_byte_limit_applies_before_retention_and_after_decode_test() {
  let legal = string.repeat("🦀", 2000)
  let saved = refused(legal)
  assert completion.decode(
      enrolled(),
      key(command.LaunchService),
      encode(saved),
    )
    == Ok(saved)
  assert completion.refused_before_native(
      enrolled(),
      key(command.LaunchService),
      legal <> "x",
    )
    == Error(completion.Invalid)
  let assert mp.ArrayValue([version, domain, header, _]) = value()
    as "Launch envelope shape."
  assert decode(
      mp.ArrayValue([
        version,
        domain,
        header,
        mp.ArrayValue([mp.IntValue(0), mp.StringValue(legal <> "x")]),
      ]),
    )
    == Error(completion.Invalid)
}

pub fn terminal_exact_limit_and_derived_unreported_limit_test() {
  let entries = [
    string.repeat("x", 8192),
    string.repeat("y", 8192),
    string.repeat("z", 8192),
    string.repeat("q", 5000),
  ]
  let base = terminal(exec.ExecResult(..exit(), enforcement: entries))
  let needed = 32_768 - bit_array.byte_size(base) + 5000
  let full =
    terminal(
      exec.ExecResult(
        ..exit(),
        enforcement: list.take(entries, 3)
          |> list.append([string.repeat("q", needed)]),
      ),
    )
  assert bit_array.byte_size(full) == 32_768
  let assert Ok(saved) =
    completion.settled_native(
      enrolled(),
      key(command.LaunchService),
      child(),
      digest(),
      full,
    )
    as "Exactly 32 KiB settlement is retained."
  assert completion.decode(
      enrolled(),
      key(command.LaunchService),
      encode(saved),
    )
    == Ok(saved)
  assert completion.settled_native(
      enrolled(),
      key(command.LaunchService),
      child(),
      digest(),
      <<full:bits, 0>>,
    )
    == Error(completion.Invalid)
  let assert Ok(unreported) =
    native.encode_terminal(
      dispatch.Failed(exec.RefusedByHelper("x", string.repeat("y", 8192))),
    )
    as "Native independent text bound permits fixture."
  assert completion.settled_native(
      enrolled(),
      key(command.LaunchService),
      child(),
      digest(),
      unreported,
    )
    == Error(completion.Invalid)
}

pub fn closed_shape_and_domains_refuse_extension_or_unknown_test() {
  let assert mp.ArrayValue([version, domain, header, outcome]) = value()
    as "Closed Launch shape."
  list.each(
    [
      mp.ArrayValue([mp.IntValue(2), domain, header, outcome]),
      mp.ArrayValue([
        version,
        mp.StringValue("loom.remote.compile-completion/1"),
        header,
        outcome,
      ]),
      mp.ArrayValue([version, domain, header, outcome, mp.NilValue]),
      mp.ArrayValue([version, domain, header, mp.ArrayValue([mp.IntValue(9)])]),
      mp.ArrayValue([
        version,
        domain,
        header,
        mp.ArrayValue([mp.IntValue(0), mp.StringValue("refused"), mp.NilValue]),
      ]),
      mp.ArrayValue([
        version,
        domain,
        header,
        mp.ArrayValue([
          mp.IntValue(1),
          mp.ArrayValue([
            mp.BinaryValue(<<1, 0>>),
            mp.BinaryValue(terminal(exit())),
          ]),
        ]),
      ]),
    ],
    fn(raw) {
      assert decode(raw) == Error(completion.Invalid)
    },
  )
}

pub fn canonical_outer_terminal_and_admit_identity_are_required_test() {
  let assert <<0x94, rest:bits>> = encode(settled()) as "Canonical outer array."
  assert completion.decode(enrolled(), key(command.LaunchService), <<
      0xdc,
      4:size(16),
      rest:bits,
    >>)
    == Error(completion.Invalid)
  let assert <<0x92, nested:bits>> = terminal(exit())
    as "Canonical terminal array."
  assert completion.settled_native(
      enrolled(),
      key(command.LaunchService),
      child(),
      digest(),
      <<0xdc, 2:size(16), nested:bits>>,
    )
    == Error(completion.Invalid)

  let assert mp.ArrayValue([
    version,
    domain,
    header,
    mp.ArrayValue([tag, mp.ArrayValue([mp.BinaryValue(admit), terminal])]),
  ]) = value()
    as "Canonical native identity shape."
  assert decode(
      mp.ArrayValue([
        version,
        domain,
        header,
        mp.ArrayValue([
          tag,
          mp.ArrayValue([
            mp.BinaryValue(<<admit:bits, 0>>),
            terminal,
          ]),
        ]),
      ]),
    )
    == Error(completion.Invalid)
  assert decode(
      mp.ArrayValue([
        version,
        domain,
        header,
        mp.ArrayValue([
          tag,
          mp.ArrayValue([
            mp.BinaryValue(journal_codec.encode(journal_codec.CloseEpoch)),
            terminal,
          ]),
        ]),
      ]),
    )
    == Error(completion.Invalid)
}

pub fn raw_framing_limits_truncation_and_hostile_terms_are_total_test() {
  let bytes = encode(settled())
  let assert Ok(short) =
    bit_array.slice(bytes, 0, bit_array.byte_size(bytes) - 1)
    as "Truncated fixture."
  list.each(
    [
      <<>>,
      short,
      <<bytes:bits, 0>>,
      <<0xdc, 129:size(16)>>,
      <<0xdb, 8193:size(32)>>,
      <<0xc6, 131_073:size(32)>>,
      <<0xa1, 0xff>>,
      <<1:size(1)>>,
    ],
    fn(raw) {
      assert completion.decode(enrolled(), key(command.LaunchService), raw)
        == Error(completion.Invalid)
    },
  )
  let a = string.repeat("a", 131_072) |> bit_array.from_string
  let b = string.repeat("b", 131_061) |> bit_array.from_string
  let boundary = <<
    0x92,
    0xc6,
    131_072:size(32),
    a:bits,
    0xc6,
    131_061:size(32),
    b:bits,
  >>
  assert bit_array.byte_size(boundary) == 262_144
  let assert Ok(_) = bounded_msgpack.decode(boundary)
    as "Exact aggregate byte limit passes preflight."
  assert completion.decode(enrolled(), key(command.LaunchService), boundary)
    == Error(completion.Invalid)
  assert completion.decode(enrolled(), key(command.LaunchService), <<
      boundary:bits,
      0,
    >>)
    == Error(completion.Invalid)
}
