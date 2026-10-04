//// Exact bounded inputs for executor-local Compile and Launch services.
////
//// Constructors certify syntax and finite transport size, never permission to
//// prepare resources. Admission additionally binds the complete original key
//// and pinned enrollment. Compilation re-vets under an administratively supplied
//// effective policy and compares selected privileged facade sources byte for byte.
//// No peer seam, allowlist, dependency or digest claim creates that authority.
//// Launch admission requires the original successful Compile evidence; a local
//// Artifact or Prepared directory cannot stand in for that completion.
////
//// Source bodies live outside metadata's small MessagePack profile. The version,
//// role and two length-prefixed canonical segments precede exact UTF-8 bodies.
//// Enrollment plus metadata occupy at most 256 KiB; the complete existing service
//// envelope, including its actual core JSON header, occupies at most nine MiB.
//// The input digest hashes the canonical body, excluding its later key header.
//// Hash computation/authentication belongs to existing owner/executor boundaries.
//// These logical bounds do not promise identical BEAM memory or parser CPU use.
////
//// ## Flow
////
//// `compile_input` and `launch_input` bound native lists before building metadata.
//// `metadata` measures encoded bytes and nodes before MessagePack allocation.
//// `decode_compile` and `decode_launch` call `segments` before converting bodies.
//// `admit_compile` re-vets with the pinned effective policy, then `selected`
//// checks the exact trusted catalogue order. `admit_launch` requires successful
//// original Compile evidence. `envelope` applies the actual full-header bound.
//// `bounded_policy` checks policy lists before flattening/conversion; `texts` and
//// `path` validate bounded literal data. `artifact_value` and `read_artifact`
//// preserve every remote artifact field, while `artifact_binding` owns linkage.

import broker/enrollment
import broker/policy
import codemode/compile
import codemode/enforcement
import codemode/vet
import codemode/vet/policy as vet_policy
import core/bounded_msgpack
import core/command
import core/ids
import core/json
import core/msgpack as mp
import core/workspace
import gleam/bit_array
import gleam/bool
import gleam/list
import gleam/result
import gleam/set
import gleam/string

/// The two program seams served by the current physical CompileService.
pub type ProgramSeam {
  /// A workspace program, with the host's actual effective policy.
  WorkspaceProgram

  /// An orchestration program, only where trusted assembly enables it.
  OrchestrationProgram
}

/// Literal compile facts. Only compile_input can certify their wire bounds.
pub type CompileFacts {
  /// Original policy/stage ceilings are retained; final wall follows Ready.
  CompileFacts(
    /// Exact pinned administrative configuration, not a replacement advertisement.
    enrolled: enrollment.SessionEnrollment,
    /// Selects a provisioned contract; it does not determine an allowlist.
    seam: ProgramSeam,
    /// Exact program text, without normalization or an encoded Vetted token.
    source: String,
    /// Ordered selected module names and complete facade source bytes.
    generated: List(#(String, String)),
    /// The exact ordered production dependency table.
    dependencies: List(compile.Dependency),
    /// Complete owner-selected initial policy, including all limit fields.
    policy_seed: policy.SandboxPolicy,
    /// Original positive compilation stage ceiling in milliseconds.
    build_timeout_ms: Int,
  )
}

/// Bounded exact compile data, without preparation or source-vetting authority.
pub opaque type CompileInput {
  CompileInput(facts: CompileFacts, enrolled_bytes: BitArray, meta: BitArray)
}

/// Literal launch facts, whose artifact can only be an executor reference.
pub type LaunchFacts {
  /// Token bytes, physical listener handles and owner authority stay elsewhere.
  LaunchFacts(
    /// The original exact session enrollment.
    enrolled: enrollment.SessionEnrollment,
    /// Complete original producer key, including physical Compile coordinates.
    compiled_by: command.ServiceKey,
    /// Every field of the exact executor-issued artifact.
    artifact: compile.Artifact,
    /// Original ordered environment, with unique bounded names.
    env: List(#(String, String)),
    /// Exact relative cwd; the owner never resolves this on its filesystem.
    cwd: workspace.RelativePath,
    /// Complete initial policy ceiling, not the final selected native wall.
    policy_seed: policy.SandboxPolicy,
    /// Lowercase SHA-256 commitment to the original private 32-byte token.
    token_commitment: String,
  )
}

/// Bounded launch data. Construction refuses the local Artifact variant.
pub opaque type LaunchInput {
  LaunchInput(facts: LaunchFacts, enrolled_bytes: BitArray, meta: BitArray)
}

/// Trusted per-seam facts installed by administrative assembly, never decoding.
/// Exact catalogue bytes authorize privileged facades. Digest meaning and seed
/// immutability remain provisioning obligations, not proofs from this constructor.
pub opaque type CompilationContract {
  CompilationContract(
    enrolled: enrollment.SessionEnrollment,
    seam: ProgramSeam,
    effective_policy: vet_policy.VetPolicy,
    catalogue: List(#(String, String)),
  )
}

/// Source re-vetted under the trusted effective policy and exact catalogue.
/// The exchange boundary must also authenticate/hash the original input body.
pub opaque type AdmittedCompile {
  AdmittedCompile(
    key: command.ServiceKey,
    input: CompileInput,
    vetted: vet.Vetted,
  )
}

/// Launch input matched against original retained successful Compile evidence.
/// This is not a live resource claim, listener capability or native clearance.
pub opaque type AdmittedLaunch {
  AdmittedLaunch(key: command.ServiceKey, input: LaunchInput)
}

/// Fixed diagnostics keep malformed peer contents out of error allocation.
pub type InputError {
  /// Native counts, metadata bytes/nodes or the whole envelope exceed a bound.
  BoundExceeded

  /// Literal names, paths, duplicate entries or complete policy are invalid.
  InvalidData

  /// Framing, version, field types or UTF-8 are malformed.
  InvalidEncoding

  /// A semantically decodable frame uses alternate canonical bytes.
  NoncanonicalEncoding

  /// Original role, coordinates, enrollment, dependencies or catalogue differ.
  AssociationMismatch

  /// User source failed the trusted effective policy before preparation.
  SourceRejected

  /// No matching successful remote Compile result/report exists.
  CompileNotSuccessful
}

type WireBudget {
  WireBudget(bytes: Int, nodes: Int)
}

/// Whole existing ServiceRequest ceiling, including its four-byte JSON prefix.
pub const max_envelope_bytes = 9_437_184

/// Aggregate enrollment and metadata bytes; source bodies are charged separately.
pub const max_metadata_bytes = 262_144

/// Constructs exact bounded input before hashing and allocating its ServiceKey.
/// Counts and source byte sums are checked before converting strings to binaries.
///
/// ## Examples
///
/// `compile_input(enrolled, WorkspaceProgram, source, [], compile.default_dependencies(), base, 180000)` retains the original stage ceiling.
pub fn compile_input(
  enrolled: enrollment.SessionEnrollment,
  seam: ProgramSeam,
  source: String,
  generated: List(#(String, String)),
  dependencies: List(compile.Dependency),
  policy_seed: policy.SandboxPolicy,
  build_timeout_ms: Int,
) -> Result(CompileInput, InputError) {
  use Nil <- result.try(count(generated, 128))
  use Nil <- result.try(count(dependencies, 4))
  use <- bool.guard(
    !{ dependencies == compile.default_dependencies() },
    Error(InvalidData),
  )
  use Nil <- result.try(
    bool.guard(!{ build_timeout_ms > 0 }, Error(InvalidData), fn() { Ok(Nil) }),
  )
  use Nil <- result.try(bounded_policy(policy_seed))
  use bytes <- result.try(source_size(source, 0))
  use _ <- result.try(modules(generated, set.new(), bytes))
  let facts =
    CompileFacts(
      enrolled,
      seam,
      source,
      generated,
      dependencies,
      policy_seed,
      build_timeout_ms,
    )

  // Native list/text bounds precede policy conversion and encoder allocation.
  use enrolled_bytes <- result.try(
    enrollment.encode(enrolled) |> result.replace_error(InvalidData),
  )
  use meta <- result.try(metadata(
    compile_value(facts),
    bit_array.byte_size(enrolled_bytes),
  ))
  let input = CompileInput(facts, enrolled_bytes, meta)
  use Nil <- result.try(body_bound(compile_body_size(input)))
  Ok(input)
}

/// Constructs launch data only for a matching full executor artifact reference.
/// This intrinsic association is checked before any retained completion is read.
///
/// ## Examples
///
/// `launch_input(enrolled, compile_key, remote_artifact, env, cwd, base, commitment)` refuses a local Artifact.
pub fn launch_input(
  enrolled: enrollment.SessionEnrollment,
  compiled_by: command.ServiceKey,
  artifact: compile.Artifact,
  env: List(#(String, String)),
  cwd: workspace.RelativePath,
  policy_seed: policy.SandboxPolicy,
  token_commitment: String,
) -> Result(LaunchInput, InputError) {
  use Nil <- result.try(count(env, 64))
  use Nil <- result.try(environment(env))
  use Nil <- result.try(bounded_policy(policy_seed))
  use Nil <- result.try(
    command.digest(token_commitment) |> result.replace_error(InvalidData),
  )
  use Nil <- result.try(enrollment_key(
    enrolled,
    compiled_by,
    command.CompileService,
  ))
  use Nil <- result.try(artifact_binding(compiled_by, artifact))
  let facts =
    LaunchFacts(
      enrolled,
      compiled_by,
      artifact,
      env,
      cwd,
      policy_seed,
      token_commitment,
    )

  use enrolled_bytes <- result.try(
    enrollment.encode(enrolled) |> result.replace_error(InvalidData),
  )
  use meta <- result.try(metadata(
    launch_value(facts),
    bit_array.byte_size(enrolled_bytes),
  ))
  Ok(LaunchInput(facts, enrolled_bytes, meta))
}

/// Returns literal compile data; these facts alone grant no preparation claim.
///
/// ## Examples
///
/// `compile_facts(input).source` preserves every original UTF-8 byte.
pub fn compile_facts(input: CompileInput) -> CompileFacts {
  input.facts
}

/// Returns literal launch data without turning remote paths into local paths.
///
/// ## Examples
///
/// `launch_facts(input).compiled_by` is the original complete producer key.
pub fn launch_facts(input: LaunchInput) -> LaunchFacts {
  input.facts
}

/// Encodes exact source bodies after constructor byte/count admission.
///
/// ## Examples
///
/// `decode_compile(encode_compile(input)) == Ok(input)` for canonical inputs.
pub fn encode_compile(input: CompileInput) -> BitArray {
  bit_array.concat([
    prefix(1, input.enrolled_bytes, input.meta),
    bit_array.from_string(input.facts.source),
    ..list.map(input.facts.generated, fn(module) {
      bit_array.from_string(module.1)
    })
  ])
}

/// Encodes a launch body, with no raw token or listener handle.
///
/// ## Examples
///
/// `decode_launch(encode_launch(input)) == Ok(input)` retains the full artifact.
pub fn encode_launch(input: LaunchInput) -> BitArray {
  prefix(2, input.enrolled_bytes, input.meta)
}

/// Builds the existing canonical whole envelope using its actual key header.
/// Role, enrollment and total size are checked; input digest computation remains
/// the caller's existing SHA-256 responsibility, not an authenticated claim here.
///
/// ## Examples
///
/// `compile_envelope(key, input)` refuses a body whose actual header crosses nine MiB.
pub fn compile_envelope(
  key: command.ServiceKey,
  input: CompileInput,
) -> Result(BitArray, InputError) {
  use Nil <- result.try(enrollment_key(
    input.facts.enrolled,
    key,
    command.CompileService,
  ))
  use header <- result.try(header_bound(key, compile_body_size(input)))
  Ok(<<header:bits, encode_compile(input):bits>>)
}

/// Frames the existing Launch envelope without allocating another service ID.
///
/// ## Examples
///
/// `launch_envelope(key, input)` checks the full original enrollment and header.
pub fn launch_envelope(
  key: command.ServiceKey,
  input: LaunchInput,
) -> Result(BitArray, InputError) {
  use Nil <- result.try(launch_key(key, input.facts))
  envelope(key, encode_launch(input))
}

/// Decodes bounded canonical metadata before allocating source text or parsing it.
/// Whole body size is checked here; actual header accounting occurs at binding.
///
/// ## Examples
///
/// `decode_compile(<<1, 1, 0xffffffff:size(32)>>)` refuses before source conversion.
pub fn decode_compile(bytes: BitArray) -> Result(CompileInput, InputError) {
  use #(enrolled, value, bodies) <- result.try(segments(bytes, 1))
  use input <- result.try(read_compile(enrolled, value, bodies))
  use Nil <- result.try(canonical(encode_compile(input), bytes))
  Ok(input)
}

/// Totally decodes exact launch data, including the canonical inner producer key.
///
/// ## Examples
///
/// `decode_launch(<<>>)` returns InvalidEncoding and creates no resource.
pub fn decode_launch(bytes: BitArray) -> Result(LaunchInput, InputError) {
  use #(enrolled, value, bodies) <- result.try(segments(bytes, 2))
  use <- bool.guard(!{ bodies == <<>> }, Error(InvalidData))
  use input <- result.try(read_launch(enrolled, value))
  use Nil <- result.try(canonical(encode_launch(input), bytes))
  Ok(input)
}

/// Pins an actual trusted host policy and catalogue for one enabled program seam.
/// Call only from administrative assembly, never with input-derived facts. The
/// selected wire list is bounded separately; this adds no deployment catalogue
/// capacity default. Source equality authorizes facades without a new hash API.
///
/// ## Examples
///
/// `trusted_contract(enrolled, WorkspaceProgram, vet_policy.workspace_effects(), [])` preserves an effect-only host's policy.
pub fn trusted_contract(
  enrolled: enrollment.SessionEnrollment,
  seam: ProgramSeam,
  effective_policy: vet_policy.VetPolicy,
  catalogue: List(#(String, String)),
) -> Result(CompilationContract, InputError) {
  use Nil <- result.try(catalogue_check(catalogue, set.new()))
  Ok(CompilationContract(enrolled, seam, effective_policy, catalogue))
}

/// Re-vets under the trusted effective policy and checks every selected facade.
/// The exchange boundary must recompute/authenticate the input digest before
/// using this result. Admission itself performs no clock, hash or resource I/O.
///
/// ## Examples
///
/// `admit_compile(key, effect_only_contract, input_importing_cap_strand)` returns SourceRejected.
pub fn admit_compile(
  key: command.ServiceKey,
  contract: CompilationContract,
  input: CompileInput,
) -> Result(AdmittedCompile, InputError) {
  use Nil <- result.try(enrollment_key(
    input.facts.enrolled,
    key,
    command.CompileService,
  ))
  use _ <- result.try(header_bound(key, compile_body_size(input)))
  use Nil <- result.try(
    enrollment.matches(contract.enrolled, input.facts.enrolled)
    |> result.replace_error(AssociationMismatch),
  )
  use <- bool.guard(
    !{ contract.seam == input.facts.seam },
    Error(AssociationMismatch),
  )

  // A peer's seam never substitutes a broader static policy for this host pin.
  use vetted <- result.try(
    case vet.vet(input.facts.source, contract.effective_policy) {
      vet.Passed(vetted) -> Ok(vetted)
      vet.Rejected(_) -> Error(SourceRejected)
    },
  )
  use <- bool.guard(
    !{ selected(contract.catalogue, vetted) == input.facts.generated },
    Error(AssociationMismatch),
  )
  Ok(AdmittedCompile(key, input, vetted))
}

/// Returns the original key, bounded input and executor-revetted source token.
///
/// ## Examples
///
/// `admitted_compile(admitted)` supplies CompileRequest's Vetted without decoding one.
pub fn admitted_compile(
  admitted: AdmittedCompile,
) -> #(command.ServiceKey, CompileInput, vet.Vetted) {
  #(admitted.key, admitted.input, admitted.vetted)
}

/// Associates launch with an exact retained successful original Compile result.
/// The producer key/result are trusted journal evidence, not peer-supplied
/// completion claims. Physical steps may differ; complete parents must agree.
///
/// ## Examples
///
/// `admit_launch(key, pin, input, producer, failed_compile)` returns CompileNotSuccessful.
pub fn admit_launch(
  key: command.ServiceKey,
  pinned: enrollment.SessionEnrollment,
  input: LaunchInput,
  producer: command.ServiceKey,
  completed: compile.Compiled,
) -> Result(AdmittedLaunch, InputError) {
  use Nil <- result.try(launch_key(key, input.facts))
  use _ <- result.try(header_bound(
    key,
    bit_array.byte_size(encode_launch(input)),
  ))
  use Nil <- result.try(
    enrollment.matches(pinned, input.facts.enrolled)
    |> result.replace_error(AssociationMismatch),
  )
  use <- bool.guard(
    !{ producer == input.facts.compiled_by },
    Error(AssociationMismatch),
  )

  // Ready locations are insufficient: only an actual successful remote result
  // with its retained enforcement report can authorize this association.
  use artifact <- result.try(case completed.result, completed.enforcement {
    Ok(compile.ExecutorArtifact(..) as artifact), enforcement.Reported(..) ->
      Ok(artifact)
    Error(_), _
    | Ok(compile.Artifact(..)), _
    | Ok(compile.ExecutorArtifact(..)), enforcement.Unreported(_)
    -> Error(CompileNotSuccessful)
  })
  use <- bool.guard(
    !{ artifact == input.facts.artifact },
    Error(AssociationMismatch),
  )
  Ok(AdmittedLaunch(key, input))
}

/// Returns associated launch data, without granting current listener usability.
///
/// ## Examples
///
/// `admitted_launch(admitted)` never returns a preparation claim.
pub fn admitted_launch(
  admitted: AdmittedLaunch,
) -> #(command.ServiceKey, LaunchInput) {
  #(admitted.key, admitted.input)
}

fn compile_value(facts: CompileFacts) -> mp.MsgPackValue {
  mp.ArrayValue([
    mp.IntValue(seam_number(facts.seam)),
    mp.ArrayValue(list.map(facts.dependencies, dependency_value)),
    policy.to_msgpack(facts.policy_seed),
    mp.IntValue(facts.build_timeout_ms),
    mp.IntValue(string.byte_size(facts.source)),
    mp.ArrayValue(
      list.map(facts.generated, fn(module) {
        mp.ArrayValue([
          mp.StringValue(module.0),
          mp.IntValue(string.byte_size(module.1)),
        ])
      }),
    ),
  ])
}

fn launch_value(facts: LaunchFacts) -> mp.MsgPackValue {
  mp.ArrayValue([
    mp.StringValue(service_text(facts.compiled_by)),
    artifact_value(facts.artifact),
    mp.ArrayValue(
      list.map(facts.env, fn(pair) {
        mp.ArrayValue([mp.StringValue(pair.0), mp.StringValue(pair.1)])
      }),
    ),
    mp.StringValue(workspace.path_string(facts.cwd)),
    policy.to_msgpack(facts.policy_seed),
    mp.StringValue(facts.token_commitment),
  ])
}

fn dependency_value(dependency: compile.Dependency) -> mp.MsgPackValue {
  case dependency {
    compile.HexDependency(name, requirement) ->
      mp.ArrayValue([
        mp.IntValue(1),
        mp.StringValue(name),
        mp.StringValue(requirement),
      ])
    compile.PathDependency(name, path) ->
      mp.ArrayValue([mp.IntValue(2), mp.StringValue(name), mp.StringValue(path)])
  }
}

fn read_compile(
  enrolled: enrollment.SessionEnrollment,
  value: mp.MsgPackValue,
  bodies: BitArray,
) -> Result(CompileInput, InputError) {
  case value {
    mp.ArrayValue([
      mp.IntValue(seam),
      mp.ArrayValue(dependencies),
      base,
      mp.IntValue(timeout),
      mp.IntValue(source_bytes),
      mp.ArrayValue(descriptors),
    ]) -> {
      use seam <- result.try(case seam {
        1 -> Ok(WorkspaceProgram)
        2 -> Ok(OrchestrationProgram)
        _ -> Error(InvalidEncoding)
      })
      use Nil <- result.try(count(dependencies, 4))
      use dependencies <- result.try(list.try_map(dependencies, read_dependency))
      use <- bool.guard(
        !{ dependencies == compile.default_dependencies() },
        Error(AssociationMismatch),
      )
      use base <- result.try(
        policy.from_msgpack(base) |> result.replace_error(InvalidData),
      )
      use descriptors <- result.try(list.try_map(descriptors, read_descriptor))
      use Nil <- result.try(descriptor_names(descriptors, set.new()))
      use Nil <- result.try(declared_sizes(
        source_bytes,
        descriptors,
        bit_array.byte_size(bodies),
      ))

      // All declared lengths have passed aggregate accounting before any body
      // becomes a UTF-8 string; no recursive body step renews the byte allowance.
      use #(source, rest) <- result.try(read_body(bodies, source_bytes))
      use generated <- result.try(read_modules(rest, descriptors))
      compile_input(
        enrolled,
        seam,
        source,
        generated,
        dependencies,
        base,
        timeout,
      )
    }
    _ -> Error(InvalidEncoding)
  }
}

fn read_launch(
  enrolled: enrollment.SessionEnrollment,
  value: mp.MsgPackValue,
) -> Result(LaunchInput, InputError) {
  case value {
    mp.ArrayValue([
      mp.StringValue(producer),
      artifact,
      mp.ArrayValue(env),
      mp.StringValue(cwd),
      base,
      mp.StringValue(commitment),
    ]) -> {
      use producer <- result.try(read_service(producer))
      use artifact <- result.try(read_artifact(artifact))
      use Nil <- result.try(count(env, 64))
      use env <- result.try(list.try_map(env, read_pair))
      use cwd <- result.try(
        workspace.relative_path(cwd) |> result.replace_error(InvalidData),
      )
      use base <- result.try(
        policy.from_msgpack(base) |> result.replace_error(InvalidData),
      )
      launch_input(enrolled, producer, artifact, env, cwd, base, commitment)
    }
    _ -> Error(InvalidEncoding)
  }
}

fn prefix(role: Int, enrolled: BitArray, meta: BitArray) -> BitArray {
  <<
    1,
    role,
    bit_array.byte_size(enrolled):size(32),
    enrolled:bits,
    bit_array.byte_size(meta):size(32),
    meta:bits,
  >>
}

fn segments(
  bytes: BitArray,
  role: Int,
) -> Result(
  #(enrollment.SessionEnrollment, mp.MsgPackValue, BitArray),
  InputError,
) {
  use Nil <- result.try(body_bound(bit_array.byte_size(bytes)))
  use <- bool.guard(!{ bit_array.bit_size(bytes) % 8 == 0 }, Error(InvalidData))
  case bytes {
    <<1, actual, enrolled_size:size(32), rest:bytes>>
      if actual == role
      && enrolled_size > 0
      && enrolled_size <= max_metadata_bytes
    -> read_segments(rest, enrolled_size)
    _ -> Error(InvalidEncoding)
  }
}

fn read_segments(
  rest: BitArray,
  enrolled_size: Int,
) -> Result(
  #(enrollment.SessionEnrollment, mp.MsgPackValue, BitArray),
  InputError,
) {
  case rest {
    <<enrolled:bytes-size(enrolled_size), meta_size:size(32), rest:bytes>>
      if meta_size > 0 && meta_size + enrolled_size <= max_metadata_bytes
    -> {
      case rest {
        <<meta:bytes-size(meta_size), bodies:bytes>> -> {
          use enrolled <- result.try(
            enrollment.decode(enrolled) |> result.replace_error(InvalidEncoding),
          )
          use value <- result.try(
            bounded_msgpack.decode(meta)
            |> result.replace_error(InvalidEncoding),
          )
          use encoded <- result.try(
            mp.encode(value) |> result.replace_error(InvalidEncoding),
          )
          use Nil <- result.try(canonical(encoded, meta))
          Ok(#(enrolled, value, bodies))
        }
        _ -> Error(InvalidEncoding)
      }
    }
    _ -> Error(InvalidEncoding)
  }
}

fn metadata(
  value: mp.MsgPackValue,
  enrolled_size: Int,
) -> Result(BitArray, InputError) {
  use _ <- result.try(measure(value, WireBudget(enrolled_size, 0)))
  use bytes <- result.try(
    mp.encode(value) |> result.replace_error(InvalidEncoding),
  )
  use _ <- result.try(
    bounded_msgpack.decode(bytes) |> result.replace_error(BoundExceeded),
  )
  Ok(bytes)
}

fn compile_body_size(input: CompileInput) -> Int {
  10
  + bit_array.byte_size(input.enrolled_bytes)
  + bit_array.byte_size(input.meta)
  + string.byte_size(input.facts.source)
  + list.fold(input.facts.generated, 0, fn(size, module) {
    size + string.byte_size(module.1)
  })
}

fn body_bound(size: Int) -> Result(Nil, InputError) {
  case size > 0 && size <= max_envelope_bytes {
    True -> Ok(Nil)
    False -> Error(BoundExceeded)
  }
}

fn header_bound(
  key: command.ServiceKey,
  body_size: Int,
) -> Result(BitArray, InputError) {
  let text = service_text(key)
  use Nil <- result.try(text_bound(text))
  let size = string.byte_size(text)
  use Nil <- result.try(body_bound(4 + size + body_size))
  Ok(<<size:size(32), text:utf8>>)
}

fn envelope(
  key: command.ServiceKey,
  body: BitArray,
) -> Result(BitArray, InputError) {
  use header <- result.try(header_bound(key, bit_array.byte_size(body)))
  Ok(<<header:bits, body:bits>>)
}

fn service_text(key: command.ServiceKey) -> String {
  command.encode_service(key) |> json.to_string
}

fn read_service(text: String) -> Result(command.ServiceKey, InputError) {
  use Nil <- result.try(text_bound(text))
  use value <- result.try(
    json.parse(text) |> result.replace_error(InvalidEncoding),
  )
  use key <- result.try(
    command.decode_service(value) |> result.replace_error(InvalidEncoding),
  )
  use Nil <- result.try(canonical(
    bit_array.from_string(service_text(key)),
    bit_array.from_string(text),
  ))
  Ok(key)
}

fn enrollment_key(
  enrolled: enrollment.SessionEnrollment,
  key: command.ServiceKey,
  role: command.ServiceRole,
) -> Result(Nil, InputError) {
  let #(scope, _, _) = command.coordinates(key)
  let #(_, registration, contract) = command.digests(key)
  bool.guard(
    !{
      command.service_role(key) == role
      && enrollment.native_facts(enrolled).scope == scope
      && enrollment.digests(enrolled) == #(registration, contract)
    },
    Error(AssociationMismatch),
    fn() { Ok(Nil) },
  )
}

fn launch_key(
  key: command.ServiceKey,
  facts: LaunchFacts,
) -> Result(Nil, InputError) {
  use Nil <- result.try(enrollment_key(
    facts.enrolled,
    key,
    command.LaunchService,
  ))
  bool.guard(
    !{ command.parent(key) == command.parent(facts.compiled_by) },
    Error(AssociationMismatch),
    fn() { Ok(Nil) },
  )
}

fn artifact_binding(
  key: command.ServiceKey,
  artifact: compile.Artifact,
) -> Result(Nil, InputError) {
  case artifact {
    compile.ExecutorArtifact(
      scope,
      operation,
      step,
      request_id,
      request_digest,
      artifact_id,
      contract_digest,
      entry_module,
      manifest_hash,
    ) -> {
      use Nil <- result.try(text_bound(artifact_id))
      use <- bool.guard(!{ artifact_id != "" }, Error(InvalidData))
      use Nil <- result.try(text_bound(manifest_hash))
      use Nil <- result.try(
        command.digest(string.drop_start(manifest_hash, 7))
        |> result.replace_error(InvalidData),
      )
      use <- bool.guard(
        !{
          string.starts_with(manifest_hash, "sha256-")
          && string.byte_size(manifest_hash) == 71
        },
        Error(InvalidData),
      )
      let #(expected_scope, expected_operation, expected_step) =
        command.coordinates(key)
      let #(input_digest, _, contract) = command.digests(key)
      bool.guard(
        !{
          scope == expected_scope
          && operation == expected_operation
          && step == expected_step
          && request_id == ids.entry_id_to_string(command.request_id(key))
          && request_digest == input_digest
          && contract_digest == contract
          && entry_module == compile.entry_module
        },
        Error(AssociationMismatch),
        fn() { Ok(Nil) },
      )
    }
    compile.Artifact(..) -> Error(AssociationMismatch)
  }
}

fn artifact_value(artifact: compile.Artifact) -> mp.MsgPackValue {
  case artifact {
    compile.ExecutorArtifact(
      scope,
      operation,
      step,
      request_id,
      request_digest,
      artifact_id,
      contract_digest,
      entry_module,
      manifest_hash,
    ) ->
      mp.ArrayValue([
        scope_value(scope),
        mp.StringValue(ids.op_id_to_string(operation)),
        mp.StringValue(workspace.step_string(step)),
        mp.StringValue(request_id),
        mp.StringValue(request_digest),
        mp.StringValue(artifact_id),
        mp.StringValue(contract_digest),
        mp.StringValue(entry_module),
        mp.StringValue(manifest_hash),
      ])
    compile.Artifact(..) -> mp.NilValue
  }
}

fn scope_value(scope: workspace.Scope) -> mp.MsgPackValue {
  let #(session, binding) = workspace.scope_fields(scope)
  let #(selector, workspace_epoch, session_epoch) =
    workspace.binding_fields(binding)
  let #(executor, selected_workspace) = workspace.selector_fields(selector)
  mp.ArrayValue([
    mp.StringValue(ids.session_id_to_string(session)),
    mp.StringValue(selected_workspace),
    mp.StringValue(executor),
    mp.IntValue(session_epoch),
    mp.IntValue(workspace_epoch),
  ])
}

fn read_artifact(
  value: mp.MsgPackValue,
) -> Result(compile.Artifact, InputError) {
  case value {
    mp.ArrayValue([
      scope,
      mp.StringValue(operation),
      mp.StringValue(step),
      mp.StringValue(request_id),
      mp.StringValue(request_digest),
      mp.StringValue(artifact_id),
      mp.StringValue(contract_digest),
      mp.StringValue(entry_module),
      mp.StringValue(manifest_hash),
    ]) -> {
      use scope <- result.try(read_scope(scope))
      use operation <- result.try(
        ids.parse_op_id(operation) |> result.replace_error(InvalidData),
      )
      use step <- result.try(
        workspace.step(step) |> result.replace_error(InvalidData),
      )
      Ok(compile.ExecutorArtifact(
        scope,
        operation,
        step,
        request_id,
        request_digest,
        artifact_id,
        contract_digest,
        entry_module,
        manifest_hash,
      ))
    }
    _ -> Error(InvalidEncoding)
  }
}

fn read_scope(value: mp.MsgPackValue) -> Result(workspace.Scope, InputError) {
  case value {
    mp.ArrayValue([
      mp.StringValue(session),
      mp.StringValue(selected_workspace),
      mp.StringValue(executor),
      mp.IntValue(session_epoch),
      mp.IntValue(workspace_epoch),
    ]) ->
      workspace.scope_from_fields(
        session,
        selected_workspace,
        executor,
        session_epoch,
        workspace_epoch,
      )
      |> result.replace_error(InvalidData)
    _ -> Error(InvalidEncoding)
  }
}

fn read_dependency(
  value: mp.MsgPackValue,
) -> Result(compile.Dependency, InputError) {
  case value {
    mp.ArrayValue([
      mp.IntValue(1),
      mp.StringValue(name),
      mp.StringValue(requirement),
    ]) -> Ok(compile.HexDependency(name, requirement))
    mp.ArrayValue([mp.IntValue(2), mp.StringValue(name), mp.StringValue(path)]) ->
      Ok(compile.PathDependency(name, path))
    _ -> Error(InvalidEncoding)
  }
}

fn read_descriptor(
  value: mp.MsgPackValue,
) -> Result(#(String, Int), InputError) {
  case value {
    mp.ArrayValue([mp.StringValue(name), mp.IntValue(size)]) ->
      Ok(#(name, size))
    _ -> Error(InvalidEncoding)
  }
}

fn read_pair(value: mp.MsgPackValue) -> Result(#(String, String), InputError) {
  case value {
    mp.ArrayValue([mp.StringValue(name), mp.StringValue(value)]) ->
      Ok(#(name, value))
    _ -> Error(InvalidEncoding)
  }
}

fn declared_sizes(
  source: Int,
  modules: List(#(String, Int)),
  available: Int,
) -> Result(Nil, InputError) {
  use Nil <- result.try(
    bool.guard(!{ source > 0 && source <= available }, Error(InvalidData), fn() {
      Ok(Nil)
    }),
  )
  use total <- result.try(
    list.try_fold(modules, source, fn(total, module) {
      use <- bool.guard(
        !{ module.1 > 0 && module.1 <= available - total },
        Error(InvalidData),
      )
      Ok(total + module.1)
    }),
  )
  bool.guard(!{ total == available }, Error(InvalidData), fn() { Ok(Nil) })
}

fn read_body(
  bytes: BitArray,
  size: Int,
) -> Result(#(String, BitArray), InputError) {
  case bytes {
    <<body:bytes-size(size), rest:bytes>> -> {
      use text <- result.try(
        bit_array.to_string(body) |> result.replace_error(InvalidEncoding),
      )
      Ok(#(text, rest))
    }
    _ -> Error(InvalidEncoding)
  }
}

fn read_modules(
  bytes: BitArray,
  descriptors: List(#(String, Int)),
) -> Result(List(#(String, String)), InputError) {
  case descriptors {
    [] -> {
      use <- bool.guard(!{ bytes == <<>> }, Error(InvalidData))
      Ok([])
    }
    [#(name, size), ..rest] -> {
      use #(source, bytes) <- result.try(read_body(bytes, size))
      use modules <- result.try(read_modules(bytes, rest))
      Ok([#(name, source), ..modules])
    }
  }
}

fn selected(
  catalogue: List(#(String, String)),
  vetted: vet.Vetted,
) -> List(#(String, String)) {
  let imports =
    list.map(vet.vetted_module(vetted).imports, fn(definition) {
      definition.definition.module
    })
  list.filter(catalogue, fn(module) { list.contains(imports, module.0) })
}

fn seam_number(seam: ProgramSeam) -> Int {
  case seam {
    WorkspaceProgram -> 1
    OrchestrationProgram -> 2
  }
}

fn count(items: List(a), maximum: Int) -> Result(Nil, InputError) {
  case list.drop(items, maximum) {
    [] -> Ok(Nil)
    [_, ..] -> Error(BoundExceeded)
  }
}

fn canonical(encoded: BitArray, original: BitArray) -> Result(Nil, InputError) {
  case encoded == original {
    True -> Ok(Nil)
    False -> Error(NoncanonicalEncoding)
  }
}

fn text_bound(text: String) -> Result(Nil, InputError) {
  use Nil <- result.try(case string.byte_size(text) <= 8192 {
    True -> Ok(Nil)
    False -> Error(BoundExceeded)
  })
  bool.guard(!{ !string.contains(text, "\u{0000}") }, Error(InvalidData), fn() {
    Ok(Nil)
  })
}

fn source_size(source: String, total: Int) -> Result(Int, InputError) {
  let size = string.byte_size(source)
  use Nil <- result.try(body_bound(total + size))
  use <- bool.guard(
    !{ size > 0 && !string.contains(source, "\u{0000}") },
    Error(InvalidData),
  )
  Ok(total + size)
}

fn modules(
  items: List(#(String, String)),
  seen: set.Set(String),
  bytes: Int,
) -> Result(Int, InputError) {
  case items {
    [] -> Ok(bytes)
    [#(name, source), ..rest] -> {
      use Nil <- result.try(text_bound(name))
      use <- bool.guard(
        !{
          vet_policy.is_legal_module_name(name)
          && string.starts_with(name, "cap/mcp/")
          && !set.contains(seen, name)
        },
        Error(InvalidData),
      )
      use bytes <- result.try(source_size(source, bytes))
      modules(rest, set.insert(seen, name), bytes)
    }
  }
}

fn environment(env: List(#(String, String))) -> Result(Nil, InputError) {
  use _ <- result.try(
    list.try_fold(env, set.new(), fn(names, pair) {
      use Nil <- result.try(text_bound(pair.0))
      use Nil <- result.try(text_bound(pair.1))
      use <- bool.guard(
        !{
          pair.0 != ""
          && !string.contains(pair.0, "=")
          && !set.contains(names, pair.0)
        },
        Error(InvalidData),
      )
      Ok(set.insert(names, pair.0))
    }),
  )
  Ok(Nil)
}

fn bounded_policy(base: policy.SandboxPolicy) -> Result(Nil, InputError) {
  use Nil <- result.try(count(base.writable_roots, 128))
  use Nil <- result.try(count(base.readable_roots, 128))
  use Nil <- result.try(count(base.protected, 128))
  use Nil <- result.try(count(base.env_allow, 128))
  use Nil <- result.try(count(base.mounts, 128))
  let scratch = case base.scratch {
    policy.ScratchTmpfs -> 0
    policy.ScratchPath(_) -> 1
  }
  use Nil <- result.try(
    case
      list.length(base.writable_roots)
      + list.length(base.readable_roots)
      + list.length(base.mounts)
      + scratch
      <= 128
    {
      True -> Ok(Nil)
      False -> Error(BoundExceeded)
    },
  )

  // Conversion and existing semantic validation see only bounded plain lists.
  use Nil <- result.try(list.try_each(
    list.flatten([base.writable_roots, base.readable_roots, base.protected]),
    path,
  ))
  use Nil <- result.try(texts(base.env_allow))
  use Nil <- result.try(
    list.try_each(base.mounts, fn(mount) { path(mount.path) }),
  )
  use Nil <- result.try(case base.scratch {
    policy.ScratchTmpfs -> Ok(Nil)
    policy.ScratchPath(root) -> path(root)
  })
  use Nil <- result.try(case base.network {
    policy.NetworkOff | policy.NetworkFull -> Ok(Nil)
    policy.NetworkProxy(allow, proxy) -> {
      use Nil <- result.try(count(allow, 128))
      use Nil <- result.try(texts(allow))
      text_bound(proxy)
    }
  })
  let roots =
    list.flatten([
      base.writable_roots,
      base.readable_roots,
      base.protected,
      base.env_allow,
      list.map(base.mounts, fn(mount) { mount.path }),
    ])
  let scratch_texts = case base.scratch {
    policy.ScratchTmpfs -> []
    policy.ScratchPath(root) -> [root]
  }
  let network_texts = case base.network {
    policy.NetworkOff | policy.NetworkFull -> []
    policy.NetworkProxy(allow, proxy) -> [proxy, ..allow]
  }
  let bytes =
    list.fold(
      list.flatten([roots, scratch_texts, network_texts]),
      0,
      fn(bytes, text) { bytes + string.byte_size(text) },
    )
  use <- bool.guard(bytes > max_metadata_bytes, Error(BoundExceeded))
  policy.validate(base) |> result.replace_error(InvalidData)
}

fn texts(values: List(String)) -> Result(Nil, InputError) {
  list.try_each(values, text_bound)
}

fn path(text: String) -> Result(Nil, InputError) {
  use Nil <- result.try(text_bound(text))
  case text {
    "/" -> Ok(Nil)
    "/" <> rest ->
      bool.guard(
        list.any(string.split(rest, "/"), fn(component) {
          component == "" || component == "." || component == ".."
        }),
        Error(InvalidData),
        fn() { Ok(Nil) },
      )
    _ -> Error(InvalidData)
  }
}

// This tree has already bounded lists/strings and a fixed schema depth. Its
// measurement prevents allocation of a large encoded metadata buffer first.
fn measure(
  value: mp.MsgPackValue,
  budget: WireBudget,
) -> Result(WireBudget, InputError) {
  use budget <- result.try(charge(budget, 0, 1))
  case value {
    mp.StringValue(text) -> {
      let size = string.byte_size(text)
      let header = case size {
        _ if size < 32 -> 1
        _ if size < 256 -> 2
        _ -> 3
      }
      charge(budget, size + header, 0)
    }
    mp.IntValue(_) | mp.BoolValue(_) -> {
      use bits <- result.try(
        mp.encode(value) |> result.replace_error(InvalidEncoding),
      )
      charge(budget, bit_array.byte_size(bits), 0)
    }
    mp.ArrayValue(items) -> {
      use budget <- result.try(charge(
        budget,
        container_header(list.length(items)),
        0,
      ))
      list.try_fold(items, budget, fn(budget, item) { measure(item, budget) })
    }
    mp.MapValue(items) -> {
      use budget <- result.try(charge(
        budget,
        container_header(list.length(items)),
        0,
      ))
      list.try_fold(items, budget, fn(budget, pair) {
        use budget <- result.try(measure(pair.0, budget))
        measure(pair.1, budget)
      })
    }
    mp.NilValue | mp.FloatValue(_) | mp.BinaryValue(_) -> Error(InvalidEncoding)
  }
}

fn container_header(count: Int) -> Int {
  case count < 16 {
    True -> 1
    False -> 3
  }
}

fn charge(
  budget: WireBudget,
  bytes: Int,
  nodes: Int,
) -> Result(WireBudget, InputError) {
  case
    budget.bytes + bytes <= max_metadata_bytes && budget.nodes + nodes <= 2048
  {
    True -> Ok(WireBudget(budget.bytes + bytes, budget.nodes + nodes))
    False -> Error(BoundExceeded)
  }
}

// Trusted provisioning may have more catalogue entries than one request selects.
// Each entry must still be selectable by the concrete wire profile.
fn catalogue_check(
  items: List(#(String, String)),
  seen: set.Set(String),
) -> Result(Nil, InputError) {
  case items {
    [] -> Ok(Nil)
    [#(name, source), ..rest] -> {
      use Nil <- result.try(module_name(name, seen))
      use _ <- result.try(source_size(source, 0))
      catalogue_check(rest, set.insert(seen, name))
    }
  }
}

fn descriptor_names(
  items: List(#(String, Int)),
  seen: set.Set(String),
) -> Result(Nil, InputError) {
  case items {
    [] -> Ok(Nil)
    [#(name, _), ..rest] -> {
      use Nil <- result.try(module_name(name, seen))
      descriptor_names(rest, set.insert(seen, name))
    }
  }
}

fn module_name(name: String, seen: set.Set(String)) -> Result(Nil, InputError) {
  use Nil <- result.try(text_bound(name))
  bool.guard(
    !{
      vet_policy.is_legal_module_name(name)
      && string.starts_with(name, "cap/mcp/")
      && !set.contains(seen, name)
    },
    Error(InvalidData),
    fn() { Ok(Nil) },
  )
}
