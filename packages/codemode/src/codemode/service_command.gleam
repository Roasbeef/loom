//// Pure expectations for the command beneath an admitted physical service.
////
//// Owner and executor independently combine pinned enrollment, retained input
//// and exact Ready locations with the same closed native templates. A bounded
//// peer offer is only syntax; `matches` compares it with this complete derived
//// expectation before clearance. No peer argv, policy or path becomes authority.
////
//// The caller supplies one positive whole native second after durable Ready.
//// These constructors check the original stage/policy ceiling, not remaining
//// live authority. The assembled caller still derives its serial control bound,
//// checks the original deadline and retains this exact offer in CommandRef
//// custody. Construction creates no claim, clearance, native UUID or token and
//// performs no clock, filesystem or process access. `toolchains` preserves the
//// enrolled order; `host_scratch` names only an actually enrolled host scratch.

import broker/command as offer
import broker/enrollment
import broker/policy
import codemode/build
import codemode/compile
import codemode/native_command
import codemode/service_input as input
import codemode/service_resources as resources
import core/command
import core/workspace
import gleam/bool
import gleam/list
import gleam/result

/// Exact construction evidence, without original or remaining execution authority.
pub opaque type ExpectedCommand {
  ExpectedCommand(
    /// All command/reference/mapping fields derived from admitted original facts.
    proposal: offer.CommandOffer,
    /// Positive finite wall selected by the caller after durable preparation.
    wall_s: Int,
  )
}

/// Refusal before any physical authority or command offer is issued.
pub type Error {
  /// Input, full Ready key, producer, enrollment or host scratch differs.
  AssociationMismatch

  /// No positive whole native second fits the original stage/policy ceiling.
  InvalidWall

  /// The derived command exceeds existing bounded offer or policy requirements.
  InvalidCommand(reason: offer.Error)
}

/// Derives the fixed compiler offer under its complete original Compile key.
/// Ready must match that key and the pinned enrollment's literal allocation.
/// The selected wall fits floor(original build timeout / 1000), tightened by
/// any positive original policy wall. A subsecond ceiling therefore refuses.
/// The shared compiler template retains original mounts and untouched policy
/// dimensions while pinning allocation access, network-off, PATH and TMPDIR.
///
/// ## Examples
///
/// `compile(enrolled, admitted, locations, 0)` refuses before making an offer.
pub fn compile(
  enrolled: enrollment.SessionEnrollment,
  admitted: input.AdmittedCompile,
  locations: resources.CompileLocations,
  selected_wall_s: Int,
) -> Result(ExpectedCommand, Error) {
  let #(service, original, _) = input.admitted_compile(admitted)
  let facts = input.compile_facts(original)
  let #(ready_service, root) = resources.compile_fields(locations)
  use <- bool.guard(service != ready_service, Error(AssociationMismatch))
  use Nil <- result.try(
    enrollment.matches(enrolled, facts.enrolled)
    |> result.replace_error(AssociationMismatch),
  )
  use _ <- result.try(
    resources.admit_compile_locations(enrolled, service, root)
    |> result.replace_error(AssociationMismatch),
  )
  use Nil <- result.try(finite_wall(selected_wall_s, facts.policy_seed))
  use <- bool.guard(
    selected_wall_s > facts.build_timeout_ms / 1000,
    Error(InvalidWall),
  )

  // Only the selected wall changes before the shared template takes ownership
  // of its explicit compiler access and environment dimensions.
  let code = enrollment.code_mode_facts(enrolled)
  let base = with_wall(facts.policy_seed, selected_wall_s)
  let data =
    native_command.compiler(
      native_command.Compiler(
        executable: code.gleam_path,
        root:,
        base:,
        toolchain_roots: code.toolchain_roots,
        env: [#("PATH", code.build_path)],
      ),
    )
  use scratch <- result.try(host_scratch(enrolled, data.requirements))
  let mappings =
    list.unique(list.append(
      [
        offer.RegionMapping(offer.Build, root),
        offer.RegionMapping(offer.Scratch, root <> "/tmp"),
        ..toolchains(code.toolchain_roots)
      ],
      scratch,
    ))
  use ref <- result.try(
    command.command_ref(service, command.CompileCommand)
    |> result.replace_error(AssociationMismatch),
  )
  use proposal <- result.try(
    offer.offer(ref, mappings, data) |> result.map_error(InvalidCommand),
  )
  Ok(ExpectedCommand(proposal, selected_wall_s))
}

/// Derives the fixed satellite offer without presenting a remote artifact locally.
/// Launch and producer keys must equal the admitted original input and Ready.
/// The producer allocation determines beam access; validated relative cwd is
/// appended literally beneath the enrolled workspace root. The shared template
/// pins channel handles, host mounts and network-off, retaining other dimensions.
/// Zero original policy wall is an unbounded ceiling, never an infinite offer.
///
/// ## Examples
///
/// `launch(enrolled, admitted, foreign_resources, 1)` refuses on full-key drift.
pub fn launch(
  enrolled: enrollment.SessionEnrollment,
  admitted: input.AdmittedLaunch,
  ready: resources.LaunchResources,
  selected_wall_s: Int,
) -> Result(ExpectedCommand, Error) {
  let #(service, original) = input.admitted_launch(admitted)
  let facts = input.launch_facts(original)
  let #(ready_service, producer) = resources.launch_keys(ready)
  use <- bool.guard(
    service != ready_service || facts.compiled_by != producer,
    Error(AssociationMismatch),
  )
  use Nil <- result.try(
    enrollment.matches(enrolled, facts.enrolled)
    |> result.replace_error(AssociationMismatch),
  )
  let #(directory, socket, token) = resources.launch_paths(ready)
  use _ <- result.try(
    resources.admit_launch_resources(
      enrolled,
      service,
      producer,
      directory,
      socket,
      token,
    )
    |> result.replace_error(AssociationMismatch),
  )
  use root <- result.try(
    enrollment.compile_path(enrolled, producer)
    |> result.replace_error(AssociationMismatch),
  )
  use Nil <- result.try(finite_wall(selected_wall_s, facts.policy_seed))

  // Admission already bound every remote artifact field to retained successful
  // Compile evidence. No local Artifact or owner filesystem resolution is needed.
  let code = enrollment.code_mode_facts(enrolled)
  let beams = root <> "/" <> build.beam_directory
  let access =
    native_command.NodeAccess(
      beam_dir: beams,
      socket_path: socket,
      token_path: token,
      base: facts.policy_seed,
      mounts: code.host_mounts,
      env: facts.env,
      wall_s: selected_wall_s,
    )
  let data =
    offer.CommandData(
      argv: native_command.node_argv(code.erl_path, beams, compile.entry_module),
      env: native_command.node_env(socket, token, facts.env),
      cwd: case workspace.path_string(facts.cwd) {
        "." -> code.workspace_root
        relative -> code.workspace_root <> "/" <> relative
      },
      requirements: native_command.node_requirements(access),
    )
  use scratch <- result.try(host_scratch(enrolled, data.requirements))
  let mappings =
    list.append(
      [
        offer.RegionMapping(offer.Workspace, code.workspace_root),
        offer.RegionMapping(offer.Artifact, root),
        offer.RegionMapping(offer.Channel, directory),
        ..toolchains(code.toolchain_roots)
      ],
      scratch,
    )
  use ref <- result.try(
    command.command_ref(service, command.SatelliteCommand)
    |> result.replace_error(AssociationMismatch),
  )
  use proposal <- result.try(
    offer.offer(ref, mappings, data) |> result.map_error(InvalidCommand),
  )
  Ok(ExpectedCommand(proposal, selected_wall_s))
}

/// Returns the complete exact offer for the existing CommandRef custody slot.
/// This value carries no clearance and grants no execution authority.
///
/// ## Examples
///
/// `matches(expected, offer(expected)) == Ok(Nil)`.
pub fn offer(expected: ExpectedCommand) -> offer.CommandOffer {
  expected.proposal
}

/// Returns the selected finite wall without reading or renewing a deadline.
///
/// ## Examples
///
/// `wall_s(expected)` returns the same whole seconds supplied after Ready.
pub fn wall_s(expected: ExpectedCommand) -> Int {
  expected.wall_s
}

/// Refuses any difference in original reference, ordered mappings or full data.
/// A syntactically valid received offer cannot substitute one generated field.
///
/// ## Examples
///
/// `matches(expected, changed_argv_offer)` returns `Error(AssociationMismatch)`.
pub fn matches(
  expected: ExpectedCommand,
  received: offer.CommandOffer,
) -> Result(Nil, Error) {
  bool.guard(received != expected.proposal, Error(AssociationMismatch), fn() {
    Ok(Nil)
  })
}

fn finite_wall(wall_s: Int, base: policy.SandboxPolicy) -> Result(Nil, Error) {
  bool.guard(
    wall_s < 1 || { base.limits.wall_s > 0 && wall_s > base.limits.wall_s },
    Error(InvalidWall),
    fn() { Ok(Nil) },
  )
}

fn with_wall(base: policy.SandboxPolicy, wall_s: Int) -> policy.SandboxPolicy {
  policy.SandboxPolicy(..base, limits: policy.Limits(..base.limits, wall_s:))
}

fn toolchains(roots: List(String)) -> List(offer.RegionMapping) {
  list.map(roots, fn(root) { offer.RegionMapping(offer.Toolchain, root) })
}

fn host_scratch(
  enrolled: enrollment.SessionEnrollment,
  requirements: policy.SandboxPolicy,
) -> Result(List(offer.RegionMapping), Error) {
  let pinned = enrollment.native_facts(enrolled).ceiling.scratch
  case requirements.scratch {
    policy.ScratchTmpfs -> Ok([])
    policy.ScratchPath(path) -> {
      // RefuseNarrowed cannot silently substitute tmpfs for a foreign literal
      // host scratch. Only the enrolled identical region becomes a mapping.
      use <- bool.guard(
        requirements.scratch != pinned,
        Error(AssociationMismatch),
      )
      Ok([offer.RegionMapping(offer.Scratch, path)])
    }
  }
}
