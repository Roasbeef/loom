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

  /// A directory member's VM runs with `connect_all` on, which would let
  /// `global` connect it to every node a peer is connected to.
  ConnectAllEnabled

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

/// The trust mode in which the pins are not in the options file or in the
/// start arguments but in a table a process on this node publishes
/// (protocol-change/086). It compiles to the atom `live` that the foreign code
/// matches where it would otherwise take a peer list.
pub type Live {
  Live
}

/// How this node connects to one peer.
pub type Link {
  /// A visible connection, made between two directory members.
  Visible

  /// A hidden connection, made in every other case.
  Hidden
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

/// Renders the options file of live mode. It names no pin, so it is a function
/// of the credential paths alone and enrolling or revoking a member never
/// changes it.
///
/// The same foreign function as `options`, which takes a peer list or `live`.
///
/// ## Examples
///
/// ```gleam
/// ffi_distribution.live_options(Live, files) // -> "[{server, ..}, {client, ..}].\n"
/// ```
@external(erlang, "client_distribution_ffi", "options")
pub fn live_options(trust: Live, files: files) -> String

/// Checks the boot preconditions, reads the credentials, makes sure an epmd
/// answers, and starts TLS distribution under `dist_auto_connect = never`:
/// hidden, or visible when `members` names the directory's members
/// (protocol-change/083), in which case `connect_all` must be off.
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
/// ffi_distribution.start(local, peers, files, option.None, option.None)
/// ```
@external(erlang, "client_distribution_ffi", "start")
pub fn start(
  local: String,
  peers: List(#(String, BitArray)),
  files: files,
  listen_port: Option(Int),
  members: Option(List(String)),
) -> Result(Membership, Failure)

/// Starts distribution in live mode: the same checks and the same start as
/// `start`, with no peer atoms made, because the pin table decides who may
/// connect and the ledger process makes an atom when it applies a member.
///
/// The same foreign function as `start`, which takes a peer list or `live`.
///
/// ## Examples
///
/// ```gleam
/// ffi_distribution.start_live(local, Live, files, option.None, option.None)
/// ```
@external(erlang, "client_distribution_ffi", "start")
pub fn start_live(
  local: String,
  trust: Live,
  files: files,
  listen_port: Option(Int),
  members: Option(List(String)),
) -> Result(Membership, Failure)

/// Replaces the table that live mode reads with these pins, each paired with
/// the node name that pin must present. The first call creates the protected
/// table, so the calling process owns it and is the only one that may call this
/// again; the table goes away with that process.
///
/// OTP `ets:new/2` and `ets:insert/2`. An ETS table is not reachable from
/// `gleam_stdlib`, `gleam_erlang` or `gleam_otp`, and one insert is what lets a
/// handshake see the old pins or the new ones and never a mixture.
///
/// ## Examples
///
/// ```gleam
/// ffi_distribution.publish_pins([#(pin, "loom@hub.example")])
/// ```
@external(erlang, "client_distribution_ffi", "publish_pins")
pub fn publish_pins(pins: List(#(BitArray, String))) -> Nil

/// Resolves one peer name to its node. In static mode that is the node made for
/// it at boot; in live mode it is a member the pin table lists.
///
/// Erlang tuple lookup over the finite boot list, or over the published table.
/// Node names are atoms, and a lookup by string must never create one.
///
/// ## Examples
///
/// ```gleam
/// ffi_distribution.peer(membership, "executor@10.0.0.2") // -> Ok(node)
/// ```
@external(erlang, "client_distribution_ffi", "peer")
pub fn peer(membership: Membership, name: String) -> Result(Node, Failure)

/// How this node connects to a configured peer: `Visible` when both are
/// directory members, `Hidden` otherwise.
///
/// A list lookup over the members made at boot; it lives beside `start`
/// because only the membership term knows which atoms were made for members.
///
/// ## Examples
///
/// ```gleam
/// ffi_distribution.link(membership, node) // -> Hidden
/// ```
@external(erlang, "client_distribution_ffi", "link")
pub fn link(membership: Membership, node: Node) -> Link

/// Connects explicitly, visibly or hidden as the link says.
///
/// OTP `net_kernel:connect_node/1` and `net_kernel:hidden_connect_node/1`;
/// `gleam_erlang` exposes no connection operation. A connection's visibility
/// is fixed when it is made, so the choice is made here, on the one path every
/// caller uses.
///
/// ## Examples
///
/// ```gleam
/// ffi_distribution.connect(node, Hidden) // -> Ok(Nil)
/// ```
@external(erlang, "client_distribution_ffi", "connect")
pub fn connect(node: Node, link: Link) -> Result(Nil, Failure)
