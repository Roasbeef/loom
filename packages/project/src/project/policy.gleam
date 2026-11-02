//// What a worker's jail allows, derived from its Mandate and nothing else.
////
//// `for_mandate` takes a `Mandate` by type, so no model output, trigger text or
//// router note can reach it. Two mandates that differ only in who asked, which
//// source carried it, how it was admitted or which policy version wrote it
//// derive the same policy; only the authority fields move the result. Those
//// are the strength and whether the admitting rule granted approvals. The
//// result is monotone in strength: an explicit mandate never gets less than
//// an inferred one in any dimension.
////
//// | | Explicit | Inferred |
//// | --- | --- | --- |
//// | Network | the owner's session policy | package registries only, which the host maps to no network until the broker enforces an allowlist |
//// | Credentials | none | none |
//// | Approvals | go to a person | refused unless a rule grants them |
////
//// A worker holds no credential at either strength, because the host does
//// every push and pull request.

import project/model.{
  type Mandate, ApprovalsGranted, ApprovalsNotGranted, Explicit, Inferred,
}

/// How far a worker's network reaches.
pub type NetworkClass {
  /// Package registries only.
  RegistriesOnly

  /// Whatever the owner's session policy allows.
  OwnerSessionPolicy
}

/// The credentials a worker holds. There is one value, on purpose.
pub type Credentials {
  /// None, at every strength.
  NoCredentials
}

/// Where a worker's approval requests go.
pub type ApprovalRoute {
  /// They are refused.
  ApprovalsRefused

  /// They go to a person, never through the router.
  ApprovalsToPerson
}

/// A worker's policy as plain data. The host maps it onto a broker policy.
pub type WorkerPolicy {
  WorkerPolicy(
    /// The network class.
    network: NetworkClass,
    /// The credentials.
    credentials: Credentials,
    /// Where approvals go.
    approvals: ApprovalRoute,
  )
}

/// Derive the policy for a mandate.
///
/// ## Examples
///
/// ```gleam
/// let mandate = model.Mandate(
///   strength: model.Explicit,
///   basis: model.FromComposer,
///   actor: model.ActorId("me"),
///   source: model.SourceId("composer"),
///   scope: model.Scope("w", model.ApprovalsNotGranted),
///   policy_version: "v1",
/// )
/// assert policy.for_mandate(mandate).network == policy.OwnerSessionPolicy
/// ```
pub fn for_mandate(mandate: Mandate) -> WorkerPolicy {
  case mandate.strength {
    Explicit ->
      WorkerPolicy(OwnerSessionPolicy, NoCredentials, ApprovalsToPerson)
    Inferred ->
      WorkerPolicy(
        RegistriesOnly,
        NoCredentials,
        inferred_approvals(mandate.scope.approvals),
      )
  }
}

// An inferred mandate gets approvals only when its rule granted them.
fn inferred_approvals(grant: model.ApprovalGrant) -> ApprovalRoute {
  case grant {
    ApprovalsGranted -> ApprovalsToPerson
    ApprovalsNotGranted -> ApprovalsRefused
  }
}

/// The network class on a scale where larger reaches further.
///
/// ## Examples
///
/// ```gleam
/// assert policy.network_rank(policy.RegistriesOnly) == 1
/// ```
pub fn network_rank(network: NetworkClass) -> Int {
  case network {
    RegistriesOnly -> 1
    OwnerSessionPolicy -> 2
  }
}

/// The approval route on a scale where larger grants more.
///
/// ## Examples
///
/// ```gleam
/// assert policy.approval_rank(policy.ApprovalsRefused) == 0
/// ```
pub fn approval_rank(route: ApprovalRoute) -> Int {
  case route {
    ApprovalsRefused -> 0
    ApprovalsToPerson -> 1
  }
}
