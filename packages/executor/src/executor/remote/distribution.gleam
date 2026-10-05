//// Trusted executor membership is an administrative boot boundary. Ordinary
//// satellites never enter it: a connected executor has the full privileges of
//// a distributed Erlang peer, including remote process creation.
////
//// Provision `tls_options` in a private options file, boot the VM with
//// the `boot_arguments` flags without `-name` or `-sname`,
//// then call `start` before publishing any executor endpoint. Both directions
//// require PKIX verification, an exact leaf SHA-256 pin and a full-node SAN.
//// Hidden nodes and explicit connections control topology, not peer privilege.
//// This module starts no provider, session owner or Ra voter.

import executor/internal/ffi_distribution
import gleam/bit_array
import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/result
import gleam/string
import weft

/// Fixed administrative files; none may be passed or mounted into a satellite.
pub type CredentialFiles {
  CredentialFiles(
    /// PEM trust roots.
    ca: String,
    /// PEM local certificate chain.
    certificate: String,
    /// Private PEM local key, mode 0600.
    key: String,
    /// Private OTP home/.erlang.cookie, mode 0600, without a trailing newline.
    cookie: String,
  )
}

/// Validated boot configuration; constructing it creates no Erlang atoms.
pub opaque type Config {
  Config(
    local: String,
    peers: List(#(String, BitArray)),
    files: CredentialFiles,
  )
}

/// A successful local boot, distinct from a connected or healthy executor.
pub type Membership =
  ffi_distribution.Membership

/// One administrative peer selected from the successful boot's finite list.
pub opaque type Peer {
  Peer(name: String, node: Node)
}

/// Closed failures exclude credential contents and arbitrary OTP diagnostics.
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

/// A send result concerns only distribution admission, never final consumption.
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

/// Validates one boot's finite names and pins without creating any atoms.
/// Each full node name is 3..255 ASCII bytes, with one `@` and an explicit host.
/// One to 32 distinct peers are required; each DER SHA-256 pin is 32 bytes.
///
/// ## Examples
/// ```gleam
/// distribution.configure("owner@127.0.0.1", [], files) // -> Error(...)
/// ```
pub fn configure(
  local: String,
  peers: List(#(String, BitArray)),
  files: CredentialFiles,
) -> Result(Config, Fault) {
  use Nil <- result.try(valid_name(local))
  use Nil <- result.try(valid_files(files))
  use Nil <- result.try(valid_peers(peers, [local], [], 0))
  Ok(Config(local:, peers:, files:))
}

/// Renders the fixed OTP option term for private administrative provisioning.
/// The verifier's initial state includes only bounded names and public pins.
///
/// ## Examples
/// ```gleam
/// distribution.tls_options(config) // -> An OTP ssl_dist_optfile term.
/// ```
pub fn tls_options(config: Config) -> String {
  ffi_distribution.options(config.peers, config.files)
}

/// Names every credential path the satellite launcher must protect from its jail.
/// This is deployment data for the trusted launcher, never satellite input.
///
/// ## Examples
/// ```gleam
/// distribution.protected_paths(config) // -> Four absolute paths.
/// ```
pub fn protected_paths(config: Config) -> List(String) {
  let files = config.files
  [files.ca, files.certificate, files.key, files.cookie]
}

/// Returns the fixed TLS flags and restores the launcher's OS HOME through
/// `-env HOME`. The trusted launcher supplies `bootstrap_home` as HOME only to
/// erlexec, which captures the private OTP init home before restoring OS HOME.
/// If the launcher has no HOME, the runtime receives an empty HOME value.
/// Do not append `-home`: OTP treats the resulting duplicate init homes as an
/// absent home and can fall back to the operator's XDG cookie directory.
///
/// ## Examples
/// ```gleam
/// distribution.boot_arguments(config, "/private/credentials/tls.options")
/// ```
pub fn boot_arguments(config: Config, options_path: String) -> List(String) {
  ffi_distribution.boot_arguments(config.files, options_path)
}

/// Returns the private directory the launcher supplies as erlexec's HOME.
/// Pair it with `boot_arguments`, which restores the original OS HOME inside
/// the BEAM. This is trusted launch configuration and never satellite input.
///
/// ## Examples
/// ```gleam
/// distribution.bootstrap_home(config) // -> "/private/credentials/owner"
/// ```
pub fn bootstrap_home(config: Config) -> String {
  ffi_distribution.bootstrap_home(config.files)
}

/// Returns the actual canonical credential and options paths validated at boot.
/// Trusted registration must retain these protected roots in every satellite
/// ceiling. Membership alone does not establish that jail assembly did so.
///
/// ## Examples
/// ```gleam
/// distribution.protected_membership_paths(membership) // -> Five paths.
/// ```
pub fn protected_membership_paths(membership: Membership) -> List(String) {
  ffi_distribution.protected_paths(membership)
}

/// Starts hidden TLS distribution only from a non-distributed OTP 29 VM with
/// exactly the provisioned TLS flags and options. No plaintext retry exists.
/// It installs explicit-only connection policy before opening distribution.
/// The pin verifier is active from listener creation, before node allowlisting.
/// Calling this twice refuses rather than enlarging the administrative atom set.
/// The host must serialize administrative starts. One admitted attempt consumes
/// this VM's bootstrap lifetime even if credentials or connectivity later fail.
///
/// ## Examples
/// ```gleam
/// distribution.start(config) // -> Ok(membership) on the provisioned VM.
/// ```
pub fn start(config: Config) -> Result(Membership, Fault) {
  ffi_distribution.start(config.local, config.peers, config.files)
  |> result.map_error(public_fault)
}

/// Resolves only names installed during this boot, with no string-to-atom path
/// for network input. Success is administrative identity, not connectivity.
///
/// ## Examples
/// ```gleam
/// distribution.peer(membership, "unconfigured@127.0.0.1") // -> Error(...)
/// ```
pub fn peer(membership: Membership, name: String) -> Result(Peer, Fault) {
  use node <- result.try(
    ffi_distribution.peer(membership, name) |> result.map_error(public_fault),
  )
  Ok(Peer(name:, node:))
}

/// Returns the already installed administrative node identity.
///
/// ## Examples
/// ```gleam
/// distribution.node(peer) // -> The configured Node.
/// ```
pub fn node(peer: Peer) -> Node {
  peer.node
}

/// Returns the original full administrative spelling.
///
/// ## Examples
/// ```gleam
/// distribution.name(peer) // -> "executor@127.0.0.1"
/// ```
pub fn name(peer: Peer) -> String {
  peer.name
}

/// Checks a transient endpoint or reply PID against this configured peer.
/// It does not authenticate an arbitrary message's asserted sender field.
///
/// ## Examples
/// ```gleam
/// distribution.owns(peer, process.self()) // -> False for a remote peer.
/// ```
pub fn owns(peer: Peer, pid: Pid) -> Bool {
  ffi_distribution.pid_node(pid) == peer.node
}

/// Makes an explicit connection under a managed finite wait. A timeout ends
/// observation; OTP's independently bounded handshake may still settle later.
/// It grants no service replay, fresh effect identity or durable admission.
///
/// ## Examples
/// ```gleam
/// distribution.connect(peer, 2000) // -> Ok(Nil) or a closed failure.
/// ```
pub fn connect(peer: Peer, within_ms: Int) -> Result(Nil, Fault) {
  case within_ms >= 1 && within_ms <= 60_000 {
    False -> Error(InvalidConfiguration)
    True -> {
      let target = peer.node
      let outcomes =
        weft.new([fn() { ffi_distribution.connect(target) }])
        |> weft.deadline(within_ms)
        |> weft.start

      case outcomes {
        [weft.Completed(_, Nil)] -> Ok(Nil)
        [weft.Failed(_, fault)] -> Error(public_fault(fault))
        [weft.Abandoned(_)] -> Error(TimedOut)
        _ -> Error(Unavailable)
      }
    }
  }
}

/// Uses `nosuspend` and `noconnect` without discarding the original owned slot.
/// Sent proves neither recipient consumption nor durable service admission.
/// WouldBlock and Disconnected did not send; callers retain that same item.
/// Only unnamed PID subjects with a reference or the fixed endpoint tag can
/// cross this boundary.
///
/// ## Examples
/// ```gleam
/// distribution.send(reply_subject, bytes) // -> Sent or a bounded refusal.
/// ```
pub fn send(subject: Subject(a), message: a) -> SendResult {
  case ffi_distribution.send(subject, message) {
    ffi_distribution.Sent -> Sent
    ffi_distribution.WouldBlock -> WouldBlock
    ffi_distribution.Disconnected -> Disconnected
    ffi_distribution.InvalidSubject -> InvalidSubject
  }
}

/// Publishes the single literal executor endpoint name in this local VM.
/// Publication belongs after successful distribution boot and service startup.
///
/// ## Examples
/// ```gleam
/// distribution.register_endpoint(process.self()) // -> Ok(Nil).
/// ```
pub fn register_endpoint(pid: Pid) -> Result(Nil, Fault) {
  ffi_distribution.register_endpoint(pid) |> result.map_error(public_fault)
}

/// Looks up only the fixed executor endpoint and validates its configured node.
/// The timeout bounds erpc's response wait; distribution backpressure can delay
/// the send before that wait. Callers must enclose discovery in their managed
/// whole-operation deadline, as beam_endpoint does. The PID names this live
/// incarnation; lookup cannot recreate a service claim or effect identity.
///
/// ## Examples
/// ```gleam
/// distribution.endpoint(peer, 1000) // -> Ok(endpoint_pid).
/// ```
pub fn endpoint(peer: Peer, within_ms: Int) -> Result(Pid, Fault) {
  ffi_distribution.endpoint(peer.node, within_ms)
  |> result.map_error(public_fault)
}

fn public_fault(fault: ffi_distribution.Fault) -> Fault {
  case fault {
    ffi_distribution.InvalidConfiguration -> InvalidConfiguration
    ffi_distribution.UnsafeBoot -> UnsafeBoot
    ffi_distribution.InvalidCredentials -> InvalidCredentials
    ffi_distribution.Unavailable -> Unavailable
    ffi_distribution.TimedOut -> TimedOut
  }
}

fn valid_name(name: String) -> Result(Nil, Fault) {
  let pieces = string.split(name, "@")
  case pieces {
    [node, host] if node != "" && host != "" -> {
      let valid =
        string.byte_size(name) <= 255
        && string.contains(host, ".")
        && string.to_graphemes(name)
        |> list.all(fn(char) {
          string.contains(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-@.",
            char,
          )
        })

      case valid {
        True -> Ok(Nil)
        False -> Error(InvalidConfiguration)
      }
    }
    _ -> Error(InvalidConfiguration)
  }
}

fn valid_files(files: CredentialFiles) -> Result(Nil, Fault) {
  let paths = [files.ca, files.certificate, files.key, files.cookie]
  case
    list.all(paths, fn(path) {
      string.starts_with(path, "/")
      && string.byte_size(path) <= 4096
      && !string.contains(path, "\u{0}")
    })
  {
    True -> Ok(Nil)
    False -> Error(InvalidConfiguration)
  }
}

fn valid_peers(
  peers: List(#(String, BitArray)),
  names: List(String),
  pins: List(BitArray),
  count: Int,
) -> Result(Nil, Fault) {
  case peers {
    [] if count >= 1 -> Ok(Nil)
    [] -> Error(InvalidConfiguration)
    [#(name, pin), ..rest] if count < 32 -> {
      use Nil <- result.try(valid_name(name))
      case
        bit_array.byte_size(pin) == 32
        && !list.contains(names, name)
        && !list.contains(pins, pin)
      {
        True -> valid_peers(rest, [name, ..names], [pin, ..pins], count + 1)
        False -> Error(InvalidConfiguration)
      }
    }
    [_, ..] -> Error(InvalidConfiguration)
  }
}
