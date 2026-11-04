//// What a project worker's jail allows, as the broker's own vocabulary.
////
//// `project/policy.for_mandate` decides what a Mandate grants, and it does so
//// in plain data that carries no broker type, because the `project` package is
//// portable and holds no I/O. This module is the other half: it maps that
//// `WorkerPolicy`, together with the owner's session policy, onto the
//// `SandboxPolicy` the worker's tools are composed against, the escalation
//// seam its refused calls go to, and the ceiling on the tools it may name.
//// Every function here is pure, and none takes anything a model wrote.
////
//// ## Flow
////
//// `jail_for` → `sandbox_of` → `escalations`; `allows`
////
//// 1. `jail_for` is the whole mapping. The daemon calls it each time a worker's
////    session is built, with the Mandate the project's ledger holds, so a boot
////    reopen, a resume after a follow-up and a retry all derive the policy
////    again and none reads it back from stored session configuration.
//// 2. `sandbox_of` fixes the network. An explicit worker gets the owner's
////    session policy unchanged. An inferred worker gets none.
//// 3. `escalations` picks the seam a refused call is sent to. A worker whose
////    approvals are refused is given `escalate.none`, which writes no record
////    and so asks nobody.
//// 4. `allows` is the tool ceiling: the question the session builder and the
////    gateway both ask about a tool name.
////
//// ## Why registries only is enforced as no network
////
//// The design note says an inferred worker reaches package registries only.
//// The broker's vocabulary can state that, as `NetworkProxy` with an
//// allowlist, but nothing enforces it: the egress proxy sidecar was never
//// built, so `policy.narrow_unenforceable` turns every `NetworkProxy` into
//// `NetworkOff` and the call is refused with a narrowing. `bash` asks for
//// whatever network its base allows, so a proxy base would refuse every shell
//// command an inferred worker ran, including the ones that touch no network.
//// An inferred worker is therefore given `NetworkOff`, which the broker and
//// the jail both enforce. That is narrower than the design's wording and
//// never wider, and the registry names stay in `registry_hosts` for the day a
//// proxy can enforce them. `protocol-change/106` records the same decision.
////
//// ## What a worker cannot change
////
//// Nothing here lives in a session's stored configuration. The gateway's
//// `set_config` accepts only the queue mode, tool execution, the model, the
//// thinking level and the active tools, and the active tools are checked
//// against the registry and against this ceiling. A worker that edits its own
//// configuration therefore changes none of the three things derived here.

import broker/policy.{type NetworkPolicy, type SandboxPolicy}
import client/escalate.{type Escalations}
import gleam/list
import gleam/string
import project/policy as project_policy

/// The package registries an inferred worker would reach if a proxy could
/// enforce the allowlist. They are not consulted by the sandbox today: see the
/// module documentation for why registries only is enforced as no network.
///
/// ## Examples
///
/// ```gleam
/// assert list.contains(project_jail.registry_hosts, "proxy.golang.org")
/// ```
pub const registry_hosts = [
  "registry.npmjs.org",
  "pypi.org",
  "files.pythonhosted.org",
  "proxy.golang.org",
  "sum.golang.org",
  "crates.io",
  "static.crates.io",
  "index.crates.io",
  "hex.pm",
  "repo.hex.pm",
  "rubygems.org",
]

/// The tools a worker may name, as the prefixes it is refused. The peer tools
/// and the `agent_*` tools are the worker's door onto other sessions, and a
/// worker talks to its project through its report alone.
pub type ToolCeiling {
  ToolCeiling(
    /// A tool whose name begins with any of these is above the ceiling.
    refused_prefixes: List(String),
  )
}

/// A worker's jail: the three things a Mandate decides.
pub type Jail {
  Jail(
    /// The base policy every one of the worker's tool calls is composed
    /// against.
    sandbox: SandboxPolicy,
    /// Where the worker's approval requests go.
    approvals: project_policy.ApprovalRoute,
    /// The tools the worker may name.
    tools: ToolCeiling,
  )
}

/// The ceiling every worker has. It does not vary with strength: no tool in
/// the registry carries a credential or reaches beyond what the base policy
/// allows, so the strength of a Mandate acts through the sandbox and the
/// approval route instead.
///
/// ## Examples
///
/// ```gleam
/// assert !project_jail.allows(project_jail.worker_tools, "agent_send")
/// ```
pub const worker_tools = ToolCeiling(refused_prefixes: ["agent_", "peer_"])

/// Derives a worker's jail from its policy and the owner's session policy.
///
/// ## Examples
///
/// ```gleam
/// let jail = project_jail.jail_for(
///   policy.WorkerPolicy(
///     policy.RegistriesOnly,
///     policy.NoCredentials,
///     policy.ApprovalsRefused,
///   ),
///   broker_policy.workspace_default("/w"),
/// )
/// assert jail.sandbox.network == broker_policy.NetworkOff
/// ```
pub fn jail_for(
  worker: project_policy.WorkerPolicy,
  owner: SandboxPolicy,
) -> Jail {
  Jail(
    sandbox: sandbox_of(worker.network, owner),
    approvals: worker.approvals,
    tools: worker_tools,
  )
}

/// The base policy a worker runs under: the owner's, with the network the
/// Mandate allows. Only the network moves, so the writable roots, protected
/// paths, limits and mounts are the owner's own.
///
/// ## Examples
///
/// ```gleam
/// let owner = broker_policy.workspace_default("/w")
/// assert project_jail.sandbox_of(policy.OwnerSessionPolicy, owner) == owner
/// ```
pub fn sandbox_of(
  network: project_policy.NetworkClass,
  owner: SandboxPolicy,
) -> SandboxPolicy {
  case network {
    project_policy.OwnerSessionPolicy -> owner

    // No proxy exists to enforce an allowlist, so the nearest form the broker
    // enforces is no network. That is also never wider than the owner's own
    // network, whatever the owner chose.
    project_policy.RegistriesOnly ->
      policy.SandboxPolicy(..owner, network: policy.NetworkOff)
  }
}

/// The escalation seam a worker's refused calls are sent to. `person` is the
/// seam that writes a record and asks whoever is attached; a worker whose
/// approvals are refused gets `escalate.none` instead, which settles every
/// refusal in band and writes nothing a person could be shown.
///
/// ## Examples
///
/// ```gleam
/// let seam = project_jail.escalations(policy.ApprovalsRefused, person)
/// assert seam.refused(refusal) == escalate.Settle
/// ```
pub fn escalations(
  route: project_policy.ApprovalRoute,
  person: Escalations,
) -> Escalations {
  case route {
    project_policy.ApprovalsToPerson -> person
    project_policy.ApprovalsRefused -> escalate.none()
  }
}

/// Whether the ceiling lets a worker name a tool.
///
/// ## Examples
///
/// ```gleam
/// assert project_jail.allows(project_jail.worker_tools, "bash")
/// ```
pub fn allows(ceiling: ToolCeiling, name: String) -> Bool {
  !list.any(ceiling.refused_prefixes, string.starts_with(name, _))
}

/// The network lattice as a number, larger reaching further.
///
/// ## Examples
///
/// ```gleam
/// assert project_jail.network_rank(policy.NetworkOff) == 0
/// ```
pub fn network_rank(network: NetworkPolicy) -> Int {
  case network {
    policy.NetworkOff -> 0
    policy.NetworkProxy(..) -> 1
    policy.NetworkFull -> 2
  }
}
