//// Pure compiler and satellite command construction shared by physical hosts.
////
//// The owner must derive the command it clears independently of an executor's
//// proposal. Keeping the literal argv, pinned environment and full policy here
//// prevents local execution and remote acceptance from acquiring different
//// templates. These functions perform no filesystem access or clearance.
////
//// Paths and policy arrive from the calling boundary. Local callers retain
//// their existing artifact checks; remote callers must first admit enrollment,
//// original service input and prepared resources. A CommandData value itself
//// grants nothing. Remote wall selection happens once after preparation; this
//// module accepts that selected value without reading or renewing a deadline.

import broker/command
import broker/policy
import filepath
import gleam/list

/// The boot runtime's socket environment name, pinned against cap/runtime by
/// the existing launcher tests without linking model-facing code into the host.
pub const sock_env = "LOOM_CAP_SOCK"

/// The boot runtime's private token-file environment name.
pub const token_env = "LOOM_CAP_TOKEN_FILE"

/// Immutable input to the hermetic compiler command.
pub type Compiler {
  Compiler(
    /// Executor-local absolute compiler executable.
    executable: String,
    /// This compilation's prepared allocation.
    root: String,
    /// Original owner-selected sandbox policy.
    base: policy.SandboxPolicy,
    /// Immutable toolchain regions available to the compiler.
    toolchain_roots: List(String),
    /// Explicit environment; TMPDIR is replaced by the allocation's tmp path.
    env: List(#(String, String)),
  )
}

/// Resource facts needed to derive satellite access without an Artifact or a
/// process handle. The caller has already checked their physical association.
pub type NodeAccess {
  NodeAccess(
    /// Prepared compiled beam directory.
    beam_dir: String,
    /// This launch's private capability socket.
    socket_path: String,
    /// This launch's private token file.
    token_path: String,
    /// Original owner-selected sandbox policy.
    base: policy.SandboxPolicy,
    /// Immutable host toolchain and seed mounts.
    mounts: List(policy.Mount),
    /// Explicit child environment before pinning channel handles.
    env: List(#(String, String)),
    /// Exact wall requirement selected by the caller's original authority.
    wall_s: Int,
  )
}

/// Derives the complete compiler data without touching the allocation.
/// Network access stays off, and the allocation is the only writable root.
///
/// ## Examples
///
/// ```gleam
/// // native_command.compiler(facts).argv == [facts.executable, "build", "--warnings-as-errors"]
/// ```
pub fn compiler(facts: Compiler) -> command.CommandData {
  let permitted = list.filter(facts.env, fn(pair) { pair.0 != "TMPDIR" })
  let env = [#("TMPDIR", facts.root <> "/tmp"), ..permitted]
  let requirements =
    policy.SandboxPolicy(
      ..facts.base,
      writable_roots: [facts.root],
      readable_roots: list.unique([facts.root, ..facts.toolchain_roots]),
      network: policy.NetworkOff,
      env_allow: list.map(env, fn(pair) { pair.0 }),
    )
  command.CommandData(
    argv: [facts.executable, "build", "--warnings-as-errors"],
    env:,
    cwd: facts.root,
    requirements:,
  )
}

/// Authorizes the compiler-owned TMPDIR name on its derived call base.
/// The original session policy remains unchanged.
///
/// ## Examples
///
/// ```gleam
/// // native_command.compiler_base(base).env_allow includes "TMPDIR".
/// ```
pub fn compiler_base(base: policy.SandboxPolicy) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..base,
    env_allow: list.unique(list.append(base.env_allow, ["TMPDIR"])),
  )
}

/// Derives the fixed satellite boot command with Erlang distribution disabled.
/// The admitted entry returns into init stop, so completion ends the node.
///
/// ## Examples
///
/// ```gleam
/// // native_command.node_argv("/otp/bin/erl", "/build/ebin", "loom_entry")
/// ```
pub fn node_argv(
  executable: String,
  beam_dir: String,
  entry: String,
) -> List(String) {
  [
    executable,
    "-noshell",
    "-boot",
    "no_dot_erlang",
    "-pa",
    beam_dir,
    "-proto_dist",
    "none",
    "-start_epmd",
    "false",
    "-run",
    entry,
    "main",
    "-s",
    "init",
    "stop",
  ]
}

/// Pins both capability handles before the caller's remaining environment.
/// Caller-supplied duplicates cannot redirect authentication to another launch.
/// Erlang's three argument-injection variables are excluded: an executor's
/// distribution flags and cookie must not become satellite boot arguments.
///
/// ## Examples
///
/// ```gleam
/// assert native_command.node_env("/c/s", "/c/cap-token", []) == [
///   #("LOOM_CAP_SOCK", "/c/s"), #("LOOM_CAP_TOKEN_FILE", "/c/cap-token"),
/// ]
/// ```
pub fn node_env(
  socket_path: String,
  token_path: String,
  env: List(#(String, String)),
) -> List(#(String, String)) {
  // A distributed executor still launches an undistributed satellite. These
  // variables add VM arguments outside node_argv's fixed command, including
  // names, cookies and TLS option files, so policy permission cannot pass them.
  let permitted =
    list.filter(env, fn(pair) {
      case pair.0 {
        "ERL_AFLAGS" | "ERL_FLAGS" | "ERL_ZFLAGS" -> False
        name -> name != sock_env && name != token_env
      }
    })
  [#(sock_env, socket_path), #(token_env, token_path), ..permitted]
}

/// Derives satellite access while retaining every untouched policy field.
/// The caller supplies the selected wall; deriving access never refreshes it.
///
/// ## Examples
///
/// ```gleam
/// // native_command.node_requirements(access).limits.wall_s == access.wall_s
/// ```
pub fn node_requirements(access: NodeAccess) -> policy.SandboxPolicy {
  let wanted = [
    filepath.directory_name(access.socket_path),
    filepath.directory_name(access.token_path),
    access.beam_dir,
  ]
  let env = node_env(access.socket_path, access.token_path, access.env)
  let base = access.base
  policy.SandboxPolicy(
    ..base,
    readable_roots: list.unique(list.append(base.readable_roots, wanted)),
    mounts: access.mounts,
    network: policy.NetworkOff,
    limits: policy.Limits(..base.limits, wall_s: access.wall_s),
    env_allow: list.map(env, fn(pair) { pair.0 }),
  )
}
