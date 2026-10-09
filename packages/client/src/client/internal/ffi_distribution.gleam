//// OTP distribution startup and certificate verification are not exposed by
//// gleam_erlang, gleam_otp or weft. This narrow boundary fixes every TLS
//// option: it accepts no remote MFA, no arbitrary option list and no
//// dynamically named atom. Only `client/distribution` imports it.

import gleam/erlang/node.{type Node}
import gleam/option.{type Option}

/// Immutable facts of a successful local boot: the local node and the finite
/// list of configured peers, each name paired with the atom made for it.
pub type Membership

/// Why a call failed. The vocabulary is closed and carries no credential
/// content and no OTP diagnostic text. `client/distribution` folds the boot
/// refusals into one public fault that names the reason.
pub type Failure {
  /// A name, pin, file or finite budget was refused.
  InvalidConfiguration

  /// The VM is already distributed.
  AlreadyDistributed

  /// The VM is older than OTP 29.
  UnsupportedOtp

  /// The VM was not booted with `-proto_dist inet_tls`.
  NotTlsDistribution

  /// The VM was booted without `-ssl_dist_optfile`.
  OptionsFileUnset

  /// The boot arguments name a node, a cookie or loose TLS options.
  ConflictingBootFlag

  /// The loaded options file is not private or differs from the configuration.
  OptionsMismatch

  /// A credential was missing, oversized, or insufficiently private.
  InvalidCredentials

  /// No epmd answers on this port, and none could be started. The port is the
  /// one this VM's epmd client uses, so the operator is told which to check.
  EpmdUnavailable(port: Int)

  /// An epmd answered but `net_kernel` would not start, for instance because
  /// the listen port is taken or the node name is already registered.
  StartFailed

  /// OTP could not connect.
  Unavailable
}

/// Renders the fixed TLS options as the text of an `ssl_dist_optfile`.
///
/// OTP `io_lib:format/2` with `~p`. The file holds an Erlang term that
/// references the verify function, and only the module that defines that
/// function can name it.
///
/// ## Examples
///
/// ```gleam
/// ffi_distribution.options(peers, files) // -> "[{server, ..}, {client, ..}].\n"
/// ```
@external(erlang, "client_distribution_ffi", "options")
pub fn options(peers: List(#(String, BitArray)), files: files) -> String

/// Checks the boot preconditions, reads the credentials, makes sure an epmd
/// answers, and starts hidden TLS distribution under
/// `dist_auto_connect = never`.
///
/// OTP `net_kernel:start/2`, `init:get_argument/1` and `ssl_dist_sup:consult/1`.
/// A node cannot start distribution except through `net_kernel`, and the
/// emulator's own boot arguments are readable only through `init`. A dynamic
/// `net_kernel:start/2` does not launch epmd the way `erl -name` does at boot,
/// so the start launches the release's `epmd -daemon` when none answers.
///
/// ## Examples
///
/// ```gleam
/// ffi_distribution.start(local, peers, files, option.None) // -> Ok(membership)
/// ```
@external(erlang, "client_distribution_ffi", "start")
pub fn start(
  local: String,
  peers: List(#(String, BitArray)),
  files: files,
  listen_port: Option(Int),
) -> Result(Membership, Failure)

/// Resolves one configured peer name to the node made for it at boot.
///
/// Erlang tuple lookup over the finite boot list. Node names are atoms, and
/// a lookup by string must never create one.
///
/// ## Examples
///
/// ```gleam
/// ffi_distribution.peer(membership, "executor@10.0.0.2") // -> Ok(node)
/// ```
@external(erlang, "client_distribution_ffi", "peer")
pub fn peer(membership: Membership, name: String) -> Result(Node, Failure)

/// Connects explicitly, as a hidden connection.
///
/// OTP `net_kernel:hidden_connect_node/1`; `gleam_erlang` exposes no
/// connection operation and `connect_node/1` would make a visible one.
///
/// ## Examples
///
/// ```gleam
/// ffi_distribution.connect(node) // -> Ok(Nil)
/// ```
@external(erlang, "client_distribution_ffi", "connect")
pub fn connect(node: Node) -> Result(Nil, Failure)
