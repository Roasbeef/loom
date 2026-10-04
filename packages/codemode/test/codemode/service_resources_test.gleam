//// Exact identity/location controls for historical preparation receipts.

import broker/enrollment
import broker/exec
import broker/policy
import codemode/service_resources as resources
import core/command
import core/ids
import core/json_wire
import core/msgpack as mp
import core/remote_tool
import core/workspace
import gleam/bit_array
import gleam/list
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

fn directory() -> String {
  "/alloc/channel/00000000-0000-7000-8000-000000000005"
}

fn compile() -> resources.CompileLocations {
  let assert Ok(value) =
    resources.admit_compile_locations(
      enrolled(),
      key(command.CompileService),
      root(),
    )
    as "Exact allocation admits."
  value
}

fn launch() -> resources.LaunchResources {
  let assert Ok(value) =
    resources.admit_launch_resources(
      enrolled(),
      key(command.LaunchService),
      key(command.CompileService),
      directory(),
      directory() <> "/s",
      directory() <> "/cap-token",
    )
    as "Exact channel handles admit."
  value
}

fn encoded(ready: resources.Ready) -> BitArray {
  let assert Ok(bytes) = resources.encode(ready) as "Canonical bounded frame."
  bytes
}

pub fn compile_and_launch_roundtrip_preserve_every_key_and_path_test() {
  let values = [
    resources.CompileReady(compile()),
    resources.LaunchReady(launch()),
  ]
  list.each(values, fn(value) {
    let bytes = encoded(value)
    assert resources.decode(enrolled(), bytes) == Ok(value)
    assert bit_array.byte_size(bytes) < 262_144
  })
  assert resources.compile_fields(compile())
    == #(key(command.CompileService), root())
  assert resources.launch_keys(launch())
    == #(key(command.LaunchService), key(command.CompileService))
  assert resources.launch_paths(launch())
    == #(directory(), directory() <> "/s", directory() <> "/cap-token")
}

pub fn different_physical_steps_inputs_and_request_ids_are_accepted_test() {
  let #(compiled, started) = #(
    key(command.CompileService),
    key(command.LaunchService),
  )
  assert command.coordinates(compiled).2 != command.coordinates(started).2
  assert command.digests(compiled).0 != command.digests(started).0
  assert command.request_id(compiled) != command.request_id(started)
  assert command.parent(compiled) == command.parent(started)
  assert resources.launch_keys(launch()) == #(started, compiled)
}

pub fn wrong_compile_or_launch_roles_are_refused_test() {
  assert resources.admit_compile_locations(
      enrolled(),
      key(command.LaunchService),
      root(),
    )
    == Error(resources.Mismatch)
  assert resources.admit_launch_resources(
      enrolled(),
      key(command.CompileService),
      key(command.CompileService),
      directory(),
      directory() <> "/s",
      directory() <> "/cap-token",
    )
    == Error(resources.Mismatch)
  assert resources.admit_launch_resources(
      enrolled(),
      key(command.LaunchService),
      key(command.LaunchService),
      directory(),
      directory() <> "/s",
      directory() <> "/cap-token",
    )
    == Error(resources.Mismatch)
}

fn changed_keys(role: command.ServiceRole) -> List(command.ServiceKey) {
  [
    service(
      role,
      scope(3),
      string.repeat("b", 64),
      string.repeat("c", 64),
      original_parent(),
    ),
    service(
      role,
      scope(2),
      string.repeat("f", 64),
      string.repeat("c", 64),
      original_parent(),
    ),
    service(
      role,
      scope(2),
      string.repeat("b", 64),
      string.repeat("f", 64),
      original_parent(),
    ),
  ]
}

pub fn changed_scope_registration_or_contract_on_either_key_is_refused_test() {
  list.each(changed_keys(command.CompileService), fn(changed) {
    assert resources.admit_compile_locations(enrolled(), changed, root())
      == Error(resources.Mismatch)
    assert resources.admit_launch_resources(
        enrolled(),
        key(command.LaunchService),
        changed,
        directory(),
        directory() <> "/s",
        directory() <> "/cap-token",
      )
      == Error(resources.Mismatch)
  })
  list.each(changed_keys(command.LaunchService), fn(changed) {
    assert resources.admit_launch_resources(
        enrolled(),
        changed,
        key(command.CompileService),
        directory(),
        directory() <> "/s",
        directory() <> "/cap-token",
      )
      == Error(resources.Mismatch)
  })
}

pub fn complete_original_parent_is_required_for_producer_test() {
  let variants = [
    parent(
      "another",
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
      "00000000-0000-7000-8000-000000000006",
    ),
  ]
  list.each(variants, fn(changed) {
    let producer =
      service(
        command.CompileService,
        scope(2),
        string.repeat("b", 64),
        string.repeat("c", 64),
        changed,
      )
    assert resources.admit_compile_locations(enrolled(), producer, root())
      != Error(resources.Mismatch)
    assert resources.admit_launch_resources(
        enrolled(),
        key(command.LaunchService),
        producer,
        directory(),
        directory() <> "/s",
        directory() <> "/cap-token",
      )
      == Error(resources.Mismatch)
  })
}

pub fn compile_path_substitution_and_aliases_are_refused_test() {
  list.each(
    [
      "/foreign",
      root() <> "/.",
      root() <> "/../other",
      root() <> "/",
      "/alloc//build/00000000-0000-7000-8000-000000000003",
    ],
    fn(path) {
      assert resources.admit_compile_locations(
          enrolled(),
          key(command.CompileService),
          path,
        )
        == Error(resources.Mismatch)
    },
  )
}

pub fn every_launch_handle_substitution_is_refused_test() {
  list.each(
    [
      #("/foreign", directory() <> "/s", directory() <> "/cap-token"),
      #(directory() <> "/.", directory() <> "/s", directory() <> "/cap-token"),
      #(directory(), directory() <> "/./s", directory() <> "/cap-token"),
      #(directory(), directory() <> "/s", directory() <> "/../cap-token"),
      #(directory(), directory() <> "/s", directory() <> "/other"),
    ],
    fn(paths) {
      assert resources.admit_launch_resources(
          enrolled(),
          key(command.LaunchService),
          key(command.CompileService),
          paths.0,
          paths.1,
          paths.2,
        )
        == Error(resources.Mismatch)
    },
  )
}

fn compile_frame(key: command.ServiceKey, path: String) -> mp.MsgPackValue {
  mp.ArrayValue([
    mp.IntValue(1),
    mp.StringValue("compile"),
    json_wire.of_json(command.encode_service(key)),
    mp.StringValue(path),
  ])
}

fn raw(value: mp.MsgPackValue) -> BitArray {
  let assert Ok(bytes) = mp.encode(value) as "Hostile semantic input encodes."
  bytes
}

pub fn decoder_readmits_keys_and_locations_under_trusted_enrollment_test() {
  assert resources.decode(
      enrolled(),
      raw(compile_frame(key(command.CompileService), "/foreign")),
    )
    == Error(resources.Mismatch)
  assert resources.decode(
      enrolled(),
      raw(compile_frame(key(command.LaunchService), root())),
    )
    == Error(resources.Mismatch)
  list.each(changed_keys(command.CompileService), fn(changed) {
    assert resources.decode(enrolled(), raw(compile_frame(changed, root())))
      == Error(resources.Mismatch)
  })
  let n = native()
  let assert Ok(changed) =
    make(enrollment.NativeFacts(..n, scope: scope(3)), code())
    as "Different enrollment validates independently."
  assert resources.decode(changed, encoded(resources.LaunchReady(launch())))
    == Error(resources.Mismatch)
}

pub fn unknown_versions_tags_shapes_and_extra_fields_are_refused_test() {
  let value = compile_frame(key(command.CompileService), root())
  let assert mp.ArrayValue(fields) = value
    as "Compile frame has fixed positional fields."
  list.each(
    [
      mp.ArrayValue(list.append(fields, [mp.NilValue])),
      mp.ArrayValue([
        mp.IntValue(2),
        mp.StringValue("compile"),
        json_wire.of_json(command.encode_service(key(command.CompileService))),
        mp.StringValue(root()),
      ]),
      mp.ArrayValue([
        mp.IntValue(1),
        mp.StringValue("lsp"),
        json_wire.of_json(command.encode_service(key(command.CompileService))),
        mp.StringValue(root()),
      ]),
      mp.ArrayValue([
        mp.IntValue(1),
        mp.StringValue("compile"),
        mp.NilValue,
        mp.StringValue(root()),
      ]),
      mp.NilValue,
    ],
    fn(value) {
      assert resources.decode(enrolled(), raw(value))
        == Error(resources.Invalid)
    },
  )
}

pub fn legal_alternative_messagepack_encodings_are_refused_test() {
  let bytes = encoded(resources.CompileReady(compile()))
  let assert <<0x94, 1, rest:bits>> = bytes
    as "Canonical four-field envelope and short version."
  assert resources.decode(enrolled(), <<0xdc, 4:size(16), 1, rest:bits>>)
    == Error(resources.Invalid)
  assert resources.decode(enrolled(), <<0x94, 0xcc, 1, rest:bits>>)
    == Error(resources.Invalid)
  assert resources.decode(enrolled(), <<bytes:bits, 0>>)
    == Error(resources.Invalid)
}

pub fn oversized_truncated_and_hostile_raw_frames_are_refused_test() {
  let large = string.repeat("a", 262_145)
  list.each(
    [
      <<>>,
      <<1:size(1)>>,
      <<0xdd, 0xff, 0xff, 0xff, 0xff>>,
      <<0xdb, 8193:size(32)>>,
      <<0xdc, 129:size(16)>>,
      <<large:utf8>>,
      raw(mp.StringValue(string.repeat("a", 8193))),
    ],
    fn(bytes) {
      assert resources.decode(enrolled(), bytes) == Error(resources.Invalid)
    },
  )
}

pub fn producer_from_another_operation_is_refused_test() {
  let retained = original_parent()
  let assert Ok(operation) =
    ids.parse_op_id("00000000-0000-7000-8000-000000000007")
    as "Distinct operation validates."
  let assert Ok(other_parent) =
    remote_tool.key(
      remote_tool.session(retained),
      operation,
      remote_tool.step(retained),
      3,
      string.repeat("a", 64),
      remote_tool.result_entry(retained),
    )
    as "Independently valid complete parent."
  let producer =
    service(
      command.CompileService,
      scope(2),
      string.repeat("b", 64),
      string.repeat("c", 64),
      other_parent,
    )
  let assert Ok(_) =
    resources.admit_compile_locations(enrolled(), producer, root())
    as "Compile location alone does not assert Launch association."
  assert resources.admit_launch_resources(
      enrolled(),
      key(command.LaunchService),
      producer,
      directory(),
      directory() <> "/s",
      directory() <> "/cap-token",
    )
    == Error(resources.Mismatch)
}

pub fn launch_decoder_checks_producing_parent_and_all_fixed_paths_test() {
  let changed =
    parent(
      "parent",
      4,
      string.repeat("a", 64),
      "00000000-0000-7000-8000-000000000004",
    )
  let producer =
    service(
      command.CompileService,
      scope(2),
      string.repeat("b", 64),
      string.repeat("c", 64),
      changed,
    )
  let launch_key =
    json_wire.of_json(command.encode_service(key(command.LaunchService)))
  let original =
    json_wire.of_json(command.encode_service(key(command.CompileService)))
  let changed = json_wire.of_json(command.encode_service(producer))
  list.each(
    [
      #(changed, directory(), directory() <> "/s", directory() <> "/cap-token"),
      #(original, "/foreign", directory() <> "/s", directory() <> "/cap-token"),
      #(
        original,
        directory(),
        directory() <> "/./s",
        directory() <> "/cap-token",
      ),
      #(original, directory(), directory() <> "/s", directory() <> "/foreign"),
    ],
    fn(fields) {
      let frame =
        mp.ArrayValue([
          mp.IntValue(1),
          mp.StringValue("launch"),
          launch_key,
          fields.0,
          mp.StringValue(fields.1),
          mp.StringValue(fields.2),
          mp.StringValue(fields.3),
        ])
      assert resources.decode(enrolled(), raw(frame))
        == Error(resources.Mismatch)
    },
  )
}
