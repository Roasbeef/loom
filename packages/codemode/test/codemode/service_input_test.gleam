//// Concrete framing, host-policy and retained artifact association controls.

import broker/enrollment
import broker/exec
import broker/policy
import codemode/compile
import codemode/enforcement
import codemode/service_input as input
import codemode/vet
import codemode/vet/policy as vet_policy
import core/command
import core/ids
import core/json
import core/msgpack as mp
import core/remote_tool
import core/workspace
import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string

pub fn exact_program_dependencies_generated_and_full_policy_roundtrip_test() {
  let original = make_compile(program(), generated(), base())
  let bytes = input.encode_compile(original)
  assert input.decode_compile(bytes) == Ok(original)
  let facts = input.compile_facts(original)
  assert facts.source == program()
  assert facts.generated == generated()
  assert facts.dependencies == compile.default_dependencies()
  assert facts.policy_seed == base()
  assert facts.build_timeout_ms == 180_000
  let #(_, meta, _) = parts(bytes)
  let assert mp.ArrayValue([_, _, full, _, _, _]) = meta
    as "The complete policy is directly embedded in metadata."
  assert full == policy.to_msgpack(base())
  assert policy.from_msgpack(full) == Ok(base())
}

pub fn large_real_source_and_generated_body_fit_existing_envelope_test() {
  let source = sized_source(8_388_608)
  let facade = sized_source(524_288)
  let original = make_compile(source, [#("cap/mcp/github", facade)], base())
  let bytes = input.encode_compile(original)
  assert bit_array.byte_size(bytes) > 8_912_896
  assert input.decode_compile(bytes) == Ok(original)
  let assert Ok(envelope) = input.compile_envelope(compile_key(), original)
    as "An eight-MiB program and half-MiB facade fit the existing nine-MiB envelope."
  assert bit_array.byte_size(envelope) <= input.max_envelope_bytes
  assert input.compile_facts(original).source == source
}

pub fn whole_envelope_uses_actual_header_at_exact_boundary_test() {
  let first = make_compile(sized_source(1_048_576), [], base())
  let assert Ok(envelope) = input.compile_envelope(compile_key(), first)
    as "The initial sample fits with its real complete service header."
  let size =
    1_048_576 + input.max_envelope_bytes - bit_array.byte_size(envelope)
  let exact = make_compile(sized_source(size), [], base())
  let assert Ok(envelope) = input.compile_envelope(compile_key(), exact)
    as "The source uses exactly the remaining aggregate allowance."
  assert bit_array.byte_size(envelope) == input.max_envelope_bytes
  assert input.decode_compile(input.encode_compile(exact)) == Ok(exact)

  // The body alone still fits. Only accounting for this actual JSON header
  // makes one additional source byte fail at the intended whole-frame boundary.
  let oversized = make_compile(sized_source(size + 1), [], base())
  assert input.compile_envelope(compile_key(), oversized)
    == Error(input.BoundExceeded)
  assert input.admit_compile(
      compile_key(),
      contract(vet_policy.workspace_effects(), []),
      oversized,
    )
    == Error(input.BoundExceeded)
}

pub fn workspace_only_effective_policy_is_not_recreated_from_seam_test() {
  let source = "import cap/strand\npub fn main() { Nil }\n"
  let original = make_compile(source, [], base())
  let bytes = input.encode_compile(original)
  assert input.decode_compile(bytes) == Ok(original)
  assert vet.vet(source, vet_policy.workspace_effects()) |> rejected
  assert vet.vet(source, vet_policy.for_seam(vet_policy.WorkspaceSeam))
    |> passed
  assert input.admit_compile(
      compile_key(),
      contract(vet_policy.workspace_effects(), []),
      original,
    )
    == Error(input.SourceRejected)

  let assert Ok(admitted) =
    input.admit_compile(
      compile_key(),
      contract(vet_policy.default(), []),
      original,
    )
    as "A separately provisioned Agency policy may admit the same program."
  let #(key, retained, vetted) = input.admitted_compile(admitted)
  assert key == compile_key()
  assert retained == original
  assert vet.vetted_source(vetted) == source
}

pub fn generated_facades_require_complete_exact_trusted_bytes_and_order_test() {
  let source =
    "import cap/mcp/github\nimport cap/mcp/gitlab\npub fn main() { Nil }\n"
  let catalogue = generated()
  let trusted =
    contract(
      vet_policy.default()
        |> vet_policy.allow("cap/mcp/github")
        |> vet_policy.allow("cap/mcp/gitlab"),
      catalogue,
    )
  let original = make_compile(source, catalogue, base())
  assert input.admit_compile(compile_key(), trusted, original) |> result.is_ok
  let variants = [
    list.reverse(catalogue),
    [#("cap/mcp/github", "pub fn tool() { 99 }\n"), ..list.drop(catalogue, 1)],
    list.take(catalogue, 1),
    [],
    [#("cap/mcp/foreign", "pub fn tool() { Nil }\n"), ..catalogue],
  ]
  list.each(variants, fn(modules) {
    let changed = make_compile(source, modules, base())
    assert input.decode_compile(input.encode_compile(changed)) == Ok(changed)
    assert input.admit_compile(compile_key(), trusted, changed)
      == Error(input.AssociationMismatch)
  })

  // Trusted facades reach internal prelude modules that user source may not
  // import. Their authorization is exact catalogue provenance, not user vetting.
  assert vet.vet(
      catalogue |> list.first |> result.unwrap(#("", "")) |> fn(pair) { pair.1 },
      vet_policy.default(),
    )
    |> rejected
}

pub fn malformed_trailing_truncated_noncanonical_and_utf8_frames_refuse_test() {
  let bytes = input.encode_compile(make_compile(program(), generated(), base()))
  let #(enrolled_bits, value, bodies) = parts(bytes)
  let assert Ok(meta) = mp.encode(value) as "Canonical metadata encodes."
  let assert <<0x96, tail:bits>> = meta as "Compile has six metadata fields."
  assert input.decode_compile(frame(
      enrolled_bits,
      <<0xdc, 6:size(16), tail:bits>>,
      bodies,
    ))
    == Error(input.NoncanonicalEncoding)
  assert input.decode_compile(<<bytes:bits, 0>>) |> result.is_error
  assert input.decode_compile(
      bit_array.slice(bytes, 0, bit_array.byte_size(bytes) - 1)
      |> result.unwrap(<<>>),
    )
    |> result.is_error
  let assert <<_, rest:bits>> = bodies as "Program source has a first byte."
  assert input.decode_compile(frame(enrolled_bits, meta, <<0xff, rest:bits>>))
    == Error(input.InvalidEncoding)
  list.each(
    [
      <<>>,
      <<2, 1>>,
      <<1, 2>>,
      <<1, 1, 0xffffffff:size(32)>>,
      <<1, 1, 1:size(32), 0x90, 0xffffffff:size(32)>>,
      <<1:1>>,
    ],
    fn(bytes) {
      assert input.decode_compile(bytes) |> result.is_error
    },
  )
  let assert mp.ArrayValue([seam, dependencies, full, timeout, _, modules]) =
    value
    as "Declared source size is separately corruptible."
  list.each([-1, 0, 9_437_185, 4_294_967_295], fn(size) {
    assert input.decode_compile(reframe(
        enrolled_bits,
        mp.ArrayValue([
          seam,
          dependencies,
          full,
          timeout,
          mp.IntValue(size),
          modules,
        ]),
        bodies,
      ))
      |> result.is_error
  })
  let huge =
    mp.ArrayValue([
      seam,
      dependencies,
      mp.ArrayValue(list.repeat(mp.NilValue, 129)),
      timeout,
      mp.IntValue(string.byte_size(program())),
      modules,
    ])
  assert input.decode_compile(reframe(enrolled_bits, huge, bodies))
    |> result.is_error
}

pub fn canonical_enrollment_and_producer_header_are_checked_test() {
  let bytes = input.encode_compile(make_compile(program(), [], base()))
  let #(enrolled_bits, value, bodies) = parts(bytes)
  let assert <<tag, rest:bits>> = enrolled_bits
    as "Enrollment has a compact outer array."
  let assert Ok(meta) = mp.encode(value) as "The rest stays canonical."
  assert input.decode_compile(frame(
      <<0xdc, { tag - 0x90 }:size(16), rest:bits>>,
      meta,
      bodies,
    ))
    |> result.is_error

  let launch = make_launch(artifact(), [#("PATH", "/tc/bin")], base())
  let #(enrolled_bits, value, _) = parts(input.encode_launch(launch))
  let assert mp.ArrayValue([mp.StringValue(key), remote, env, cwd, full, token]) =
    value
    as "Producer is a separately canonical core key header."
  assert input.decode_launch(launch_reframe(
      enrolled_bits,
      mp.ArrayValue([mp.StringValue(" " <> key), remote, env, cwd, full, token]),
    ))
    == Error(input.NoncanonicalEncoding)
}

pub fn native_counts_duplicates_paths_dependencies_and_aggregate_metadata_refuse_test() {
  let construct = fn(generated, dependencies, base) {
    input.compile_input(
      enrolled(),
      input.WorkspaceProgram,
      program(),
      generated,
      dependencies,
      base,
      180_000,
    )
  }
  assert construct(
      list.repeat(#("cap/mcp/github", program()), 4096),
      compile.default_dependencies(),
      base(),
    )
    == Error(input.BoundExceeded)
  assert construct(
      [#("cap/mcp/github", program()), #("cap/mcp/github", program())],
      compile.default_dependencies(),
      base(),
    )
    == Error(input.InvalidData)
  assert construct(
      [#("cap/mcp/../evil", program())],
      compile.default_dependencies(),
      base(),
    )
    == Error(input.InvalidData)
  assert construct([], list.reverse(compile.default_dependencies()), base())
    |> result.is_error
  assert construct(
      [],
      compile.default_dependencies(),
      policy.SandboxPolicy(..base(), env_allow: list.repeat("PATH", 4096)),
    )
    == Error(input.BoundExceeded)
  assert construct(
      [],
      compile.default_dependencies(),
      policy.SandboxPolicy(..base(), readable_roots: ["/work/../elsewhere"]),
    )
    == Error(input.InvalidData)
  assert construct(
      [],
      compile.default_dependencies(),
      policy.SandboxPolicy(
        ..base(),
        limits: policy.Limits(..base().limits, pids: -1),
      ),
    )
    == Error(input.InvalidData)
  assert construct(
      [],
      compile.default_dependencies(),
      policy.SandboxPolicy(
        ..base(),
        env_allow: list.repeat(string.repeat("x", 8192), 128),
      ),
    )
    == Error(input.BoundExceeded)
  assert input.compile_input(
      enrolled(),
      input.WorkspaceProgram,
      string.repeat("x", input.max_envelope_bytes + 1),
      [],
      compile.default_dependencies(),
      base(),
      180_000,
    )
    == Error(input.BoundExceeded)
  assert input.compile_input(
      enrolled(),
      input.WorkspaceProgram,
      "\u{0000}",
      [],
      compile.default_dependencies(),
      base(),
      180_000,
    )
    == Error(input.InvalidData)
  assert input.launch_input(
      enrolled(),
      compile_key(),
      artifact(),
      list.repeat(#("X", "x"), 65),
      cwd(),
      base(),
      hash("d"),
    )
    == Error(input.BoundExceeded)
  assert input.launch_input(
      enrolled(),
      compile_key(),
      artifact(),
      [#("X", "x"), #("X", "y")],
      cwd(),
      base(),
      hash("d"),
    )
    == Error(input.InvalidData)
}

pub fn every_policy_field_remains_observable_in_retained_input_test() {
  let original = make_compile(program(), [], base())
  let initial = input.encode_compile(original)
  let b = base()
  let variants = [
    policy.SandboxPolicy(..b, writable_roots: ["/changed"]),
    policy.SandboxPolicy(..b, readable_roots: ["/changed"]),
    policy.SandboxPolicy(..b, protected: ["/changed"]),
    policy.SandboxPolicy(..b, network: policy.NetworkOff),
    policy.SandboxPolicy(..b, env_allow: ["PATH"]),
    policy.SandboxPolicy(..b, scratch: policy.ScratchPath("/scratch")),
    policy.SandboxPolicy(..b, mounts: []),
    policy.SandboxPolicy(..b, mounts: [
      policy.Mount("/tc", policy.MountReadWrite, policy.MountOptional),
    ]),
    policy.SandboxPolicy(..b, limits: policy.Limits(..b.limits, cpu_s: 99)),
    policy.SandboxPolicy(..b, limits: policy.Limits(..b.limits, wall_s: 99)),
    policy.SandboxPolicy(..b, limits: policy.Limits(..b.limits, mem_bytes: 99)),
    policy.SandboxPolicy(..b, limits: policy.Limits(..b.limits, pids: 99)),
    policy.SandboxPolicy(
      ..b,
      limits: policy.Limits(..b.limits, fsize_bytes: 99),
    ),
    policy.SandboxPolicy(
      ..b,
      limits: policy.Limits(..b.limits, output_bytes: 99),
    ),
  ]
  list.each(variants, fn(base) {
    let changed = make_compile(program(), [], base)
    assert input.encode_compile(changed) != initial
    assert input.decode_compile(input.encode_compile(changed)) == Ok(changed)
    assert input.compile_facts(changed).policy_seed == base
  })
}

pub fn full_enrollment_and_enabled_seam_are_pinned_test() {
  let original = make_compile(program(), [], base())
  let pin = contract(vet_policy.workspace_effects(), [])
  let facts = enrollment.code_mode_facts(enrolled())
  let assert Ok(changed_pin) =
    enrollment.new(
      enrollment.native_facts(enrolled()),
      enrollment.CodeModeFacts(..facts, build_path: "/tc/other"),
      hash("b"),
      hash("c"),
    )
    as "Different configured PATH remains an individually valid enrollment."
  let assert Ok(changed) =
    input.compile_input(
      changed_pin,
      input.WorkspaceProgram,
      program(),
      [],
      compile.default_dependencies(),
      base(),
      180_000,
    )
    as "Bounds do not grant enrollment authority."
  assert input.admit_compile(compile_key(), pin, changed)
    == Error(input.AssociationMismatch)
  let assert Ok(other) =
    input.trusted_contract(
      enrolled(),
      input.OrchestrationProgram,
      vet_policy.default(),
      [],
    )
    as "Trusted assembly may separately enable the other program seam."
  assert input.admit_compile(compile_key(), other, original)
    == Error(input.AssociationMismatch)
  assert input.compile_envelope(launch_key(), original)
    == Error(input.AssociationMismatch)
}

pub fn launch_roundtrip_requires_successful_compile_with_separate_physical_steps_test() {
  let original =
    make_launch(artifact(), [#("HOME", "/work"), #("PATH", "/tc/bin")], base())
  let bytes = input.encode_launch(original)
  assert input.decode_launch(bytes) == Ok(original)
  let assert Ok(admitted) =
    input.admit_launch(
      launch_key(),
      enrolled(),
      original,
      compile_key(),
      successful(artifact()),
    )
    as "Matching Compile completion admits Launch despite distinct physical steps."
  assert input.admitted_launch(admitted) == #(launch_key(), original)
  assert input.launch_facts(original).compiled_by == compile_key()
  assert input.launch_envelope(launch_key(), original) |> result.is_ok
  assert input.admit_launch(
      launch_key(),
      enrolled(),
      original,
      compile_key(),
      compile.Compiled(
        Error(compile.BuildRejected("failed")),
        enforcement.Reported([], False),
      ),
    )
    == Error(input.CompileNotSuccessful)
  assert input.admit_launch(
      launch_key(),
      enrolled(),
      original,
      compile_key(),
      compile.Compiled(
        Ok(artifact()),
        enforcement.Unreported("Ready alone is not Compile success"),
      ),
    )
    == Error(input.CompileNotSuccessful)
  let local =
    compile.Artifact(
      "/build",
      "/build/ebin",
      compile.entry_module,
      "sha256-" <> hash("e"),
    )
  assert input.launch_input(
      enrolled(),
      compile_key(),
      local,
      [],
      cwd(),
      base(),
      hash("d"),
    )
    == Error(input.AssociationMismatch)
  assert input.admit_launch(
      launch_key(),
      enrolled(),
      original,
      compile_key(),
      successful(local),
    )
    == Error(input.CompileNotSuccessful)
}

pub fn changed_every_artifact_field_refuses_original_association_test() {
  let original = make_launch(artifact(), [], base())
  let #(enrolled_bits, value, _) = parts(input.encode_launch(original))
  let assert mp.ArrayValue([
    producer,
    mp.ArrayValue(fields),
    env,
    cwd,
    base,
    token,
  ]) = value
    as "Every artifact field can be independently substituted on the wire."
  let variants = [
    #(
      0,
      mp.ArrayValue([
        mp.StringValue(session_text()),
        mp.StringValue("other"),
        mp.StringValue("linux"),
        mp.IntValue(2),
        mp.IntValue(7),
      ]),
    ),
    #(1, mp.StringValue("00000000-0000-7000-8000-000000000009")),
    #(2, mp.StringValue("physical:elsewhere")),
    #(3, mp.StringValue("00000000-0000-7000-8000-000000000009")),
    #(4, mp.StringValue(hash("f"))),
    #(5, mp.StringValue("other-issued-artifact")),
    #(6, mp.StringValue(hash("f"))),
    #(7, mp.StringValue("foreign_entry")),
    #(8, mp.StringValue("sha256-" <> hash("f"))),
  ]
  list.each(variants, fn(change) {
    let changed_fields =
      list.index_map(fields, fn(field, index) {
        case index == change.0 {
          True -> change.1
          False -> field
        }
      })
    let changed =
      launch_reframe(
        enrolled_bits,
        mp.ArrayValue([
          producer,
          mp.ArrayValue(changed_fields),
          env,
          cwd,
          base,
          token,
        ]),
      )
    case change.0 == 5 || change.0 == 8 {
      True -> {
        let assert Ok(changed) = input.decode_launch(changed)
          as "A changed issued ID or fingerprint remains structurally valid."
        assert input.admit_launch(
            launch_key(),
            enrolled(),
            changed,
            compile_key(),
            successful(artifact()),
          )
          == Error(input.AssociationMismatch)
      }
      False -> assert_association_refused(changed)
    }
  })
}

pub fn producer_original_parent_uuid_digest_and_epochs_are_not_substitutable_test() {
  let original = make_launch(artifact(), [], base())
  let producer =
    service(
      command.CompileService,
      "physical:build",
      "00000000-0000-7000-8000-000000000009",
    )
  assert input.admit_launch(
      launch_key(),
      enrolled(),
      original,
      producer,
      successful(artifact()),
    )
    == Error(input.AssociationMismatch)
  let facts = input.launch_facts(original)
  assert input.launch_input(
      enrolled(),
      launch_key(),
      facts.artifact,
      [],
      cwd(),
      base(),
      hash("d"),
    )
    == Error(input.AssociationMismatch)
  let bytes = input.encode_launch(original)
  let #(enrolled_bits, value, _) = parts(bytes)
  let assert mp.ArrayValue([
    mp.StringValue(producer),
    artifact,
    env,
    cwd,
    full,
    token,
  ]) = value
    as "A full producer key accompanies the artifact."
  let assert Ok(json.Array(fields)) = json.parse(producer)
    as "Core producer key is the exact canonical array."
  let changes = [
    #(7, json.String(hash("f"))),
    #(8, json.String(hash("f"))),
    #(9, json.String(hash("f"))),
  ]
  list.each(changes, fn(change) {
    let producer =
      list.index_map(fields, fn(field, index) {
        case index == change.0 {
          True -> change.1
          False -> field
        }
      })
      |> json.Array
      |> json.to_string
    assert input.decode_launch(launch_reframe(
        enrolled_bits,
        mp.ArrayValue([
          mp.StringValue(producer),
          artifact,
          env,
          cwd,
          full,
          token,
        ]),
      ))
      |> result.is_error
  })
}

fn rejected(result: vet.VetResult) -> Bool {
  case result {
    vet.Rejected(_) -> True
    vet.Passed(_) -> False
  }
}

fn passed(result: vet.VetResult) -> Bool {
  case result {
    vet.Passed(_) -> True
    vet.Rejected(_) -> False
  }
}

fn hash(character: String) -> String {
  string.repeat(character, 64)
}

fn session_text() -> String {
  "00000000-0000-7000-8000-000000000001"
}

fn program() -> String {
  "pub fn main() { Nil }\n"
}

fn sized_source(size: Int) -> String {
  let prefix = program() <> "//"
  prefix <> string.repeat("x", size - string.byte_size(prefix))
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
    readable_roots: ["/tc", "/seed", "/work"],
    protected: ["/work/.git"],
    network: policy.NetworkProxy(["*.example.org"], "127.0.0.1:443"),
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
  let assert Ok(value) =
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
    as "Canonical isolated administrative enrollment."
  value
}

fn generated() -> List(#(String, String)) {
  [
    #("cap/mcp/github", "import cap/internal/mcp\npub fn tool() { Nil }\n"),
    #("cap/mcp/gitlab", "pub fn tool() { Nil }\n"),
  ]
}

fn make_compile(
  source: String,
  generated: List(#(String, String)),
  base: policy.SandboxPolicy,
) -> input.CompileInput {
  let assert Ok(value) =
    input.compile_input(
      enrolled(),
      input.WorkspaceProgram,
      source,
      generated,
      compile.default_dependencies(),
      base,
      180_000,
    )
    as "Exact bounded compile fixture."
  value
}

fn contract(
  policy: vet_policy.VetPolicy,
  catalogue: List(#(String, String)),
) -> input.CompilationContract {
  let assert Ok(value) =
    input.trusted_contract(
      enrolled(),
      input.WorkspaceProgram,
      policy,
      catalogue,
    )
    as "Trusted effective policy fixture."
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

fn artifact() -> compile.Artifact {
  let key = compile_key()
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

fn cwd() -> workspace.RelativePath {
  workspace.root()
}

fn make_launch(
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

fn parts(bytes: BitArray) -> #(BitArray, mp.MsgPackValue, BitArray) {
  let assert <<
    1,
    _,
    size:size(32),
    enrolled_bits:bytes-size(size),
    meta_size:size(32),
    meta:bytes-size(meta_size),
    bodies:bits,
  >> = bytes
    as "Two bounded canonical segments precede exact source bodies."
  let assert Ok(value) = mp.decode(meta) as "Fixture metadata is canonical."
  #(enrolled_bits, value, bodies)
}

fn frame(
  enrolled_bits: BitArray,
  meta: BitArray,
  bodies: BitArray,
) -> BitArray {
  <<
    1,
    1,
    bit_array.byte_size(enrolled_bits):size(32),
    enrolled_bits:bits,
    bit_array.byte_size(meta):size(32),
    meta:bits,
    bodies:bits,
  >>
}

fn reframe(
  enrolled_bits: BitArray,
  value: mp.MsgPackValue,
  bodies: BitArray,
) -> BitArray {
  let assert Ok(meta) = mp.encode(value)
    as "Corrupted semantic metadata remains encodable."
  frame(enrolled_bits, meta, bodies)
}

fn launch_reframe(enrolled_bits: BitArray, value: mp.MsgPackValue) -> BitArray {
  let assert Ok(meta) = mp.encode(value) as "Launch metadata remains encodable."
  <<
    1,
    2,
    bit_array.byte_size(enrolled_bits):size(32),
    enrolled_bits:bits,
    bit_array.byte_size(meta):size(32),
    meta:bits,
  >>
}

fn assert_association_refused(bytes: BitArray) -> Nil {
  assert input.decode_launch(bytes) == Error(input.AssociationMismatch)
}

pub fn changed_complete_parent_and_both_producer_epochs_refuse_test() {
  let original = make_launch(artifact(), [], base())
  let #(scope, operation, step) = command.coordinates(launch_key())
  let #(session, _) = workspace.scope_fields(scope)
  let assert Ok(entry) =
    ids.parse_entry_id("00000000-0000-7000-8000-000000000004")
    as "Original reserved entry."
  let assert Ok(other_entry) =
    ids.parse_entry_id("00000000-0000-7000-8000-000000000009")
    as "A different reserved result entry is still a valid core UUID."

  // Each substitution changes only one original parent field. Valid new keys
  // must refuse because complete parent equality binds the retained service.
  list.each(
    [
      #(4, hash("a"), entry),
      #(3, hash("f"), entry),
      #(3, hash("a"), other_entry),
    ],
    fn(change) {
      let assert Ok(foreign) =
        remote_tool.key(
          session,
          operation,
          "parent",
          change.0,
          change.1,
          change.2,
        )
        as "A changed source index, argument digest or reserved entry is a valid parent."
      let assert Ok(key) =
        command.service_key(
          foreign,
          command.LaunchService,
          scope,
          operation,
          step,
          command.request_id(launch_key()),
          hash("a"),
          hash("b"),
          hash("c"),
        )
        as "Other complete parent is syntactically valid."
      assert input.launch_envelope(key, original)
        == Error(input.AssociationMismatch)
      assert input.admit_launch(
          key,
          enrolled(),
          original,
          compile_key(),
          successful(artifact()),
        )
        == Error(input.AssociationMismatch)
    },
  )

  let #(enrolled_bits, value, _) = parts(input.encode_launch(original))
  let assert mp.ArrayValue([
    mp.StringValue(producer),
    artifact,
    env,
    cwd,
    base,
    token,
  ]) = value
    as "Original producer accompanies launch."
  let assert Ok(json.Array(fields)) = json.parse(producer)
    as "Closed canonical producer array."
  let assert Ok(json.Array(scope_fields)) = list.first(list.drop(fields, 3))
    as "Full scope is retained in the original key."
  list.each([3, 4], fn(epoch_index) {
    let changed_scope =
      list.index_map(scope_fields, fn(field, index) {
        case index == epoch_index {
          True -> json.Int(99)
          False -> field
        }
      })
    let changed =
      list.index_map(fields, fn(field, index) {
        case index == 3 {
          True -> json.Array(changed_scope)
          False -> field
        }
      })
      |> json.Array
      |> json.to_string
    assert_association_refused(launch_reframe(
      enrolled_bits,
      mp.ArrayValue([mp.StringValue(changed), artifact, env, cwd, base, token]),
    ))
  })
}

const rewrite_diagnostics =
  "  Compiling loom_codemode_program
warning: Unused imported module
  ┌─ /b/src/loom_program.gleam:2:1
  │
2 │ import gleam/int
  │ ^^^^^^^^^^^^^^^^ This imported module is never used

Hint: You can safely remove it.

error: 1 warning generated.

Your project was compiled with the `--warnings-as-errors` flag.
Fix the warnings and try again."

/// Pure admission binds source and host facts to the exact retained failure.
pub fn rewrite_admission_rejects_changed_source_policy_and_nonrewrite_failure_test() {
  let previous = compile_key()
  let assert Ok(id) = ids.parse_entry_id("00000000-0000-7000-8000-000000000009")
    as "Distinct rewrite UUID."
  let assert Ok(key) =
    command.rewrite_service_key(previous, id, string.repeat("d", 64))
    as "Closed lineage."
  let original =
    make_compile(
      "import cap/fs\nimport gleam/int\npub fn main() { fs.read(\"x\") }\n",
      [],
      base(),
    )
  let rewritten =
    make_compile(
      "import cap/fs\npub fn main() { fs.read(\"x\") }\n",
      [],
      base(),
    )
  let trusted = contract(vet_policy.workspace_effects(), [])
  let failed = compile.BuildRejected(rewrite_diagnostics)
  assert input.admit_rewrite(
      key,
      trusted,
      rewritten,
      previous,
      original,
      failed,
    )
    |> result.is_ok
  assert input.admit_rewrite(key, trusted, original, previous, original, failed)
    == Error(input.AssociationMismatch)
  assert input.admit_rewrite(
      key,
      trusted,
      rewritten,
      launch_key(),
      original,
      failed,
    )
    == Error(input.AssociationMismatch)
  assert input.admit_rewrite(
      key,
      trusted,
      rewritten,
      previous,
      original,
      compile.BuildUnavailable("lost result"),
    )
    == Error(input.AssociationMismatch)
  let changed =
    make_compile(
      input.compile_facts(rewritten).source,
      [],
      policy.SandboxPolicy(..base(), env_allow: ["CHANGED"]),
    )
  assert input.admit_rewrite(key, trusted, changed, previous, original, failed)
    == Error(input.AssociationMismatch)
  list.each(
    [
      "type error",
      "warning: Unused imported module",
      rewrite_diagnostics <> "\nerror: another failure",
      string.replace(
        rewrite_diagnostics,
        "2 │ import gleam/int",
        "2 │ import gleam/float",
      ),
    ],
    fn(diagnostics) {
      assert input.admit_rewrite(
          key,
          trusted,
          rewritten,
          previous,
          original,
          compile.BuildRejected(diagnostics),
        )
        == Error(input.AssociationMismatch)
    },
  )
}
