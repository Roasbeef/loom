//// OTP distribution startup and certificate verification are not exposed by
//// gleam_erlang, gleam_otp or weft. This narrow boundary fixes every TLS option;
//// it accepts no remote MFA, arbitrary option list or dynamically named atom.

import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Pid, type Subject}

/// Immutable successful administrative boot facts.
pub type Membership

/// Safe startup and connection failures.
pub type Fault {
  /// An administrative name, pin, file or finite budget was refused.
  InvalidConfiguration

  /// The VM lacks the exact TLS boot arguments or is already distributed.
  UnsafeBoot

  /// A credential was missing, oversized, or insufficiently private.
  InvalidCredentials

  /// OTP could not start or connect.
  Unavailable

  /// The managed connection observation deadline ended.
  TimedOut
}

/// Fixed nonblocking send dispositions.
pub type SendResult {
  /// Distribution accepted this message once.
  Sent

  /// Distribution pressure refused this message before sending.
  WouldBlock

  /// No connection exists; automatic connection was prohibited.
  Disconnected

  /// A named or malformed subject was refused.
  InvalidSubject
}

/// Renders fixed TLS options without installing atoms.
///
/// ## Examples
/// ```gleam
/// ffi_distribution.options(peers, files) // -> OTP option text.
/// ```
@external(erlang, "executor_distribution_ffi", "options")
pub fn options(peers: List(#(String, BitArray)), files: files) -> String

/// Returns only fixed TLS flags and the configured private OTP init home.
///
/// ## Examples
/// ```gleam
/// ffi_distribution.boot_arguments(files, options_path)
/// ```
@external(erlang, "executor_distribution_ffi", "boot_arguments")
pub fn boot_arguments(files: files, options_path: String) -> List(String)

/// Returns the private erlexec HOME which becomes the single OTP init home.
///
/// ## Examples
/// ```gleam
/// ffi_distribution.bootstrap_home(files)
/// ```
@external(erlang, "executor_distribution_ffi", "bootstrap_home")
pub fn bootstrap_home(files: files) -> String

/// Returns the five actual canonical protected paths from successful boot.
///
/// ## Examples
/// ```gleam
/// ffi_distribution.protected_paths(membership)
/// ```
@external(erlang, "executor_distribution_ffi", "protected_paths")
pub fn protected_paths(membership: Membership) -> List(String)

/// Validates options and private credentials before starting hidden distribution.
///
/// ## Examples
/// ```gleam
/// ffi_distribution.start(local, peers, files) // -> Ok(membership).
/// ```
@external(erlang, "executor_distribution_ffi", "start")
pub fn start(
  local: String,
  peers: List(#(String, BitArray)),
  files: files,
) -> Result(Membership, Fault)

/// Resolves one boot's finite installed identity without creating atoms.
///
/// ## Examples
/// ```gleam
/// ffi_distribution.peer(membership, name) // -> Ok(node).
/// ```
@external(erlang, "executor_distribution_ffi", "peer")
pub fn peer(membership: Membership, name: String) -> Result(Node, Fault)

/// Uses OTP's explicit hidden connection operation.
///
/// ## Examples
/// ```gleam
/// ffi_distribution.connect(node) // -> Ok(Nil).
/// ```
@external(erlang, "executor_distribution_ffi", "connect")
pub fn connect(node: Node) -> Result(Nil, Fault)

/// Reads PID node identity using the OTP BIF.
///
/// ## Examples
/// ```gleam
/// ffi_distribution.pid_node(pid) // -> Node.
/// ```
@external(erlang, "erlang", "node")
pub fn pid_node(pid: Pid) -> Node

/// Preserves the unnamed Gleam Subject tag with fixed send/3 options.
///
/// ## Examples
/// ```gleam
/// ffi_distribution.send(subject, bytes) // -> Sent.
/// ```
@external(erlang, "executor_distribution_ffi", "send")
pub fn send(subject: Subject(a), message: a) -> SendResult

/// Registers only the literal executor endpoint name.
///
/// ## Examples
/// ```gleam
/// ffi_distribution.register_endpoint(pid) // -> Ok(Nil).
/// ```
@external(erlang, "executor_distribution_ffi", "register_endpoint")
pub fn register_endpoint(pid: Pid) -> Result(Nil, Fault)

/// Looks up only the literal endpoint name and verifies the returned PID node.
///
/// ## Examples
/// ```gleam
/// ffi_distribution.endpoint(node, 1000) // -> Ok(pid).
/// ```
@external(erlang, "executor_distribution_ffi", "endpoint")
pub fn endpoint(node: Node, within_ms: Int) -> Result(Pid, Fault)
