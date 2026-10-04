//// Exact per-session provisioning for registered physical command services.
////
//// Trusted assembly pins `new` once for the persisted core workspace Scope.
//// `matches` compares every retained fact, including both digest claims; a
//// current description cannot replace that pin under the same authority epochs.
//// These claims are authenticated by assembly, not recomputed or proved here.
//// The contract digest pins the negotiated source/prelude/seed contract; concrete
//// source inputs and their association still belong to later physical assembly.
////
//// Native working roots are an administrative ceiling, not ordinary workspace
//// authority. The latter is concretely the CodeModeFacts workspace_root. Build
//// and channel areas must be disjoint from it and each other, while seed,
//// toolchains and PATH directories admit no writable authority in this snapshot.
//// Assembly must canonicalize these paths on the executor before construction:
//// pure lexical validation cannot detect symlinks or later filesystem races.
////
//// `encode` uses the full nested policy codec after bounded plain-value checks.
//// `decode` preflights raw framing before allocating a value tree, reconstructs
//// through `new`, and demands canonical bytes. No callback, grant, token or
//// deadline belongs here. `compile_path` and `launch_paths` derive only original
//// UUID components, after exact scope, registration, contract and role checks.
//// `covered` compares region components, `strings` preserves exact field order,
//// and `read_mounts` totally decodes the closed host-mount list.

import broker/exec
import broker/policy
import core/bounded_msgpack
import core/command
import core/ids
import core/msgpack as mp
import core/workspace
import gleam/bool
import gleam/list
import gleam/result
import gleam/string

/// Executor-local native facts, described without the canonicalizer callback.
pub type NativeFacts {
  NativeFacts(
    /// The persisted session and both administrative epochs.
    scope: workspace.Scope,
    /// Broad canonical roots in which native commands may start.
    working_roots: List(String),
    /// Complete administrative policy, including mounts and protected paths.
    ceiling: policy.SandboxPolicy,
    /// Administrative kernel enforcement requirement.
    demand: exec.EnforcementDemand,
  )
}

/// Concrete configured command locations, before any physical preparation.
pub type CodeModeFacts {
  CodeModeFacts(
    /// Ordinary workspace jobs' writable authority.
    workspace_root: String,
    /// Compile UUID directories are allocated immediately beneath this root.
    build_area: String,
    /// Launch UUID directories are allocated immediately beneath this root.
    channel_area: String,
    /// Canonical immutable compiler executable.
    gleam_path: String,
    /// Canonical immutable BEAM executable.
    erl_path: String,
    /// Canonical immutable offline package seed.
    seed_root: String,
    /// Canonical immutable toolchain regions.
    toolchain_roots: List(String),
    /// Exact read-only binds used by command templates.
    host_mounts: List(policy.Mount),
    /// Exact colon-separated PATH, with unique canonical absolute directories.
    build_path: String,
  )
}

/// Bounded exact enrollment; construction establishes the location invariants.
pub opaque type SessionEnrollment {
  SessionEnrollment(
    /// Exact native description pinned by trusted administration.
    native: NativeFacts,
    /// Exact negotiated physical layout and toolchain configuration.
    code: CodeModeFacts,
    /// Authenticated claim using core command's lowercase SHA-256 spelling.
    registration: String,
    /// Authenticated negotiated contract claim, never a recomputed proof.
    contract: String,
  )
}

/// A fixed refusal that never retains hostile metadata.
pub type Error {
  /// Shape, bound, policy, spelling or isolation checks refused construction.
  Invalid

  /// Exact enrollment or service binding differs from the retained pin.
  Mismatch
}

/// Constructs one exact snapshot after bounding plain fields before encoding.
/// Paths are executor-canonicalized claims; this function checks their lexical
/// spelling and authority separation without touching a filesystem.
///
/// ## Examples
///
/// `new(native, code, registration, contract)` retains the full nested policy.
pub fn new(
  native: NativeFacts,
  code: CodeModeFacts,
  registration: String,
  contract: String,
) -> Result(SessionEnrollment, Error) {
  use Nil <- result.try(
    command.digest(registration) |> result.replace_error(Invalid),
  )
  use Nil <- result.try(
    command.digest(contract) |> result.replace_error(Invalid),
  )
  use Nil <- result.try(bound_native(native))
  use Nil <- result.try(bound_code(code))
  use Nil <- result.try(
    policy.validate(native.ceiling) |> result.replace_error(Invalid),
  )
  use Nil <- result.try(isolate(native, code))

  // The text budget leaves ample room for the fixed tags, map keys and nodes.
  // It is checked before building the encoded tree, including repeated fields.
  let texts = list.flatten([native_texts(native), code_texts(code)])
  let bytes =
    list.fold(texts, 128, fn(total, text) { total + string.byte_size(text) })
  use <- bool.guard(bytes > 196_608, Error(Invalid))
  Ok(SessionEnrollment(native:, code:, registration:, contract:))
}

/// Returns the exact native facts, without operational capabilities.
///
/// ## Examples
///
/// `native_facts(enrolled).scope` retains both original epochs.
pub fn native_facts(enrolled: SessionEnrollment) -> NativeFacts {
  enrolled.native
}

/// Returns the exact physical configuration pinned by enrollment.
///
/// ## Examples
///
/// `code_mode_facts(enrolled).seed_root` is immutable to these jobs.
pub fn code_mode_facts(enrolled: SessionEnrollment) -> CodeModeFacts {
  enrolled.code
}

/// Returns original registration and negotiated contract digest claims.
///
/// ## Examples
///
/// `digests(enrolled)` performs no hashing or authentication.
pub fn digests(enrolled: SessionEnrollment) -> #(String, String) {
  #(enrolled.registration, enrolled.contract)
}

/// Refuses drift in any field, even beneath an unchanged Scope or digest claim.
///
/// ## Examples
///
/// `matches(retained, advertised)` succeeds only for exact snapshot equality.
pub fn matches(
  retained: SessionEnrollment,
  advertised: SessionEnrollment,
) -> Result(Nil, Error) {
  case retained == advertised {
    True -> Ok(Nil)
    False -> Error(Mismatch)
  }
}

/// Encodes the bounded snapshot with the complete nested policy.
///
/// ## Examples
///
/// `decode(encode(enrolled) |> result.unwrap(<<>>)) == Ok(enrolled)`.
pub fn encode(enrolled: SessionEnrollment) -> Result(BitArray, Error) {
  use bytes <- result.try(
    mp.encode(to_value(enrolled)) |> result.replace_error(Invalid),
  )
  use _ <- result.try(
    bounded_msgpack.decode(bytes) |> result.replace_error(Invalid),
  )
  Ok(bytes)
}

/// Rejects hostile framing before allocation, then requires canonical encoding.
///
/// ## Examples
///
/// `decode(<<0xdd, 0xff, 0xff, 0xff, 0xff>>) == Error(Invalid)`.
pub fn decode(bytes: BitArray) -> Result(SessionEnrollment, Error) {
  use value <- result.try(
    bounded_msgpack.decode(bytes) |> result.replace_error(Invalid),
  )
  use enrolled <- result.try(from_value(value))
  use canonical <- result.try(encode(enrolled))
  case canonical == bytes {
    True -> Ok(enrolled)
    False -> Error(Invalid)
  }
}

/// Derives the compile allocation from the complete original service key.
///
/// ## Examples
///
/// A LaunchService passed to `compile_path` returns `Error(Mismatch)`.
pub fn compile_path(
  enrolled: SessionEnrollment,
  service: command.ServiceKey,
) -> Result(String, Error) {
  use Nil <- result.try(bind_service(enrolled, service, command.CompileService))
  Ok(
    enrolled.code.build_area
    <> "/"
    <> ids.entry_id_to_string(command.request_id(service)),
  )
}

/// Derives the launch directory, fixed socket basename and private token path.
/// The socket limit is 100 UTF-8 bytes, including the full original UUID.
///
/// ## Examples
///
/// `launch_paths(enrolled, launch)` returns `#(directory, directory <> "/s", directory <> "/cap-token")`.
pub fn launch_paths(
  enrolled: SessionEnrollment,
  service: command.ServiceKey,
) -> Result(#(String, String, String), Error) {
  use Nil <- result.try(bind_service(enrolled, service, command.LaunchService))
  let directory =
    enrolled.code.channel_area
    <> "/"
    <> ids.entry_id_to_string(command.request_id(service))
  let socket = directory <> "/s"
  use <- bool.guard(string.byte_size(socket) > 100, Error(Invalid))
  Ok(#(directory, socket, directory <> "/cap-token"))
}

fn bind_service(
  enrolled: SessionEnrollment,
  service: command.ServiceKey,
  role: command.ServiceRole,
) -> Result(Nil, Error) {
  let #(scope, _, _) = command.coordinates(service)
  let #(_, registration, contract) = command.digests(service)
  case
    scope == enrolled.native.scope
    && command.service_role(service) == role
    && registration == enrolled.registration
    && contract == enrolled.contract
  {
    True -> Ok(Nil)
    False -> Error(Mismatch)
  }
}

fn bound_native(native: NativeFacts) -> Result(Nil, Error) {
  let ceiling = native.ceiling
  let limits = ceiling.limits
  use <- bool.guard(
    !list.all(
      [
        limits.cpu_s,
        limits.wall_s,
        limits.mem_bytes,
        limits.pids,
        limits.fsize_bytes,
        limits.output_bytes,
      ],
      fn(n) { n >= 0 && n <= 9_223_372_036_854_775_807 },
    ),
    Error(Invalid),
  )
  use Nil <- result.try(paths(native.working_roots, 16))
  use <- bool.guard(native.working_roots == [], Error(Invalid))
  use Nil <- result.try(paths(ceiling.writable_roots, 32))
  use Nil <- result.try(paths(ceiling.readable_roots, 32))
  use Nil <- result.try(paths(ceiling.protected, 32))
  use Nil <- result.try(mounts(ceiling.mounts))
  use Nil <- result.try(texts(ceiling.env_allow, 64, 256))
  use Nil <- result.try(list.try_each(ceiling.env_allow, environment_name))
  use Nil <- result.try(list.try_each(scratch_paths(ceiling), absolute))
  case ceiling.network {
    policy.NetworkOff | policy.NetworkFull -> Ok(Nil)
    policy.NetworkProxy(allow, proxy) -> {
      use Nil <- result.try(texts(allow, 16, 1024))
      texts([proxy], 1, 4096)
    }
  }
}

fn bound_code(code: CodeModeFacts) -> Result(Nil, Error) {
  use Nil <- result.try(list.try_each(
    [
      code.workspace_root, code.build_area, code.channel_area, code.gleam_path,
      code.erl_path, code.seed_root,
    ],
    absolute,
  ))
  use <- bool.guard(
    string.byte_size(code.build_area) > 4059
      || string.byte_size(code.channel_area) > 61,
    Error(Invalid),
  )
  use Nil <- result.try(paths(code.toolchain_roots, 16))
  use <- bool.guard(code.toolchain_roots == [], Error(Invalid))
  use Nil <- result.try(mounts(code.host_mounts))

  // Split PATH only after its byte bound; empty, relative and duplicate entries
  // would change command lookup and cannot be normalized into this pin.
  use <- bool.guard(string.byte_size(code.build_path) > 8192, Error(Invalid))
  paths(string.split(code.build_path, ":"), 16)
}

fn isolate(native: NativeFacts, code: CodeModeFacts) -> Result(Nil, Error) {
  let regions = [code.workspace_root, code.build_area, code.channel_area]
  use <- bool.guard(!disjoint(regions), Error(Invalid))
  use <- bool.guard(
    !list.all(regions, fn(path) {
      covered(native.working_roots, path)
      && covered(native.ceiling.writable_roots, path)
    }),
    Error(Invalid),
  )
  use <- bool.guard(
    list.any([code.build_area, code.channel_area], fn(path) {
      list.any(native.ceiling.protected, overlaps(path, _))
    }),
    Error(Invalid),
  )

  // A broad working root remains legal. Writable roots, scratch and RW mounts
  // carry authority instead, so none may overlap immutable inputs or PATH.
  let immutable = [
    code.seed_root,
    ..list.append(code.toolchain_roots, string.split(code.build_path, ":"))
  ]
  let writable =
    list.flatten([
      native.ceiling.writable_roots,
      scratch_paths(native.ceiling),
      native.ceiling.mounts
        |> list.filter(fn(m) { m.access == policy.MountReadWrite })
        |> list.map(fn(m) { m.path }),
    ])
  use <- bool.guard(
    list.any(immutable, fn(path) {
      list.any(list.append(regions, writable), overlaps(path, _))
      || !covered(native.ceiling.readable_roots, path)
    }),
    Error(Invalid),
  )
  use <- bool.guard(
    !covered(code.toolchain_roots, code.gleam_path)
      || !covered(code.toolchain_roots, code.erl_path),
    Error(Invalid),
  )
  use <- bool.guard(
    !list.all(code.host_mounts, fn(m) {
      m.access == policy.MountReadOnly
      && list.contains(native.ceiling.mounts, m)
      && !list.any(regions, overlaps(m.path, _))
    }),
    Error(Invalid),
  )
  Ok(Nil)
}

fn paths(values: List(String), maximum: Int) -> Result(Nil, Error) {
  use Nil <- result.try(texts(values, maximum, 4096))
  list.try_each(values, absolute)
}

fn texts(values: List(String), maximum: Int, size: Int) -> Result(Nil, Error) {
  // Stop at the first item beyond the finite cap, before uniqueness or mapping.
  use Nil <- result.try(count(values, maximum))
  use <- bool.guard(
    !list.all(values, fn(text) {
      string.byte_size(text) > 0 && string.byte_size(text) <= size
    }),
    Error(Invalid),
  )
  case list.unique(values) == values {
    True -> Ok(Nil)
    False -> Error(Invalid)
  }
}

fn count(values: List(a), remaining: Int) -> Result(Nil, Error) {
  case values, remaining {
    [], _ -> Ok(Nil)
    [_, ..], 0 -> Error(Invalid)
    [_, ..rest], _ -> count(rest, remaining - 1)
  }
}

fn absolute(path: String) -> Result(Nil, Error) {
  use <- bool.guard(string.byte_size(path) > 4096, Error(Invalid))
  case path {
    "/" -> Ok(Nil)
    "/" <> relative -> {
      use <- bool.guard(relative == ".", Error(Invalid))
      workspace.relative_path(relative)
      |> result.replace(Nil)
      |> result.replace_error(Invalid)
    }
    _ -> Error(Invalid)
  }
}

fn environment_name(name: String) -> Result(Nil, Error) {
  case <<name:utf8>> {
    <<first, rest:bits>>
      if first >= 65 && first <= 90 || first >= 97 && first <= 122 || first == 95
    -> environment_tail(rest)
    _ -> Error(Invalid)
  }
}

fn environment_tail(bytes: BitArray) -> Result(Nil, Error) {
  case bytes {
    <<>> -> Ok(Nil)
    <<byte, rest:bits>>
      if byte >= 65
      && byte <= 90
      || byte >= 97
      && byte <= 122
      || byte >= 48
      && byte <= 57
      || byte == 95
    -> environment_tail(rest)
    _ -> Error(Invalid)
  }
}

fn mounts(values: List(policy.Mount)) -> Result(Nil, Error) {
  use Nil <- result.try(count(values, 16))
  paths(list.map(values, fn(m) { m.path }), 16)
}

fn scratch_paths(ceiling: policy.SandboxPolicy) -> List(String) {
  case ceiling.scratch {
    policy.ScratchTmpfs -> []
    policy.ScratchPath(path) -> [path]
  }
}

fn covered(roots: List(String), path: String) -> Bool {
  list.any(roots, policy.covers(_, path))
}

fn overlaps(a: String, b: String) -> Bool {
  policy.covers(a, b) || policy.covers(b, a)
}

fn disjoint(paths: List(String)) -> Bool {
  case paths {
    [] -> True
    [path, ..rest] -> !list.any(rest, overlaps(path, _)) && disjoint(rest)
  }
}

fn native_texts(native: NativeFacts) -> List(String) {
  let p = native.ceiling
  list.flatten([
    native.working_roots,
    p.writable_roots,
    p.readable_roots,
    p.protected,
    p.env_allow,
    scratch_paths(p),
    list.map(p.mounts, fn(m) { m.path }),
    case p.network {
      policy.NetworkOff | policy.NetworkFull -> []
      policy.NetworkProxy(allow, proxy) -> [proxy, ..allow]
    },
  ])
}

fn code_texts(code: CodeModeFacts) -> List(String) {
  list.flatten([
    [
      code.workspace_root,
      code.build_area,
      code.channel_area,
      code.gleam_path,
      code.erl_path,
      code.seed_root,
      code.build_path,
    ],
    code.toolchain_roots,
    list.map(code.host_mounts, fn(m) { m.path }),
  ])
}

fn to_value(enrolled: SessionEnrollment) -> mp.MsgPackValue {
  let native = enrolled.native
  let code = enrolled.code
  let #(session, binding) = workspace.scope_fields(native.scope)
  let #(selector, workspace_epoch, session_epoch) =
    workspace.binding_fields(binding)
  let #(executor, name) = workspace.selector_fields(selector)
  mp.ArrayValue([
    mp.IntValue(1),
    mp.ArrayValue([
      mp.StringValue(ids.session_id_to_string(session)),
      mp.StringValue(name),
      mp.StringValue(executor),
      mp.IntValue(session_epoch),
      mp.IntValue(workspace_epoch),
    ]),
    strings(native.working_roots),
    policy.to_msgpack(native.ceiling),
    mp.IntValue(case native.demand {
      exec.FullEnforcement -> 0
      exec.BestEffort -> 1
      exec.PlatformEnforcement -> 2
    }),
    mp.ArrayValue([
      mp.StringValue(code.workspace_root),
      mp.StringValue(code.build_area),
      mp.StringValue(code.channel_area),
      mp.StringValue(code.gleam_path),
      mp.StringValue(code.erl_path),
      mp.StringValue(code.seed_root),
      strings(code.toolchain_roots),
      mp.ArrayValue(list.map(code.host_mounts, mount_value)),
      mp.StringValue(code.build_path),
    ]),
    mp.StringValue(enrolled.registration),
    mp.StringValue(enrolled.contract),
  ])
}

fn strings(values: List(String)) -> mp.MsgPackValue {
  mp.ArrayValue(list.map(values, mp.StringValue))
}

fn mount_value(m: policy.Mount) -> mp.MsgPackValue {
  mp.ArrayValue([
    mp.StringValue(m.path),
    mp.IntValue(case m.access {
      policy.MountReadOnly -> 0
      policy.MountReadWrite -> 1
    }),
    mp.IntValue(case m.requirement {
      policy.MountRequired -> 0
      policy.MountOptional -> 1
    }),
  ])
}

fn from_value(value: mp.MsgPackValue) -> Result(SessionEnrollment, Error) {
  case value {
    mp.ArrayValue([
      mp.IntValue(1),
      scope_value,
      roots_value,
      ceiling_value,
      demand_value,
      code_value,
      mp.StringValue(registration),
      mp.StringValue(contract),
    ]) -> {
      use scope <- result.try(read_scope(scope_value))
      use working_roots <- result.try(read_strings(roots_value))
      use ceiling <- result.try(
        policy.from_msgpack(ceiling_value) |> result.replace_error(Invalid),
      )
      use demand <- result.try(read_demand(demand_value))
      use code <- result.try(read_code(code_value))
      new(
        NativeFacts(scope:, working_roots:, ceiling:, demand:),
        code,
        registration,
        contract,
      )
    }
    _ -> Error(Invalid)
  }
}

fn read_scope(value: mp.MsgPackValue) -> Result(workspace.Scope, Error) {
  case value {
    mp.ArrayValue([
      mp.StringValue(session),
      mp.StringValue(name),
      mp.StringValue(executor),
      mp.IntValue(session_epoch),
      mp.IntValue(workspace_epoch),
    ]) ->
      workspace.scope_from_fields(
        session,
        name,
        executor,
        session_epoch,
        workspace_epoch,
      )
      |> result.replace_error(Invalid)
    _ -> Error(Invalid)
  }
}

fn read_demand(
  value: mp.MsgPackValue,
) -> Result(exec.EnforcementDemand, Error) {
  case value {
    mp.IntValue(0) -> Ok(exec.FullEnforcement)
    mp.IntValue(1) -> Ok(exec.BestEffort)
    mp.IntValue(2) -> Ok(exec.PlatformEnforcement)
    _ -> Error(Invalid)
  }
}

fn read_strings(value: mp.MsgPackValue) -> Result(List(String), Error) {
  case value {
    mp.ArrayValue(values) ->
      list.try_map(values, fn(v) {
        case v {
          mp.StringValue(text) -> Ok(text)
          mp.NilValue
          | mp.BoolValue(_)
          | mp.IntValue(_)
          | mp.FloatValue(_)
          | mp.BinaryValue(_)
          | mp.ArrayValue(_)
          | mp.MapValue(_) -> Error(Invalid)
        }
      })
    mp.NilValue
    | mp.BoolValue(_)
    | mp.IntValue(_)
    | mp.FloatValue(_)
    | mp.BinaryValue(_)
    | mp.StringValue(_)
    | mp.MapValue(_) -> Error(Invalid)
  }
}

fn read_code(value: mp.MsgPackValue) -> Result(CodeModeFacts, Error) {
  case value {
    mp.ArrayValue([
      mp.StringValue(workspace_root),
      mp.StringValue(build_area),
      mp.StringValue(channel_area),
      mp.StringValue(gleam_path),
      mp.StringValue(erl_path),
      mp.StringValue(seed_root),
      roots_value,
      mounts_value,
      mp.StringValue(build_path),
    ]) -> {
      use toolchain_roots <- result.try(read_strings(roots_value))
      use host_mounts <- result.try(read_mounts(mounts_value))
      Ok(CodeModeFacts(
        workspace_root:,
        build_area:,
        channel_area:,
        gleam_path:,
        erl_path:,
        seed_root:,
        toolchain_roots:,
        host_mounts:,
        build_path:,
      ))
    }
    _ -> Error(Invalid)
  }
}

fn read_mounts(value: mp.MsgPackValue) -> Result(List(policy.Mount), Error) {
  case value {
    mp.ArrayValue(values) -> list.try_map(values, read_mount)
    mp.NilValue
    | mp.BoolValue(_)
    | mp.IntValue(_)
    | mp.FloatValue(_)
    | mp.BinaryValue(_)
    | mp.StringValue(_)
    | mp.MapValue(_) -> Error(Invalid)
  }
}

fn read_mount(value: mp.MsgPackValue) -> Result(policy.Mount, Error) {
  case value {
    mp.ArrayValue([
      mp.StringValue(path),
      mp.IntValue(access),
      mp.IntValue(requirement),
    ]) -> {
      use access <- result.try(case access {
        0 -> Ok(policy.MountReadOnly)
        1 -> Ok(policy.MountReadWrite)
        _ -> Error(Invalid)
      })
      use requirement <- result.try(case requirement {
        0 -> Ok(policy.MountRequired)
        1 -> Ok(policy.MountOptional)
        _ -> Error(Invalid)
      })
      Ok(policy.Mount(path:, access:, requirement:))
    }
    _ -> Error(Invalid)
  }
}
