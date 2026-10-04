//// Pure original-input/Ready construction controls with no fixture I/O.

import broker/command as offer
import broker/enrollment
import broker/exec
import broker/policy
import codemode/build
import codemode/compile
import codemode/enforcement
import codemode/native_command
import codemode/service_command as expected
import codemode/service_input as input
import codemode/service_resources as resources
import codemode/vet/policy as vet_policy
import core/command
import core/ids
import core/json
import core/remote_tool
import core/workspace
import gleam/list
import gleam/result
import gleam/string

fn hash(char: String) -> String {
  string.repeat(char, 64)
}

fn session_text() -> String {
  "00000000-0000-7000-8000-000000000001"
}

fn scope() -> workspace.Scope {
  let assert Ok(value) =
    workspace.scope_from_fields(session_text(), "checkout", "linux", 2, 7)
    as "Full original scope."
  value
}

fn base() -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    writable_roots: ["/work", "/alloc"],
    readable_roots: ["/tc", "/otp", "/seed", "/work"],
    protected: ["/work/.git"],
    network: policy.NetworkProxy(["*.example.org"], "127.0.0.1:443"),
    limits: policy.Limits(11, 12, 13, 14, 15, 16),
    env_allow: ["PATH", "HOME"],
    scratch: policy.ScratchTmpfs,
    mounts: [
      policy.Mount("/tc", policy.MountReadOnly, policy.MountRequired),
      policy.Mount("/otp", policy.MountReadOnly, policy.MountRequired),
      policy.Mount("/seed", policy.MountReadOnly, policy.MountOptional),
    ],
  )
}

fn enrolled() -> enrollment.SessionEnrollment {
  let assert Ok(value) =
    enrollment.new(
      enrollment.NativeFacts(scope(), ["/"], base(), exec.PlatformEnforcement),
      enrollment.CodeModeFacts(
        "/work",
        "/alloc/build",
        "/alloc/channel",
        "/tc/bin/gleam",
        "/otp/bin/erl",
        "/seed",
        ["/tc", "/otp"],
        base().mounts,
        "/tc/bin",
      ),
      hash("b"),
      hash("c"),
    )
    as "Canonical isolated administrative enrollment."
  value
}

fn service(
  role: command.ServiceRole,
  step: String,
  request_id: String,
) -> command.ServiceKey {
  let assert Ok(session) = ids.parse_session_id(session_text())
    as "Valid session."
  let assert Ok(operation) =
    ids.parse_op_id("00000000-0000-7000-8000-000000000002")
    as "Valid operation."
  let assert Ok(id) = ids.parse_entry_id(request_id) as "Valid original UUID."
  let assert Ok(entry) =
    ids.parse_entry_id("00000000-0000-7000-8000-000000000004")
    as "Reserved parent result entry."
  let assert Ok(parent) =
    remote_tool.key(session, operation, "parent", 3, hash("a"), entry)
    as "Exact managed parent."
  let assert Ok(step) = workspace.step(step) as "Valid physical step."
  let assert Ok(key) =
    command.service_key(
      parent,
      role,
      scope(),
      operation,
      step,
      id,
      hash("a"),
      hash("b"),
      hash("c"),
    )
    as "Complete service identity."
  key
}

fn compile_key() -> command.ServiceKey {
  service(
    command.CompileService,
    "physical:build",
    "00000000-0000-7000-8000-000000000003",
  )
}

fn launch_key() -> command.ServiceKey {
  service(
    command.LaunchService,
    "physical:run",
    "00000000-0000-7000-8000-000000000005",
  )
}

fn artifact_for(key: command.ServiceKey) -> compile.Artifact {
  let #(scope, operation, step) = command.coordinates(key)
  let #(digest, _, contract) = command.digests(key)
  compile.ExecutorArtifact(
    scope,
    operation,
    step,
    ids.entry_id_to_string(command.request_id(key)),
    digest,
    "issued-artifact",
    contract,
    compile.entry_module,
    "sha256-" <> hash("e"),
  )
}

fn artifact() -> compile.Artifact {
  artifact_for(compile_key())
}

fn cwd() -> workspace.RelativePath {
  let assert Ok(path) = workspace.relative_path("src/deep")
    as "Canonical relative cwd."
  path
}

fn launch_input(
  artifact: compile.Artifact,
  env: List(#(String, String)),
  base: policy.SandboxPolicy,
) -> input.LaunchInput {
  let assert Ok(value) =
    input.launch_input(
      enrolled(),
      compile_key(),
      artifact,
      env,
      cwd(),
      base,
      hash("d"),
    )
    as "Bounded original remote launch."
  value
}

fn successful(artifact: compile.Artifact) -> compile.Compiled {
  compile.Compiled(Ok(artifact), enforcement.Reported([], False))
}

fn admitted_compile(
  pin: enrollment.SessionEnrollment,
  key: command.ServiceKey,
  seed: policy.SandboxPolicy,
  timeout: Int,
) -> input.AdmittedCompile {
  let assert Ok(original) =
    input.compile_input(
      pin,
      input.WorkspaceProgram,
      "pub fn main() { Nil }\n",
      [],
      compile.default_dependencies(),
      seed,
      timeout,
    )
    as "Bounded original Compile input."
  let assert Ok(contract) =
    input.trusted_contract(
      pin,
      input.WorkspaceProgram,
      vet_policy.workspace_effects(),
      [],
    )
    as "Trusted concrete workspace contract."
  let assert Ok(admitted) = input.admit_compile(key, contract, original)
    as "The original source and full Compile key admit."
  admitted
}

fn compile_ready(
  pin: enrollment.SessionEnrollment,
  key: command.ServiceKey,
) -> resources.CompileLocations {
  let assert Ok(root) = enrollment.compile_path(pin, key)
    as "Original allocation."
  let assert Ok(ready) = resources.admit_compile_locations(pin, key, root)
    as "Exact returned Compile locations."
  ready
}

fn launch_ready(
  pin: enrollment.SessionEnrollment,
  key: command.ServiceKey,
  producer: command.ServiceKey,
) -> resources.LaunchResources {
  let assert Ok(paths) = enrollment.launch_paths(pin, key)
    as "Original channel allocation."
  let assert Ok(ready) =
    resources.admit_launch_resources(
      pin,
      key,
      producer,
      paths.0,
      paths.1,
      paths.2,
    )
    as "Exact returned Launch and producer keys."
  ready
}

fn admitted_launch(
  seed: policy.SandboxPolicy,
  env: List(#(String, String)),
) -> input.AdmittedLaunch {
  let original = launch_input(artifact(), env, seed)
  let assert Ok(admitted) =
    input.admit_launch(
      launch_key(),
      enrolled(),
      original,
      compile_key(),
      successful(artifact()),
    )
    as "Original retained successful executor artifact admits."
  admitted
}

fn compiling() -> expected.ExpectedCommand {
  let assert Ok(value) =
    expected.compile(
      enrolled(),
      admitted_compile(enrolled(), compile_key(), base(), 180_000),
      compile_ready(enrolled(), compile_key()),
      7,
    )
    as "Exact compiler expectation admits."
  value
}

fn launching(env: List(#(String, String))) -> expected.ExpectedCommand {
  let assert Ok(value) =
    expected.launch(
      enrolled(),
      admitted_launch(base(), env),
      launch_ready(enrolled(), launch_key(), compile_key()),
      7,
    )
    as "Exact satellite expectation admits."
  value
}

fn changed_key(
  key: command.ServiceKey,
  index: Int,
  value: json.JsonValue,
) -> command.ServiceKey {
  let assert json.Array(fields) = command.encode_service(key)
    as "Complete canonical key array."
  let fields =
    list.index_map(fields, fn(old, at) {
      case at == index {
        True -> value
        False -> old
      }
    })
  let assert Ok(changed) = command.decode_service(json.Array(fields))
    as "Changed full identity remains well formed."
  changed
}

fn same_scope_key_variants(
  key: command.ServiceKey,
) -> List(command.ServiceKey) {
  let assert json.Array([_, json.Array(parent), ..]) =
    command.encode_service(key)
    as "Parent has every original axis."
  let parent_changes = [
    #(2, json.String("another-parent-step")),
    #(3, json.Int(4)),
    #(4, json.String(hash("f"))),
    #(5, json.String("00000000-0000-7000-8000-000000000006")),
  ]
  list.append(
    list.map(parent_changes, fn(change) {
      let altered =
        list.index_map(parent, fn(old, index) {
          case index == change.0 {
            True -> change.1
            False -> old
          }
        })
      changed_key(key, 1, json.Array(altered))
    }),
    [
      changed_key(key, 5, json.String("another-physical-step")),
      changed_key(key, 6, json.String("00000000-0000-7000-8000-000000000007")),
      changed_key(key, 7, json.String(hash("f"))),
    ],
  )
}

pub fn compile_matches_complete_shared_template_and_ordered_regions_test() {
  let value = compiling()
  let proposal = expected.offer(value)
  let root =
    resources.compile_fields(compile_ready(enrolled(), compile_key())).1
  let code = enrollment.code_mode_facts(enrolled())
  let initial = base()
  let selected =
    policy.SandboxPolicy(
      ..initial,
      limits: policy.Limits(..initial.limits, wall_s: 7),
    )
  let template =
    native_command.compiler(
      native_command.Compiler(
        code.gleam_path,
        root,
        selected,
        code.toolchain_roots,
        [#("PATH", code.build_path)],
      ),
    )
  assert offer.data(proposal) == template
  assert offer.data(proposal).argv
    == ["/tc/bin/gleam", "build", "--warnings-as-errors"]
  assert offer.data(proposal).env
    == [#("TMPDIR", root <> "/tmp"), #("PATH", "/tc/bin")]
  assert offer.data(proposal).requirements
    == policy.SandboxPolicy(
      ..selected,
      writable_roots: [root],
      readable_roots: [root, "/tc", "/otp"],
      network: policy.NetworkOff,
      env_allow: ["TMPDIR", "PATH"],
    )
  assert offer.mappings(proposal)
    == [
      offer.RegionMapping(offer.Build, root),
      offer.RegionMapping(offer.Scratch, root <> "/tmp"),
      offer.RegionMapping(offer.Toolchain, "/tc"),
      offer.RegionMapping(offer.Toolchain, "/otp"),
    ]
  let assert Ok(ref) =
    command.command_ref(compile_key(), command.CompileCommand)
    as "Closed Compile/native pair."
  assert offer.reference(proposal) == ref
  assert expected.wall_s(value) == 7
  assert expected.matches(value, proposal) == Ok(Nil)
}

pub fn launch_matches_complete_shared_template_and_remote_artifact_path_test() {
  let env = [
    #("Z", "last-first"),
    #("HOME", "/home/literal"),
    #("LOOM_CAP_SOCK", "/hostile/s"),
    #("LOOM_CAP_TOKEN_FILE", "/hostile/token"),
    #("A", "first-last"),
  ]
  let value = launching(env)
  let proposal = expected.offer(value)
  let ready = launch_ready(enrolled(), launch_key(), compile_key())
  let #(directory, socket, token) = resources.launch_paths(ready)
  let root =
    resources.compile_fields(compile_ready(enrolled(), compile_key())).1
  let beams = root <> "/" <> build.beam_directory
  let code = enrollment.code_mode_facts(enrolled())
  let template =
    native_command.NodeAccess(
      beams,
      socket,
      token,
      base(),
      code.host_mounts,
      env,
      7,
    )
  assert offer.data(proposal)
    == offer.CommandData(
      native_command.node_argv(code.erl_path, beams, compile.entry_module),
      native_command.node_env(socket, token, env),
      "/work/src/deep",
      native_command.node_requirements(template),
    )
  assert offer.data(proposal).env
    == [
      #("LOOM_CAP_SOCK", socket),
      #("LOOM_CAP_TOKEN_FILE", token),
      #("Z", "last-first"),
      #("HOME", "/home/literal"),
      #("A", "first-last"),
    ]
  let initial = base()
  assert offer.data(proposal).requirements
    == policy.SandboxPolicy(
      ..initial,
      readable_roots: ["/tc", "/otp", "/seed", "/work", directory, beams],
      mounts: code.host_mounts,
      network: policy.NetworkOff,
      limits: policy.Limits(..initial.limits, wall_s: 7),
      env_allow: ["LOOM_CAP_SOCK", "LOOM_CAP_TOKEN_FILE", "Z", "HOME", "A"],
    )
  assert offer.mappings(proposal)
    == [
      offer.RegionMapping(offer.Workspace, "/work"),
      offer.RegionMapping(offer.Artifact, root),
      offer.RegionMapping(offer.Channel, directory),
      offer.RegionMapping(offer.Toolchain, "/tc"),
      offer.RegionMapping(offer.Toolchain, "/otp"),
    ]
  let assert Ok(ref) =
    command.command_ref(launch_key(), command.SatelliteCommand)
    as "Closed launch/native pair."
  assert offer.reference(proposal) == ref
  assert expected.wall_s(value) == 7
}

pub fn foreign_compile_ready_full_parent_and_service_axes_refuse_test() {
  let admitted = admitted_compile(enrolled(), compile_key(), base(), 180_000)
  list.each(same_scope_key_variants(compile_key()), fn(key) {
    assert expected.compile(
        enrolled(),
        admitted,
        compile_ready(enrolled(), key),
        7,
      )
      == Error(expected.AssociationMismatch)
  })
}

pub fn foreign_launch_ready_and_producer_axes_refuse_test() {
  let admitted = admitted_launch(base(), [])
  let service_changes = [
    changed_key(launch_key(), 5, json.String("changed-launch-step")),
    changed_key(
      launch_key(),
      6,
      json.String("00000000-0000-7000-8000-000000000007"),
    ),
    changed_key(launch_key(), 7, json.String(hash("f"))),
  ]
  list.each(service_changes, fn(key) {
    assert expected.launch(
        enrolled(),
        admitted,
        launch_ready(enrolled(), key, compile_key()),
        7,
      )
      == Error(expected.AssociationMismatch)
  })
  // Changing the whole parent in both Ready keys keeps the receipt valid but
  // cannot replace any parent axis of this already admitted original launch.
  list.each(list.take(same_scope_key_variants(launch_key()), 4), fn(key) {
    let assert json.Array([_, parent, ..]) = command.encode_service(key)
      as "The changed Ready parent is complete."
    let producer = changed_key(compile_key(), 1, parent)
    assert expected.launch(
        enrolled(),
        admitted,
        launch_ready(enrolled(), key, producer),
        7,
      )
      == Error(expected.AssociationMismatch)
  })
  let producer_changes = [
    changed_key(compile_key(), 5, json.String("changed-compile-step")),
    changed_key(
      compile_key(),
      6,
      json.String("00000000-0000-7000-8000-000000000007"),
    ),
    changed_key(compile_key(), 7, json.String(hash("f"))),
  ]
  list.each(producer_changes, fn(key) {
    assert expected.launch(
        enrolled(),
        admitted,
        launch_ready(enrolled(), launch_key(), key),
        7,
      )
      == Error(expected.AssociationMismatch)
  })
}

pub fn compile_stage_ceiling_never_rounds_up_test() {
  let original = base()
  let unbounded =
    policy.SandboxPolicy(
      ..original,
      limits: policy.Limits(..original.limits, wall_s: 0),
    )
  let admitted = admitted_compile(enrolled(), compile_key(), unbounded, 1999)
  let ready = compile_ready(enrolled(), compile_key())
  assert expected.compile(enrolled(), admitted, ready, 1) |> result.is_ok
  assert expected.compile(enrolled(), admitted, ready, 2)
    == Error(expected.InvalidWall)
}

pub fn selected_wall_zero_negative_policy_excess_and_subsecond_refuse_test() {
  let admitted = admitted_compile(enrolled(), compile_key(), base(), 180_000)
  let ready = compile_ready(enrolled(), compile_key())
  list.each([0, -1, 13], fn(wall) {
    assert expected.compile(enrolled(), admitted, ready, wall)
      == Error(expected.InvalidWall)
    assert expected.launch(
        enrolled(),
        admitted_launch(base(), []),
        launch_ready(enrolled(), launch_key(), compile_key()),
        wall,
      )
      == Error(expected.InvalidWall)
  })
  let subsecond = admitted_compile(enrolled(), compile_key(), base(), 999)
  assert expected.compile(enrolled(), subsecond, ready, 1)
    == Error(expected.InvalidWall)
  assert expected.compile(enrolled(), admitted, ready, 12) |> result.is_ok
  let seed = base()
  let unbounded =
    policy.SandboxPolicy(
      ..seed,
      limits: policy.Limits(..seed.limits, wall_s: 0),
    )
  assert expected.launch(
      enrolled(),
      admitted_launch(unbounded, []),
      launch_ready(enrolled(), launch_key(), compile_key()),
      999,
    )
    |> result.is_ok
}

pub fn matching_refuses_changed_argv_env_cwd_policy_and_region_test() {
  let value = compiling()
  let original = expected.offer(value)
  let data = offer.data(original)
  let mappings = offer.mappings(original)
  let req = data.requirements
  let variants = [
    offer.CommandData(..data, argv: [
      "/tc/bin/foreign",
      ..list.drop(data.argv, 1)
    ]),
    offer.CommandData(..data, argv: ["/tc/bin/gleam", "build", "--no-warnings"]),
    offer.CommandData(..data, env: list.reverse(data.env)),
    offer.CommandData(..data, cwd: "/work"),
    offer.CommandData(
      ..data,
      requirements: policy.SandboxPolicy(..req, protected: []),
    ),
    offer.CommandData(
      ..data,
      requirements: policy.SandboxPolicy(..req, network: policy.NetworkFull),
    ),
    offer.CommandData(
      ..data,
      requirements: policy.SandboxPolicy(
        ..req,
        limits: policy.Limits(..req.limits, cpu_s: 9),
      ),
    ),
  ]
  list.each(variants, fn(changed) {
    let assert Ok(proposed) =
      offer.offer(offer.reference(original), mappings, changed)
      as "Changed offer remains syntactically bounded."
    assert expected.matches(value, proposed)
      == Error(expected.AssociationMismatch)
  })
  let assert Ok(proposed) =
    offer.offer(
      offer.reference(original),
      [offer.RegionMapping(offer.Build, "/foreign"), ..list.drop(mappings, 1)],
      data,
    )
    as "Changed literal region is bounded."
  assert expected.matches(value, proposed)
    == Error(expected.AssociationMismatch)
  let assert Ok(foreign_ref) =
    command.command_ref(
      changed_key(compile_key(), 7, json.String(hash("f"))),
      command.CompileCommand,
    )
    as "Different exact reference is bounded."
  let assert Ok(proposed) = offer.offer(foreign_ref, mappings, data)
    as "Changed full command identity encodes."
  assert expected.matches(value, proposed)
    == Error(expected.AssociationMismatch)
}

fn repin(
  native: enrollment.NativeFacts,
  code: enrollment.CodeModeFacts,
  registration: String,
  contract: String,
) -> enrollment.SessionEnrollment {
  let assert Ok(pin) = enrollment.new(native, code, registration, contract)
    as "Changed snapshot is independently well formed."
  pin
}

fn admitted_launch_at(
  pin: enrollment.SessionEnrollment,
  key: command.ServiceKey,
  producer: command.ServiceKey,
  seed: policy.SandboxPolicy,
  cwd: workspace.RelativePath,
) -> input.AdmittedLaunch {
  let artifact = artifact_for(producer)
  let assert Ok(original) =
    input.launch_input(pin, producer, artifact, [], cwd, seed, hash("d"))
    as "Exact changed original launch."
  let assert Ok(admitted) =
    input.admit_launch(key, pin, original, producer, successful(artifact))
    as "Trusted retained producer association admits."
  admitted
}

pub fn same_scope_digest_claims_never_substitute_snapshot_contents_test() {
  let pin = enrolled()
  let native = enrollment.native_facts(pin)
  let code = enrollment.code_mode_facts(pin)
  let variants = [
    enrollment.CodeModeFacts(..code, workspace_root: "/work/sub"),
    enrollment.CodeModeFacts(..code, build_area: "/alloc/other-build"),
    enrollment.CodeModeFacts(..code, channel_area: "/alloc/other-channel"),
    enrollment.CodeModeFacts(..code, gleam_path: "/tc/bin/other-gleam"),
    enrollment.CodeModeFacts(..code, erl_path: "/otp/bin/other-erl"),
    enrollment.CodeModeFacts(..code, seed_root: "/seed/sub"),
    enrollment.CodeModeFacts(
      ..code,
      toolchain_roots: list.reverse(code.toolchain_roots),
    ),
    enrollment.CodeModeFacts(
      ..code,
      host_mounts: list.reverse(code.host_mounts),
    ),
    enrollment.CodeModeFacts(..code, build_path: "/tc/bin:/otp/bin"),
  ]
  let compile = admitted_compile(pin, compile_key(), base(), 180_000)
  let launch = admitted_launch(base(), [])
  list.each(variants, fn(changed) {
    let foreign = repin(native, changed, hash("b"), hash("c"))
    assert expected.compile(
        foreign,
        compile,
        compile_ready(pin, compile_key()),
        7,
      )
      == Error(expected.AssociationMismatch)
    assert expected.launch(
        foreign,
        launch,
        launch_ready(pin, launch_key(), compile_key()),
        7,
      )
      == Error(expected.AssociationMismatch)
    assert expected.compile(
        pin,
        admitted_compile(foreign, compile_key(), base(), 180_000),
        compile_ready(pin, compile_key()),
        7,
      )
      == Error(expected.AssociationMismatch)
  })
  let ceiling = native.ceiling
  let changed_native = [
    enrollment.NativeFacts(..native, working_roots: [
      "/work",
      "/alloc",
      "/tc",
      "/otp",
      "/seed",
    ]),
    enrollment.NativeFacts(..native, demand: exec.FullEnforcement),
    enrollment.NativeFacts(
      ..native,
      ceiling: policy.SandboxPolicy(..ceiling, protected: ["/work/secret"]),
    ),
  ]
  list.each(changed_native, fn(changed) {
    let foreign = repin(changed, code, hash("b"), hash("c"))
    assert expected.compile(
        foreign,
        compile,
        compile_ready(pin, compile_key()),
        7,
      )
      == Error(expected.AssociationMismatch)
    assert expected.launch(
        foreign,
        launch,
        launch_ready(pin, launch_key(), compile_key()),
        7,
      )
      == Error(expected.AssociationMismatch)
  })
}

pub fn foreign_ready_epochs_registration_contract_and_literal_root_refuse_test() {
  let pin = enrolled()
  let native = enrollment.native_facts(pin)
  let code = enrollment.code_mode_facts(pin)
  let admitted = admitted_compile(pin, compile_key(), base(), 180_000)
  let epoch_scope =
    json.Array([
      json.String(session_text()),
      json.String("checkout"),
      json.String("linux"),
      json.Int(3),
      json.Int(8),
    ])
  let epoch_key = changed_key(compile_key(), 3, epoch_scope)
  let foreign_scope = command.coordinates(epoch_key).0
  let epoch_pin =
    repin(
      enrollment.NativeFacts(..native, scope: foreign_scope),
      code,
      hash("b"),
      hash("c"),
    )
  assert expected.compile(pin, admitted, compile_ready(epoch_pin, epoch_key), 7)
    == Error(expected.AssociationMismatch)
  let registration_pin = repin(native, code, hash("f"), hash("c"))
  let registration_key = changed_key(compile_key(), 8, json.String(hash("f")))
  assert expected.compile(
      pin,
      admitted,
      compile_ready(registration_pin, registration_key),
      7,
    )
    == Error(expected.AssociationMismatch)
  let contract_pin = repin(native, code, hash("b"), hash("f"))
  let contract_key = changed_key(compile_key(), 9, json.String(hash("f")))
  assert expected.compile(
      pin,
      admitted,
      compile_ready(contract_pin, contract_key),
      7,
    )
    == Error(expected.AssociationMismatch)
  let another_root =
    repin(
      native,
      enrollment.CodeModeFacts(..code, build_area: "/alloc/other-build"),
      hash("b"),
      hash("c"),
    )
  assert expected.compile(
      pin,
      admitted,
      compile_ready(another_root, compile_key()),
      7,
    )
    == Error(expected.AssociationMismatch)
  let root = resources.compile_fields(compile_ready(pin, compile_key())).1
  list.each([root <> "/.", root <> "/../foreign", root <> "/sub"], fn(path) {
    assert resources.admit_compile_locations(pin, compile_key(), path)
      == Error(resources.Mismatch)
  })
}

pub fn enrolled_host_scratch_is_mapped_and_distinct_scratch_refuses_both_roles_test() {
  let original = enrolled()
  let native = enrollment.native_facts(original)
  let seed = base()
  let matching =
    policy.SandboxPolicy(..seed, scratch: policy.ScratchPath("/scratch"))
  let pin =
    repin(
      enrollment.NativeFacts(..native, ceiling: matching),
      enrollment.code_mode_facts(original),
      hash("b"),
      hash("c"),
    )
  let assert Ok(compiler) =
    expected.compile(
      pin,
      admitted_compile(pin, compile_key(), matching, 180_000),
      compile_ready(pin, compile_key()),
      7,
    )
    as "The enrolled scratch is exact."
  assert list.last(offer.mappings(expected.offer(compiler)))
    == Ok(offer.RegionMapping(offer.Scratch, "/scratch"))
  let launch =
    admitted_launch_at(
      pin,
      launch_key(),
      compile_key(),
      matching,
      workspace.root(),
    )
  let assert Ok(satellite) =
    expected.launch(
      pin,
      launch,
      launch_ready(pin, launch_key(), compile_key()),
      7,
    )
    as "Exact satellite scratch is enrolled."
  assert list.last(offer.mappings(expected.offer(satellite)))
    == Ok(offer.RegionMapping(offer.Scratch, "/scratch"))
  assert offer.data(expected.offer(satellite)).cwd == "/work"
  let foreign =
    policy.SandboxPolicy(
      ..matching,
      scratch: policy.ScratchPath("/another-scratch"),
    )
  assert expected.compile(
      pin,
      admitted_compile(pin, compile_key(), foreign, 180_000),
      compile_ready(pin, compile_key()),
      7,
    )
    == Error(expected.AssociationMismatch)
  assert expected.launch(
      pin,
      admitted_launch_at(
        pin,
        launch_key(),
        compile_key(),
        foreign,
        workspace.root(),
      ),
      launch_ready(pin, launch_key(), compile_key()),
      7,
    )
    == Error(expected.AssociationMismatch)
}

pub fn compiler_keeps_original_mounts_satellite_uses_enrolled_mounts_test() {
  let initial = base()
  let original =
    policy.SandboxPolicy(..initial, mounts: [
      policy.Mount(
        "/original-mount",
        policy.MountReadOnly,
        policy.MountOptional,
      ),
    ])
  let assert Ok(compiler) =
    expected.compile(
      enrolled(),
      admitted_compile(enrolled(), compile_key(), original, 180_000),
      compile_ready(enrolled(), compile_key()),
      7,
    )
    as "The compiler retains its original seed mounts."
  assert offer.data(expected.offer(compiler)).requirements.mounts
    == original.mounts
  let assert Ok(satellite) =
    expected.launch(
      enrolled(),
      admitted_launch(original, []),
      launch_ready(enrolled(), launch_key(), compile_key()),
      7,
    )
    as "Satellite mounting is owned by the shared template."
  assert offer.data(expected.offer(satellite)).requirements.mounts
    == enrollment.code_mode_facts(enrolled()).host_mounts
}

pub fn closed_roles_refuse_swapped_original_service_keys_test() {
  assert command.command_ref(compile_key(), command.SatelliteCommand)
    |> result.is_error
  assert command.command_ref(launch_key(), command.CompileCommand)
    |> result.is_error
  assert resources.admit_compile_locations(
      enrolled(),
      launch_key(),
      "/alloc/build/foreign",
    )
    == Error(resources.Mismatch)
  assert resources.admit_launch_resources(
      enrolled(),
      compile_key(),
      compile_key(),
      "/alloc/channel/foreign",
      "/alloc/channel/foreign/s",
      "/alloc/channel/foreign/cap-token",
    )
    == Error(resources.Mismatch)
}

pub fn changed_original_operation_and_offer_integer_boundary_refuse_test() {
  let assert json.Array(fields) = command.encode_service(compile_key())
    as "The service retains parent and physical operation."
  let operation = json.String("00000000-0000-7000-8000-000000000008")
  let fields =
    list.index_map(fields, fn(old, index) {
      case index, old {
        1, json.Array(parent) ->
          json.Array(
            list.index_map(parent, fn(value, at) {
              case at == 1 {
                True -> operation
                False -> value
              }
            }),
          )
        4, _ -> operation
        _, _ -> old
      }
    })
  let assert Ok(key) = command.decode_service(json.Array(fields))
    as "The changed operation remains internally consistent."
  assert expected.compile(
      enrolled(),
      admitted_compile(enrolled(), compile_key(), base(), 180_000),
      compile_ready(enrolled(), key),
      7,
    )
    == Error(expected.AssociationMismatch)
  let original = base()
  let unbounded =
    policy.SandboxPolicy(
      ..original,
      limits: policy.Limits(..original.limits, wall_s: 0),
    )
  assert expected.launch(
      enrolled(),
      admitted_launch(unbounded, []),
      launch_ready(enrolled(), launch_key(), compile_key()),
      18_446_744_073_709_551_616,
    )
    == Error(expected.InvalidCommand(offer.InvalidEncoding))
}

/// Historical construction recovers data without minting source admission.
pub fn retained_input_reconstructs_exact_compiler_expectation_test() {
  let admitted = admitted_compile(enrolled(), compile_key(), base(), 180_000)
  let #(key, original, _) = input.admitted_compile(admitted)
  let ready = compile_ready(enrolled(), key)
  let assert Ok(live) = expected.compile(enrolled(), admitted, ready, 1)
    as "The live admitted entry derives an expectation."
  let assert Ok(historical) =
    expected.compile_from_input(enrolled(), key, original, ready, 1)
    as "Retained bounded data can reconstruct the same expectation."
  let assert True = live == historical
    as "Both paths share every command field."
  let assert Error(expected.AssociationMismatch) =
    expected.compile_from_input(enrolled(), launch_key(), original, ready, 1)
    as "Historical reconstruction cannot substitute another service role."
  let assert Error(expected.InvalidWall) =
    expected.compile_from_input(enrolled(), key, original, ready, 0)
    as "Historical reconstruction preserves the finite original wall check."
}
