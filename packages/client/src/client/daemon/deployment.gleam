//// Immutable registered deployment authority shared by listener and assembly.
////
//// `decode` admits bounded strict administrative TOML once. Subsequent selection
//// compares retained epochs against that same table. File edits never refresh
//// authority. Membership startup and activation remain explicit caller actions.

import broker/enrollment
import client/daemon/server
import core/command
import core/generation
import core/workspace
import executor/remote/distribution
import executor/remote/identity
import executor/remote/registration
import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string
import host/bootstrap
import simplifile
import storage/owner_custody
import tom

/// One startup snapshot, without live processes or executor physical paths.
pub opaque type Table {
  /// Module-owned constructor containing no runtime capabilities.
  Table(
    /// Validated administrative owner label.
    owner: String,
    /// Finite node names, exact public pins and private credential locations.
    membership: distribution.Config,
    /// Fixed TLS options pathname for the same boot configuration.
    options: String,
    /// Unique selector rows, immutable for this VM lifetime.
    rows: List(Selected),
  )
}

/// Exact configured binding and descriptor commitment.
pub opaque type Selected {
  /// Exact administrative selection, not an activation claim.
  Selected(
    /// Selector and both retained authority epochs.
    binding: workspace.RegisteredBinding,
    /// Installed executor node name, resolved after membership startup.
    peer: String,
    /// Lowercase canonical immutable descriptor commitment.
    descriptor: String,
    /// Configured first-generation number, without allocating that identity.
    first_generation: Int,
  )
}

/// Verified immutable companion pin, independent of service generations.
pub opaque type PinnedEnrollment {
  /// Verified durable metadata and complete decoded content.
  PinnedEnrollment(
    /// Original exact configuration row used by this session.
    selected: Selected,
    /// Generation-free immutable companion metadata.
    stored: owner_custody.EnrollmentPin,
    /// Canonical content whose scope and native digest were rechecked.
    enrolled: enrollment.SessionEnrollment,
  )
}

/// Closed refusals never retain credentials or rejected input.
pub type DeploymentError {
  /// A bounded regular UTF-8 file could not be read.
  Unreadable

  /// The pre-parse eight-MiB bound was exceeded.
  TooLarge

  /// A key, type, spelling, count or membership invariant was refused.
  InvalidConfiguration

  /// The selector is absent or its exact epochs differ.
  Unavailable

  /// The pin's descriptor, scope, canonical bytes or digest differs.
  PinMismatch
}

const max_bytes = 8_388_608

/// Checks file size before reading and checks content size before parsing.
///
/// ## Examples
///
/// `load("/etc/loom-owner/deployment.toml")` starts no membership or session.
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
  decode(text)
}

/// Decodes the closed protocol-077 owner schema without effects.
/// TOML rejects duplicate keys before constructing the immutable table.
///
/// ## Examples
///
/// `decode("schema = 2")` returns `Error(InvalidConfiguration)`.
pub fn decode(text: String) -> Result(Table, DeploymentError) {
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

  // Distribution owns finite node names, peer uniqueness and exact leaf pins.
  use local <- result.try(text_field(fields, "local_node"))
  use files <- result.try(table_field(fields, "membership"))
  use Nil <- result.try(
    keys(files, ["ca", "certificate", "key", "cookie", "options"]),
  )
  use ca <- result.try(text_field(files, "ca"))
  use certificate <- result.try(text_field(files, "certificate"))
  use key <- result.try(text_field(files, "key"))
  use cookie <- result.try(text_field(files, "cookie"))
  use options <- result.try(text_field(files, "options"))
  use Nil <- result.try(absolute(options))
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

  // Unique selectors may route only to installed peers.
  use rows <- result.try(rows_field(fields, "workspaces", 1, 32))
  use rows <- result.try(
    list.try_map(rows, selected_row(_, list.map(peers, fn(p) { p.0 }))),
  )
  let selectors =
    list.map(rows, fn(row) { workspace.binding_fields(row.binding).0 })
  use <- bool.guard(
    list.length(list.unique(selectors)) != list.length(rows),
    Error(InvalidConfiguration),
  )
  Ok(Table(owner:, membership:, options:, rows:))
}

/// Projects trusted membership and its private options path.
///
/// ## Examples
///
/// `membership(table)` supplies the same startup snapshot as `authority`.
pub fn membership(table: Table) -> #(distribution.Config, String) {
  #(table.membership, table.options)
}

/// Returns the validated administrative owner label.
///
/// ## Examples
///
/// `owner(table)` grants no peer authority.
pub fn owner(table: Table) -> String {
  table.owner
}

/// Captures exact table rows for fresh resolution and retained epoch checks.
/// Local choices retain ordinary host canonicalization behavior.
///
/// ## Examples
///
/// `authority(table)` and `select(table, binding)` share one immutable snapshot.
pub fn authority(table: Table) -> server.WorkspaceAuthority {
  let rows = table.rows
  let local = server.local_workspace_authority()
  server.WorkspaceAuthority(
    resolve: fn(selection) {
      case selection {
        workspace.LocalDirectory(_) -> local.resolve(selection)
        workspace.RegisteredWorkspace(selector) ->
          list.find(rows, fn(row) {
            workspace.binding_fields(row.binding).0 == selector
          })
          |> result.map(fn(row) { workspace.Registered(row.binding) })
          |> result.replace_error("workspace_unavailable")
      }
    },
    revalidate: fn(binding) {
      case binding {
        workspace.LocalBinding(_) -> local.revalidate(binding)
        workspace.Registered(retained) ->
          selected_in(rows, retained)
          |> result.replace(Nil)
          |> result.replace_error("workspace_unavailable")
      }
    },
  )
}

/// Selects retained exact epochs without replacing them.
///
/// ## Examples
///
/// `select(table, retained)` refuses an epoch change under the same selector.
pub fn select(
  table: Table,
  retained: workspace.RegisteredBinding,
) -> Result(Selected, DeploymentError) {
  selected_in(table.rows, retained)
}

/// Projects binding, peer name, descriptor digest and first generation.
///
/// ## Examples
///
/// `selected_fields(selected)` contains no executor physical path.
pub fn selected_fields(
  selected: Selected,
) -> #(workspace.RegisteredBinding, String, String, Int) {
  #(
    selected.binding,
    selected.peer,
    selected.descriptor,
    selected.first_generation,
  )
}

/// Verifies companion content before exposing decoded immutable enrollment.
///
/// ## Examples
///
/// `pinned(selected, stored)` neither activates nor repairs a generation.
pub fn pinned(
  selected: Selected,
  stored: owner_custody.EnrollmentPin,
) -> Result(PinnedEnrollment, DeploymentError) {
  let #(session, binding, descriptor, digest, bytes) =
    owner_custody.enrollment_fields(stored)
  use <- bool.guard(binding != selected.binding, Error(PinMismatch))
  use expected <- result.try(
    bit_array.base16_decode(selected.descriptor)
    |> result.replace_error(PinMismatch),
  )
  use <- bool.guard(
    generation.digest_bytes(descriptor) != expected
      || generation.digest_bytes(digest) != bootstrap.sha256(bytes),
    Error(PinMismatch),
  )
  use enrolled <- result.try(
    enrollment.decode(bytes) |> result.replace_error(PinMismatch),
  )
  use <- bool.guard(
    enrollment.native_facts(enrolled).scope != workspace.scope(session, binding),
    Error(PinMismatch),
  )
  use Nil <- result.try(check_registration(enrolled))
  Ok(PinnedEnrollment(selected:, stored:, enrolled:))
}

/// Projects verified durable metadata and decoded enrollment together.
///
/// ## Examples
///
/// `pin_fields(pin)` supplies readback and physical assembly input.
pub fn pin_fields(
  pin: PinnedEnrollment,
) -> #(owner_custody.EnrollmentPin, enrollment.SessionEnrollment) {
  #(pin.stored, pin.enrolled)
}

/// Checks original binding and descriptor against the same immutable table.
///
/// ## Examples
///
/// `revalidate(table, pin)` performs no peer probing or configuration refresh.
pub fn revalidate(
  table: Table,
  pin: PinnedEnrollment,
) -> Result(Nil, DeploymentError) {
  use current <- result.try(select(table, pin.selected.binding))
  case current == pin.selected {
    True -> Ok(Nil)
    False -> Error(PinMismatch)
  }
}

fn check_registration(
  enrolled: enrollment.SessionEnrollment,
) -> Result(Nil, DeploymentError) {
  let native = enrollment.native_facts(enrolled)
  let #(session, binding) = workspace.scope_fields(native.scope)
  let #(selector, workspace_epoch, session_epoch) =
    workspace.binding_fields(binding)
  let #(executor, name) = workspace.selector_fields(selector)
  use executor <- result.try(
    identity.executor_id(executor) |> result.replace_error(PinMismatch),
  )
  use name <- result.try(
    identity.workspace_id(name) |> result.replace_error(PinMismatch),
  )
  use workspace_epoch <- result.try(
    identity.epoch(workspace_epoch) |> result.replace_error(PinMismatch),
  )
  use session_epoch <- result.try(
    identity.epoch(session_epoch) |> result.replace_error(PinMismatch),
  )
  let scope =
    identity.scope(session, name, executor, session_epoch, workspace_epoch)
  use registered <- result.try(
    registration.new(
      scope,
      native.working_roots,
      native.ceiling,
      native.demand,
      Ok,
    )
    |> result.replace_error(PinMismatch),
  )
  let digest =
    identity.digest_bytes(registration.digest(registered))
    |> bit_array.base16_encode
    |> string.lowercase
  case enrollment.digests(enrolled).0 == digest {
    True -> Ok(Nil)
    False -> Error(PinMismatch)
  }
}

fn selected_in(
  rows: List(Selected),
  retained: workspace.RegisteredBinding,
) -> Result(Selected, DeploymentError) {
  list.find(rows, fn(row) { row.binding == retained })
  |> result.replace_error(Unavailable)
}

fn selected_row(
  fields: Dict(String, tom.Toml),
  peers: List(String),
) -> Result(Selected, DeploymentError) {
  use Nil <- result.try(
    keys(fields, [
      "executor",
      "workspace",
      "peer",
      "workspace_epoch",
      "session_epoch",
      "first_generation",
      "generation_policy",
      "descriptor_sha256",
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

  // Clean successors preserve the immutable descriptor and original owner doors.
  use first_generation <- result.try(int_field(fields, "first_generation"))
  use <- bool.guard(
    first_generation < 1 || first_generation > 2_147_483_647,
    Error(InvalidConfiguration),
  )
  use Nil <- result.try(exact_text(
    fields,
    "generation_policy",
    "clean_successor",
  ))
  use descriptor <- result.try(text_field(fields, "descriptor_sha256"))
  use Nil <- result.try(
    command.digest(descriptor) |> result.replace_error(InvalidConfiguration),
  )
  use peer <- result.try(text_field(fields, "peer"))
  use <- bool.guard(!list.contains(peers, peer), Error(InvalidConfiguration))
  Ok(Selected(binding:, peer:, descriptor:, first_generation:))
}

fn peer_row(
  fields: Dict(String, tom.Toml),
) -> Result(#(String, BitArray), DeploymentError) {
  use Nil <- result.try(keys(fields, ["node", "leaf_sha256"]))
  use name <- result.try(text_field(fields, "node"))
  use pin <- result.try(text_field(fields, "leaf_sha256"))
  use Nil <- result.try(
    command.digest(pin) |> result.replace_error(InvalidConfiguration),
  )
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
