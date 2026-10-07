//// Executor-resident immutable deployment descriptors for protocol 077.
////
//// `load` totally decodes administration, checks actual canonical physical
//// placement, then freezes bounded descriptors. `describe` derives a real
//// session's registration and enrollment purely from those frozen facts.
//// It starts no helper, journal, service or generation. LSP declarations retain
//// their trusted home/cache recipes; full activation must join their actual
//// environment and session cache placement before granting fresh authority.
////
//// ## Flow
////
//// `load` → `parse` → `facts_row` → `code_row` freezes bounded administrative
//// facts, then `placement` checks real roots and `fingerprint` compares their
//// immutable commitment. `select` exposes only an exact installed Descriptor.
//// `describe` → `scoped_enrollment` derives the actual session's canonical
//// registration without probing. `fingerprints` is pure provisioning inspection
//// and cannot construct a usable Descriptor.

import broker/enrollment
import broker/exec
import broker/policy
import codemode/lsp_host/profile
import core/command
import core/ids
import core/json
import core/msgpack as mp
import core/workspace
import envoy
import executor/remote/distribution
import executor/remote/identity
import executor/remote/registration
import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/json as encoding
import gleam/list
import gleam/result
import gleam/string
import simplifile
import tom
import tools/fs

/// One validated immutable boot configuration, without runtime authority.
pub opaque type Table {
  /// Module-owned startup snapshot, never a live generation handle.
  Table(
    /// Finite membership configuration for this same validated boot.
    membership: distribution.Config,
    /// Canonical private options file protected from physical consumers.
    options: String,
    /// Actual checked helper and private executor state placement.
    settings: Settings,
    /// Unique immutable selector descriptions.
    descriptors: List(Descriptor),
  )
}

/// Trusted executor physical startup settings.
pub type Settings {
  Settings(
    /// Canonical regular executable for the native helper.
    helper: String,
    /// Explicit positive helper-pool capacity, at most 32.
    pool_size: Int,
    /// Existing canonical mode-private executor state directory.
    state_root: String,
  )
}

/// Frozen physical facts; construction is owned exclusively by `load`.
pub opaque type Descriptor {
  /// Constructed only after exact physical placement and digest checks.
  Descriptor(
    /// Complete immutable administrative native, code-mode and LSP facts.
    facts: Facts,
    /// Domain-separated canonical lowercase descriptor commitment.
    digest: String,
  )
}

type Facts {
  Facts(
    binding: workspace.RegisteredBinding,
    owner: String,
    owner_peer: String,
    local_node: String,
    first_generation: Int,
    working_roots: List(String),
    ceiling: policy.SandboxPolicy,
    code: enrollment.CodeModeFacts,
    contract: String,
    profiles: List(profile.LspServer),
  )
}

type Parsed {
  Parsed(
    membership: distribution.Config,
    options: String,
    settings: Settings,
    descriptors: List(#(Facts, String)),
  )
}

/// Closed startup refusals, without physical path or credential contents.
pub type DeploymentError {
  /// The source file cannot be read as a regular UTF-8 file.
  Unreadable

  /// Raw input exceeds eight MiB or descriptor content exceeds its envelope.
  TooLarge

  /// A strict field, bound, policy or administrative identity was refused.
  InvalidConfiguration

  /// An actual root or executable is absent, aliased or has the wrong type.
  InvalidPlacement

  /// Native or LSP authority intersects a protected physical region.
  ProtectedOverlap

  /// The supplied descriptor digest differs from the canonical immutable value.
  DescriptorMismatch

  /// No installed descriptor has the exact retained binding and digest.
  Unavailable
}

const max_bytes = 8_388_608

const template_session = "00000000-0000-7000-8000-000000000001"

/// Validates real physical placement before constructing any usable descriptor.
///
/// ## Examples
///
/// `load("/etc/loom-executor/deployment.toml")` starts no runtime processes.
pub fn load(path: String) -> Result(Table, DeploymentError) {
  use info <- result.try(
    simplifile.file_info(path) |> result.replace_error(Unreadable),
  )
  use <- bool.guard(
    simplifile.file_info_type(info) != simplifile.File,
    Error(Unreadable),
  )
  use <- bool.guard(info.size > max_bytes, Error(TooLarge))
  use text <- result.try(
    simplifile.read(path) |> result.replace_error(Unreadable),
  )
  use parsed <- result.try(parse(text))
  let protected = [
    parsed.options,
    parsed.settings.state_root,
    ..distribution.protected_paths(parsed.membership)
  ]
  use Nil <- result.try(list.try_each(
    distribution.protected_paths(parsed.membership),
    checked_file,
  ))
  use Nil <- result.try(checked_file(parsed.options))
  use Nil <- result.try(checked_executable(parsed.settings.helper))
  use Nil <- result.try(checked_private_directory(parsed.settings.state_root))

  // Configured digest equality follows complete canonical placement checks.
  use descriptors <- result.try(
    list.try_map(parsed.descriptors, fn(row) {
      use Nil <- result.try(placement(row.0, protected, parsed.settings.helper))
      use digest <- result.try(fingerprint(row.0))
      use <- bool.guard(digest != row.1, Error(DescriptorMismatch))
      Ok(Descriptor(row.0, digest))
    }),
  )
  Ok(Table(parsed.membership, parsed.options, parsed.settings, descriptors))
}

/// Computes immutable descriptor commitments for administrative provisioning.
/// This pure inspection returns no Table, Descriptor or authority handle.
///
/// ## Examples
///
/// `fingerprints(text)` lets an administrator pin canonical configuration bytes.
pub fn fingerprints(
  text: String,
) -> Result(List(#(workspace.RegisteredBinding, String)), DeploymentError) {
  use parsed <- result.try(parse(text))
  list.try_map(parsed.descriptors, fn(row) {
    use digest <- result.map(fingerprint(row.0))
    #(row.0.binding, digest)
  })
}

/// Projects exact membership settings shared by boot and runtime startup.
///
/// ## Examples
///
/// `membership(table)` supplies the same frozen descriptor table's membership.
pub fn membership(table: Table) -> #(distribution.Config, String) {
  #(table.membership, table.options)
}

/// Returns the checked helper, pool capacity and private state root.
///
/// ## Examples
///
/// `settings(table)` itself launches no helpers.
pub fn settings(table: Table) -> Settings {
  table.settings
}

/// Selects only exact retained binding and canonical descriptor digest.
///
/// ## Examples
///
/// `select(table, binding, digest)` refuses either authority epoch drift.
pub fn select(
  table: Table,
  binding: workspace.RegisteredBinding,
  digest: String,
) -> Result(Descriptor, DeploymentError) {
  list.find(table.descriptors, fn(row) {
    row.facts.binding == binding && row.digest == digest
  })
  |> result.replace_error(Unavailable)
}

/// Returns configured owner authentication and immutable generation policy input.
///
/// ## Examples
///
/// `descriptor_fields(descriptor)` carries no session or generation claim.
pub fn descriptor_fields(
  descriptor: Descriptor,
) -> #(workspace.RegisteredBinding, String, String, String, Int) {
  let facts = descriptor.facts
  #(
    facts.binding,
    facts.owner,
    facts.owner_peer,
    descriptor.digest,
    facts.first_generation,
  )
}

/// Returns approved declarations in their frozen sorted profile-label order.
/// Trusted home/cache recipes require the later physical adapter's exact join.
///
/// ## Examples
///
/// `lsp_profiles(descriptor)` preserves all sixteen accepted profiles.
pub fn lsp_profiles(descriptor: Descriptor) -> List(profile.LspServer) {
  descriptor.facts.profiles
}

/// Purely derives every scope-dependent digest from the actual session identity.
/// This neither probes the checkout nor constructs a live service registration.
///
/// ## Examples
///
/// `describe(descriptor, session)` changes the enrollment scope and registration.
pub fn describe(
  descriptor: Descriptor,
  session: ids.SessionId,
) -> Result(enrollment.SessionEnrollment, DeploymentError) {
  scoped_enrollment(descriptor.facts, session)
}

fn parse(text: String) -> Result(Parsed, DeploymentError) {
  use <- bool.guard(string.byte_size(text) > max_bytes, Error(TooLarge))
  use fields <- result.try(
    tom.parse(text) |> result.replace_error(InvalidConfiguration),
  )
  use Nil <- result.try(
    keys(fields, [
      "schema",
      "endpoint_lifetime",
      "owner",
      "local_node",
      "membership",
      "peers",
      "executor",
      "workspaces",
    ]),
  )
  use Nil <- result.try(exact_int(fields, "schema", 1))
  use Nil <- result.try(exact_text(
    fields,
    "endpoint_lifetime",
    "retired_slots_v1",
  ))
  use owner <- result.try(text_field(fields, "owner"))
  use _ <- result.try(
    workspace.selector(owner, owner)
    |> result.replace_error(InvalidConfiguration),
  )
  use local <- result.try(text_field(fields, "local_node"))
  use files <- result.try(table_field(fields, "membership"))
  use Nil <- result.try(
    keys(files, ["ca", "certificate", "key", "cookie", "options"]),
  )
  use ca <- result.try(path_field(files, "ca"))
  use certificate <- result.try(path_field(files, "certificate"))
  use key <- result.try(path_field(files, "key"))
  use cookie <- result.try(path_field(files, "cookie"))
  use options <- result.try(path_field(files, "options"))
  use <- bool.guard(
    list.length(list.unique([ca, certificate, key, cookie, options])) != 5,
    Error(InvalidConfiguration),
  )
  use peers <- result.try(rows_field(fields, "peers", 1, 32))
  use peers <- result.try(list.try_map(peers, peer_row))
  use membership <- result.try(
    distribution.configure(
      local,
      peers,
      distribution.CredentialFiles(ca:, certificate:, key:, cookie:),
    )
    |> result.replace_error(InvalidConfiguration),
  )

  // A descriptor names its owner peer explicitly; the reverse route is not implied.
  use settings_fields <- result.try(table_field(fields, "executor"))
  use settings <- result.try(settings_row(settings_fields))
  use rows <- result.try(rows_field(fields, "workspaces", 1, 32))
  use descriptors <- result.try(
    list.try_map(rows, facts_row(
      _,
      owner,
      local,
      list.map(peers, fn(peer) { peer.0 }),
    )),
  )
  let selectors =
    list.map(descriptors, fn(row) { workspace.binding_fields(row.0.binding).0 })
  use <- bool.guard(
    list.length(list.unique(selectors)) != list.length(descriptors),
    Error(InvalidConfiguration),
  )
  Ok(Parsed(membership:, options:, settings:, descriptors:))
}

fn settings_row(
  fields: Dict(String, tom.Toml),
) -> Result(Settings, DeploymentError) {
  use Nil <- result.try(keys(fields, ["helper", "pool_size", "state_root"]))
  use helper <- result.try(path_field(fields, "helper"))
  use state_root <- result.try(path_field(fields, "state_root"))
  use pool_size <- result.try(int_field(fields, "pool_size"))
  use <- bool.guard(
    pool_size < 1 || pool_size > 32,
    Error(InvalidConfiguration),
  )
  Ok(Settings(helper:, pool_size:, state_root:))
}

fn facts_row(
  fields: Dict(String, tom.Toml),
  expected_owner: String,
  local_node: String,
  peers: List(String),
) -> Result(#(Facts, String), DeploymentError) {
  use Nil <- result.try(
    keys(fields, [
      "executor",
      "workspace",
      "owner",
      "owner_peer",
      "workspace_epoch",
      "session_epoch",
      "first_generation",
      "generation_policy",
      "descriptor_sha256",
      "compilation_contract_sha256",
      "native_working_roots",
      "native_demand",
      "native_ceiling",
      "code_mode",
      "lsp",
    ]),
  )
  use executor <- result.try(text_field(fields, "executor"))
  use name <- result.try(text_field(fields, "workspace"))
  use selector <- result.try(
    workspace.selector(executor, name)
    |> result.replace_error(InvalidConfiguration),
  )
  use workspace_epoch <- result.try(int_field(fields, "workspace_epoch"))
  use session_epoch <- result.try(int_field(fields, "session_epoch"))
  use binding <- result.try(
    workspace.registered_binding(selector, workspace_epoch, session_epoch)
    |> result.replace_error(InvalidConfiguration),
  )
  use owner <- result.try(text_field(fields, "owner"))
  use <- bool.guard(owner != expected_owner, Error(InvalidConfiguration))
  use owner_peer <- result.try(text_field(fields, "owner_peer"))
  use <- bool.guard(
    !list.contains(peers, owner_peer),
    Error(InvalidConfiguration),
  )
  use first_generation <- result.try(positive_epoch(fields, "first_generation"))
  use Nil <- result.try(exact_text(
    fields,
    "generation_policy",
    "clean_successor",
  ))
  use Nil <- result.try(exact_text(fields, "native_demand", "full"))
  use expected <- result.try(digest_field(fields, "descriptor_sha256"))
  use contract <- result.try(digest_field(fields, "compilation_contract_sha256"))

  // Full policy semantics are decoded by the existing strict policy codec.
  use working_roots <- result.try(paths_field(
    fields,
    "native_working_roots",
    1,
    16,
  ))
  use ceiling_text <- result.try(text_field(fields, "native_ceiling"))
  use <- bool.guard(string.byte_size(ceiling_text) > 196_608, Error(TooLarge))
  use ceiling <- result.try(policy_json(ceiling_text))
  use code_fields <- result.try(table_field(fields, "code_mode"))
  use code <- result.try(code_row(code_fields))
  use lsp_fields <- result.try(table_field(fields, "lsp"))
  use <- bool.guard(dict.size(lsp_fields) > 16, Error(InvalidConfiguration))
  use lsp_size <- result.try(tom_text_size(tom.Table(lsp_fields), 0))
  use <- bool.guard(lsp_size > 196_608, Error(TooLarge))
  use profiles <- result.try(
    profile.decode_servers(lsp_fields)
    |> result.replace_error(InvalidConfiguration),
  )
  let facts =
    Facts(
      binding:,
      owner:,
      owner_peer:,
      local_node:,
      first_generation:,
      working_roots:,
      ceiling:,
      code:,
      contract:,
      profiles:,
    )
  use _ <- result.try(template_enrollment(facts))
  Ok(#(facts, expected))
}

fn code_row(
  fields: Dict(String, tom.Toml),
) -> Result(enrollment.CodeModeFacts, DeploymentError) {
  use Nil <- result.try(
    keys(fields, [
      "workspace_root",
      "build_area",
      "channel_area",
      "gleam_path",
      "erl_path",
      "seed_root",
      "toolchain_roots",
      "host_mounts",
      "build_path",
    ]),
  )
  use workspace_root <- result.try(path_field(fields, "workspace_root"))
  use build_area <- result.try(path_field(fields, "build_area"))
  use channel_area <- result.try(path_field(fields, "channel_area"))
  use gleam_path <- result.try(path_field(fields, "gleam_path"))
  use erl_path <- result.try(path_field(fields, "erl_path"))
  use seed_root <- result.try(path_field(fields, "seed_root"))
  use toolchain_roots <- result.try(paths_field(
    fields,
    "toolchain_roots",
    1,
    64,
  ))
  use build_path <- result.try(text_field(fields, "build_path"))
  use mounts <- result.try(rows_field(fields, "host_mounts", 0, 64))
  use host_mounts <- result.try(list.try_map(mounts, mount_row))
  Ok(enrollment.CodeModeFacts(
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

fn mount_row(
  fields: Dict(String, tom.Toml),
) -> Result(policy.Mount, DeploymentError) {
  use Nil <- result.try(keys(fields, ["path", "access", "presence"]))
  use path <- result.try(path_field(fields, "path"))
  use Nil <- result.try(exact_text(fields, "access", "read-only"))
  use Nil <- result.try(exact_text(fields, "presence", "required"))
  Ok(policy.Mount(
    path:,
    access: policy.MountReadOnly,
    requirement: policy.MountRequired,
  ))
}

fn scoped_enrollment(
  facts: Facts,
  session: ids.SessionId,
) -> Result(enrollment.SessionEnrollment, DeploymentError) {
  let #(selector, workspace_epoch, session_epoch) =
    workspace.binding_fields(facts.binding)
  let #(executor, name) = workspace.selector_fields(selector)
  use executor <- result.try(
    identity.executor_id(executor) |> result.replace_error(InvalidConfiguration),
  )
  use name <- result.try(
    identity.workspace_id(name) |> result.replace_error(InvalidConfiguration),
  )
  use workspace_epoch <- result.try(
    identity.epoch(workspace_epoch)
    |> result.replace_error(InvalidConfiguration),
  )
  use session_epoch <- result.try(
    identity.epoch(session_epoch) |> result.replace_error(InvalidConfiguration),
  )
  let scope =
    identity.scope(session, name, executor, session_epoch, workspace_epoch)

  // Boot already checked these exact paths; Describe performs no later probing.
  use registered <- result.try(
    registration.new(
      scope,
      facts.working_roots,
      facts.ceiling,
      exec.FullEnforcement,
      fn(path) { Ok(path) },
    )
    |> result.replace_error(InvalidConfiguration),
  )
  use native <- result.try(
    registration.describe(registered)
    |> result.replace_error(InvalidConfiguration),
  )
  let digest =
    identity.digest_bytes(registration.digest(registered))
    |> bit_array.base16_encode
    |> string.lowercase
  enrollment.new(native, facts.code, digest, facts.contract)
  |> result.replace_error(InvalidConfiguration)
}

fn template_enrollment(
  facts: Facts,
) -> Result(enrollment.SessionEnrollment, DeploymentError) {
  use session <- result.try(
    ids.parse_session_id(template_session)
    |> result.replace_error(InvalidConfiguration),
  )
  scoped_enrollment(facts, session)
}

fn fingerprint(facts: Facts) -> Result(String, DeploymentError) {
  use enrolled <- result.try(template_enrollment(facts))
  use bytes <- result.try(
    enrollment.encode(enrolled) |> result.replace_error(InvalidConfiguration),
  )
  let profiles =
    list.map(facts.profiles, fn(server) {
      profile.encode_server(server) |> encoding.to_string
    })
  let profile_size =
    list.fold(profiles, 0, fn(total, text) { total + string.byte_size(text) })
  use <- bool.guard(
    bit_array.byte_size(bytes) + profile_size > 196_608,
    Error(TooLarge),
  )
  let profiles = list.map(profiles, mp.StringValue)

  // The frozen endpoint route is descriptor authority across reopening the same selector.
  use canonical <- result.try(
    mp.encode(
      mp.ArrayValue([
        mp.StringValue("loom.registered.descriptor.v1"),
        mp.StringValue(facts.owner),
        mp.StringValue(facts.owner_peer),
        mp.StringValue(facts.local_node),
        mp.IntValue(facts.first_generation),
        mp.StringValue("clean_successor"),
        mp.BinaryValue(bytes),
        mp.ArrayValue(profiles),
      ]),
    )
    |> result.replace_error(InvalidConfiguration),
  )
  use <- bool.guard(bit_array.byte_size(canonical) > 262_144, Error(TooLarge))
  Ok(
    crypto.hash(crypto.Sha256, canonical)
    |> bit_array.base16_encode
    |> string.lowercase,
  )
}

fn placement(
  facts: Facts,
  protected: List(String),
  helper: String,
) -> Result(Nil, DeploymentError) {
  let code = facts.code
  let immutable = [
    helper,
    code.seed_root,
    code.gleam_path,
    code.erl_path,
    ..code.toolchain_roots
  ]
  let administrative = protected
  let protected = list.append(administrative, immutable)
  let scratch = case facts.ceiling.scratch {
    policy.ScratchTmpfs -> []
    policy.ScratchPath(path) -> [path]
  }
  let writable =
    list.flatten([
      facts.ceiling.writable_roots,
      [code.workspace_root, code.build_area, code.channel_area],
      scratch,
      facts.ceiling.mounts
        |> list.filter(fn(mount) { mount.access == policy.MountReadWrite })
        |> list.map(fn(mount) { mount.path }),
    ])
  use <- bool.guard(
    list.any(writable, fn(root) { list.any(protected, overlap(root, _)) }),
    Error(ProtectedOverlap),
  )
  use <- bool.guard(
    !list.all(administrative, list.contains(facts.ceiling.protected, _)),
    Error(ProtectedOverlap),
  )

  // Explicit readable roots cannot expose administrative private material.
  use <- bool.guard(
    list.any(facts.ceiling.readable_roots, fn(root) {
      list.any(administrative, overlap(root, _))
    }),
    Error(ProtectedOverlap),
  )

  // Membership and private administrative state must not be exposed as mounts.
  use <- bool.guard(
    list.any(facts.ceiling.mounts, fn(mount) {
      list.any(administrative, overlap(mount.path, _))
    }),
    Error(ProtectedOverlap),
  )
  use Nil <- result.try(list.try_each(facts.working_roots, checked_directory))
  use Nil <- result.try(list.try_each(
    [
      code.workspace_root,
      code.build_area,
      code.channel_area,
      code.seed_root,
      ..code.toolchain_roots
    ],
    checked_directory,
  ))
  use Nil <- result.try(checked_executable(code.gleam_path))
  use Nil <- result.try(checked_executable(code.erl_path))
  use Nil <- result.try(list.try_each(
    string.split(code.build_path, ":"),
    checked_directory,
  ))
  use Nil <- result.try(list.try_each(
    policy_paths(facts.ceiling),
    checked_existing,
  ))
  use Nil <- result.try(
    list.try_each(code.host_mounts, fn(mount) { checked_existing(mount.path) }),
  )
  list.try_each(facts.profiles, profile_placement(_, protected))
}

fn profile_placement(
  server: profile.LspServer,
  protected: List(String),
) -> Result(Nil, DeploymentError) {
  use executable <- result.try(
    list.first(server.command) |> result.replace_error(InvalidPlacement),
  )
  use Nil <- result.try(checked_executable(executable))
  use Nil <- result.try(list.try_each(server.readable, checked_lsp_path))
  use Nil <- result.try(
    list.try_each(server.writable, fn(path) {
      use Nil <- result.try(checked_lsp_path(path))
      case path {
        profile.AbsolutePath(root) ->
          case list.any(protected, overlap(root, _)) {
            True -> Error(ProtectedOverlap)
            False -> Ok(Nil)
          }
        profile.HomePath(rest) -> {
          use home <- result.try(
            envoy.get("HOME") |> result.replace_error(InvalidPlacement),
          )
          use root <- result.try(canonical_path(home <> "/" <> rest))
          case list.any(protected, overlap(root, _)) {
            True -> Error(ProtectedOverlap)
            False -> Ok(Nil)
          }
        }
        profile.CachePath(_) -> Ok(Nil)
      }
    }),
  )
  Ok(Nil)
}

fn checked_lsp_path(path: profile.LspPath) -> Result(Nil, DeploymentError) {
  case path {
    profile.AbsolutePath(path) -> checked_existing(path)
    profile.HomePath(rest) -> {
      use home <- result.try(
        envoy.get("HOME") |> result.replace_error(InvalidPlacement),
      )
      use root <- result.try(canonical_path(home <> "/" <> rest))
      checked_existing(root)
    }
    profile.CachePath(_) -> Ok(Nil)
  }
}

fn policy_paths(ceiling: policy.SandboxPolicy) -> List(String) {
  let scratch = case ceiling.scratch {
    policy.ScratchTmpfs -> []
    policy.ScratchPath(path) -> [path]
  }
  list.flatten([
    ceiling.writable_roots,
    ceiling.readable_roots,
    ceiling.protected,
    scratch,
    list.map(ceiling.mounts, fn(mount) { mount.path }),
  ])
}

fn checked_existing(path: String) -> Result(Nil, DeploymentError) {
  use Nil <- result.try(absolute(path))
  use canonical <- result.try(
    fs.resolve_real(fs.real_filesystem(), "/", path)
    |> result.replace_error(InvalidPlacement),
  )
  use <- bool.guard(canonical != path, Error(InvalidPlacement))
  simplifile.file_info(path)
  |> result.replace(Nil)
  |> result.replace_error(InvalidPlacement)
}

fn canonical_path(path: String) -> Result(String, DeploymentError) {
  fs.resolve_real(fs.real_filesystem(), "/", path)
  |> result.replace_error(InvalidPlacement)
}

fn checked_directory(path: String) -> Result(Nil, DeploymentError) {
  use Nil <- result.try(checked_existing(path))
  use info <- result.try(
    simplifile.file_info(path) |> result.replace_error(InvalidPlacement),
  )
  case simplifile.file_info_type(info) == simplifile.Directory {
    True -> Ok(Nil)
    False -> Error(InvalidPlacement)
  }
}

fn checked_private_directory(path: String) -> Result(Nil, DeploymentError) {
  use Nil <- result.try(checked_directory(path))
  use info <- result.try(
    simplifile.file_info(path) |> result.replace_error(InvalidPlacement),
  )
  case info.mode % 64 == 0 {
    True -> Ok(Nil)
    False -> Error(InvalidPlacement)
  }
}

fn checked_file(path: String) -> Result(Nil, DeploymentError) {
  use Nil <- result.try(checked_existing(path))
  use info <- result.try(
    simplifile.file_info(path) |> result.replace_error(InvalidPlacement),
  )
  case simplifile.file_info_type(info) == simplifile.File {
    True -> Ok(Nil)
    False -> Error(InvalidPlacement)
  }
}

fn checked_executable(path: String) -> Result(Nil, DeploymentError) {
  use Nil <- result.try(checked_file(path))
  use info <- result.try(
    simplifile.file_info(path) |> result.replace_error(InvalidPlacement),
  )
  case info.mode / 64 % 2 == 1 {
    True -> Ok(Nil)
    False -> Error(InvalidPlacement)
  }
}

fn policy_json(text: String) -> Result(policy.SandboxPolicy, DeploymentError) {
  use value <- result.try(
    json.parse(text) |> result.replace_error(InvalidConfiguration),
  )
  use value <- result.try(json_msgpack(value, 0))
  policy.from_msgpack(value) |> result.replace_error(InvalidConfiguration)
}

fn json_msgpack(
  value: json.JsonValue,
  depth: Int,
) -> Result(mp.MsgPackValue, DeploymentError) {
  use <- bool.guard(depth > 8, Error(InvalidConfiguration))
  case value {
    json.String(value) -> Ok(mp.StringValue(value))
    json.Int(value) -> Ok(mp.IntValue(value))
    json.Bool(value) -> Ok(mp.BoolValue(value))
    json.Null -> Ok(mp.NilValue)
    json.Float(_) -> Error(InvalidConfiguration)
    json.Array(values) -> {
      use <- bool.guard(list.length(values) > 256, Error(InvalidConfiguration))
      list.try_map(values, json_msgpack(_, depth + 1))
      |> result.map(mp.ArrayValue)
    }
    json.Object(fields) -> {
      use <- bool.guard(list.length(fields) > 64, Error(InvalidConfiguration))
      use entries <- result.map(
        list.try_map(fields, fn(field) {
          use value <- result.map(json_msgpack(field.1, depth + 1))
          #(mp.StringValue(field.0), value)
        }),
      )
      mp.MapValue(entries)
    }
  }
}

fn tom_text_size(value: tom.Toml, depth: Int) -> Result(Int, DeploymentError) {
  use <- bool.guard(depth > 8, Error(InvalidConfiguration))
  case value {
    tom.String(text) -> Ok(string.byte_size(text))
    tom.Array(values) -> {
      use <- bool.guard(list.length(values) > 256, Error(InvalidConfiguration))
      list.try_fold(values, 0, fn(total, value) {
        use size <- result.map(tom_text_size(value, depth + 1))
        total + size
      })
    }
    tom.Table(fields) | tom.InlineTable(fields) -> {
      use <- bool.guard(dict.size(fields) > 64, Error(InvalidConfiguration))
      list.try_fold(dict.to_list(fields), 0, fn(total, field) {
        use size <- result.map(tom_text_size(field.1, depth + 1))
        total + string.byte_size(field.0) + size
      })
    }
    tom.Int(_) | tom.Bool(_) -> Ok(16)
    _ -> Error(InvalidConfiguration)
  }
}

fn peer_row(
  fields: Dict(String, tom.Toml),
) -> Result(#(String, BitArray), DeploymentError) {
  use Nil <- result.try(keys(fields, ["node", "leaf_sha256"]))
  use name <- result.try(text_field(fields, "node"))
  use pin <- result.try(digest_field(fields, "leaf_sha256"))
  use bytes <- result.try(
    bit_array.base16_decode(pin) |> result.replace_error(InvalidConfiguration),
  )
  Ok(#(name, bytes))
}

fn keys(
  fields: Dict(String, tom.Toml),
  allowed: List(String),
) -> Result(Nil, DeploymentError) {
  case list.all(dict.keys(fields), list.contains(allowed, _)) {
    True -> Ok(Nil)
    False -> Error(InvalidConfiguration)
  }
}

fn text_field(
  fields: Dict(String, tom.Toml),
  key: String,
) -> Result(String, DeploymentError) {
  case dict.get(fields, key) {
    Ok(tom.String(value)) -> Ok(value)
    Ok(_) | Error(_) -> Error(InvalidConfiguration)
  }
}

fn int_field(
  fields: Dict(String, tom.Toml),
  key: String,
) -> Result(Int, DeploymentError) {
  case dict.get(fields, key) {
    Ok(tom.Int(value)) -> Ok(value)
    Ok(_) | Error(_) -> Error(InvalidConfiguration)
  }
}

fn positive_epoch(
  fields: Dict(String, tom.Toml),
  key: String,
) -> Result(Int, DeploymentError) {
  use value <- result.try(int_field(fields, key))
  case value >= 1 && value <= 2_147_483_647 {
    True -> Ok(value)
    False -> Error(InvalidConfiguration)
  }
}

fn digest_field(
  fields: Dict(String, tom.Toml),
  key: String,
) -> Result(String, DeploymentError) {
  use value <- result.try(text_field(fields, key))
  use Nil <- result.try(
    command.digest(value) |> result.replace_error(InvalidConfiguration),
  )
  Ok(value)
}

fn path_field(
  fields: Dict(String, tom.Toml),
  key: String,
) -> Result(String, DeploymentError) {
  use value <- result.try(text_field(fields, key))
  use Nil <- result.try(absolute(value))
  Ok(value)
}

fn exact_text(
  fields: Dict(String, tom.Toml),
  key: String,
  expected: String,
) -> Result(Nil, DeploymentError) {
  use value <- result.try(text_field(fields, key))
  case value == expected {
    True -> Ok(Nil)
    False -> Error(InvalidConfiguration)
  }
}

fn exact_int(
  fields: Dict(String, tom.Toml),
  key: String,
  expected: Int,
) -> Result(Nil, DeploymentError) {
  use value <- result.try(int_field(fields, key))
  case value == expected {
    True -> Ok(Nil)
    False -> Error(InvalidConfiguration)
  }
}

fn table_field(
  fields: Dict(String, tom.Toml),
  key: String,
) -> Result(Dict(String, tom.Toml), DeploymentError) {
  case dict.get(fields, key) {
    Ok(tom.Table(value)) | Ok(tom.InlineTable(value)) -> Ok(value)
    Ok(_) | Error(_) -> Error(InvalidConfiguration)
  }
}

fn rows_field(
  fields: Dict(String, tom.Toml),
  key: String,
  low: Int,
  high: Int,
) -> Result(List(Dict(String, tom.Toml)), DeploymentError) {
  use values <- result.try(
    tom.get_array(fields, [key]) |> result.replace_error(InvalidConfiguration),
  )
  use <- bool.guard(
    list.length(values) < low || list.length(values) > high,
    Error(InvalidConfiguration),
  )
  list.try_map(values, fn(value) {
    case value {
      tom.Table(fields) | tom.InlineTable(fields) -> Ok(fields)
      _ -> Error(InvalidConfiguration)
    }
  })
}

fn paths_field(
  fields: Dict(String, tom.Toml),
  key: String,
  low: Int,
  high: Int,
) -> Result(List(String), DeploymentError) {
  use values <- result.try(
    tom.get_array(fields, [key]) |> result.replace_error(InvalidConfiguration),
  )
  use <- bool.guard(
    list.length(values) < low || list.length(values) > high,
    Error(InvalidConfiguration),
  )
  list.try_map(values, fn(value) {
    case value {
      tom.String(path) -> {
        use Nil <- result.map(absolute(path))
        path
      }
      _ -> Error(InvalidConfiguration)
    }
  })
}

fn absolute(path: String) -> Result(Nil, DeploymentError) {
  case
    string.starts_with(path, "/")
    && string.byte_size(path) <= 4096
    && !string.contains(path, "\u{0}")
  {
    True -> Ok(Nil)
    False -> Error(InvalidConfiguration)
  }
}

fn overlap(left: String, right: String) -> Bool {
  left == right
  || left == "/"
  || right == "/"
  || string.starts_with(left, right <> "/")
  || string.starts_with(right, left <> "/")
}
