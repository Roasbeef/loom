//// SandboxPolicyV1 as a typed value, plus policy composition.
////
//// The wire shape is frozen in the implementation spec, Part 1.4:
////
//// ```
//// { v:1, writable_roots:[path], readable_roots:[path], protected:[path],
////   network: {mode:"off"} | {mode:"proxy", allow:[host_glob], proxy:addr}
////           | {mode:"full"},
////   limits: {cpu_s, wall_s, mem_bytes, pids, fsize_bytes, output_bytes},
////   env_allow:[name], scratch:"tmpfs"|path }
//// ```
////
//// This module mirrors that vocabulary field for field, encodes it via
//// `core/msgpack` in a canonical byte form the Go helper's strict decoder
//// accepts (golden-pinned under `protocol/msgpack-fixtures/`), decodes it
//// totally, and implements composition per design §5.2/§5.3: session base
//// ⊕ tool requirements ⊕ escalation grants, most-restrictive-wins except
//// explicit grants.
////
//// ## Network `proxy` mode is not implemented in phase 1
////
//// `NetworkProxy` is part of the frozen wire vocabulary, but the egress
//// proxy sidecar that would enforce its allowlist (spec WP-H "Egress
//// proxy sidecar", hardened in follow-up track 10, "Egress proxy
//// hardening") is a later work item. Until it exists a proxy-mode
//// policy cannot be enforced as requested, and the one thing the design
//// forbids is widening silently — so `narrow_unenforceable` fails
//// closed: it downgrades `NetworkProxy` to `NetworkOff` and reports the
//// downgrade as an ordinary `Narrowing`. The broker applies it to every
//// composed policy before dispatch, so a proxy request either becomes a
//// structured refusal (carrying the wanted grant) or runs with no
//// network at all — never with silent unrestricted egress.
////
//// Everything here is pure.

import core/corruption.{type CorruptionReport}
import core/msgpack.{type MsgPackValue}
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// The only policy version this broker speaks. A different `v` on the
/// wire is corruption, never tolerated drift (frozen-interface rule).
pub const version = 1

/// The network policy lattice, ordered `Off < Proxy < Full` for
/// composition purposes.
pub type NetworkPolicy {
  /// No network. bwrap unshares the net namespace and seccomp denies
  /// non-AF_UNIX socket creation.
  NetworkOff
  /// Egress only through a harness-owned proxy. Invariants: `allow`
  /// holds host globs; `proxy` is the proxy address.
  NetworkProxy(allow: List(String), proxy: String)
  /// No network restriction.
  NetworkFull
}

/// Resource ceilings. Invariant on every field: non-negative, with `0`
/// meaning "no limit of this kind" — the wire requires every key, so
/// "unlimited" is expressed as zero rather than omission.
pub type Limits {
  Limits(
    /// RLIMIT_CPU seconds for the jailed process.
    cpu_s: Int,
    /// Wall-clock seconds enforced by the helper's supervision timer.
    wall_s: Int,
    /// cgroup v2 `memory.max` bytes.
    mem_bytes: Int,
    /// cgroup v2 `pids.max`.
    pids: Int,
    /// RLIMIT_FSIZE bytes.
    fsize_bytes: Int,
    /// Per-stream stdout/stderr cap enforced by the helper.
    output_bytes: Int,
  )
}

/// Names one field of `Limits`; used by grants and narrowing reports.
pub type LimitField {
  CpuSeconds
  WallSeconds
  MemBytes
  Pids
  FsizeBytes
  OutputBytes
}

/// One limit field under the name the wire and the policy file use.
///
/// The same spelling `SandboxPolicyV1` carries and `client/grants`
/// encodes, so a refusal that names a field names the thing an operator
/// would edit.
///
/// ## Examples
///
/// ```gleam
/// assert policy.limit_field_name(policy.WallSeconds) == "wall_s"
/// ```
///
pub fn limit_field_name(field: LimitField) -> String {
  case field {
    CpuSeconds -> "cpu_s"
    WallSeconds -> "wall_s"
    MemBytes -> "mem_bytes"
    Pids -> "pids"
    FsizeBytes -> "fsize_bytes"
    OutputBytes -> "output_bytes"
  }
}

/// The scratch area given to the jail.
pub type Scratch {
  /// A fresh tmpfs, the most restrictive choice.
  ScratchTmpfs
  /// A bind-mounted host path. Invariant: absolute.
  ScratchPath(path: String)
}

/// A validated SandboxPolicyV1. Invariants (checked by `validate` and by
/// the total decoder): all paths absolute, all limits non-negative.
pub type SandboxPolicy {
  SandboxPolicy(
    /// Roots the jail may write under. Invariant: absolute paths.
    writable_roots: List(String),
    /// Roots the jail may read under. Invariant: absolute paths.
    readable_roots: List(String),
    /// Paths never writable even inside writable roots (.git internals,
    /// credential files). Invariant: absolute paths.
    protected: List(String),
    /// The network policy.
    network: NetworkPolicy,
    /// Resource ceilings.
    limits: Limits,
    /// Environment variable names the jail's env is constructed from
    /// (allowlist construction, never inheritance).
    env_allow: List(String),
    /// The scratch area.
    scratch: Scratch,
  )
}

/// Why a policy value failed validation before encoding or dispatch.
pub type PolicyError {
  /// A root, protected, or scratch path is not absolute.
  RelativePath(path: String)
  /// A limit field is negative.
  NegativeLimit(field: LimitField, value: Int)
  /// Scratch names the literal host root. Landlock has no deny rules
  /// (its grants union, and never subtract), so a host-path scratch of
  /// "/" grants read-write over the entire filesystem at that layer
  /// regardless of what the mount layer does — narrowing belongs here,
  /// before the policy ever reaches the wire, not in the mount layer
  /// (which is right to bind exactly what the policy says; see 4b4983d
  /// and packages/sandbox/CLAUDE.md's Landlock layering note).
  ScratchIsRoot
}

/// One explicit widening of a policy, granted by an approval. Grants are
/// the only way composition ever widens anything.
pub type Grant {
  /// Adds a writable root.
  GrantWritableRoot(path: String)
  /// Adds a readable root.
  GrantReadableRoot(path: String)
  /// Widens the network policy up the lattice (never narrows).
  GrantNetwork(network: NetworkPolicy)
  /// Adds an environment variable to the allowlist.
  GrantEnv(name: String)
  /// Raises one limit (`0` grants "unlimited").
  GrantLimit(field: LimitField, value: Int)
  /// Replaces the scratch choice, e.g. granting a host path.
  GrantScratch(scratch: Scratch)
}

/// One place where composition gave a tool less than it asked for. The
/// list of narrowings *is* the policy diff an escalation surfaces
/// ("wants: network to registry.npmjs.org"), convertible to the grants
/// that would satisfy it via `wanted_grants`.
pub type Narrowing {
  /// A requested writable root is not covered by the composed policy.
  NarrowedWritableRoot(path: String)
  /// A requested readable root is not covered by the composed policy.
  NarrowedReadableRoot(path: String)
  /// The requested network policy exceeds the composed one.
  NarrowedNetwork(wanted: NetworkPolicy, granted: NetworkPolicy)
  /// A requested environment variable was not allowed.
  NarrowedEnv(name: String)
  /// A requested limit exceeds the composed ceiling.
  NarrowedLimit(field: LimitField, wanted: Int, granted: Int)
  /// The requested scratch choice was replaced by tmpfs.
  NarrowedScratch(wanted: Scratch)
}

/// A restrictive default: nothing readable or writable beyond the given
/// workspace, network off, tmpfs scratch, no environment, and moderate
/// limits. A starting point for session bases; callers widen explicitly.
///
/// ## Examples
///
/// ```gleam
/// assert policy.workspace_default("/work").network == policy.NetworkOff
/// ```
///
pub fn workspace_default(workspace: String) -> SandboxPolicy {
  SandboxPolicy(
    writable_roots: [workspace],
    readable_roots: [workspace],
    protected: [],
    network: NetworkOff,
    limits: Limits(
      cpu_s: 300,
      wall_s: 600,
      mem_bytes: 2_147_483_648,
      pids: 512,
      fsize_bytes: 1_073_741_824,
      output_bytes: 4_194_304,
    ),
    env_allow: ["PATH", "HOME", "LANG", "TERM"],
    scratch: ScratchTmpfs,
  )
}

/// Checks the invariants the wire shape demands: absolute paths
/// everywhere, non-negative limits, and a scratch that is not the
/// literal host root (`ScratchIsRoot` — issue #59; see the module doc's
/// layering note in `packages/sandbox/CLAUDE.md`).
///
/// ## Examples
///
/// ```gleam
/// assert policy.validate(policy.workspace_default("/work")) == Ok(Nil)
/// ```
///
pub fn validate(policy: SandboxPolicy) -> Result(Nil, PolicyError) {
  use _ <- result.try(refuse_scratch_root(policy.scratch))
  let paths =
    list.flatten([
      policy.writable_roots,
      policy.readable_roots,
      policy.protected,
      case policy.scratch {
        ScratchTmpfs -> []
        ScratchPath(path:) -> [path]
      },
    ])
  use _ <- result.try(
    list.try_each(paths, fn(path) {
      case string.starts_with(path, "/") {
        True -> Ok(Nil)
        False -> Error(RelativePath(path:))
      }
    }),
  )
  list.try_each(limit_fields(), fn(field) {
    let value = limit_get(policy.limits, field)
    case value < 0 {
      True -> Error(NegativeLimit(field:, value:))
      False -> Ok(Nil)
    }
  })
}

// A scratch of the literal host root would make Landlock grant
// read-write over the whole filesystem (issue #59): Landlock has no
// deny rules, so nothing at that layer can carve a hole back out of
// "/". Refusing it here — at the one place every policy passes through
// before dispatch — keeps the mount layer free to go on binding exactly
// what the policy names, which is its own job (4b4983d), and makes sure
// the policy never names this.
fn refuse_scratch_root(scratch: Scratch) -> Result(Nil, PolicyError) {
  case scratch {
    ScratchPath(path: "/") -> Error(ScratchIsRoot)
    ScratchPath(_) | ScratchTmpfs -> Ok(Nil)
  }
}

// --- composition --------------------------------------------------------

/// Composes a session base policy with a tool's requirements and any
/// escalation grants: `base ⊕ requirements ⊕ grants`.
///
/// Most-restrictive-wins everywhere except grants: the result is the
/// meet of base and requirements (root coverage intersected, network
/// lattice meet, per-field limit minimum with `0` as unlimited,
/// environment intersection, protected paths unioned, differing scratch
/// collapsing to tmpfs), then each grant explicitly widens it. The
/// returned narrowings report every requirement the final policy does
/// not satisfy — an empty list means the tool got everything it asked
/// for.
///
/// ## Examples
///
/// ```gleam
/// let base = policy.workspace_default("/work")
/// assert policy.compose(base, base, []) == #(base, [])
/// ```
///
pub fn compose(
  base base: SandboxPolicy,
  requirements requirements: SandboxPolicy,
  grants grants: List(Grant),
) -> #(SandboxPolicy, List(Narrowing)) {
  let met = meet(base, requirements)
  let final = list.fold(grants, met, apply_grant)
  #(final, shortfall(requirements, final))
}

/// Converts narrowings into the grants that would satisfy them — the
/// "policy diff wanted" attached to an escalation.
///
/// ## Examples
///
/// ```gleam
/// assert policy.wanted_grants([policy.NarrowedEnv("CC")])
///   == [policy.GrantEnv("CC")]
/// ```
///
pub fn wanted_grants(narrowings: List(Narrowing)) -> List(Grant) {
  list.map(narrowings, fn(narrowing) {
    case narrowing {
      NarrowedWritableRoot(path:) -> GrantWritableRoot(path:)
      NarrowedReadableRoot(path:) -> GrantReadableRoot(path:)
      NarrowedNetwork(wanted:, granted: _) -> GrantNetwork(network: wanted)
      NarrowedEnv(name:) -> GrantEnv(name:)
      NarrowedLimit(field:, wanted:, granted: _) ->
        GrantLimit(field:, value: wanted)
      NarrowedScratch(wanted:) -> GrantScratch(scratch: wanted)
    }
  })
}

/// Downgrades any part of a policy whose enforcement is not implemented
/// in phase 1 to its nearest enforceable, more restrictive form,
/// reporting each downgrade as a `Narrowing` (see the module doc).
///
/// Today this is exactly one rule: `NetworkProxy` becomes `NetworkOff`,
/// because the egress proxy sidecar does not exist yet and a proxy-mode
/// jail would otherwise run with unrestricted direct egress. The
/// returned narrowing carries the wanted proxy policy, so a refusal
/// built from it surfaces the exact unenforceable grant.
///
/// ## Examples
///
/// ```gleam
/// assert policy.narrow_unenforceable(policy.workspace_default("/w"))
///   == #(policy.workspace_default("/w"), [])
/// ```
///
pub fn narrow_unenforceable(
  policy: SandboxPolicy,
) -> #(SandboxPolicy, List(Narrowing)) {
  case policy.network {
    NetworkOff | NetworkFull -> #(policy, [])
    NetworkProxy(allow: _, proxy: _) as wanted -> #(
      SandboxPolicy(..policy, network: NetworkOff),
      [NarrowedNetwork(wanted:, granted: NetworkOff)],
    )
  }
}

// The most-restrictive combination of two policies.
fn meet(base: SandboxPolicy, requirements: SandboxPolicy) -> SandboxPolicy {
  SandboxPolicy(
    writable_roots: meet_roots(base.writable_roots, requirements.writable_roots),
    readable_roots: meet_roots(base.readable_roots, requirements.readable_roots),
    protected: union(base.protected, requirements.protected),
    network: meet_network(base.network, requirements.network),
    limits: meet_limits(base.limits, requirements.limits),
    env_allow: intersect(base.env_allow, requirements.env_allow),
    scratch: case base.scratch == requirements.scratch {
      True -> base.scratch
      False -> ScratchTmpfs
    },
  )
}

// Requested roots the base actually covers. Coverage is prefix-aware:
// base root "/work" covers requested "/work/sub". The result is the
// requested (narrower) roots, so a tool asking for less than the base
// gets exactly what it asked for.
fn meet_roots(base: List(String), requested: List(String)) -> List(String) {
  list.filter(requested, fn(path) { covered_by(path, base) })
}

// Whether some root in `roots` is `path` itself or a path-prefix of it.
fn covered_by(path: String, roots: List(String)) -> Bool {
  list.any(roots, fn(root) { covers(root:, path:) })
}

/// Whether `root` is `path` itself or a path-**component** prefix of it,
/// with `"/"` covering everything.
///
/// Component-wise is the whole point: `/workspace` merely shares a
/// textual prefix with `/work` and is not covered by it, and `.gitx/file`
/// is not under `.git`. Composition (`meet_roots`), the jail's
/// reachability checks (`codemode/launch`) and the harness-side
/// protected-path refusal (`tools/fs.resolve_writable`) all ask exactly
/// this question, so they ask it of one function: three textual copies
/// were three places a fix could land in two of.
///
/// Matching is **byte-exact**, and deliberately so. A case-insensitive
/// filesystem would let `/WORK/x` escape a `/work` root here, but the
/// enforced target is Linux — the jail is bwrap, Landlock and seccomp —
/// and inventing a case fold would make this predicate disagree with the
/// kernel that actually enforces the same boundary.
///
/// ## Examples
///
/// ```gleam
/// assert policy.covers(root: "/work", path: "/work/sub")
/// assert !policy.covers(root: "/work", path: "/workspace")
/// ```
///
pub fn covers(root root: String, path path: String) -> Bool {
  root == "/" || root == path || string.starts_with(path, root <> "/")
}

fn meet_network(
  base: NetworkPolicy,
  requested: NetworkPolicy,
) -> NetworkPolicy {
  case base, requested {
    NetworkOff, _ | _, NetworkOff -> NetworkOff
    NetworkFull, other -> other
    other, NetworkFull -> other
    NetworkProxy(allow: base_allow, proxy: base_proxy),
      NetworkProxy(allow: requested_allow, proxy: _)
    ->
      // The base's proxy address wins: the harness owns the proxy, a
      // tool requirement must not redirect egress elsewhere.
      NetworkProxy(
        allow: intersect(base_allow, requested_allow),
        proxy: base_proxy,
      )
  }
}

// Grant-side join: only ever widens. `Off < Proxy < Full`; joining two
// proxies unions the allowlists and keeps the current (harness-owned)
// proxy address unless there is none yet.
fn join_network(
  current: NetworkPolicy,
  granted: NetworkPolicy,
) -> NetworkPolicy {
  case current, granted {
    NetworkFull, _ | _, NetworkFull -> NetworkFull
    NetworkOff, other -> other
    other, NetworkOff -> other
    NetworkProxy(allow: current_allow, proxy: current_proxy),
      NetworkProxy(allow: granted_allow, proxy: granted_proxy)
    -> {
      let proxy = case current_proxy {
        "" -> granted_proxy
        _ -> current_proxy
      }
      NetworkProxy(allow: union(current_allow, granted_allow), proxy:)
    }
  }
}

fn meet_limits(base: Limits, requested: Limits) -> Limits {
  Limits(
    cpu_s: meet_limit(base.cpu_s, requested.cpu_s),
    wall_s: meet_limit(base.wall_s, requested.wall_s),
    mem_bytes: meet_limit(base.mem_bytes, requested.mem_bytes),
    pids: meet_limit(base.pids, requested.pids),
    fsize_bytes: meet_limit(base.fsize_bytes, requested.fsize_bytes),
    output_bytes: meet_limit(base.output_bytes, requested.output_bytes),
  )
}

// Per-field meet with 0 as "unlimited" (the top of the lattice).
fn meet_limit(a: Int, b: Int) -> Int {
  case a, b {
    0, other -> other
    other, 0 -> other
    _, _ -> int.min(a, b)
  }
}

// Per-field join with 0 as "unlimited": granting 0 lifts the cap.
fn join_limit(a: Int, b: Int) -> Int {
  case a == 0 || b == 0 {
    True -> 0
    False -> int.max(a, b)
  }
}

fn apply_grant(policy: SandboxPolicy, grant: Grant) -> SandboxPolicy {
  case grant {
    GrantWritableRoot(path:) -> {
      let writable_roots = union(policy.writable_roots, [path])
      SandboxPolicy(..policy, writable_roots:)
    }
    GrantReadableRoot(path:) -> {
      let readable_roots = union(policy.readable_roots, [path])
      SandboxPolicy(..policy, readable_roots:)
    }
    GrantNetwork(network:) -> {
      let network = join_network(policy.network, network)
      SandboxPolicy(..policy, network:)
    }
    GrantEnv(name:) -> {
      let env_allow = union(policy.env_allow, [name])
      SandboxPolicy(..policy, env_allow:)
    }
    GrantLimit(field:, value:) -> {
      let current = limit_get(policy.limits, field)
      let limits = limit_set(policy.limits, field, join_limit(current, value))
      SandboxPolicy(..policy, limits:)
    }
    GrantScratch(scratch:) -> SandboxPolicy(..policy, scratch:)
  }
}

// Every requirement the final policy does not satisfy.
fn shortfall(
  requirements: SandboxPolicy,
  final: SandboxPolicy,
) -> List(Narrowing) {
  let writable =
    requirements.writable_roots
    |> list.filter(fn(path) { !covered_by(path, final.writable_roots) })
    |> list.map(fn(path) { NarrowedWritableRoot(path:) })
  let readable =
    requirements.readable_roots
    |> list.filter(fn(path) { !covered_by(path, final.readable_roots) })
    |> list.map(fn(path) { NarrowedReadableRoot(path:) })
  let network = case network_exceeds(requirements.network, final.network) {
    True -> [
      NarrowedNetwork(wanted: requirements.network, granted: final.network),
    ]
    False -> []
  }
  let env =
    requirements.env_allow
    |> list.filter(fn(name) { !list.contains(final.env_allow, name) })
    |> list.map(fn(name) { NarrowedEnv(name:) })
  let limits =
    list.filter_map(limit_fields(), fn(field) {
      let wanted = limit_get(requirements.limits, field)
      let granted = limit_get(final.limits, field)
      case limit_exceeds(wanted, granted) {
        True -> Ok(NarrowedLimit(field:, wanted:, granted:))
        False -> Error(Nil)
      }
    })
  let scratch = case requirements.scratch == final.scratch {
    True -> []
    False -> [NarrowedScratch(wanted: requirements.scratch)]
  }
  list.flatten([writable, readable, network, env, limits, scratch])
}

// Whether `wanted` allows strictly more than `granted` on the network
// lattice (proxy-vs-proxy compares allowlists).
fn network_exceeds(wanted: NetworkPolicy, granted: NetworkPolicy) -> Bool {
  case wanted, granted {
    NetworkOff, _ -> False
    _, NetworkFull -> False
    NetworkFull, _ -> True
    NetworkProxy(allow: _, proxy: _), NetworkOff -> True
    NetworkProxy(allow: wanted_allow, proxy: _),
      NetworkProxy(allow: granted_allow, proxy: _)
    -> list.any(wanted_allow, fn(host) { !list.contains(granted_allow, host) })
  }
}

// Whether `wanted` is a looser limit than `granted` (0 = unlimited).
fn limit_exceeds(wanted: Int, granted: Int) -> Bool {
  case wanted, granted {
    _, 0 -> False
    0, _ -> True
    _, _ -> wanted > granted
  }
}

fn limit_fields() -> List(LimitField) {
  [CpuSeconds, WallSeconds, MemBytes, Pids, FsizeBytes, OutputBytes]
}

fn limit_get(limits: Limits, field: LimitField) -> Int {
  case field {
    CpuSeconds -> limits.cpu_s
    WallSeconds -> limits.wall_s
    MemBytes -> limits.mem_bytes
    Pids -> limits.pids
    FsizeBytes -> limits.fsize_bytes
    OutputBytes -> limits.output_bytes
  }
}

fn limit_set(limits: Limits, field: LimitField, value: Int) -> Limits {
  case field {
    CpuSeconds -> Limits(..limits, cpu_s: value)
    WallSeconds -> Limits(..limits, wall_s: value)
    MemBytes -> Limits(..limits, mem_bytes: value)
    Pids -> Limits(..limits, pids: value)
    FsizeBytes -> Limits(..limits, fsize_bytes: value)
    OutputBytes -> Limits(..limits, output_bytes: value)
  }
}

// Order-preserving set union / intersection over small lists. Policies
// hold a handful of entries; linear scans beat pulling in a set type
// that would lose ordering determinism for the canonical encoding.
fn union(left: List(String), right: List(String)) -> List(String) {
  let missing = list.filter(right, fn(item) { !list.contains(left, item) })
  list.append(left, missing)
}

fn intersect(left: List(String), right: List(String)) -> List(String) {
  list.filter(left, fn(item) { list.contains(right, item) })
}

// --- wire codec ---------------------------------------------------------

/// The policy as a msgpack value in the frozen wire vocabulary. Map keys
/// are emitted in sorted order and `core/msgpack` encodes canonically,
/// so equal policies always produce identical bytes (golden-pinned in
/// `protocol/msgpack-fixtures/sandbox_policy_1.bin`).
pub fn to_msgpack(policy: SandboxPolicy) -> MsgPackValue {
  msgpack.MapValue([
    #(msgpack.StringValue("env_allow"), string_array(policy.env_allow)),
    #(msgpack.StringValue("limits"), limits_to_msgpack(policy.limits)),
    #(msgpack.StringValue("network"), network_to_msgpack(policy.network)),
    #(msgpack.StringValue("protected"), string_array(policy.protected)),
    #(
      msgpack.StringValue("readable_roots"),
      string_array(policy.readable_roots),
    ),
    #(
      msgpack.StringValue("scratch"),
      msgpack.StringValue(case policy.scratch {
        ScratchTmpfs -> "tmpfs"
        ScratchPath(path:) -> path
      }),
    ),
    #(msgpack.StringValue("v"), msgpack.IntValue(version)),
    #(
      msgpack.StringValue("writable_roots"),
      string_array(policy.writable_roots),
    ),
  ])
}

/// Encodes the policy to its canonical wire bytes.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(_bytes) =
///   policy.encode(policy.workspace_default("/work"))
/// ```
///
pub fn encode(policy: SandboxPolicy) -> Result(BitArray, msgpack.EncodeError) {
  msgpack.encode(to_msgpack(policy))
}

/// Decodes wire bytes into a policy, totally: any structural problem is
/// a `CorruptionReport`, never a crash. Mirrors the Go helper's strict
/// decoder: unknown keys, missing keys, wrong types, unknown network
/// modes, negative limits, relative paths, a bad scratch, and trailing
/// bytes are all rejected.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(bytes) = policy.encode(policy.workspace_default("/w"))
/// assert policy.decode(bytes) == Ok(policy.workspace_default("/w"))
/// ```
///
pub fn decode(bytes: BitArray) -> Result(SandboxPolicy, CorruptionReport) {
  use value <- result.try(msgpack.decode(bytes))
  from_msgpack(value)
}

/// Decodes an already-parsed msgpack value into a policy, with the same
/// strictness as `decode`. Used when a policy arrives nested inside an
/// `exec_start` body.
pub fn from_msgpack(
  value: MsgPackValue,
) -> Result(SandboxPolicy, CorruptionReport) {
  use entries <- result.try(as_map(value, "policy"))
  use Nil <- result.try(reject_unknown_keys(
    entries,
    [
      "v",
      "writable_roots",
      "readable_roots",
      "protected",
      "network",
      "limits",
      "env_allow",
      "scratch",
    ],
    "policy",
  ))
  use v <- result.try(required_int(entries, "v", "policy"))
  use Nil <- result.try(case v == version {
    True -> Ok(Nil)
    False ->
      Error(fail(
        "policy.v",
        "version " <> int.to_string(version),
        int.to_string(v),
      ))
  })
  use writable_roots <- result.try(required_paths(entries, "writable_roots"))
  use readable_roots <- result.try(required_paths(entries, "readable_roots"))
  use protected <- result.try(required_paths(entries, "protected"))
  use network_value <- result.try(required(entries, "network", "policy"))
  use network <- result.try(network_from_msgpack(network_value))
  use limits_value <- result.try(required(entries, "limits", "policy"))
  use limits <- result.try(limits_from_msgpack(limits_value))
  use env_allow <- result.try(
    required(entries, "env_allow", "policy")
    |> result.try(as_string_array(_, "policy.env_allow")),
  )
  use scratch_text <- result.try(required_string(entries, "scratch", "policy"))
  use scratch <- result.try(case scratch_text {
    "tmpfs" -> Ok(ScratchTmpfs)
    "/" <> _ -> Ok(ScratchPath(path: scratch_text))
    _ ->
      Error(fail(
        "policy.scratch",
        "\"tmpfs\" or an absolute path",
        scratch_text,
      ))
  })
  Ok(SandboxPolicy(
    writable_roots:,
    readable_roots:,
    protected:,
    network:,
    limits:,
    env_allow:,
    scratch:,
  ))
}

fn network_to_msgpack(network: NetworkPolicy) -> MsgPackValue {
  case network {
    NetworkOff ->
      msgpack.MapValue([
        #(msgpack.StringValue("mode"), msgpack.StringValue("off")),
      ])
    NetworkFull ->
      msgpack.MapValue([
        #(msgpack.StringValue("mode"), msgpack.StringValue("full")),
      ])
    NetworkProxy(allow:, proxy:) ->
      msgpack.MapValue([
        #(msgpack.StringValue("allow"), string_array(allow)),
        #(msgpack.StringValue("mode"), msgpack.StringValue("proxy")),
        #(msgpack.StringValue("proxy"), msgpack.StringValue(proxy)),
      ])
  }
}

fn network_from_msgpack(
  value: MsgPackValue,
) -> Result(NetworkPolicy, CorruptionReport) {
  use entries <- result.try(as_map(value, "policy.network"))
  use mode <- result.try(required_string(entries, "mode", "policy.network"))
  case mode {
    "off" -> {
      use Nil <- result.try(reject_unknown_keys(
        entries,
        ["mode"],
        "policy.network",
      ))
      Ok(NetworkOff)
    }
    "full" -> {
      use Nil <- result.try(reject_unknown_keys(
        entries,
        ["mode"],
        "policy.network",
      ))
      Ok(NetworkFull)
    }
    "proxy" -> {
      use Nil <- result.try(reject_unknown_keys(
        entries,
        ["mode", "allow", "proxy"],
        "policy.network",
      ))
      use allow <- result.try(
        required(entries, "allow", "policy.network")
        |> result.try(as_string_array(_, "policy.network.allow")),
      )
      use proxy <- result.try(required_string(
        entries,
        "proxy",
        "policy.network",
      ))
      Ok(NetworkProxy(allow:, proxy:))
    }
    _ -> Error(fail("policy.network.mode", "off, proxy, or full", mode))
  }
}

fn limits_to_msgpack(limits: Limits) -> MsgPackValue {
  msgpack.MapValue([
    #(msgpack.StringValue("cpu_s"), msgpack.IntValue(limits.cpu_s)),
    #(msgpack.StringValue("fsize_bytes"), msgpack.IntValue(limits.fsize_bytes)),
    #(msgpack.StringValue("mem_bytes"), msgpack.IntValue(limits.mem_bytes)),
    #(
      msgpack.StringValue("output_bytes"),
      msgpack.IntValue(limits.output_bytes),
    ),
    #(msgpack.StringValue("pids"), msgpack.IntValue(limits.pids)),
    #(msgpack.StringValue("wall_s"), msgpack.IntValue(limits.wall_s)),
  ])
}

fn limits_from_msgpack(
  value: MsgPackValue,
) -> Result(Limits, CorruptionReport) {
  use entries <- result.try(as_map(value, "policy.limits"))
  use Nil <- result.try(reject_unknown_keys(
    entries,
    ["cpu_s", "wall_s", "mem_bytes", "pids", "fsize_bytes", "output_bytes"],
    "policy.limits",
  ))
  use cpu_s <- result.try(required_limit(entries, "cpu_s"))
  use wall_s <- result.try(required_limit(entries, "wall_s"))
  use mem_bytes <- result.try(required_limit(entries, "mem_bytes"))
  use pids <- result.try(required_limit(entries, "pids"))
  use fsize_bytes <- result.try(required_limit(entries, "fsize_bytes"))
  use output_bytes <- result.try(required_limit(entries, "output_bytes"))
  Ok(Limits(cpu_s:, wall_s:, mem_bytes:, pids:, fsize_bytes:, output_bytes:))
}

// --- decoding plumbing --------------------------------------------------

fn fail(
  subject: String,
  expected: String,
  context: String,
) -> CorruptionReport {
  corruption.report(
    at: "broker/policy.decode",
    on: subject,
    expected:,
    context:,
  )
}

fn string_array(items: List(String)) -> MsgPackValue {
  msgpack.ArrayValue(list.map(items, msgpack.StringValue))
}

fn as_map(
  value: MsgPackValue,
  subject: String,
) -> Result(List(#(MsgPackValue, MsgPackValue)), CorruptionReport) {
  case value {
    msgpack.MapValue(entries:) -> Ok(entries)
    _ -> Error(fail(subject, "a msgpack map", describe_value(value)))
  }
}

fn reject_unknown_keys(
  entries: List(#(MsgPackValue, MsgPackValue)),
  known: List(String),
  subject: String,
) -> Result(Nil, CorruptionReport) {
  list.try_each(entries, fn(entry) {
    case entry.0 {
      msgpack.StringValue(key) ->
        case list.contains(known, key) {
          True -> Ok(Nil)
          False -> Error(fail(subject, "no unknown keys", key))
        }
      other -> Error(fail(subject, "string keys", describe_value(other)))
    }
  })
}

fn find(
  entries: List(#(MsgPackValue, MsgPackValue)),
  key: String,
) -> Result(MsgPackValue, Nil) {
  list.find_map(entries, fn(entry) {
    case entry.0 == msgpack.StringValue(key) {
      True -> Ok(entry.1)
      False -> Error(Nil)
    }
  })
}

fn required(
  entries: List(#(MsgPackValue, MsgPackValue)),
  key: String,
  subject: String,
) -> Result(MsgPackValue, CorruptionReport) {
  // map_error, not replace_error: the reason is a string concatenation
  // built on every key of every decode, taken or not (house rule R1).
  find(entries, key)
  |> result.map_error(fn(_) { fail(subject, "required key " <> key, "missing") })
}

fn required_int(
  entries: List(#(MsgPackValue, MsgPackValue)),
  key: String,
  subject: String,
) -> Result(Int, CorruptionReport) {
  use value <- result.try(required(entries, key, subject))
  case value {
    msgpack.IntValue(number) -> Ok(number)
    other ->
      Error(fail(subject <> "." <> key, "an integer", describe_value(other)))
  }
}

fn required_limit(
  entries: List(#(MsgPackValue, MsgPackValue)),
  key: String,
) -> Result(Int, CorruptionReport) {
  use number <- result.try(required_int(entries, key, "policy.limits"))
  case number < 0 {
    True ->
      Error(fail(
        "policy.limits." <> key,
        "a non-negative integer",
        int.to_string(number),
      ))
    False -> Ok(number)
  }
}

fn required_string(
  entries: List(#(MsgPackValue, MsgPackValue)),
  key: String,
  subject: String,
) -> Result(String, CorruptionReport) {
  use value <- result.try(required(entries, key, subject))
  case value {
    msgpack.StringValue(text) -> Ok(text)
    other ->
      Error(fail(subject <> "." <> key, "a string", describe_value(other)))
  }
}

fn required_paths(
  entries: List(#(MsgPackValue, MsgPackValue)),
  key: String,
) -> Result(List(String), CorruptionReport) {
  use value <- result.try(required(entries, key, "policy"))
  use paths <- result.try(as_string_array(value, "policy." <> key))
  use Nil <- result.try(
    list.try_each(paths, fn(path) {
      case string.starts_with(path, "/") {
        True -> Ok(Nil)
        False -> Error(fail("policy." <> key, "absolute paths", path))
      }
    }),
  )
  Ok(paths)
}

fn as_string_array(
  value: MsgPackValue,
  subject: String,
) -> Result(List(String), CorruptionReport) {
  case value {
    msgpack.ArrayValue(items:) ->
      list.try_map(items, fn(item) {
        case item {
          msgpack.StringValue(text) -> Ok(text)
          other ->
            Error(fail(subject, "string elements", describe_value(other)))
        }
      })
    // The Go encoder writes a nil slice as msgpack nil; accept it as
    // the empty list when decoding (we never emit it ourselves).
    msgpack.NilValue -> Ok([])
    other -> Error(fail(subject, "an array of strings", describe_value(other)))
  }
}

fn describe_value(value: MsgPackValue) -> String {
  case value {
    msgpack.NilValue -> "nil"
    msgpack.BoolValue(_) -> "a bool"
    msgpack.IntValue(number) -> "int " <> int.to_string(number)
    msgpack.FloatValue(_) -> "a float"
    msgpack.StringValue(text) -> "string \"" <> text <> "\""
    msgpack.BinaryValue(_) -> "a binary"
    msgpack.ArrayValue(_) -> "an array"
    msgpack.MapValue(_) -> "a map"
  }
}
