//// Closed Compile completion controls preserve exact identity and native evidence.
////
//// ## Flow
////
//// `success` constructs the common full association, `terminal` supplies exact
//// native evidence, and `decode` submits hostile closed-shape variants. The
//// controls vary identity, native verdict, physical products and raw framing
//// independently so a constructor or canonicality regression has a concrete
//// witness rather than a test that repeats its implementation.

import broker/broker
import broker/dispatch
import broker/enrollment
import broker/exec
import broker/policy
import codemode/compile
import codemode/enforcement
import codemode/service_resources as resources
import core/bounded_msgpack
import core/command
import core/ids
import core/msgpack as mp
import core/remote_tool
import core/workspace
import executor/remote/compile_completion as completion
import executor/remote/identity
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

fn root() -> String {
  "/alloc/build/00000000-0000-7000-8000-000000000003"
}

fn locations() -> resources.CompileLocations {
  let assert Ok(value) =
    resources.admit_compile_locations(
      enrolled(),
      key(command.CompileService),
      root(),
    )
    as "The exact prepared allocation validates."
  value
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

fn products() -> compile.BuildProducts {
  compile.BuildProducts(root() <> "/ebin", "sha256-" <> string.repeat("f", 64))
}

fn success() -> completion.CompileCompletion {
  let assert Ok(value) =
    completion.successful(
      enrolled(),
      key(command.CompileService),
      locations(),
      child(),
      digest(),
      terminal(exit()),
      products(),
    )
    as "Actual successful native evidence and physical products admit."
  value
}

fn encode(value: completion.CompileCompletion) -> BitArray {
  let assert Ok(bytes) = completion.encode(value)
    as "A bounded checked completion encodes."
  bytes
}

fn value() -> mp.MsgPackValue {
  let assert Ok(value) = mp.decode(encode(success()))
    as "Canonical fixture decodes."
  value
}

fn decode(
  value: mp.MsgPackValue,
) -> Result(completion.CompileCompletion, completion.Error) {
  let assert Ok(bytes) = mp.encode(value) as "Raw test value encodes."
  completion.decode(enrolled(), key(command.CompileService), bytes)
}

pub fn success_derives_all_artifact_and_native_fields_and_report_test() {
  let saved = success()
  assert completion.decode(
      enrolled(),
      key(command.CompileService),
      encode(saved),
    )
    == Ok(saved)
  assert completion.original(saved) == key(command.CompileService)
  assert completion.native_association(saved)
    == Some(completion.NativeAssociation(child(), digest(), terminal(exit())))
  let #(scope, operation, step) =
    command.coordinates(key(command.CompileService))
  assert completion.compiled(saved)
    == compile.Compiled(
      Ok(compile.ExecutorArtifact(
        scope,
        operation,
        step,
        "00000000-0000-7000-8000-000000000003",
        string.repeat("d", 64),
        "00000000-0000-7000-8000-000000000003",
        string.repeat("c", 64),
        compile.entry_module,
        "sha256-" <> string.repeat("f", 64),
      )),
      enforcement.Reported(exit().enforcement, True),
    )
  assert identity.key_fields(child()).1
    != ids.entry_id_to_string(command.request_id(key(command.CompileService)))
}

pub fn all_pre_native_errors_preserve_discriminator_and_fixed_report_test() {
  list.each(
    [
      compile.WorkspaceSetupFailed("mkdir"),
      compile.BuildRejected("diagnostics"),
      compile.BuildUnavailable("helper"),
      compile.ArtifactIncomplete("beam"),
    ],
    fn(error) {
      let assert Ok(saved) =
        completion.failed_before_native(
          enrolled(),
          key(command.CompileService),
          error,
        )
        as "Each pre-native error admits."
      assert completion.native_association(saved) == None
      assert completion.compiled(saved)
        == compile.Compiled(
          Error(error),
          enforcement.Unreported(completion.before_native_reason),
        )
      assert completion.decode(
          enrolled(),
          key(command.CompileService),
          encode(saved),
        )
        == Ok(saved)
    },
  )
}

pub fn native_errors_retain_complete_terminal_report_and_discriminator_test() {
  let failed = exec.ExecResult(..exit(), code: 1)
  list.each(
    [
      compile.WorkspaceSetupFailed("mkdir"),
      compile.BuildRejected("diagnostics"),
      compile.BuildUnavailable("helper"),
      compile.ArtifactIncomplete("beam"),
    ],
    fn(error) {
      let assert Ok(saved) =
        completion.failed_native(
          enrolled(),
          key(command.CompileService),
          child(),
          digest(),
          terminal(failed),
          error,
        )
        as "Native-associated error admits."
      assert completion.compiled(saved)
        == compile.Compiled(
          Error(error),
          enforcement.of_call(broker.CallExited(failed)),
        )
      assert completion.native_association(saved)
        == Some(completion.NativeAssociation(
          child(),
          digest(),
          terminal(failed),
        ))
      assert completion.decode(
          enrolled(),
          key(command.CompileService),
          encode(saved),
        )
        == Ok(saved)
    },
  )

  // Successful native work may still fail finalization without yielding an artifact.
  list.each(
    [compile.ArtifactIncomplete("missing"), compile.BuildUnavailable("hash")],
    fn(error) {
      let assert Ok(saved) =
        completion.failed_native(
          enrolled(),
          key(command.CompileService),
          child(),
          digest(),
          terminal(exit()),
          error,
        )
        as "A finalizer failure retains successful native evidence."
      assert completion.compiled(saved).result == Error(error)
      assert completion.decode(
          enrolled(),
          key(command.CompileService),
          encode(saved),
        )
        == Ok(saved)
    },
  )
}

pub fn failed_native_terminal_derives_unreported_and_degraded_reports_test() {
  list.each(
    [
      exec.HelperBusy,
      exec.RefusedByHelper("code", "reason"),
      exec.DegradedExecution(exit()),
    ],
    fn(failure) {
      let assert Ok(bytes) = native.encode_terminal(dispatch.Failed(failure))
        as "Native failure encodes."
      let error = compile.BuildUnavailable("native")
      let assert Ok(saved) =
        completion.failed_native(
          enrolled(),
          key(command.CompileService),
          child(),
          digest(),
          bytes,
          error,
        )
        as "A native failure is data, not success."
      assert completion.compiled(saved)
        == compile.Compiled(
          Error(error),
          enforcement.of_call(broker.CallFailed(failure)),
        )
      assert completion.decode(
          enrolled(),
          key(command.CompileService),
          encode(saved),
        )
        == Ok(saved)
      assert completion.successful(
          enrolled(),
          key(command.CompileService),
          locations(),
          child(),
          digest(),
          bytes,
          products(),
        )
        == Error(completion.Invalid)
    },
  )
}

pub fn cancelled_zero_never_issues_an_artifact_test() {
  assert completion.successful(
      enrolled(),
      key(command.CompileService),
      locations(),
      child(),
      digest(),
      terminal(exec.ExecResult(..exit(), cancelled: True)),
      products(),
    )
    == Error(completion.Invalid)
}

pub fn signal_timeout_and_nonzero_never_issue_an_artifact_test() {
  list.each(
    [
      exec.ExecResult(..exit(), signal: 15),
      exec.ExecResult(..exit(), timed_out: True),
      exec.ExecResult(..exit(), code: 1),
    ],
    fn(failed) {
      assert completion.successful(
          enrolled(),
          key(command.CompileService),
          locations(),
          child(),
          digest(),
          terminal(failed),
          products(),
        )
        == Error(completion.Invalid)
    },
  )
}

pub fn all_scope_fields_and_enrollment_digests_are_pinned_test() {
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
        as "Valid independently substituted scope."
      let assert Ok(session) = ids.parse_session_id(fields.0)
        as "Valid session."
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
        as "Parent binds changed session."
      let changed =
        service(
          command.CompileService,
          scope,
          string.repeat("b", 64),
          string.repeat("c", 64),
          parent,
        )
      assert completion.failed_before_native(
          enrolled(),
          changed,
          compile.BuildUnavailable("failure"),
        )
        == Error(completion.Mismatch)
      assert completion.decode(enrolled(), changed, encode(success()))
        == Error(completion.Mismatch)
      assert completion.successful(
          enrolled(),
          key(command.CompileService),
          locations(),
          identity.request_key(
            native_scope(scope),
            remote_tool.operation(base),
            native_request(),
          ),
          digest(),
          terminal(exit()),
          products(),
        )
        == Error(completion.Mismatch)
    },
  )
  list.each(
    [
      #(string.repeat("e", 64), string.repeat("c", 64)),
      #(string.repeat("b", 64), string.repeat("e", 64)),
    ],
    fn(digests) {
      let changed =
        service(
          command.CompileService,
          scope(2),
          digests.0,
          digests.1,
          original_parent(),
        )
      assert completion.failed_before_native(
          enrolled(),
          changed,
          compile.BuildUnavailable("failure"),
        )
        == Error(completion.Mismatch)
      assert completion.decode(enrolled(), changed, encode(success()))
        == Error(completion.Mismatch)
    },
  )
}

fn native_request() -> identity.RequestId {
  let assert Ok(request) =
    identity.request_id("00000000-0000-7000-8000-000000000009")
    as "Valid native request."
  request
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
        string.repeat("e", 64),
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
          command.CompileService,
          scope(2),
          string.repeat("b", 64),
          string.repeat("c", 64),
          parent,
        )
      assert completion.decode(enrolled(), changed, encode(success()))
        == Error(completion.Mismatch)
    },
  )
  let assert Ok(operation) =
    ids.parse_op_id("00000000-0000-7000-8000-000000000022")
    as "Another complete original operation."
  let base_parent = original_parent()
  let assert Ok(other_parent) =
    remote_tool.key(
      remote_tool.session(base_parent),
      operation,
      "parent",
      3,
      string.repeat("a", 64),
      remote_tool.result_entry(base_parent),
    )
    as "Parent binds another operation."
  let other =
    service(
      command.CompileService,
      scope(2),
      string.repeat("b", 64),
      string.repeat("c", 64),
      other_parent,
    )
  assert completion.decode(enrolled(), other, encode(success()))
    == Error(completion.Mismatch)
  let original = key(command.CompileService)
  let #(scope, operation, step) = command.coordinates(original)
  let assert Ok(other_step) = workspace.step("other")
    as "Another physical step."
  let assert Ok(other_id) =
    ids.parse_entry_id("00000000-0000-7000-8000-000000000013")
    as "Another original UUID."
  list.each(
    [
      #(step, command.request_id(original), string.repeat("e", 64)),
      #(other_step, command.request_id(original), string.repeat("d", 64)),
      #(step, other_id, string.repeat("d", 64)),
    ],
    fn(fields) {
      let assert Ok(changed) =
        command.service_key(
          original_parent(),
          command.CompileService,
          scope,
          operation,
          fields.0,
          fields.1,
          fields.2,
          string.repeat("b", 64),
          string.repeat("c", 64),
        )
        as "Valid substituted full original."
      assert completion.decode(enrolled(), changed, encode(success()))
        == Error(completion.Mismatch)
    },
  )
  assert completion.failed_before_native(
      enrolled(),
      key(command.LaunchService),
      compile.BuildUnavailable("failure"),
    )
    == Error(completion.Mismatch)
}

pub fn foreign_native_operation_and_changed_location_are_refused_test() {
  let assert mp.ArrayValue([
    version,
    header,
    mp.ArrayValue([tag, _, association, beam, hash]),
  ]) = value()
    as "Success keeps literal allocation."
  assert decode(
      mp.ArrayValue([
        version,
        header,
        mp.ArrayValue([
          tag,
          mp.StringValue(root() <> "/."),
          association,
          beam,
          hash,
        ]),
      ]),
    )
    == Error(completion.Mismatch)

  let assert Ok(operation) =
    ids.parse_op_id("00000000-0000-7000-8000-000000000022")
    as "Another native operation."
  let foreign =
    identity.request_key(native_scope(scope(2)), operation, native_request())
  assert completion.successful(
      enrolled(),
      key(command.CompileService),
      locations(),
      foreign,
      digest(),
      terminal(exit()),
      products(),
    )
    == Error(completion.Mismatch)
  assert completion.failed_native(
      enrolled(),
      key(command.CompileService),
      foreign,
      digest(),
      terminal(exit()),
      compile.BuildUnavailable("failure"),
    )
    == Error(completion.Mismatch)
  let other =
    service(
      command.CompileService,
      scope(2),
      string.repeat("b", 64),
      string.repeat("c", 64),
      parent(
        "different",
        3,
        string.repeat("a", 64),
        "00000000-0000-7000-8000-000000000004",
      ),
    )
  let assert Ok(other_locations) =
    resources.admit_compile_locations(enrolled(), other, root())
    as "Same root can describe another original parent."
  assert completion.successful(
      enrolled(),
      key(command.CompileService),
      other_locations,
      child(),
      digest(),
      terminal(exit()),
      products(),
    )
    == Error(completion.Mismatch)
  list.each(
    [root() <> "/./ebin", root() <> "/elsewhere", root() <> "/ebin/"],
    fn(beam) {
      assert completion.successful(
          enrolled(),
          key(command.CompileService),
          locations(),
          child(),
          digest(),
          terminal(exit()),
          compile.BuildProducts(beam, products().manifest_hash),
        )
        == Error(completion.Mismatch)
    },
  )
}

pub fn products_fingerprint_and_closed_entry_boundary_test() {
  list.each(
    [
      string.repeat("a", 64),
      "sha256-" <> string.repeat("F", 64),
      "sha256-" <> string.repeat("g", 64),
      "sha256-" <> string.repeat("f", 63),
      "sha256-" <> string.repeat("f", 65),
    ],
    fn(hash) {
      assert completion.successful(
          enrolled(),
          key(command.CompileService),
          locations(),
          child(),
          digest(),
          terminal(exit()),
          compile.BuildProducts(products().beam_dir, hash),
        )
        == Error(completion.Invalid)
    },
  )
  let assert mp.ArrayValue([version, key, mp.ArrayValue(fields)]) = value()
    as "Success shape."

  // Entry is derived, not a peer field; adding a purported alternative refuses.
  assert decode(
      mp.ArrayValue([
        version,
        key,
        mp.ArrayValue(list.append(fields, [mp.StringValue("foreign_entry")])),
      ]),
    )
    == Error(completion.Invalid)
}

pub fn diagnostic_byte_limit_applies_to_every_error_before_retention_test() {
  let legal = string.repeat("🦀", 2000)
  let oversized = legal <> "x"
  list.each(
    [
      compile.WorkspaceSetupFailed,
      compile.BuildRejected,
      compile.BuildUnavailable,
      compile.ArtifactIncomplete,
    ],
    fn(make_error) {
      let assert Ok(saved) =
        completion.failed_before_native(
          enrolled(),
          key(command.CompileService),
          make_error(legal),
        )
        as "Exactly 8000 bytes are preserved."
      assert completion.decode(
          enrolled(),
          key(command.CompileService),
          encode(saved),
        )
        == Ok(saved)
      assert completion.failed_before_native(
          enrolled(),
          key(command.CompileService),
          make_error(oversized),
        )
        == Error(completion.Invalid)
      assert completion.failed_native(
          enrolled(),
          key(command.CompileService),
          child(),
          digest(),
          terminal(exit()),
          make_error(oversized),
        )
        == Error(completion.Invalid)
    },
  )
}

pub fn terminal_exact_limit_and_derived_report_bound_test() {
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
    completion.successful(
      enrolled(),
      key(command.CompileService),
      locations(),
      child(),
      digest(),
      full,
      products(),
    )
    as "Exactly 32 KiB terminal remains bounded and usable."
  assert completion.decode(
      enrolled(),
      key(command.CompileService),
      encode(saved),
    )
    == Ok(saved)
  assert completion.successful(
      enrolled(),
      key(command.CompileService),
      locations(),
      child(),
      digest(),
      <<full:bits, 0>>,
      products(),
    )
    == Error(completion.Invalid)
  let assert Ok(unreported) =
    native.encode_terminal(
      dispatch.Failed(exec.RefusedByHelper("x", string.repeat("y", 8192))),
    )
    as "Native text meets its independent field bound."
  assert completion.failed_native(
      enrolled(),
      key(command.CompileService),
      child(),
      digest(),
      unreported,
      compile.BuildUnavailable("native"),
    )
    == Error(completion.Invalid)
}

pub fn changed_native_uuid_digest_and_terminal_are_preserved_without_hash_confusion_test() {
  let assert Ok(request) =
    identity.request_id("00000000-0000-7000-8000-000000000019")
    as "Another independent UUID."
  let other =
    identity.request_key(
      native_scope(scope(2)),
      remote_tool.operation(original_parent()),
      request,
    )
  let assert Ok(digest) = identity.digest(<<18:size(256)>>)
    as "Another Prepared digest."
  let bytes = terminal(exec.ExecResult(..exit(), wall_ms: 101, degraded: True))
  let assert Ok(saved) =
    completion.successful(
      enrolled(),
      key(command.CompileService),
      locations(),
      other,
      digest,
      bytes,
      products(),
    )
    as "Prepared digest is not incorrectly compared with a terminal hash."
  assert completion.native_association(saved)
    == Some(completion.NativeAssociation(other, digest, bytes))
  assert completion.decode(
      enrolled(),
      key(command.CompileService),
      encode(saved),
    )
    == Ok(saved)
  assert completion.compiled(saved).result
    == completion.compiled(success()).result
  assert encode(saved) != encode(success())
}

pub fn closed_shape_and_noncanonical_outer_and_nested_encodings_refuse_test() {
  let assert mp.ArrayValue([version, header, outcome]) = value()
    as "Closed completion shape."
  list.each(
    [
      mp.ArrayValue([mp.IntValue(2), header, outcome]),
      mp.ArrayValue([version, header, outcome, mp.NilValue]),
      mp.ArrayValue([version, header, mp.ArrayValue([mp.IntValue(9)])]),
      mp.ArrayValue([
        version,
        header,
        mp.ArrayValue([
          mp.IntValue(0),
          mp.ArrayValue([mp.IntValue(9), mp.StringValue("unknown")]),
        ]),
      ]),
      mp.ArrayValue([
        version,
        header,
        mp.ArrayValue([
          mp.IntValue(1),
          mp.ArrayValue([
            mp.BinaryValue(<<1, 0>>),
            mp.BinaryValue(terminal(exit())),
          ]),
          mp.ArrayValue([mp.IntValue(2), mp.StringValue("failure")]),
        ]),
      ]),
    ],
    fn(raw) {
      assert decode(raw) == Error(completion.Invalid)
    },
  )
  let assert <<0x93, rest:bits>> = encode(success()) as "Canonical outer array."
  assert completion.decode(enrolled(), key(command.CompileService), <<
      0xdc,
      3:size(16),
      rest:bits,
    >>)
    == Error(completion.Invalid)
  let assert <<0x92, nested:bits>> = terminal(exit())
    as "Canonical terminal array."
  assert completion.successful(
      enrolled(),
      key(command.CompileService),
      locations(),
      child(),
      digest(),
      <<0xdc, 2:size(16), nested:bits>>,
      products(),
    )
    == Error(completion.Invalid)
}

pub fn raw_framing_limits_truncation_and_hostile_terms_are_total_test() {
  let bytes = encode(success())
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
      assert completion.decode(enrolled(), key(command.CompileService), raw)
        == Error(completion.Invalid)
    },
  )

  // The complete raw preflight accepts its exact total ceiling before semantic
  // completion decoding refuses this unrelated but well-formed value.
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
    as "Exact outer byte ceiling passes preflight."
  assert completion.decode(enrolled(), key(command.CompileService), boundary)
    == Error(completion.Invalid)
  assert completion.decode(enrolled(), key(command.CompileService), <<
      boundary:bits,
      0,
    >>)
    == Error(completion.Invalid)
}
