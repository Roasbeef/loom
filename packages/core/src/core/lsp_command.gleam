//// Original identities and finite timing data for the registered LSP service.
////
//// Startup and Search have disjoint complete parents. A Search retains its
//// original finite request and the checked enrolled profile/root; it cannot
//// construct a server lease. These values describe identity, never a live claim.
//// The serialized custody writer owns first capture, nonce consumption and the
//// sole first timed admission. Semantic bytes and digests come from lsp_wire;
//// core neither interprets host query types nor hashes or performs effects.
////
//// Parent references name the complete original child and physical coordinates.
//// A proposal requires equality with the owner's actual original parent record
//// and remaining interval. Decoded proposal/history values do not reconstruct
//// that live parent control. E0 stays in the executor's original clock era.
////
//// ## Flow
////
//// `original_child_ref` → `parent_control` → `lsp_capture` → `finite_anchor` → `verify_parent_control` → `finite_timing_proposal` → `lsp_invocation` → `lsp_search_command`
////
//// `lsp_service_key` → `lsp_startup_command` builds the separate lease family.
//// `admitted_control` checks timing data before the custody writer's first claim.
//// `decode_lease_value`, `decode_capture_value`, `decode_invocation_value` and
//// `decode_command_value` read identity/history without producing live authority.

import core/generation as g
import core/ids
import core/msgpack as m
import core/remote_tool as r
import core/workspace as w
import gleam/bit_array
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Fixed refusal categories contain no rejected peer body.
pub type IdentityError {
  /// A bounded canonical identity field or closed shape was invalid.
  InvalidIdentity

  /// The complete immutable parent, scope or enrollment differs.
  ParentMismatch

  /// The original control has no positive remaining interval.
  ExpiredControl

  /// The complete command/header exceeds its fixed reservation.
  HeaderTooLarge
}

/// The three startup commands beneath an exact original lease.
pub type LspStartupRole {
  /// Fixed ten-second confinement check.
  Probe

  /// The immutable administratively enrolled dependency recipe.
  Prepare

  /// The separately timed session-owned protocol process.
  ServerLease
}

/// Complete original child data; construction grants no effect permission.
pub opaque type OriginalChildRef {
  /// The complete checked fields retained by this opaque boundary.
  OriginalChildRef(
    /// The complete original checked child origin.
    origin: r.ChildOrigin,
    /// The complete session, executor, workspace and both epochs.
    scope: w.Scope,
    /// The original owning operation identity.
    operation: ids.OpId,
    /// The retained original physical operation step.
    step: w.Step,
    /// The original durable request identity.
    request_id: ids.EntryId,
    /// The exact canonical semantic input digest.
    input_digest: g.Digest,
  )
}

/// A complete original durable control reference, without executable authority.
/// Actual managed-control provenance is verified by the trusted owner boundary.
pub opaque type OriginalParentControlRef {
  /// The original admitted tool or observation child.
  ParentControl(
    /// The original admitted controlled child reference.
    child: OriginalChildRef,
  )

  /// The landed write and its original admitted post-write child.
  PostWriteControl(
    /// The original physically landed write reference.
    write: OriginalChildRef,
    /// The original admitted controlled child reference.
    child: OriginalChildRef,
  )
}

/// Semantic input bytes have an independent digest before timing exists.
pub opaque type SemanticInput {
  /// The complete checked fields retained by this opaque boundary.
  SemanticInput(
    /// The unchanged bounded canonical semantic body.
    bytes: BitArray,
    /// The exact semantic body digest supplied by the checked adapter.
    digest: g.Digest,
    /// The closed protocol-076 request discriminant.
    tag: Int,
  )
}

/// The concrete executor clock incarnation, independent of scope and tick values.
pub opaque type ClockEra {
  /// The complete checked fields retained by this opaque boundary.
  ClockEra(
    /// The canonical executor-incarnation UUID spelling.
    value: String,
  )
}

/// A complete original lease identity; its input retains name/root/incarnation.
pub opaque type LspServiceKey {
  /// The complete checked fields retained by this opaque boundary.
  LspServiceKey(
    /// The complete original checked child origin.
    origin: r.ChildOrigin,
    /// The complete session, executor, workspace and both epochs.
    scope: w.Scope,
    /// The original owning operation identity.
    operation: ids.OpId,
    /// The retained original physical operation step.
    step: w.Step,
    /// The original durable request identity.
    request_id: ids.EntryId,
    /// The exact canonical semantic input digest.
    input_digest: g.Digest,
    /// The immutable checked enrollment digest.
    enrollment_digest: g.Digest,
    /// The committed closed service contract digest.
    contract_digest: g.Digest,
  )
}

/// A content-independent finite address with immutable request/control evidence.
pub opaque type FiniteCapture {
  /// The complete checked fields retained by this opaque boundary.
  FiniteCapture(
    /// The complete original checked child origin.
    origin: r.ChildOrigin,
    /// The complete session, executor, workspace and both epochs.
    scope: w.Scope,
    /// The original owning operation identity.
    operation: ids.OpId,
    /// The retained original physical operation step.
    step: w.Step,
    /// The original durable request identity.
    request_id: ids.EntryId,
    /// The checked original semantic bytes, digest and closed request tag.
    input: SemanticInput,
    /// The complete original durable parent-control reference.
    parent: OriginalParentControlRef,
    /// The immutable checked enrollment digest.
    enrollment_digest: g.Digest,
    /// The committed closed service contract digest.
    contract_digest: g.Digest,
  )
}

/// An original captured nonce and era, without executor tick on the wire.
pub opaque type FiniteAnchor {
  /// The complete checked fields retained by this opaque boundary.
  FiniteAnchor(
    /// The original concrete executor clock incarnation.
    era: ClockEra,
    /// The original single-use finite capture nonce.
    nonce: g.Digest,
    /// The canonical digest of the complete original control reference.
    parent_digest: g.Digest,
  )
}

/// Equality with the actual owner parent precedes remaining-duration projection.
pub opaque type VerifiedParentControl {
  /// The complete checked fields retained by this opaque boundary.
  VerifiedParentControl(
    /// The complete original durable parent-control reference.
    parent: OriginalParentControlRef,
    /// The positive original sampled remaining allowance.
    remaining_ms: Int,
  )
}

/// The immutable causal timing proposal, never a renewable absolute deadline.
pub opaque type FiniteTimingProposal {
  /// The complete checked fields retained by this opaque boundary.
  FiniteTimingProposal(
    /// The original captured clock era, nonce and control digest.
    anchor: FiniteAnchor,
    /// The positive original sampled remaining allowance.
    remaining_ms: Int,
    /// The complete original durable parent-control reference.
    parent: OriginalParentControlRef,
  )
}

/// A complete original invocation including its unchanged timing proposal.
pub opaque type LspInvocation {
  /// The complete checked fields retained by this opaque boundary.
  LspInvocation(
    /// The complete original preliminary finite capture.
    capture: FiniteCapture,
    /// The exact unchanged causal timing proposal.
    proposal: FiniteTimingProposal,
  )
}

/// An invocation key retains the complete timed parent rather than an address.
pub type LspInvocationKey =
  LspInvocation

/// A startup command retains its exact separately session-owned lease.
pub type ExactLeaseKey =
  LspServiceKey

/// Search retains its actual original finite invocation.
pub type OriginalFiniteInvocation =
  LspInvocationKey

/// One immutable configured label and canonical enrolled workspace root.
pub type Profile {
  /// Metadata projected from the already checked administrative enrollment.
  Profile(
    /// The immutable configured server label.
    server: String,
    /// The canonical administratively enrolled workspace root.
    workspace_root: String,
  )
}

/// The admitted ordered profile inventory, bounded before registration.
pub opaque type EnrolledProfiles {
  /// The complete checked fields retained by this opaque boundary.
  EnrolledProfiles(
    /// The complete session, executor, workspace and both epochs.
    scope: w.Scope,
    /// The immutable checked enrollment digest.
    enrollment_digest: g.Digest,
    /// The immutable ordered profile inventory, capped at sixteen.
    profiles: List(Profile),
  )
}

/// A checked ordinal still carries its actual enrolled inventory projection.
pub opaque type CheckedProfileOrdinal {
  /// The complete checked fields retained by this opaque boundary.
  CheckedProfileOrdinal(
    /// The complete session, executor, workspace and both epochs.
    scope: w.Scope,
    /// The immutable checked enrollment digest.
    enrollment_digest: g.Digest,
    /// The index checked against the actual enrolled inventory.
    ordinal: Int,
    /// The actual checked enrolled profile projection.
    profile: Profile,
  )
}

/// Warm search names the manager's retained selected server/root.
pub opaque type SelectedProject {
  /// The complete checked fields retained by this opaque boundary.
  SelectedProject(
    /// The actual checked enrolled profile projection.
    profile: CheckedProfileOrdinal,
    /// The canonical root derived from enrollment or manager selection.
    root: String,
  )
}

/// A root derived from cold enrollment or the exact warm selection.
pub opaque type CheckedSearchRoot {
  /// The complete checked fields retained by this opaque boundary.
  CheckedSearchRoot(
    /// The actual checked enrolled profile projection.
    profile: CheckedProfileOrdinal,
    /// The canonical root derived from enrollment or manager selection.
    root: String,
  )
}

/// The two parent forms have no interchangeable role selector.
pub type LspCommandParent {
  /// Only an exact lease admits the closed startup roles.
  Startup(
    /// The exact separately session-owned startup lease.
    lease: ExactLeaseKey,
  )

  /// Only an original finite invocation admits one checked profile/root search.
  Search(
    /// The complete original timed finite parent.
    invocation: OriginalFiniteInvocation,
    /// The actual checked enrolled profile projection.
    profile: CheckedProfileOrdinal,
    /// The canonical root derived from enrollment or manager selection.
    root: CheckedSearchRoot,
  )
}

/// A complete command association; Search has no startup-role field.
pub opaque type LspCommandRef {
  /// The exact lease and its closed startup role.
  StartupCommand(
    /// The exact separately session-owned startup lease.
    lease: LspServiceKey,
    /// The closed startup role admitted beneath that lease.
    role: LspStartupRole,
  )

  /// The original finite invocation and checked search selection.
  SearchCommand(
    /// The complete original timed finite parent.
    invocation: LspInvocation,
    /// The actual checked enrolled profile projection.
    profile: CheckedProfileOrdinal,
    /// The canonical root derived from enrollment or manager selection.
    root: CheckedSearchRoot,
  )
}

/// Executor-local immutable admitted timing; this is data, not a live claim.
pub opaque type AdmittedFiniteControl {
  /// The complete checked fields retained by this opaque boundary.
  AdmittedFiniteControl(
    /// The original concrete executor clock incarnation.
    era: ClockEra,
    /// The original executor-local E0 capture tick.
    anchor_tick: Int,
    /// The positive original sampled remaining allowance.
    remaining_ms: Int,
    /// The original executor-local E0 plus sampled allowance.
    deadline_tick: Int,
    /// The canonical unchanged timing-proposal digest.
    timing_digest: g.Digest,
  )
}

/// Validates the complete original child relation without inventing coordinates.
///
/// ## Examples
///
/// A tool parent from another session or operation is refused.
pub fn original_child_ref(
  origin: r.ChildOrigin,
  scope: w.Scope,
  operation: ids.OpId,
  step: w.Step,
  request_id: ids.EntryId,
  input_digest: g.Digest,
) -> Result(OriginalChildRef, IdentityError) {
  use Nil <- result.try(origin_matches(origin, scope, operation))
  Ok(OriginalChildRef(
    origin:,
    scope:,
    operation:,
    step:,
    request_id:,
    input_digest:,
  ))
}

/// Wraps the complete original child reference, never ChildOrigin alone.
/// Construction checks identity and size; it cannot establish live provenance.
///
/// ## Examples
///
/// `parent_control(child)` refuses an oversized complete reference.
pub fn parent_control(
  child: OriginalChildRef,
) -> Result(OriginalParentControlRef, IdentityError) {
  let ref = ParentControl(child)
  use Nil <- result.try(fits(parent_value(ref), 1024))
  Ok(ref)
}

/// Binds the original write and its separately admitted post-write child.
///
/// ## Examples
///
/// Different scopes or operations refuse before durable reference construction.
pub fn post_write_control(
  write: OriginalChildRef,
  child: OriginalChildRef,
) -> Result(OriginalParentControlRef, IdentityError) {
  use <- bool.guard(
    write.scope != child.scope || write.operation != child.operation,
    Error(ParentMismatch),
  )
  let ref = PostWriteControl(write, child)
  use Nil <- result.try(fits(parent_value(ref), 1024))
  Ok(ref)
}

/// Retains bounded semantic bytes/digest supplied by the checked semantic codec.
/// This validates identity framing; lsp_wire validates request meaning and hash.
///
/// ## Examples
///
/// A request body above 131072 bytes is refused before capture.
pub fn semantic_input(
  bytes: BitArray,
  digest: g.Digest,
  tag: Int,
) -> Result(SemanticInput, IdentityError) {
  use <- bool.guard(
    tag < 0
      || tag > 9
      || bit_array.bit_size(bytes) % 8 != 0
      || bit_array.byte_size(bytes) == 0
      || bit_array.byte_size(bytes) > 131_072,
    Error(InvalidIdentity),
  )
  Ok(SemanticInput(bytes:, digest:, tag:))
}

/// Validates canonical UUID syntax for a trusted installed clock incarnation.
/// A decoder validates syntax only; assembly establishes the actual clock.
///
/// ## Examples
///
/// Uppercase UUID spellings are refused.
pub fn clock_era(value: String) -> Result(ClockEra, IdentityError) {
  case <<value:utf8>> {
    <<
      a:bytes-size(8),
      "-",
      b:bytes-size(4),
      "-",
      c:bytes-size(4),
      "-",
      d:bytes-size(4),
      "-",
      e:bytes-size(12),
    >> -> {
      use <- bool.guard(
        !list.all([a, b, c, d, e], lowercase_hex),
        Error(InvalidIdentity),
      )
      Ok(ClockEra(value))
    }
    _ -> Error(InvalidIdentity)
  }
}

/// Constructs a separately session-owned lease from the real lsp system family.
///
/// ## Examples
///
/// A tool child or another system service cannot construct ServerLease identity.
pub fn lsp_service_key(
  origin: r.ChildOrigin,
  scope: w.Scope,
  operation: ids.OpId,
  step: w.Step,
  request_id: ids.EntryId,
  input_digest: g.Digest,
  enrollment_digest: g.Digest,
  contract_digest: g.Digest,
) -> Result(LspServiceKey, IdentityError) {
  use Nil <- result.try(origin_matches(origin, scope, operation))
  use Nil <- result.try(case r.child_fields(origin) {
    r.SystemFields(_, "lsp", _) -> Ok(Nil)
    _ -> Error(ParentMismatch)
  })
  let key =
    LspServiceKey(
      origin:,
      scope:,
      operation:,
      step:,
      request_id:,
      input_digest:,
      enrollment_digest:,
      contract_digest:,
    )
  use Nil <- result.try(fits(lease_value(key), 8192))
  Ok(key)
}

/// Retains original finite identity before asking the executor for its anchor.
///
/// ## Examples
///
/// A changed child origin cannot borrow another parent's control reference.
pub fn lsp_capture(
  origin: r.ChildOrigin,
  scope: w.Scope,
  operation: ids.OpId,
  step: w.Step,
  request_id: ids.EntryId,
  input: SemanticInput,
  parent: OriginalParentControlRef,
  enrollment_digest: g.Digest,
  contract_digest: g.Digest,
) -> Result(FiniteCapture, IdentityError) {
  use Nil <- result.try(origin_matches(origin, scope, operation))

  // Ordinary queries retain the actual admitted tool/capability origin. The
  // existing lsp system family is reserved for a separately checked AfterWrite.

  use Nil <- result.try(case r.child_fields(origin) {
    r.ToolFields(_, _) -> Ok(Nil)
    r.SystemFields(_, "lsp", _) if input.tag == 8 -> Ok(Nil)
    r.SystemFields(_, _, _) -> Error(InvalidIdentity)
  })
  let child = controlled_child(parent)
  use <- bool.guard(
    child.origin != origin
      || child.scope != scope
      || child.operation != operation
      || child.step != step
      || child.request_id != request_id
      || child.input_digest != input.digest,
    Error(ParentMismatch),
  )
  use <- bool.guard(
    input.tag == 8
      && !is_post_write(parent)
      || input.tag != 8
      && is_post_write(parent),
    Error(ParentMismatch),
  )
  let capture =
    FiniteCapture(
      origin:,
      scope:,
      operation:,
      step:,
      request_id:,
      input:,
      parent:,
      enrollment_digest:,
      contract_digest:,
    )
  use Nil <- result.try(fits(capture_value(capture), 8192))
  Ok(capture)
}

/// Represents one checked anchor response without exposing E0 across hosts.
///
/// ## Examples
///
/// Nonce and digest are already checked exact 32-byte values.
pub fn finite_anchor(
  era: ClockEra,
  nonce: g.Digest,
  parent_digest: g.Digest,
) -> FiniteAnchor {
  FiniteAnchor(era:, nonce:, parent_digest:)
}

/// Compares retained provenance with the actual original owner's control record.
/// The trusted caller supplies times from that original live managed control.
///
/// ## Examples
///
/// Observe includes all elapsed time since its original admission.
pub fn verify_parent_control(
  retained: FiniteCapture,
  actual: OriginalParentControlRef,
  parent_deadline: Int,
  parent_now: Int,
  observation_admission: Option(Int),
) -> Result(VerifiedParentControl, IdentityError) {
  use <- bool.guard(retained.parent != actual, Error(ParentMismatch))
  use <- bool.guard(
    !signed_tick(parent_deadline)
      || !signed_tick(parent_now)
      || { retained.input.tag == 9 } != { observation_admission != None },
    Error(InvalidIdentity),
  )
  let remaining = minimum(parent_deadline - parent_now, 86_400_000)
  use remaining <- result.try(case observation_admission {
    None -> Ok(remaining)
    Some(admitted) -> {
      use <- bool.guard(
        !signed_tick(admitted) || admitted > parent_now,
        Error(InvalidIdentity),
      )
      Ok(minimum(remaining, 75_000 - { parent_now - admitted }))
    }
  })
  use <- bool.guard(
    parent_deadline == 0 || remaining <= 0,
    Error(ExpiredControl),
  )
  Ok(VerifiedParentControl(retained.parent, remaining))
}

/// Builds the immutable proposal only from the verified actual parent interval.
/// The parent digest is computed by the effect-layer canonical hash adapter.
///
/// ## Examples
///
/// A response anchored to another original control digest is refused.
pub fn finite_timing_proposal(
  anchor: FiniteAnchor,
  parent: VerifiedParentControl,
  actual_parent_digest: g.Digest,
) -> Result(FiniteTimingProposal, IdentityError) {
  use <- bool.guard(
    anchor.parent_digest != actual_parent_digest,
    Error(ParentMismatch),
  )
  Ok(FiniteTimingProposal(anchor, parent.remaining_ms, parent.parent))
}

/// Joins the exact original capture and unchanged causally sampled timing.
/// The checked adapter supplies the hash of this capture's parent reference.
///
/// ## Examples
///
/// Proposal changes remain different immutable invocation evidence.
pub fn lsp_invocation(
  capture: FiniteCapture,
  proposal: FiniteTimingProposal,
  parent_digest: g.Digest,
) -> Result(LspInvocation, IdentityError) {
  use <- bool.guard(
    proposal.anchor.parent_digest != parent_digest
      || proposal.parent != capture.parent,
    Error(ParentMismatch),
  )
  use <- bool.guard(
    capture.input.tag == 9 && proposal.remaining_ms > 75_000,
    Error(InvalidIdentity),
  )
  let invocation = LspInvocation(capture, proposal)
  use Nil <- result.try(fits(invocation_value(invocation), 8192))
  Ok(invocation)
}

/// Checks the complete immutable profile inventory before Registered admission.
///
/// ## Examples
///
/// A seventeenth profile is refused; no configured suffix is dropped.
pub fn enrolled_profiles(
  scope: w.Scope,
  enrollment_digest: g.Digest,
  profiles: List(Profile),
) -> Result(EnrolledProfiles, IdentityError) {
  use <- bool.guard(
    profiles == [] || list.drop(profiles, 16) != [],
    Error(InvalidIdentity),
  )
  use _ <- result.try(
    list.try_map(profiles, fn(profile) {
      use <- bool.guard(
        string.byte_size(profile.server) == 0
          || string.byte_size(profile.server) > 128
          || string.contains(profile.server, "\u{0000}"),
        Error(InvalidIdentity),
      )
      canonical_root(profile.workspace_root)
    }),
  )
  use <- bool.guard(
    list.length(list.unique(list.map(profiles, fn(p) { p.server })))
      != list.length(profiles),
    Error(InvalidIdentity),
  )
  Ok(EnrolledProfiles(scope:, enrollment_digest:, profiles:))
}

/// Selects an actual ordinal from the bounded immutable enrollment.
///
/// ## Examples
///
/// `checked_profile(profiles, 16)` refuses a peer-invented seventeenth ordinal.
pub fn checked_profile(
  inventory: EnrolledProfiles,
  ordinal: Int,
) -> Result(CheckedProfileOrdinal, IdentityError) {
  use <- bool.guard(ordinal < 0 || ordinal >= 16, Error(InvalidIdentity))
  use profile <- result.try(
    list.first(list.drop(inventory.profiles, ordinal))
    |> result.replace_error(InvalidIdentity),
  )
  Ok(CheckedProfileOrdinal(
    inventory.scope,
    inventory.enrollment_digest,
    ordinal,
    profile,
  ))
}

/// Records the exact profile/root selected by the trusted manager.
/// The adapter compares this metadata with its actual retained by_project result.
///
/// ## Examples
///
/// A selection for a different configured server is refused.
pub fn selected_project(
  profile: CheckedProfileOrdinal,
  server: String,
  canonical_project_root: String,
) -> Result(SelectedProject, IdentityError) {
  use <- bool.guard(profile.profile.server != server, Error(ParentMismatch))
  use Nil <- result.try(canonical_root(canonical_project_root))
  Ok(SelectedProject(profile, canonical_project_root))
}

/// Derives a cold Search root directly from that profile's enrolled workspace.
///
/// ## Examples
///
/// Cold resolution cannot substitute a selected project or peer root.
pub fn cold_search_root(profile: CheckedProfileOrdinal) -> CheckedSearchRoot {
  CheckedSearchRoot(profile, profile.profile.workspace_root)
}

/// Derives a warm Search root from the manager's exact retained selection.
///
/// ## Examples
///
/// Warm calls search their selected profile rather than all configured profiles.
pub fn warm_search_root(selected: SelectedProject) -> CheckedSearchRoot {
  CheckedSearchRoot(selected.profile, selected.root)
}

/// Constructs only one of the three closed startup roles beneath a lease.
///
/// ## Examples
///
/// Search has a different constructor and cannot be selected here.
pub fn lsp_startup_command(
  lease: ExactLeaseKey,
  role: LspStartupRole,
) -> Result(LspCommandRef, IdentityError) {
  let ref = StartupCommand(lease, role)
  use Nil <- result.try(fits(command_value(ref), 8192))
  Ok(ref)
}

/// Binds Search to its actual finite parent and checked enrolled profile/root.
///
/// ## Examples
///
/// Another scope, enrollment or profile cannot share an earlier search row.
pub fn lsp_search_command(
  invocation: OriginalFiniteInvocation,
  profile: CheckedProfileOrdinal,
  root: CheckedSearchRoot,
) -> Result(LspCommandRef, IdentityError) {
  use <- bool.guard(
    profile != root.profile
      || profile.scope != invocation.capture.scope
      || profile.enrollment_digest != invocation.capture.enrollment_digest,
    Error(ParentMismatch),
  )
  let ref = SearchCommand(invocation, profile, root)
  use Nil <- result.try(fits(command_value(ref), 8192))
  Ok(ref)
}

/// Validates executor-local admitted timing without returning dispatch authority.
/// The custody transaction alone consumes the nonce and creates its first claim.
///
/// ## Examples
///
/// Negative E0 is valid; expired windows, changed era and zero deadline refuse.
pub fn admitted_control(
  anchor: FiniteAnchor,
  proposal: FiniteTimingProposal,
  anchor_tick: Int,
  current_tick: Int,
  current_era: ClockEra,
  timing_digest: g.Digest,
) -> Result(AdmittedFiniteControl, IdentityError) {
  use <- bool.guard(
    anchor != proposal.anchor || anchor.era != current_era,
    Error(ParentMismatch),
  )
  use <- bool.guard(
    !signed_tick(anchor_tick) || !signed_tick(current_tick),
    Error(InvalidIdentity),
  )
  let deadline = anchor_tick + proposal.remaining_ms
  use <- bool.guard(
    !signed_tick(deadline)
      || deadline == 0
      || current_tick < anchor_tick
      || current_tick - anchor_tick >= 1000
      || current_tick >= deadline,
    Error(ExpiredControl),
  )
  Ok(AdmittedFiniteControl(
    current_era,
    anchor_tick,
    proposal.remaining_ms,
    deadline,
    timing_digest,
  ))
}

/// Returns exact immutable local timing for custody readback and physical checks.
///
/// ## Examples
///
/// A receipt never changes the original anchor or deadline.
pub fn control_fields(
  control: AdmittedFiniteControl,
) -> #(ClockEra, Int, Int, Int, g.Digest) {
  #(
    control.era,
    control.anchor_tick,
    control.remaining_ms,
    control.deadline_tick,
    control.timing_digest,
  )
}

/// Returns the concrete clock-incarnation spelling without comparing hosts.
///
/// ## Examples
///
/// An old era remains historical even when a later clock repeats its tick.
pub fn era_string(era: ClockEra) -> String {
  era.value
}

/// Returns exact semantic bytes, digest and closed operation tag.
///
/// ## Examples
///
/// The semantic body digest does not depend on later proposal bytes.
pub fn input_fields(input: SemanticInput) -> #(BitArray, g.Digest, Int) {
  #(input.bytes, input.digest, input.tag)
}

/// Returns the complete parent reference held by an original capture.
///
/// ## Examples
///
/// `capture_parent(capture)` never resolves a latest control.
pub fn capture_parent(capture: FiniteCapture) -> OriginalParentControlRef {
  capture.parent
}

/// Returns the unchanged preliminary capture retained by a timed invocation.
///
/// ## Examples
///
/// A timed duplicate has the same original coordinates as CaptureFinite.
pub fn invocation_capture(invocation: LspInvocation) -> FiniteCapture {
  invocation.capture
}

/// Returns the original proposal rather than computing later remaining time.
///
/// ## Examples
///
/// Query of an old invocation cannot refresh its proposal.
pub fn invocation_proposal(invocation: LspInvocation) -> FiniteTimingProposal {
  invocation.proposal
}

/// Encodes the original durable control reference in its closed form.
///
/// ## Examples
///
/// AfterWrite names both its original write and admitted finite child.
pub fn parent_value(parent: OriginalParentControlRef) -> m.MsgPackValue {
  case parent {
    ParentControl(child) ->
      m.ArrayValue([m.IntValue(0), child_ref_value(child)])
    PostWriteControl(write, child) ->
      m.ArrayValue([
        m.IntValue(1),
        child_ref_value(write),
        child_ref_value(child),
      ])
  }
}

/// Encodes the exact bounded timing proposal without an owner absolute time.
///
/// ## Examples
///
/// Timing always retains the originally received era, nonce and parent digest.
pub fn timing_value(proposal: FiniteTimingProposal) -> m.MsgPackValue {
  m.ArrayValue([
    m.IntValue(1),
    m.StringValue(proposal.anchor.era.value),
    m.BinaryValue(g.digest_bytes(proposal.anchor.nonce)),
    m.IntValue(proposal.remaining_ms),
    m.BinaryValue(g.digest_bytes(proposal.anchor.parent_digest)),
  ])
}

/// Encodes the checked capture response with no executor anchor tick.
///
/// ## Examples
///
/// The capture response is bounded independently of the semantic result.
pub fn anchor_value(anchor: FiniteAnchor) -> m.MsgPackValue {
  m.ArrayValue([
    m.IntValue(1),
    m.StringValue(anchor.era.value),
    m.BinaryValue(g.digest_bytes(anchor.nonce)),
    m.BinaryValue(g.digest_bytes(anchor.parent_digest)),
  ])
}

/// Encodes the complete original lease header, with nil timing and control.
///
/// ## Examples
///
/// Startup cannot encode an admitted finite invocation as a lease.
pub fn lease_value(lease: LspServiceKey) -> m.MsgPackValue {
  header(
    0,
    lease.scope,
    lease.origin,
    lease.operation,
    lease.step,
    lease.request_id,
    lease.input_digest,
    lease.enrollment_digest,
    lease.contract_digest,
    m.NilValue,
    m.NilValue,
  )
}

/// Encodes preliminary CaptureFinite with its unchanged semantic input digest.
///
/// ## Examples
///
/// Capturing has a nil timing field and a complete original control reference.
pub fn capture_value(capture: FiniteCapture) -> m.MsgPackValue {
  header(
    1,
    capture.scope,
    capture.origin,
    capture.operation,
    capture.step,
    capture.request_id,
    capture.input.digest,
    capture.enrollment_digest,
    capture.contract_digest,
    m.NilValue,
    parent_value(capture.parent),
  )
}

/// Encodes the timed invocation with the exact original capture and proposal.
///
/// ## Examples
///
/// InputDigest stays unchanged when timing is added to the header.
pub fn invocation_value(invocation: LspInvocation) -> m.MsgPackValue {
  let c = invocation.capture
  header(
    1,
    c.scope,
    c.origin,
    c.operation,
    c.step,
    c.request_id,
    c.input.digest,
    c.enrollment_digest,
    c.contract_digest,
    timing_value(invocation.proposal),
    parent_value(c.parent),
  )
}

/// Encodes both complete command parent forms with disjoint closed tags.
///
/// ## Examples
///
/// A Search row has no startup role and retains its exact timed parent.
pub fn command_value(ref: LspCommandRef) -> m.MsgPackValue {
  m.ArrayValue([
    m.IntValue(1),
    case ref {
      StartupCommand(lease, role) ->
        m.ArrayValue([
          m.IntValue(0),
          lease_value(lease),
          m.IntValue(case role {
            Probe -> 0
            Prepare -> 1
            ServerLease -> 2
          }),
        ])
      SearchCommand(invocation, profile, root) ->
        m.ArrayValue([
          m.IntValue(1),
          invocation_value(invocation),
          m.IntValue(profile.ordinal),
          m.StringValue(root.root),
        ])
    },
  ])
}

/// Returns the closed parent projection without creating another association.
///
/// ## Examples
///
/// A query parent can never be projected as Startup.
pub fn command_parent(ref: LspCommandRef) -> LspCommandParent {
  case ref {
    StartupCommand(lease, _) -> Startup(lease)
    SearchCommand(invocation, profile, root) ->
      Search(invocation, profile, root)
  }
}

/// Returns a content-independent original finite address.
///
/// ## Examples
///
/// Changed semantic bytes still find the original conflict fence.
pub fn capture_address(capture: FiniteCapture) -> String {
  identity_address(
    1,
    capture.scope,
    capture.origin,
    capture.operation,
    capture.step,
    capture.request_id,
  )
}

/// Returns a content-independent original lease address.
///
/// ## Examples
///
/// Changed lease input cannot allocate a second original row.
pub fn lease_address(lease: LspServiceKey) -> String {
  identity_address(
    0,
    lease.scope,
    lease.origin,
    lease.operation,
    lease.step,
    lease.request_id,
  )
}

/// Returns the complete parent-coordinate command address without content hashes.
///
/// ## Examples
///
/// Each new finite invocation gives its Search a disjoint association.
pub fn command_address(ref: LspCommandRef) -> String {
  let fields = case ref {
    StartupCommand(lease, role) ->
      m.ArrayValue([
        m.IntValue(0),
        m.StringValue(lease_address(lease)),
        m.IntValue(case role {
          Probe -> 0
          Prepare -> 1
          ServerLease -> 2
        }),
      ])
    SearchCommand(invocation, profile, root) ->
      m.ArrayValue([
        m.IntValue(1),
        m.StringValue(capture_address(invocation.capture)),
        m.IntValue(profile.ordinal),
        m.StringValue(root.root),
      ])
  }
  encoded_address(fields)
}

fn child_ref_value(child: OriginalChildRef) -> m.MsgPackValue {
  m.ArrayValue([
    r.child_value(child.origin),
    scope_value(child.scope),
    m.StringValue(ids.op_id_to_string(child.operation)),
    m.StringValue(w.step_string(child.step)),
    m.StringValue(ids.entry_id_to_string(child.request_id)),
    m.BinaryValue(g.digest_bytes(child.input_digest)),
  ])
}

fn header(
  kind: Int,
  scope: w.Scope,
  origin: r.ChildOrigin,
  operation: ids.OpId,
  step: w.Step,
  request_id: ids.EntryId,
  input: g.Digest,
  enrollment: g.Digest,
  contract: g.Digest,
  timing: m.MsgPackValue,
  parent: m.MsgPackValue,
) -> m.MsgPackValue {
  m.ArrayValue([
    m.IntValue(1),
    m.IntValue(kind),
    scope_value(scope),
    r.child_value(origin),
    m.StringValue(ids.op_id_to_string(operation)),
    m.StringValue(w.step_string(step)),
    m.StringValue(ids.entry_id_to_string(request_id)),
    m.BinaryValue(g.digest_bytes(input)),
    m.BinaryValue(g.digest_bytes(enrollment)),
    m.BinaryValue(g.digest_bytes(contract)),
    timing,
    parent,
  ])
}

fn scope_value(scope: w.Scope) -> m.MsgPackValue {
  let #(session, binding) = w.scope_fields(scope)
  let #(selector, workspace_epoch, session_epoch) = w.binding_fields(binding)
  let #(executor, workspace) = w.selector_fields(selector)
  m.ArrayValue([
    m.StringValue(ids.session_id_to_string(session)),
    m.StringValue(executor),
    m.StringValue(workspace),
    m.IntValue(workspace_epoch),
    m.IntValue(session_epoch),
  ])
}

fn origin_matches(
  origin: r.ChildOrigin,
  scope: w.Scope,
  operation: ids.OpId,
) -> Result(Nil, IdentityError) {
  use <- bool.guard(
    r.child_session(origin) != w.scope_fields(scope).0,
    Error(ParentMismatch),
  )
  case r.child_fields(origin) {
    r.ToolFields(parent, _) -> {
      use <- bool.guard(r.operation(parent) != operation, Error(ParentMismatch))
      Ok(Nil)
    }
    r.SystemFields(_, _, _) -> Ok(Nil)
  }
}

fn controlled_child(parent: OriginalParentControlRef) -> OriginalChildRef {
  case parent {
    ParentControl(child) | PostWriteControl(_, child) -> child
  }
}

fn is_post_write(parent: OriginalParentControlRef) -> Bool {
  case parent {
    ParentControl(_) -> False
    PostWriteControl(_, _) -> True
  }
}

fn canonical_root(root: String) -> Result(Nil, IdentityError) {
  use <- bool.guard(
    string.byte_size(root) == 0
      || string.byte_size(root) > 8192
      || !string.starts_with(root, "/")
      || string.contains(root, "\u{0000}")
      || string.contains(root, "\\"),
    Error(InvalidIdentity),
  )
  case root {
    "/" -> Ok(Nil)
    _ -> {
      use <- bool.guard(
        !list.all(string.split(string.drop_start(root, 1), "/"), fn(part) {
          part != "" && part != "." && part != ".."
        }),
        Error(InvalidIdentity),
      )
      Ok(Nil)
    }
  }
}

fn fits(value: m.MsgPackValue, limit: Int) -> Result(Nil, IdentityError) {
  use bytes <- result.try(
    m.encode(value) |> result.replace_error(InvalidIdentity),
  )
  case bit_array.byte_size(bytes) <= limit {
    True -> Ok(Nil)
    False -> Error(HeaderTooLarge)
  }
}

fn signed_tick(tick: Int) -> Bool {
  tick >= -9_223_372_036_854_775_808 && tick <= 9_223_372_036_854_775_807
}

fn minimum(a: Int, b: Int) -> Int {
  case a < b {
    True -> a
    False -> b
  }
}

fn lowercase_hex(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<c, rest:bytes>> if c >= 48 && c <= 57 || c >= 97 && c <= 102 ->
      lowercase_hex(rest)
    _ -> False
  }
}

fn identity_address(
  kind: Int,
  scope: w.Scope,
  origin: r.ChildOrigin,
  operation: ids.OpId,
  step: w.Step,
  request_id: ids.EntryId,
) -> String {
  encoded_address(
    m.ArrayValue([
      m.IntValue(kind),
      scope_value(scope),
      m.StringValue(r.child_address(origin)),
      m.StringValue(ids.op_id_to_string(operation)),
      m.StringValue(w.step_string(step)),
      m.StringValue(ids.entry_id_to_string(request_id)),
    ]),
  )
}

fn encoded_address(value: m.MsgPackValue) -> String {
  case m.encode(value) {
    Ok(bytes) -> bit_array.base16_encode(bytes)
    Error(_) -> ""
  }
}

/// Decodes a complete original lease through the system-origin constructor.
///
/// ## Examples
///
/// Timed invocation headers cannot be decoded as startup leases.
pub fn decode_lease_value(
  value: m.MsgPackValue,
) -> Result(LspServiceKey, IdentityError) {
  case value {
    m.ArrayValue([
      m.IntValue(1),
      m.IntValue(0),
      scope,
      origin,
      op,
      step,
      id,
      input,
      enrollment,
      contract,
      m.NilValue,
      m.NilValue,
    ]) -> {
      use scope <- result.try(decode_scope(scope))
      use origin <- result.try(
        r.decode_child_value(origin) |> result.replace_error(InvalidIdentity),
      )
      use op <- result.try(parse_op(op))
      use step <- result.try(parse_step(step))
      use id <- result.try(parse_id(id))
      use input <- result.try(parse_digest(input))
      use enrollment <- result.try(parse_digest(enrollment))
      use contract <- result.try(parse_digest(contract))
      lsp_service_key(origin, scope, op, step, id, input, enrollment, contract)
    }
    _ -> Error(InvalidIdentity)
  }
}

/// Decodes preliminary capture and compares its exact semantic input digest.
///
/// ## Examples
///
/// CaptureFinite always requires nil timing and the complete control reference.
pub fn decode_capture_value(
  value: m.MsgPackValue,
  input: SemanticInput,
) -> Result(FiniteCapture, IdentityError) {
  case value {
    m.ArrayValue([
      m.IntValue(1),
      m.IntValue(1),
      scope,
      origin,
      op,
      step,
      id,
      digest,
      enrollment,
      contract,
      m.NilValue,
      parent,
    ]) -> {
      use scope <- result.try(decode_scope(scope))
      use origin <- result.try(
        r.decode_child_value(origin) |> result.replace_error(InvalidIdentity),
      )
      use op <- result.try(parse_op(op))
      use step <- result.try(parse_step(step))
      use id <- result.try(parse_id(id))
      use digest <- result.try(parse_digest(digest))
      use <- bool.guard(digest != input.digest, Error(ParentMismatch))
      use enrollment <- result.try(parse_digest(enrollment))
      use contract <- result.try(parse_digest(contract))
      use parent <- result.try(decode_parent_value(parent))
      lsp_capture(
        origin,
        scope,
        op,
        step,
        id,
        input,
        parent,
        enrollment,
        contract,
      )
    }
    _ -> Error(InvalidIdentity)
  }
}

/// Decodes a timed invocation as immutable data without reconstructing a claim.
///
/// ## Examples
///
/// Timing arity and positive allowance remain checked during historical reads.
pub fn decode_invocation_value(
  value: m.MsgPackValue,
  input: SemanticInput,
) -> Result(LspInvocation, IdentityError) {
  case value {
    m.ArrayValue([
      m.IntValue(1),
      m.IntValue(1),
      scope,
      origin,
      op,
      step,
      id,
      digest,
      enrollment,
      contract,
      timing,
      parent,
    ]) -> {
      use capture <- result.try(decode_capture_value(
        m.ArrayValue([
          m.IntValue(1),
          m.IntValue(1),
          scope,
          origin,
          op,
          step,
          id,
          digest,
          enrollment,
          contract,
          m.NilValue,
          parent,
        ]),
        input,
      ))
      use proposal <- result.try(decode_timing_value(timing, capture.parent))
      lsp_invocation(capture, proposal, proposal.anchor.parent_digest)
    }
    _ -> Error(InvalidIdentity)
  }
}

/// Decodes command identity against the actual immutable inventory and selection.
///
/// ## Examples
///
/// A peer root cannot replace either the cold enrolled root or warm selected root.
pub fn decode_command_value(
  value: m.MsgPackValue,
  input: SemanticInput,
  inventory: EnrolledProfiles,
  selected: Option(SelectedProject),
) -> Result(LspCommandRef, IdentityError) {
  case value {
    m.ArrayValue([
      m.IntValue(1),
      m.ArrayValue([m.IntValue(0), lease, m.IntValue(role)]),
    ]) -> {
      use lease <- result.try(decode_lease_value(lease))
      use role <- result.try(case role {
        0 -> Ok(Probe)
        1 -> Ok(Prepare)
        2 -> Ok(ServerLease)
        _ -> Error(InvalidIdentity)
      })
      lsp_startup_command(lease, role)
    }
    m.ArrayValue([
      m.IntValue(1),
      m.ArrayValue([
        m.IntValue(1),
        invocation,
        m.IntValue(ordinal),
        m.StringValue(root),
      ]),
    ]) -> {
      use invocation <- result.try(decode_invocation_value(invocation, input))
      use profile <- result.try(checked_profile(inventory, ordinal))
      let checked_root = case selected {
        None -> cold_search_root(profile)
        Some(selection) -> warm_search_root(selection)
      }
      use <- bool.guard(root != checked_root.root, Error(ParentMismatch))
      lsp_search_command(invocation, profile, checked_root)
    }
    _ -> Error(InvalidIdentity)
  }
}

/// Decodes original control provenance as bounded immutable reference data.
///
/// ## Examples
///
/// A decoded reference still requires equality with actual live owner custody.
pub fn decode_parent_value(
  value: m.MsgPackValue,
) -> Result(OriginalParentControlRef, IdentityError) {
  case value {
    m.ArrayValue([m.IntValue(0), child]) -> {
      use child <- result.try(decode_child_ref_value(child))
      parent_control(child)
    }
    m.ArrayValue([m.IntValue(1), write, child]) -> {
      use write <- result.try(decode_child_ref_value(write))
      use child <- result.try(decode_child_ref_value(child))
      post_write_control(write, child)
    }
    _ -> Error(InvalidIdentity)
  }
}

/// Decodes an exact bounded capture response, with no anchor tick field.
///
/// ## Examples
///
/// Surplus E0 or owner timestamp fields refuse rather than being ignored.
pub fn decode_anchor_value(
  value: m.MsgPackValue,
) -> Result(FiniteAnchor, IdentityError) {
  case value {
    m.ArrayValue([m.IntValue(1), m.StringValue(era), nonce, parent]) -> {
      use era <- result.try(clock_era(era))
      use nonce <- result.try(parse_digest(nonce))
      use parent <- result.try(parse_digest(parent))
      Ok(finite_anchor(era, nonce, parent))
    }
    _ -> Error(InvalidIdentity)
  }
}

/// Decodes a historical proposal with exact era, nonce and remaining allowance.
/// This creates no verified parent control or first-submit permission.
///
/// ## Examples
///
/// Zero, negative or greater-than-one-day remaining durations are refused.
pub fn decode_timing_value(
  value: m.MsgPackValue,
  original_parent: OriginalParentControlRef,
) -> Result(FiniteTimingProposal, IdentityError) {
  case value {
    m.ArrayValue([
      m.IntValue(1),
      m.StringValue(era),
      nonce,
      m.IntValue(remaining),
      parent,
    ]) -> {
      use era <- result.try(clock_era(era))
      use nonce <- result.try(parse_digest(nonce))
      use parent <- result.try(parse_digest(parent))
      use <- bool.guard(
        remaining <= 0 || remaining > 86_400_000,
        Error(InvalidIdentity),
      )
      Ok(FiniteTimingProposal(
        finite_anchor(era, nonce, parent),
        remaining,
        original_parent,
      ))
    }
    _ -> Error(InvalidIdentity)
  }
}

/// Encodes the complete child reference used by mutation and write identities.
///
/// ## Examples
///
/// Its original scope and physical coordinates remain part of equality.
pub fn original_child_value(child: OriginalChildRef) -> m.MsgPackValue {
  child_ref_value(child)
}

/// Decodes original child reference data through the existing identity checks.
///
/// ## Examples
///
/// Different parent operation or session coordinates are refused.
pub fn decode_child_ref_value(
  value: m.MsgPackValue,
) -> Result(OriginalChildRef, IdentityError) {
  case value {
    m.ArrayValue([origin, scope, operation, step, id, digest]) -> {
      use origin <- result.try(
        r.decode_child_value(origin) |> result.replace_error(InvalidIdentity),
      )
      use scope <- result.try(decode_scope(scope))
      use operation <- result.try(parse_op(operation))
      use step <- result.try(parse_step(step))
      use id <- result.try(parse_id(id))
      use digest <- result.try(parse_digest(digest))
      original_child_ref(origin, scope, operation, step, id, digest)
    }
    _ -> Error(InvalidIdentity)
  }
}

fn decode_scope(value: m.MsgPackValue) -> Result(w.Scope, IdentityError) {
  case value {
    m.ArrayValue([
      m.StringValue(session),
      m.StringValue(executor),
      m.StringValue(workspace),
      m.IntValue(workspace_epoch),
      m.IntValue(session_epoch),
    ]) ->
      w.scope_from_fields(
        session,
        workspace,
        executor,
        session_epoch,
        workspace_epoch,
      )
      |> result.replace_error(InvalidIdentity)
    _ -> Error(InvalidIdentity)
  }
}

fn parse_digest(value: m.MsgPackValue) -> Result(g.Digest, IdentityError) {
  case value {
    m.BinaryValue(bytes) ->
      g.digest(bytes) |> result.replace_error(InvalidIdentity)
    _ -> Error(InvalidIdentity)
  }
}

fn parse_op(value: m.MsgPackValue) -> Result(ids.OpId, IdentityError) {
  case value {
    m.StringValue(value) ->
      ids.parse_op_id(value) |> result.replace_error(InvalidIdentity)
    _ -> Error(InvalidIdentity)
  }
}

fn parse_step(value: m.MsgPackValue) -> Result(w.Step, IdentityError) {
  case value {
    m.StringValue(value) ->
      w.step(value) |> result.replace_error(InvalidIdentity)
    _ -> Error(InvalidIdentity)
  }
}

fn parse_id(value: m.MsgPackValue) -> Result(ids.EntryId, IdentityError) {
  case value {
    m.StringValue(value) ->
      ids.parse_entry_id(value) |> result.replace_error(InvalidIdentity)
    _ -> Error(InvalidIdentity)
  }
}
