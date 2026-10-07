//// Trusted membership in Erlang distribution (protocol-change/078).
////
//// An orchestrator and an executor are the same release, administered by the
//// same operator, and they trust each other as Erlang peers. This module is
//// the membership layer only: it starts TLS distribution on a node that was
//// booted for it, and it connects to the peers the operator listed. It sends
//// no message, registers no name and runs no service. The slices that put an
//// executor role on top of it use the `Peer` it hands out.
////
//// A connected peer has the full privileges of a distributed Erlang node, so
//// the boundary is drawn around who may connect, in both directions:
////
//// - the VM must be booted with `-proto_dist inet_tls` and an
////   `-ssl_dist_optfile` that `tls_options` generated from this very
////   configuration, and with no node name, no cookie flag and no loose TLS
////   options. `start` refuses anything else and says which check failed;
//// - every certificate chain is verified (PKIX), and the presented leaf must
////   hash to the SHA-256 pin configured for the peer and carry that peer's
////   exact node name as a DNS name. Both sides of every connection check
////   this, so a stolen certificate for another node, or a pin that matches
////   a certificate from an untrusted CA, does not get in;
//// - `dist_auto_connect` is `never`, so a message to a node nobody connected
////   to is dropped rather than dialed. The only connections are the ones
////   `connect` makes, and only to configured peers;
//// - the node is hidden, and only configured peers are allowed to connect.
////
//// Nothing here is reachable from code-mode satellites, language servers or
//// MCP servers. They boot with `-proto_dist none` and never see the
//// credential files or the options file.
////
//// The credentials are four operator-provisioned files. The cookie file must
//// be the VM's own `$HOME/.erlang.cookie`, because the emulator reads the
//// cookie from there when it opens its listener.

import client/internal/ffi_distribution
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/node.{type Node}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tom
import weft

/// The environment variable the `bin/loomd` launcher honours. When it is set,
/// the launcher boots the VM with the TLS distribution flags and the options
/// file it names, and when it is unset the launcher is unchanged.
pub const launcher_variable = "LOOM_DISTRIBUTION_OPTFILE"

/// The fixed administrative files. Each path is absolute, and none of them is
/// ever passed to a satellite or mounted into a jail.
pub type CredentialFiles {
  CredentialFiles(
    /// PEM trust roots that must chain every peer certificate.
    ca: String,
    /// PEM certificate chain of this node. Its leaf carries this node's name.
    certificate: String,
    /// Private PEM key of this node, mode 0600.
    key: String,
    /// This VM's `$HOME/.erlang.cookie`, mode 0600, at least 16 characters of
    /// `[A-Za-z0-9_-]` and no trailing newline.
    cookie: String,
  )
}

/// One configured peer: the node name it answers to and the SHA-256 of the
/// DER of its leaf certificate.
pub type PeerPin {
  PeerPin(
    /// The full node name, `name@host`.
    node: String,
    /// Exactly 32 bytes.
    sha256: BitArray,
  )
}

/// A validated configuration. Building one creates no Erlang atoms and reads
/// no file; `start` does both.
pub opaque type Config {
  Config(
    local: String,
    peers: List(PeerPin),
    files: CredentialFiles,
    listen_port: Option(Int),
  )
}

/// A successful local boot. It says this VM is a distribution member, not that
/// any peer is reachable.
pub type Membership =
  ffi_distribution.Membership

/// One configured peer, resolved to its node at boot.
pub opaque type Peer {
  Peer(name: String, node: Node)
}

/// Which boot precondition failed. Each names the operator's remedy and none
/// carries a credential.
pub type BootRefusal {
  /// This VM is already distributed, so it was not booted for this module.
  AlreadyDistributed

  /// The emulator is older than OTP 29.
  UnsupportedOtp

  /// The emulator was not booted with `-proto_dist inet_tls`.
  NotTlsDistribution

  /// The emulator was booted without `-ssl_dist_optfile`.
  OptionsFileUnset

  /// The boot arguments also name a node, a cookie or loose TLS options.
  ConflictingBootFlag

  /// The loaded options file is not private, or is not the one `tls_options`
  /// generates for this configuration.
  OptionsMismatch
}

/// Closed failures. None carries credential contents or OTP diagnostic text.
pub type Fault {
  /// A name, port or deadline was outside its finite range.
  InvalidConfiguration

  /// The VM was not booted for trusted distribution.
  UnsafeBoot(BootRefusal)

  /// A credential file was missing, oversized, not private, or does not
  /// match this node.
  InvalidCredentials

  /// OTP could not start distribution or complete a connection.
  Unavailable

  /// The observation deadline of a connection ended.
  TimedOut
}

/// Validates one node's identity, credentials and peers.
///
/// A node name is `name@host` of at most 255 ASCII letters, digits, `_`, `-`
/// and `.`, with a dot in the host. One to 32 distinct peers are required, none
/// of them this node, each with a distinct 32-byte pin. A listen port, when
/// given, pins the distribution listener to one port.
///
/// ## Examples
///
/// ```gleam
/// distribution.configure("a@10.0.0.1", [], files, None) // -> Error(..)
/// ```
pub fn configure(
  local: String,
  peers: List(PeerPin),
  files: CredentialFiles,
  listen_port: Option(Int),
) -> Result(Config, String) {
  use Nil <- result.try(valid_name("distribution.node", local))
  use Nil <- result.try(valid_files(files))
  use Nil <- result.try(valid_peers(local, peers))
  use Nil <- result.try(valid_port(listen_port))
  Ok(Config(local:, peers:, files:, listen_port:))
}

/// Reads the `[distribution]` table of a configuration document, or `None`
/// when the document has no such table, in which case distribution stays off.
///
/// Every refusal names the key, because the operator is looking at a file.
///
/// ## Examples
///
/// ```gleam
/// assert distribution.from_document(dict.new()) == Ok(None)
/// ```
pub fn from_document(
  document: Dict(String, tom.Toml),
) -> Result(Option(Config), String) {
  case dict.get(document, "distribution") {
    Error(Nil) -> Ok(None)
    Ok(tom.Table(fields)) -> table(fields) |> result.map(Some)
    Ok(_) -> Error("distribution must be a [distribution] table")
  }
}

/// Reads the configuration from TOML text, for callers that hold no parsed
/// document.
///
/// ## Examples
///
/// ```gleam
/// assert distribution.parse("") == Ok(None)
/// ```
pub fn parse(text: String) -> Result(Option(Config), String) {
  use document <- result.try(
    tom.parse(text)
    |> result.map_error(fn(error) {
      "invalid daemon configuration: " <> string.inspect(error)
    }),
  )
  from_document(document)
}

/// The node names of the configured peers, in the order the file lists them.
///
/// Another table that names a peer, such as `[executors.<name>]`, checks its
/// reference against this list, so the reference means a node the operator
/// has pinned and nothing else.
///
/// ## Examples
///
/// ```gleam
/// distribution.peer_nodes(config) // -> ["executor@10.0.0.2"]
/// ```
pub fn peer_nodes(config: Config) -> List(String) {
  list.map(config.peers, fn(peer) { peer.node })
}

/// Renders the `ssl_dist_optfile` for a configuration. The text names the
/// credential paths and the public pins only, so it holds no secret, but
/// `start` still requires the file to be private and to equal this text.
///
/// ## Examples
///
/// ```gleam
/// distribution.tls_options(config) // -> "[{server, [..]}, {client, [..]}].\n"
/// ```
pub fn tls_options(config: Config) -> String {
  ffi_distribution.options(pairs(config.peers), config.files)
}

/// The emulator flags a launcher adds to boot a VM for this module.
///
/// ## Examples
///
/// ```gleam
/// distribution.boot_arguments("/etc/loom/dist.options")
/// // -> ["-proto_dist", "inet_tls", "-ssl_dist_optfile", "/etc/loom/dist.options"]
/// ```
pub fn boot_arguments(options_path: String) -> List(String) {
  ["-proto_dist", "inet_tls", "-ssl_dist_optfile", options_path]
}

/// Starts hidden TLS distribution on a VM booted with `boot_arguments`.
///
/// The preconditions are checked before a credential is read or a listener
/// opened. A VM that is already distributed, that was booted without the TLS
/// flags, or whose options file differs from `tls_options` is refused and
/// left untouched. A VM that passes is started once; a failed start stops the
/// partial distribution and leaves the VM non-distributed.
///
/// ## Examples
///
/// ```gleam
/// distribution.start(config) // -> Ok(membership) on a VM booted for it
/// ```
pub fn start(config: Config) -> Result(Membership, Fault) {
  ffi_distribution.start(
    config.local,
    pairs(config.peers),
    config.files,
    config.listen_port,
  )
  |> result.map_error(fault)
}

/// Resolves a configured peer name to the node made for it at boot. A name
/// that was not configured is refused, so network input never reaches the
/// atom table. Success is identity only, not connectivity.
///
/// ## Examples
///
/// ```gleam
/// distribution.peer(membership, "unconfigured@10.0.0.9") // -> Error(..)
/// ```
pub fn peer(membership: Membership, name: String) -> Result(Peer, Fault) {
  use node <- result.try(
    ffi_distribution.peer(membership, name) |> result.map_error(fault),
  )
  Ok(Peer(name:, node:))
}

/// The peer's node, for the slices that address it.
///
/// ## Examples
///
/// ```gleam
/// distribution.node(peer) // -> the configured Node
/// ```
pub fn node(peer: Peer) -> Node {
  peer.node
}

/// The peer's configured spelling.
///
/// ## Examples
///
/// ```gleam
/// distribution.name(peer) // -> "executor@10.0.0.2"
/// ```
pub fn name(peer: Peer) -> String {
  peer.name
}

/// Connects to a configured peer and waits at most `within_ms` for the answer.
///
/// The wait is a weft deadline around OTP's own handshake bound. When it ends
/// first the call reports `TimedOut`, and the handshake may still settle
/// afterwards. A refused certificate, a wrong pin, a wrong name and an
/// unreachable host all report `Unavailable`.
///
/// ## Examples
///
/// ```gleam
/// distribution.connect(peer, 2000) // -> Ok(Nil) or Error(Unavailable)
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
        [weft.Completed(..)] -> Ok(Nil)
        [weft.Failed(error: failure, ..)] -> Error(fault(failure))
        [weft.Abandoned(..)] -> Error(TimedOut)
        _ -> Error(Unavailable)
      }
    }
  }
}

/// An operator-facing sentence for a fault, with the remedy where there is one.
///
/// ## Examples
///
/// ```gleam
/// distribution.describe(distribution.InvalidCredentials)
/// ```
pub fn describe(failure: Fault) -> String {
  case failure {
    InvalidConfiguration -> "the distribution configuration was refused"
    UnsafeBoot(refusal) -> describe_boot(refusal)
    InvalidCredentials ->
      "a distribution credential file is missing, too large, not private "
      <> "(mode 0600 for the key and the cookie), or does not match this node: "
      <> "the certificate must carry the node name as its only DNS name with "
      <> "an at sign, and the cookie must be this VM's $HOME/.erlang.cookie"
    Unavailable ->
      "OTP could not start distribution or reach the peer; check that epmd is "
      <> "reachable, the listen port is free, and the peer pins and "
      <> "certificates match"
    TimedOut -> "the distribution connection did not settle in time"
  }
}

fn describe_boot(refusal: BootRefusal) -> String {
  let remedy =
    "; generate the options file with `loomd distribution options` and start "
    <> "the daemon through bin/loomd with "
    <> launcher_variable
    <> " set to it"
  case refusal {
    AlreadyDistributed ->
      "[distribution] is configured but this VM already runs distribution"
    UnsupportedOtp -> "[distribution] needs Erlang/OTP 29 or newer"
    NotTlsDistribution ->
      "[distribution] is configured but this VM was not booted with "
      <> "-proto_dist inet_tls"
      <> remedy
    OptionsFileUnset ->
      "[distribution] is configured but this VM was booted without "
      <> "-ssl_dist_optfile"
      <> remedy
    ConflictingBootFlag ->
      "[distribution] is configured but the VM boot arguments also set a "
      <> "node name, a cookie or loose TLS options; remove them from ERL_FLAGS"
    OptionsMismatch ->
      "[distribution] is configured but the loaded options file is not "
      <> "private or was generated from a different configuration"
      <> remedy
  }
}

// The FFI keeps one flat vocabulary of failures. The public type groups the
// boot refusals under one constructor so a caller can tell "the operator booted
// this VM wrongly" from "OTP failed" with a single match.
fn fault(failure: ffi_distribution.Failure) -> Fault {
  case failure {
    ffi_distribution.InvalidConfiguration -> InvalidConfiguration
    ffi_distribution.AlreadyDistributed -> UnsafeBoot(AlreadyDistributed)
    ffi_distribution.UnsupportedOtp -> UnsafeBoot(UnsupportedOtp)
    ffi_distribution.NotTlsDistribution -> UnsafeBoot(NotTlsDistribution)
    ffi_distribution.OptionsFileUnset -> UnsafeBoot(OptionsFileUnset)
    ffi_distribution.ConflictingBootFlag -> UnsafeBoot(ConflictingBootFlag)
    ffi_distribution.OptionsMismatch -> UnsafeBoot(OptionsMismatch)
    ffi_distribution.InvalidCredentials -> InvalidCredentials
    ffi_distribution.Unavailable -> Unavailable
  }
}

fn pairs(peers: List(PeerPin)) -> List(#(String, BitArray)) {
  list.map(peers, fn(pin) { #(pin.node, pin.sha256) })
}

// The table decoder. A key it does not know is refused, as the daemon's other
// tables refuse one, so a typo in a trust setting never becomes a setting that
// silently does nothing.
fn table(fields: Dict(String, tom.Toml)) -> Result(Config, String) {
  use Nil <- result.try(known_keys(
    dict.keys(fields),
    ["node", "ca", "certificate", "key", "cookie", "listen_port", "peers"],
    "[distribution]",
  ))
  use local <- result.try(string_key(fields, "node", "distribution"))
  use ca <- result.try(string_key(fields, "ca", "distribution"))
  use certificate <- result.try(string_key(
    fields,
    "certificate",
    "distribution",
  ))
  use key <- result.try(string_key(fields, "key", "distribution"))
  use cookie <- result.try(string_key(fields, "cookie", "distribution"))
  use listen_port <- result.try(port_key(fields))
  use peers <- result.try(peer_rows(fields))
  configure(
    local,
    peers,
    CredentialFiles(ca:, certificate:, key:, cookie:),
    listen_port,
  )
}

fn peer_rows(fields: Dict(String, tom.Toml)) -> Result(List(PeerPin), String) {
  case dict.get(fields, "peers") {
    Error(Nil) ->
      Error("distribution needs at least one [[distribution.peers]] row")
    Ok(tom.ArrayOfTables(rows)) -> list.try_map(rows, peer_row)
    Ok(_) -> Error("distribution.peers must be [[distribution.peers]] tables")
  }
}

fn peer_row(row: Dict(String, tom.Toml)) -> Result(PeerPin, String) {
  use Nil <- result.try(known_keys(
    dict.keys(row),
    ["node", "sha256"],
    "[[distribution.peers]]",
  ))
  use node <- result.try(string_key(row, "node", "distribution.peers"))
  use hex <- result.try(string_key(row, "sha256", "distribution.peers"))
  use sha256 <- result.try(
    bit_array.base16_decode(hex)
    |> result.map_error(fn(_) {
      "distribution.peers.sha256 must be hexadecimal for " <> node
    }),
  )
  Ok(PeerPin(node:, sha256:))
}

fn port_key(fields: Dict(String, tom.Toml)) -> Result(Option(Int), String) {
  case dict.get(fields, "listen_port") {
    Error(Nil) -> Ok(None)
    Ok(tom.Int(port)) -> Ok(Some(port))
    Ok(_) -> Error("distribution.listen_port must be a whole number")
  }
}

fn string_key(
  fields: Dict(String, tom.Toml),
  key: String,
  table: String,
) -> Result(String, String) {
  case dict.get(fields, key) {
    Ok(tom.String(value)) -> Ok(value)
    Ok(_) -> Error(table <> "." <> key <> " must be a string")
    Error(Nil) -> Error(table <> "." <> key <> " is required")
  }
}

fn known_keys(
  present: List(String),
  allowed: List(String),
  place: String,
) -> Result(Nil, String) {
  case list.find(present, fn(key) { !list.contains(allowed, key) }) {
    Error(Nil) -> Ok(Nil)
    Ok(unknown) ->
      Error(
        "unknown key `"
        <> unknown
        <> "` in "
        <> place
        <> " (allowed: "
        <> string.join(allowed, ", ")
        <> ")",
      )
  }
}

// Node names become atoms once, at start, so the grammar is narrow: ASCII only,
// a dotted host, and a hard length bound. The same grammar is what the TLS
// name check compares, so a name that passes here is one a certificate can
// carry exactly.
fn valid_name(place: String, name: String) -> Result(Nil, String) {
  let allowed =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-."
  let shaped = case string.split(name, "@") {
    [user, host] ->
      user != ""
      && host != ""
      && string.contains(host, ".")
      && string.byte_size(name) <= 255
      && list.all(string.to_graphemes(user <> host), string.contains(allowed, _))
    _ -> False
  }
  case shaped {
    True -> Ok(Nil)
    False ->
      Error(
        place
        <> " must be a full node name name@host (host with a dot, ASCII "
        <> "letters, digits, `_`, `-` and `.`, at most 255 bytes): "
        <> name,
      )
  }
}

fn valid_files(files: CredentialFiles) -> Result(Nil, String) {
  list.try_each(
    [
      #("ca", files.ca),
      #("certificate", files.certificate),
      #("key", files.key),
      #("cookie", files.cookie),
    ],
    fn(entry) {
      let #(key, path) = entry
      case
        string.starts_with(path, "/")
        && string.byte_size(path) <= 4096
        && !string.contains(path, "\u{0}")
      {
        True -> Ok(Nil)
        False -> Error("distribution." <> key <> " must be an absolute path")
      }
    },
  )
}

fn valid_peers(local: String, peers: List(PeerPin)) -> Result(Nil, String) {
  let count = list.length(peers)
  use Nil <- result.try(case count >= 1 && count <= 32 {
    True -> Ok(Nil)
    False -> Error("distribution needs between 1 and 32 peers")
  })
  use Nil <- result.try(
    list.try_each(peers, fn(pin) {
      use Nil <- result.try(valid_name("distribution.peers.node", pin.node))
      case bit_array.byte_size(pin.sha256) == 32 {
        True -> Ok(Nil)
        False ->
          Error(
            "distribution.peers.sha256 must be 64 hexadecimal characters "
            <> "(32 bytes) for "
            <> pin.node,
          )
      }
    }),
  )
  let names = list.map(peers, fn(pin) { pin.node })
  let pins = list.map(peers, fn(pin) { pin.sha256 })
  case
    list.contains(names, local),
    list.unique(names) == names,
    list.unique(pins) == pins
  {
    True, _, _ -> Error("distribution.peers must not list this node itself")
    _, False, _ -> Error("distribution.peers lists a node name twice")
    _, _, False -> Error("distribution.peers lists a pin twice")
    False, True, True -> Ok(Nil)
  }
}

fn valid_port(port: Option(Int)) -> Result(Nil, String) {
  case port {
    None -> Ok(Nil)
    Some(value) if value >= 1 && value <= 65_535 -> Ok(Nil)
    Some(value) ->
      Error(
        "distribution.listen_port must be between 1 and 65535, got "
        <> int.to_string(value),
      )
  }
}
