//// The single-file bundle that carries one node's identity to its machine.
////
//// An operator provisions a deployment on one machine and then has to put each
//// node's credentials on the machine that will run it. A bundle makes that one
//// file: copy it over a secure channel, run `loom distribution install` on the
//// far side, and the node is configured. It is JSON, because a program writes
//// it and a program reads it, and its first key says what it is.
////
//// A bundle holds private material, the node's key and the deployment's
//// cookie, so it is written with mode 0600 and must travel over a channel the
//// operator trusts. Everything else in it is public: the role, the Erlang node
//// name, the peer pins, the executors an orchestrator uses and the workspaces
//// an executor registers.
////
//// ## Decoding is the install gate
////
//// `decode` is total. It accepts a bundle only when every field is present and
//// of the right type, no key is unknown, the role carries only its own tables,
//// the cookie meets the daemon's rule, and the three PEM files are readable,
//// chain to the CA, and belong together. It hands the daemon's own validators
//// the node name and the peers, so the file `install` writes is one the daemon
//// accepts. What it cannot check is a peer's pin: the bundle does not hold the
//// peers' certificates.

import client/distribution.{type CredentialFiles, type PeerPin}
import client/distribution_plan.{type Role, type Workspace}
import client/executors.{type Executor as ExecutorRow}
import client/internal/ffi_pki
import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import storage/catalogue

/// The marker a bundle's first key carries. A reader refuses any other value,
/// so a future layout is a new marker and not a silent reinterpretation.
pub const format = "loom-distribution-bundle/1"

/// One node's complete provisioning.
pub type Bundle {
  Bundle(
    /// The node's plan name.
    name: String,
    /// What the daemon does.
    role: Role,
    /// The full Erlang node name, which is the certificate's exact name.
    erlang_node: String,
    /// The host other machines reach it at, also a name in the certificate.
    host: String,
    /// The fixed distribution port, if the plan gave one.
    listen_port: Option(Int),
    /// Where the credential files go on this machine, if the plan said.
    bundle_dir: Option(String),
    /// The trusted peers and the SHA-256 pin of each one's leaf certificate.
    peers: List(PeerPin),
    /// An orchestrator's `[executors.<name>]` rows.
    executors: List(ExecutorRow),
    /// An executor's `[workspaces.<name>]` rows.
    workspaces: List(Workspace),
    /// PEM of the deployment's CA certificate.
    ca: String,
    /// PEM of this node's certificate.
    certificate: String,
    /// PEM of this node's private key.
    key: String,
    /// The deployment's shared cookie, written to `$HOME/.erlang.cookie`.
    cookie: String,
  )
}

/// The bundle as JSON text with a trailing newline.
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(distribution_bundle.encode(bundle), "loom-distribution-bundle/1")
/// ```
pub fn encode(bundle: Bundle) -> String {
  let fields =
    list.flatten([
      [
        #("format", json.string(format)),
        #("name", json.string(bundle.name)),
        #("role", json.string(distribution_plan.role_word(bundle.role))),
        #("erlang_node", json.string(bundle.erlang_node)),
        #("host", json.string(bundle.host)),
      ],
      present("listen_port", bundle.listen_port, json.int),
      present("bundle_dir", bundle.bundle_dir, json.string),
      [
        #("peers", json.array(bundle.peers, peer_json)),
        #("executors", json.array(bundle.executors, executor_json)),
        #("workspaces", json.array(bundle.workspaces, workspace_json)),
        #("ca", json.string(bundle.ca)),
        #("certificate", json.string(bundle.certificate)),
        #("key", json.string(bundle.key)),
        #("cookie", json.string(bundle.cookie)),
      ],
    ])
  json.to_string(json.object(fields)) <> "\n"
}

/// Reads and validates a bundle. Every refusal names the field and carries no
/// key, certificate or cookie content.
///
/// ## Examples
///
/// ```gleam
/// assert result.is_error(distribution_bundle.decode("{}"))
/// ```
pub fn decode(text: String) -> Result(Bundle, String) {
  use present <- result.try(
    json.parse(text, decode.dict(decode.string, decode.dynamic))
    |> result.map_error(describe_json),
  )
  use Nil <- result.try(known_keys(dict.keys(present)))
  use raw <- result.try(
    json.parse(text, raw_decoder()) |> result.map_error(describe_json),
  )
  validate(raw)
}

/// One top-level table of a configuration file, with the text that defines it.
/// `[distribution]` and its `[[distribution.peers]]` rows are one table here,
/// because the rows belong to it; each `[executors.<name>]` and each
/// `[workspaces.<name>]` is its own.
pub type Table {
  Table(
    /// The keys that name the table: `["distribution"]` or
    /// `["executors", "devbox"]`.
    path: List(String),
    /// The TOML text that defines it, ending in a newline.
    text: String,
  )
}

/// The configuration tables a bundle owns, in the order they are written. The
/// credential paths are the ones `install` chose on this machine.
///
/// ## Examples
///
/// ```gleam
/// distribution_bundle.config_tables(bundle, files)
/// // -> [Table(["distribution"], "[distribution]\nnode = ..."), ..]
/// ```
pub fn config_tables(bundle: Bundle, files: CredentialFiles) -> List(Table) {
  let port = case bundle.listen_port {
    Some(number) -> "listen_port = " <> int.to_string(number) <> "\n"
    None -> ""
  }
  let head =
    "[distribution]\n"
    <> "node = "
    <> toml_string(bundle.erlang_node)
    <> "\nca = "
    <> toml_string(files.ca)
    <> "\ncertificate = "
    <> toml_string(files.certificate)
    <> "\nkey = "
    <> toml_string(files.key)
    <> "\ncookie = "
    <> toml_string(files.cookie)
    <> "\n"
    <> port
  let peers =
    list.map(bundle.peers, fn(peer) {
      "\n[[distribution.peers]]\nnode = "
      <> toml_string(peer.node)
      <> "\nsha256 = "
      <> toml_string(pin_hex(peer.sha256))
      <> "\n"
    })
  let rows =
    list.map(bundle.executors, fn(row) {
      Table(
        ["executors", row.name],
        "[executors."
          <> toml_key(row.name)
          <> "]\nnode = "
          <> toml_string(row.node)
          <> "\n",
      )
    })
  let workspaces =
    list.map(bundle.workspaces, fn(workspace) {
      Table(
        ["workspaces", workspace.name],
        "[workspaces."
          <> toml_key(workspace.name)
          <> "]\nroot = "
          <> toml_string(workspace.root)
          <> "\n",
      )
    })
  list.flatten([
    [Table(["distribution"], string.concat([head, ..peers]))],
    rows,
    workspaces,
  ])
}

/// The tables of `config_tables` as one piece of `loom.toml` text.
///
/// ## Examples
///
/// ```gleam
/// distribution_bundle.config_text(bundle, files)
/// ```
pub fn config_text(bundle: Bundle, files: CredentialFiles) -> String {
  config_tables(bundle, files)
  |> list.map(fn(table) { table.text })
  |> string.join("\n")
}

/// Lowercase hexadecimal of a pin, the spelling `[[distribution.peers]]` uses.
///
/// ## Examples
///
/// ```gleam
/// assert distribution_bundle.pin_hex(<<0, 255>>) == "00ff"
/// ```
pub fn pin_hex(pin: BitArray) -> String {
  string.lowercase(bit_array.base16_encode(pin))
}

/// A TOML basic string, escaping the two characters that need it. Every value
/// reaching it has already been checked to hold no control character.
///
/// ## Examples
///
/// ```gleam
/// assert distribution_bundle.toml_string("a\"b") == "\"a\\\"b\""
/// ```
pub fn toml_string(text: String) -> String {
  let escaped =
    text
    |> string.replace("\\", "\\\\")
    |> string.replace("\"", "\\\"")
  "\"" <> escaped <> "\""
}

/// A TOML table key: bare when its characters allow it, otherwise quoted.
///
/// ## Examples
///
/// ```gleam
/// assert distribution_bundle.toml_key("repo") == "repo"
/// assert distribution_bundle.toml_key("my repo") == "\"my repo\""
/// ```
pub fn toml_key(name: String) -> String {
  let bare = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
  case
    name != "" && list.all(string.to_graphemes(name), string.contains(bare, _))
  {
    True -> name
    False -> toml_string(name)
  }
}

// --- encoding ----------------------------------------------------------------

fn present(
  key: String,
  value: Option(a),
  encoder: fn(a) -> json.Json,
) -> List(#(String, json.Json)) {
  case value {
    Some(inner) -> [#(key, encoder(inner))]
    None -> []
  }
}

fn peer_json(peer: PeerPin) -> json.Json {
  json.object([
    #("node", json.string(peer.node)),
    #("sha256", json.string(pin_hex(peer.sha256))),
  ])
}

fn executor_json(row: ExecutorRow) -> json.Json {
  json.object([
    #("name", json.string(row.name)),
    #("node", json.string(row.node)),
  ])
}

fn workspace_json(workspace: Workspace) -> json.Json {
  json.object([
    #("name", json.string(workspace.name)),
    #("root", json.string(workspace.root)),
  ])
}

// --- decoding ----------------------------------------------------------------

const keys = [
  "format", "name", "role", "erlang_node", "host", "listen_port", "bundle_dir",
  "peers", "executors", "workspaces", "ca", "certificate", "key", "cookie",
]

fn known_keys(present: List(String)) -> Result(Nil, String) {
  case list.find(present, fn(key) { !list.contains(keys, key) }) {
    Error(Nil) -> Ok(Nil)
    Ok(unknown) ->
      Error(
        "bundle has an unknown key `"
        <> unknown
        <> "` (allowed: "
        <> string.join(keys, ", ")
        <> ")",
      )
  }
}

// Fields are read by name and the role is kept as the word the file carries,
// so a wrong word is refused by `validate` with the rule that names the allowed
// ones instead of by the decoder with a generic type error.
type Raw {
  Raw(
    marker: String,
    name: String,
    role: String,
    erlang_node: String,
    host: String,
    listen_port: Option(Int),
    bundle_dir: Option(String),
    peers: List(#(String, String)),
    executors: List(#(String, String)),
    workspaces: List(#(String, String)),
    ca: String,
    certificate: String,
    key: String,
    cookie: String,
  )
}

fn pair_decoder(
  first: String,
  second: String,
) -> decode.Decoder(#(String, String)) {
  use one <- decode.field(first, decode.string)
  use two <- decode.field(second, decode.string)
  decode.success(#(one, two))
}

fn raw_decoder() -> decode.Decoder(Raw) {
  use marker <- decode.field("format", decode.string)
  use name <- decode.field("name", decode.string)
  use role <- decode.field("role", decode.string)
  use erlang_node <- decode.field("erlang_node", decode.string)
  use host <- decode.field("host", decode.string)
  use listen_port <- decode.optional_field(
    "listen_port",
    None,
    decode.optional(decode.int),
  )
  use bundle_dir <- decode.optional_field(
    "bundle_dir",
    None,
    decode.optional(decode.string),
  )
  use peers <- decode.field(
    "peers",
    decode.list(pair_decoder("node", "sha256")),
  )
  use executors <- decode.optional_field(
    "executors",
    [],
    decode.list(pair_decoder("name", "node")),
  )
  use workspaces <- decode.optional_field(
    "workspaces",
    [],
    decode.list(pair_decoder("name", "root")),
  )
  use ca <- decode.field("ca", decode.string)
  use certificate <- decode.field("certificate", decode.string)
  use key <- decode.field("key", decode.string)
  use cookie <- decode.field("cookie", decode.string)
  decode.success(Raw(
    marker:,
    name:,
    role:,
    erlang_node:,
    host:,
    listen_port:,
    bundle_dir:,
    peers:,
    executors:,
    workspaces:,
    ca:,
    certificate:,
    key:,
    cookie:,
  ))
}

fn describe_json(error: json.DecodeError) -> String {
  case error {
    json.UnexpectedEndOfInput -> "the bundle is not complete JSON"
    json.UnexpectedByte(_) | json.UnexpectedSequence(_) ->
      "the bundle is not valid JSON"
    json.UnableToDecode([decode.DecodeError(expected:, found:, path:), ..]) ->
      "bundle field "
      <> case path {
        [] -> "(top level)"
        _ -> string.join(path, ".")
      }
      <> " is wrong: expected "
      <> expected
      <> ", found "
      <> found
    json.UnableToDecode([]) -> "the bundle does not match its format"
  }
}

// --- validation --------------------------------------------------------------

// The order is the order an operator can act on: the marker says whether this
// is a bundle at all, the node's own rules come next, then the peers and the
// role tables, and the credentials last because they are the costly check.
fn validate(raw: Raw) -> Result(Bundle, String) {
  use Nil <- result.try(case raw.marker == format {
    True -> Ok(Nil)
    False ->
      Error(
        "this is not a "
        <> format
        <> " bundle (format is \""
        <> string.slice(raw.marker, 0, 64)
        <> "\")",
      )
  })
  use bundle <- result.try(assemble(raw))
  use Nil <- result.try(
    distribution_plan.check_node(node_of(bundle))
    |> result.map_error(fn(reason) { "bundle " <> reason }),
  )
  use Nil <- result.try(valid_peers(bundle))
  use Nil <- result.try(valid_role_tables(bundle))
  use Nil <- result.try(valid_cookie(bundle.cookie))
  use Nil <- result.try(valid_credentials(bundle))
  Ok(bundle)
}

fn assemble(raw: Raw) -> Result(Bundle, String) {
  use role <- result.try(
    distribution_plan.role_from_word(raw.role)
    |> result.map_error(fn(reason) { "bundle " <> reason }),
  )
  use peers <- result.try(
    list.try_map(raw.peers, fn(pair) {
      bit_array.base16_decode(pair.1)
      |> result.map(fn(sha256) { distribution.PeerPin(node: pair.0, sha256:) })
      |> result.map_error(fn(_) {
        "bundle peers.sha256 must be hexadecimal for " <> pair.0
      })
    }),
  )
  Ok(Bundle(
    name: raw.name,
    role:,
    erlang_node: raw.erlang_node,
    host: raw.host,
    listen_port: raw.listen_port,
    bundle_dir: raw.bundle_dir,
    peers:,
    executors: list.map(raw.executors, fn(pair) {
      executors.plain(pair.0, pair.1)
    }),
    workspaces: list.map(raw.workspaces, fn(pair) {
      distribution_plan.Workspace(name: pair.0, root: pair.1)
    }),
    ca: raw.ca,
    certificate: raw.certificate,
    key: raw.key,
    cookie: raw.cookie,
  ))
}

// The plan's own node rules apply to a bundle unchanged, so the bundle is
// seen as the node it was made from. Its `executors` field is the plan's list
// of executor names, which the bundle carries as rows.
fn node_of(bundle: Bundle) -> distribution_plan.Node {
  distribution_plan.Node(
    name: bundle.name,
    role: bundle.role,
    erlang_node: bundle.erlang_node,
    host: bundle.host,
    listen_port: bundle.listen_port,
    bundle_dir: bundle.bundle_dir,
    executors: list.map(bundle.executors, fn(row) { row.name }),
    workspaces: bundle.workspaces,
  )
}

// The daemon's own validator judges the node name, the peers and their pins
// and the port, with placeholder paths, so the bundle cannot hold a
// configuration the daemon would refuse at start.
fn valid_peers(bundle: Bundle) -> Result(Nil, String) {
  let placeholder =
    distribution.CredentialFiles(
      ca: "/ca",
      certificate: "/certificate",
      key: "/key",
      cookie: "/cookie",
    )
  distribution.configure(
    bundle.erlang_node,
    bundle.peers,
    placeholder,
    bundle.listen_port,
  )
  |> result.replace(Nil)
  |> result.map_error(fn(reason) { "bundle " <> reason })
}

// The plan's node rules already keep the other role's tables out. What is left
// is that an orchestrator's executor rows name peers it trusts, which is the
// rule `executors.from_document` applies to the file.
fn valid_role_tables(bundle: Bundle) -> Result(Nil, String) {
  let nodes = list.map(bundle.peers, fn(peer) { peer.node })
  list.try_each(bundle.executors, fn(row) {
    case catalogue.is_executor_name(row.name), list.contains(nodes, row.node) {
      True, True -> Ok(Nil)
      False, _ ->
        Error("bundle executors.name is not an executor name: " <> row.name)
      _, False ->
        Error(
          "bundle executors "
          <> row.name
          <> " names "
          <> row.node
          <> ", which is not one of its peers",
        )
    }
  })
}

// The daemon's cookie rule, checked here so a bad cookie is found before it is
// installed and not when the daemon refuses to start.
fn valid_cookie(cookie: String) -> Result(Nil, String) {
  let allowed =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
  case
    string.byte_size(cookie) >= 16
    && string.byte_size(cookie) <= 128
    && list.all(string.to_graphemes(cookie), string.contains(allowed, _))
  {
    True -> Ok(Nil)
    False ->
      Error(
        "bundle cookie must be 16 to 128 characters of A-Z, a-z, 0-9, _ and -",
      )
  }
}

fn valid_credentials(bundle: Bundle) -> Result(Nil, String) {
  use names <- result.try(
    ffi_pki.inspect(bundle.ca, bundle.certificate, bundle.key)
    |> result.map_error(fn(defect) {
      case defect {
        ffi_pki.UnreadableAuthority ->
          "bundle ca is not exactly one PEM certificate"
        ffi_pki.UnreadableCertificate ->
          "bundle certificate is not exactly one PEM certificate"
        ffi_pki.UnreadableKey -> "bundle key is not exactly one PEM private key"
        ffi_pki.ChainRejected ->
          "bundle certificate does not chain to its ca, or is outside its validity period"
        ffi_pki.KeyMismatch ->
          "bundle key is not the private key of its certificate"
      }
    }),
  )

  // The daemon's own rule: exactly one DNS name holds an at sign and it is the
  // node name. The host has to be there too, or a peer's host name check
  // would refuse this node.
  let nodes = list.filter(names, string.contains(_, "@"))
  case nodes == [bundle.erlang_node], list.contains(names, bundle.host) {
    True, True -> Ok(Nil)
    False, _ ->
      Error(
        "bundle certificate must carry "
        <> bundle.erlang_node
        <> " as its only DNS name with an at sign",
      )
    _, False -> Error("bundle certificate must carry the host " <> bundle.host)
  }
}
