//// Immutable original journal provenance, separate from startup authority.
////
//// The administrator checks physical canonical/private placement before `new`.
//// This pure metadata boundary checks lexical paths, complete scope/enrollment
//// equality and the actual selected journal profiles. Its opaque Plan contains
//// no callback, credential, service, SQLite connection or execution recipe.
//// Paths identify the original files; recovery must additionally check each
//// DAL's stored binding and never substitute a current deployment state root.
////
//// Header and enrollment are independently bounded canonical bodies. Wrapping
//// enrollment in the ordinary MessagePack binary profile would reject otherwise
//// valid snapshots above its 128-KiB binary ceiling. The digest binds both exact
//// lengths and bodies. Permanent admission charges their actual bytes plus the
//// digest before it can issue a StartupClaim. Disabled LSP carries no recovery
//// inputs; it preserves the deployment loader's valid empty profile inventory.
////
//// ## Flow
////
//// `new` checks `checked_lsp` and `validate_paths`, then header encoding
//// and `content_digest` freeze the two bodies. `decode` preflights each body,
//// enters `decode_header`, and reconstructs through `new` before exact equality.
//// `original`, `encoded`, `reservation`, `owner_peer`, `enrolled`, `native`,
//// `workspace_inputs`, `resource_inputs` and `lsp_inputs` project only metadata.
//// `lsp_value`, `journal_value` and `profile_value` encode checked fields;
//// `decode_lsp`, `decode_journal` and `decode_profile` accept closed shapes.
//// `validate_peer` and `canonical_path` bound plain text before encoding.

import broker/enrollment
import core/bounded_msgpack
import core/generation as g
import core/lsp_command as id
import core/msgpack as mp
import executor/remote/admission
import executor/remote/lsp_journal as lsp
import executor/remote/resource_journal as resource
import executor/remote/workspace_journal as ws
import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Independent canonical body ceiling; it changes no transport profile.
pub const max_body_bytes = 262_144

/// Selected original journal placement; only `new` validates these plain facts.
pub type Journal {
  /// Actual choices, rather than defaults looked up during recovery.
  Journal(
    /// Original canonical private database path, at most 4096 UTF-8 bytes.
    path: String,
    /// Original checked permanent row ceiling.
    rows: Int,
    /// Original checked permanent logical-byte ceiling.
    bytes: Int,
  )
}

/// Closed original LSP selection; empty deployment inventories stay disabled.
pub type Lsp {
  /// No LSP custody database or recovery parameters were provisioned.
  DisabledLsp

  /// Complete original DAL metadata for one through sixteen ordered profiles.
  EnabledLsp(
    /// Original selected custody placement and limits.
    journal: Journal,
    /// Exact contract digest used by the original custody DAL.
    contract: g.Digest,
    /// Immutable ordered labels and canonical workspace roots.
    profiles: List(id.Profile),
  )
}

/// Checked metadata without any startup or connection authority.
pub opaque type Plan {
  /// Only canonical checked construction and decoding can retain this value.
  Plan(
    /// Full original generation and enrollment association.
    associated: g.GenerationAssociation,
    /// Complete original canonical session enrollment.
    enrolled: enrollment.SessionEnrollment,
    /// Configured original authentication route, never a credential.
    owner_peer: String,
    /// Original native journal placement.
    native_path: String,
    /// Actual original checked admission capacity.
    native_capacity: admission.Capacity,
    /// Original workspace placement and existing checked Limits.
    workspace: CheckedJournal(ws.Limits),
    /// Original resource placement and existing checked Limits.
    resource: CheckedJournal(resource.Limits),
    /// Disabled metadata or exact original checked LSP recovery inputs.
    lsp: CheckedLsp,
    /// Independently bounded canonical metadata header.
    header: BitArray,
    /// Independently bounded complete enrollment body.
    enrollment_body: BitArray,
    /// Domain-separated digest of both lengths and bodies.
    digest: g.Digest,
  )
}

/// Fixed validation errors never retain paths or hostile body contents.
pub type Error {
  /// Bounds, canonical shape or selected existing journal profile is invalid.
  Invalid

  /// Original scope, enrollment hash or canonical bodies differ.
  Mismatch
}

type CheckedJournal(limits) {
  CheckedJournal(facts: Journal, limits: limits)
}

type CheckedLsp {
  Disabled
  Enabled(
    journal: CheckedJournal(lsp.Limits),
    contract: g.Digest,
    profiles: List(id.Profile),
    enrolled: id.EnrolledProfiles,
  )
}

/// Checks actual selected inputs after trusted physical placement validation.
/// This performs no filesystem access and grants no startup permission.
///
/// ## Examples
///
/// `new(original, enrolled, peer, native_path, capacity, workspace, resource,
/// DisabledLsp)` retains an empty deployment LSP inventory without inventing one.
@internal
pub fn new(
  associated: g.GenerationAssociation,
  enrolled: enrollment.SessionEnrollment,
  owner_peer: String,
  native_path: String,
  native_capacity: admission.Capacity,
  workspace: Journal,
  resource: Journal,
  selected_lsp: Lsp,
) -> Result(Plan, Error) {
  use Nil <- result.try(validate_peer(owner_peer))
  let scope = g.key_scope(g.association_key(associated))
  use <- bool.guard(
    enrollment.native_facts(enrolled).scope != scope,
    Error(Mismatch),
  )
  use body <- result.try(
    enrollment.encode(enrolled) |> result.replace_error(Invalid),
  )
  use <- bool.guard(bit_array.byte_size(body) > max_body_bytes, Error(Invalid))
  let #(_, expected, _, _) = g.association_fields(associated)
  use <- bool.guard(
    crypto.hash(crypto.Sha256, body) != g.digest_bytes(expected),
    Error(Mismatch),
  )

  // Existing constructors establish the actual selected profiles once. Recovery
  // projects these same opaque values and never obtains replacement defaults.
  use workspace_limits <- result.try(
    ws.limits(workspace.rows, workspace.bytes) |> result.replace_error(Invalid),
  )
  use resource_limits <- result.try(
    resource.limits(resource.rows, resource.bytes)
    |> result.replace_error(Invalid),
  )
  use checked_lsp <- result.try(checked_lsp(associated, selected_lsp))
  use Nil <- result.try(validate_paths(
    native_path,
    workspace,
    resource,
    checked_lsp,
  ))

  // The two complete bodies have separate decoding profiles. Their digest also
  // binds exact lengths, so neither body can be substituted or concatenated.
  use header <- result.try(
    mp.encode(
      mp.ArrayValue([
        mp.StringValue("loom.generation.scope-plan/1"),
        g.association_value(associated),
        mp.StringValue(owner_peer),
        mp.ArrayValue([
          mp.StringValue(native_path),
          mp.IntValue(admission.capacity_value(native_capacity)),
        ]),
        journal_value(workspace),
        journal_value(resource),
        lsp_value(selected_lsp),
        mp.IntValue(bit_array.byte_size(body)),
        mp.BinaryValue(crypto.hash(crypto.Sha256, body)),
      ]),
    )
    |> result.replace_error(Invalid),
  )
  use <- bool.guard(
    bit_array.byte_size(header) > max_body_bytes,
    Error(Invalid),
  )
  use _ <- result.try(
    bounded_msgpack.decode(header) |> result.replace_error(Invalid),
  )
  use digest <- result.try(content_digest(header, body))
  Ok(Plan(
    associated,
    enrolled,
    owner_peer,
    native_path,
    native_capacity,
    CheckedJournal(workspace, workspace_limits),
    CheckedJournal(resource, resource_limits),
    checked_lsp,
    header,
    body,
    digest,
  ))
}

/// Returns the exact immutable association, without a claim or live handle.
///
/// ## Examples
///
/// `original(plan)` still names the same generation after endpoint removal.
@internal
pub fn original(plan: Plan) -> g.GenerationAssociation {
  plan.associated
}

/// Projects the two exact canonical bodies and their domain-separated digest.
///
/// ## Examples
///
/// `decode(encoded(plan).0, encoded(plan).1, encoded(plan).2) == Ok(plan)`.
@internal
pub fn encoded(plan: Plan) -> #(BitArray, BitArray, g.Digest) {
  #(plan.header, plan.enrollment_body, plan.digest)
}

/// Accounts all immutable child bytes; these stay charged after retirement.
///
/// ## Examples
///
/// The maximum is `2 * max_body_bytes + 32`, excluding parent reservations.
@internal
pub fn reservation(plan: Plan) -> Int {
  bit_array.byte_size(plan.header)
  + bit_array.byte_size(plan.enrollment_body)
  + 32
}

/// Returns the original configured authentication route.
///
/// ## Examples
///
/// `owner_peer(plan)` cannot resolve a current owner or grant membership.
@internal
pub fn owner_peer(plan: Plan) -> String {
  plan.owner_peer
}

/// Returns the full original enrollment, not an abbreviated digest projection.
///
/// ## Examples
///
/// `enrolled(plan)` includes original policy, toolchain and both authority epochs.
@internal
pub fn enrolled(plan: Plan) -> enrollment.SessionEnrollment {
  plan.enrolled
}

/// Projects the original native path and actual existing checked capacity.
///
/// ## Examples
///
/// `native(plan)` never consults a new deployment state root or default.
@internal
pub fn native(plan: Plan) -> #(String, admission.Capacity) {
  #(plan.native_path, plan.native_capacity)
}

/// Projects the original workspace path and exact existing Limits.
///
/// ## Examples
///
/// `workspace_inputs(plan)` is metadata for the later managed recovery owner.
@internal
pub fn workspace_inputs(plan: Plan) -> #(String, ws.Limits) {
  #(plan.workspace.facts.path, plan.workspace.limits)
}

/// Projects the original resource path and exact existing Limits.
///
/// ## Examples
///
/// Resource recovery separately requires the same temporarily recovered native.
@internal
pub fn resource_inputs(plan: Plan) -> #(String, resource.Limits) {
  #(plan.resource.facts.path, plan.resource.limits)
}

/// Projects original LSP DAL metadata; disabled descriptors yield no inputs.
///
/// ## Examples
///
/// `lsp_inputs(plan) == None` when the original descriptor contained no profiles.
@internal
pub fn lsp_inputs(
  plan: Plan,
) -> Option(#(String, lsp.Limits, g.Digest, id.EnrolledProfiles)) {
  case plan.lsp {
    Disabled -> None
    Enabled(journal, contract, _, enrolled) ->
      Some(#(journal.facts.path, journal.limits, contract, enrolled))
  }
}

/// Totally decodes both bounded bodies and demands exact original integrity.
///
/// ## Examples
///
/// A changed path or enrollment body cannot reuse the old plan digest.
@internal
pub fn decode(
  header: BitArray,
  body: BitArray,
  digest: g.Digest,
) -> Result(Plan, Error) {
  use <- bool.guard(
    bit_array.byte_size(header) > max_body_bytes
      || bit_array.byte_size(body) > max_body_bytes,
    Error(Invalid),
  )
  use actual <- result.try(content_digest(header, body))
  use <- bool.guard(actual != digest, Error(Mismatch))
  use value <- result.try(
    bounded_msgpack.decode(header) |> result.replace_error(Invalid),
  )
  use enrolled <- result.try(
    enrollment.decode(body) |> result.replace_error(Invalid),
  )
  use plan <- result.try(decode_header(value, enrolled, body))
  use <- bool.guard(
    plan.header != header
      || plan.enrollment_body != body
      || plan.digest != digest,
    Error(Mismatch),
  )
  Ok(plan)
}

fn journal_value(value: Journal) -> mp.MsgPackValue {
  mp.ArrayValue([
    mp.StringValue(value.path),
    mp.IntValue(value.rows),
    mp.IntValue(value.bytes),
  ])
}

fn checked_lsp(
  associated: g.GenerationAssociation,
  selected: Lsp,
) -> Result(CheckedLsp, Error) {
  case selected {
    DisabledLsp -> Ok(Disabled)
    EnabledLsp(facts, contract, profiles) -> {
      use limits <- result.try(
        lsp.limits(facts.rows, facts.bytes) |> result.replace_error(Invalid),
      )
      let #(_, enrollment, _, _) = g.association_fields(associated)
      use inventory <- result.try(
        id.enrolled_profiles(
          g.key_scope(g.association_key(associated)),
          enrollment,
          profiles,
        )
        |> result.replace_error(Invalid),
      )
      Ok(Enabled(CheckedJournal(facts, limits), contract, profiles, inventory))
    }
  }
}

fn validate_paths(
  native: String,
  workspace: Journal,
  resource: Journal,
  lsp: CheckedLsp,
) -> Result(Nil, Error) {
  let paths = case lsp {
    Disabled -> [native, workspace.path, resource.path]
    Enabled(journal, _, _, _) -> [
      native,
      workspace.path,
      resource.path,
      journal.facts.path,
    ]
  }
  use Nil <- result.try(list.try_each(paths, canonical_path))
  use <- bool.guard(
    list.length(list.unique(paths)) != list.length(paths),
    Error(Invalid),
  )
  Ok(Nil)
}

fn content_digest(header: BitArray, body: BitArray) -> Result(g.Digest, Error) {
  g.digest(
    crypto.hash(crypto.Sha256, <<
      "loom.generation.scope-plan.digest/1":utf8,
      bit_array.byte_size(header):size(64),
      header:bits,
      bit_array.byte_size(body):size(64),
      body:bits,
    >>),
  )
  |> result.replace_error(Invalid)
}

fn lsp_value(selected: Lsp) -> mp.MsgPackValue {
  case selected {
    DisabledLsp -> mp.ArrayValue([mp.IntValue(0)])
    EnabledLsp(journal, contract, profiles) ->
      mp.ArrayValue([
        mp.IntValue(1),
        journal_value(journal),
        mp.BinaryValue(g.digest_bytes(contract)),
        mp.ArrayValue(list.map(profiles, profile_value)),
      ])
  }
}

fn profile_value(profile: id.Profile) -> mp.MsgPackValue {
  mp.ArrayValue([
    mp.StringValue(profile.server),
    mp.StringValue(profile.workspace_root),
  ])
}

fn decode_header(
  value: mp.MsgPackValue,
  enrolled: enrollment.SessionEnrollment,
  body: BitArray,
) -> Result(Plan, Error) {
  case value {
    mp.ArrayValue([
      mp.StringValue("loom.generation.scope-plan/1"),
      associated,
      mp.StringValue(peer),
      mp.ArrayValue([mp.StringValue(path), mp.IntValue(capacity)]),
      workspace,
      resource,
      selected_lsp,
      mp.IntValue(size),
      mp.BinaryValue(hash),
    ]) -> {
      use <- bool.guard(
        size != bit_array.byte_size(body)
          || hash != crypto.hash(crypto.Sha256, body),
        Error(Mismatch),
      )
      use associated <- result.try(
        g.decode_association_value(associated) |> result.replace_error(Invalid),
      )
      use capacity <- result.try(
        admission.capacity(capacity) |> result.replace_error(Invalid),
      )
      use workspace <- result.try(decode_journal(workspace))
      use resource <- result.try(decode_journal(resource))
      use selected_lsp <- result.try(decode_lsp(selected_lsp))
      new(
        associated,
        enrolled,
        peer,
        path,
        capacity,
        workspace,
        resource,
        selected_lsp,
      )
    }
    _ -> Error(Invalid)
  }
}

fn decode_journal(value: mp.MsgPackValue) -> Result(Journal, Error) {
  case value {
    mp.ArrayValue([mp.StringValue(path), mp.IntValue(rows), mp.IntValue(bytes)]) ->
      Ok(Journal(path, rows, bytes))
    _ -> Error(Invalid)
  }
}

fn decode_lsp(value: mp.MsgPackValue) -> Result(Lsp, Error) {
  case value {
    mp.ArrayValue([mp.IntValue(0)]) -> Ok(DisabledLsp)
    mp.ArrayValue([
      mp.IntValue(1),
      journal,
      mp.BinaryValue(contract),
      mp.ArrayValue(profiles),
    ]) -> {
      use journal <- result.try(decode_journal(journal))
      use contract <- result.try(
        g.digest(contract) |> result.replace_error(Invalid),
      )
      use profiles <- result.try(list.try_map(profiles, decode_profile))
      Ok(EnabledLsp(journal, contract, profiles))
    }
    _ -> Error(Invalid)
  }
}

fn decode_profile(value: mp.MsgPackValue) -> Result(id.Profile, Error) {
  case value {
    mp.ArrayValue([mp.StringValue(server), mp.StringValue(root)]) ->
      Ok(id.Profile(server, root))
    _ -> Error(Invalid)
  }
}

fn validate_peer(peer: String) -> Result(Nil, Error) {
  use <- bool.guard(string.byte_size(peer) > 255, Error(Invalid))
  case string.split(peer, "@") {
    [node, host] if node != "" && host != "" -> {
      use <- bool.guard(!string.contains(host, "."), Error(Invalid))
      use <- bool.guard(
        !list.all(string.to_graphemes(peer), fn(c) {
          string.contains(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.@",
            c,
          )
        }),
        Error(Invalid),
      )
      Ok(Nil)
    }
    _ -> Error(Invalid)
  }
}

fn canonical_path(path: String) -> Result(Nil, Error) {
  use <- bool.guard(
    string.byte_size(path) == 0
      || string.byte_size(path) > 4096
      || !string.starts_with(path, "/")
      || string.contains(path, "\u{0}")
      || string.contains(path, "\\"),
    Error(Invalid),
  )
  use <- bool.guard(
    !list.all(string.split(string.drop_start(path, 1), "/"), fn(part) {
      part != "" && part != "." && part != ".."
    }),
    Error(Invalid),
  )
  Ok(Nil)
}
