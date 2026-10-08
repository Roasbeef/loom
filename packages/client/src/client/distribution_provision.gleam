//// Provisioning a whole deployment from a plan.
////
//// One run of this module turns a validated plan into everything the nodes
//// need to trust each other: a fresh certificate authority, one certificate
//// per node, one shared cookie, and for each node a single-file bundle that
//// carries all of it. It also describes the deployment in `system.json`, which
//// holds no private material, so an operator can see who peers with whom and
//// which pin each node presents without opening a bundle.
////
//// ## What is minted, and what is thrown away
////
//// The authority exists only for the length of this call. Its key signs the
//// node certificates and is then dropped, so nothing an operator keeps can
//// issue a certificate for a new node. Adding a node means provisioning again,
//// which mints a new authority and replaces every bundle. Renewing a
//// certificate before it expires, adding a node without touching the others
//// and revoking one are all the same later work: certificate rotation.
////
//// The cookie is shared by the whole deployment, because Erlang distribution
//// refuses a connection between nodes whose cookies differ. It is 32 random
//// characters from the daemon's cookie alphabet.
////
//// ## Files
////
//// `write` puts `<node>.loombundle` (mode 0600) and `system.json` in the output
//// directory, which it creates with mode 0700. A directory that already holds
//// anything is refused unless the caller asks to replace, so a second run
//// cannot quietly mix bundles of two different authorities.

import client/distribution
import client/distribution_bundle.{type Bundle, Bundle}
import client/distribution_plan.{
  type Node, type Plan, type Role, type Workspace, Executor, Orchestrator,
}
import client/executors
import client/internal/ffi_pki
import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import simplifile

/// What to do when the output directory already holds files.
pub type Overwrite {
  /// Refuse, so two runs never mix.
  RefuseExisting

  /// Write over files with the same names and leave other files alone.
  ReplaceExisting
}

/// The result of provisioning, before anything is written.
pub type Deployment {
  Deployment(
    /// One bundle per node, in plan order.
    bundles: List(Bundle),
    /// The public description of the whole deployment.
    system: System,
  )
}

/// The machine-readable description of a deployment. It holds nothing private:
/// no key, no cookie and no certificate, only the pins that identify them.
pub type System {
  System(nodes: List(SystemNode))
}

/// One node of the description.
pub type SystemNode {
  SystemNode(
    /// The plan name, and the bundle's file name without its extension.
    name: String,
    /// What the daemon does.
    role: Role,
    /// The Erlang node name.
    erlang_node: String,
    /// The host other machines reach it at.
    host: String,
    /// The fixed distribution port, if there is one.
    listen_port: Option(Int),
    /// Where its credentials will live on its machine, if the plan said.
    bundle_dir: Option(String),
    /// Hexadecimal SHA-256 of its leaf certificate: the pin its peers hold.
    pin: String,
    /// The plan names of the nodes it trusts, in plan order.
    peers: List(String),
    /// The executors an orchestrator uses, by plan name.
    executors: List(String),
    /// The workspaces an executor registers.
    workspaces: List(Workspace),
  )
}

/// The marker `system.json` carries as its first key.
pub const system_format = "loom-distribution-system/1"

/// The file name of the description inside the output directory.
pub const system_file = "system.json"

/// The extension of a bundle file.
pub const bundle_extension = ".loombundle"

/// Mints the authority, the node certificates, the cookie and the bundles for a
/// plan. Nothing is written.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(deployment) = distribution_provision.provision(plan)
/// ```
pub fn provision(plan: Plan) -> Result(Deployment, String) {
  let #(authority, authority_key) = ffi_pki.authority("loom deployment CA")
  use issued <- result.try(
    list.try_map(plan.nodes, fn(node) {
      let names = list.unique([node.erlang_node, node.host])
      use #(certificate, key) <- result.try(
        ffi_pki.issue(authority, authority_key, node.name, names)
        |> result.map_error(fn(_) {
          "could not issue a certificate for " <> node.name
        }),
      )
      use pin <- result.try(
        ffi_pki.pin(certificate)
        |> result.map_error(fn(_) {
          "could not pin the certificate of " <> node.name
        }),
      )
      Ok(Issued(node:, certificate:, key:, pin:))
    }),
  )
  let cookie = bit_array.base64_url_encode(ffi_pki.random_bytes(24), False)
  let bundles =
    list.map(issued, fn(entry) {
      bundle(plan, issued, entry, authority, cookie)
    })
  Ok(Deployment(bundles:, system: system(plan, issued)))
}

/// Writes the bundles and `system.json` into `output` and returns the paths it
/// wrote. The directory is created with mode 0700 when it is absent, and an
/// existing directory that holds anything is refused under `RefuseExisting`.
///
/// ## Examples
///
/// ```gleam
/// distribution_provision.write(deployment, "out", RefuseExisting)
/// ```
pub fn write(
  deployment: Deployment,
  output: String,
  overwrite: Overwrite,
) -> Result(List(String), String) {
  use Nil <- result.try(check_empty(output, overwrite))
  use Nil <- result.try(bootstrap.ensure_private_directory(output))
  use bundle_paths <- result.try(
    list.try_map(deployment.bundles, fn(bundle) {
      let path = output <> "/" <> bundle.name <> bundle_extension
      bootstrap.atomic_write_private(path, distribution_bundle.encode(bundle))
      |> result.replace(path)
      |> result.map_error(fn(reason) { path <> " is unwritable: " <> reason })
    }),
  )
  let system_path = output <> "/" <> system_file
  use Nil <- result.try(
    simplifile.write(system_path, system_json(deployment.system))
    |> result.map_error(fn(error) {
      system_path <> " is unwritable: " <> simplifile.describe_error(error)
    }),
  )
  Ok(list.append(bundle_paths, [system_path]))
}

/// The description as JSON text with a trailing newline.
///
/// ## Examples
///
/// ```gleam
/// distribution_provision.system_json(deployment.system)
/// ```
pub fn system_json(system: System) -> String {
  let node_json = fn(node: SystemNode) {
    json.object(
      list.flatten([
        [
          #("name", json.string(node.name)),
          #("role", json.string(distribution_plan.role_word(node.role))),
          #("erlang_node", json.string(node.erlang_node)),
          #("host", json.string(node.host)),
        ],
        optional("listen_port", node.listen_port, json.int),
        optional("bundle_dir", node.bundle_dir, json.string),
        [
          #("pin", json.string(node.pin)),
          #("peers", json.array(node.peers, json.string)),
          #("executors", json.array(node.executors, json.string)),
          #(
            "workspaces",
            json.array(node.workspaces, fn(workspace) {
              json.object([
                #("name", json.string(workspace.name)),
                #("root", json.string(workspace.root)),
              ])
            }),
          ),
        ],
      ]),
    )
  }
  json.object([
    #("format", json.string(system_format)),
    #("nodes", json.array(system.nodes, node_json)),
  ])
  |> json.to_string
  <> "\n"
}

/// Reads `system.json` back. Total: a wrong marker, a missing field and a
/// wrong type are each a worded error.
///
/// ## Examples
///
/// ```gleam
/// assert distribution_provision.system_from_json(text) == Ok(deployment.system)
/// ```
pub fn system_from_json(text: String) -> Result(System, String) {
  json.parse(text, system_decoder())
  |> result.map_error(fn(error) {
    "invalid " <> system_file <> ": " <> string.inspect(error)
  })
  |> result.flatten
}

/// A fixed-width table of the deployment for `loom distribution show`: one row
/// per node, then who each node trusts.
///
/// ## Examples
///
/// ```gleam
/// io.println(distribution_provision.render(system))
/// ```
pub fn render(system: System) -> String {
  let header = ["NODE", "ROLE", "ERLANG NODE", "HOST", "PORT", "PIN"]
  let rows =
    list.map(system.nodes, fn(node) {
      [
        node.name,
        distribution_plan.role_word(node.role),
        node.erlang_node,
        node.host,
        case node.listen_port {
          Some(port) -> int.to_string(port)
          None -> "-"
        },
        string.slice(node.pin, 0, 16),
      ]
    })
  let widths =
    list.index_map(header, fn(title, column) {
      list.fold([header, ..rows], string.length(title), fn(widest, row) {
        case list.drop(row, column) {
          [cell, ..] -> int.max(widest, string.length(cell))
          [] -> widest
        }
      })
    })
  let line = fn(cells) {
    list.zip(cells, widths)
    |> list.map(fn(pair) { string.pad_end(pair.0, pair.1, " ") })
    |> string.join("  ")
    |> string.trim_end
  }
  let table = list.map([header, ..rows], line)
  let edges =
    list.map(system.nodes, fn(node) {
      "  " <> node.name <> " trusts " <> names(node.peers) <> detail(node)
    })
  string.join(list.flatten([table, ["", "Peer edges:"], edges]), "\n")
}

// --- the bundle of one node --------------------------------------------------

type Issued {
  Issued(node: Node, certificate: String, key: String, pin: BitArray)
}

fn bundle(
  plan: Plan,
  issued: List(Issued),
  entry: Issued,
  authority: String,
  cookie: String,
) -> Bundle {
  let node = entry.node
  Bundle(
    name: node.name,
    role: node.role,
    erlang_node: node.erlang_node,
    host: node.host,
    listen_port: node.listen_port,
    bundle_dir: node.bundle_dir,
    peers: list.map(distribution_plan.peers(plan, node), fn(peer) {
      distribution.PeerPin(node: peer.erlang_node, sha256: pin_of(issued, peer))
    }),
    executors: list.map(distribution_plan.used_executors(plan, node), fn(row) {
      executors.plain(row.name, row.erlang_node)
    }),
    workspaces: node.workspaces,
    ca: authority,
    certificate: entry.certificate,
    key: entry.key,
    cookie:,
  )
}

// A pin is looked up by node name, which is unique in a validated plan. The
// empty fallback is unreachable and would fail the daemon's 32-byte rule at
// `decode`, so a bug here cannot produce a bundle that installs.
fn pin_of(issued: List(Issued), node: Node) -> BitArray {
  case list.find(issued, fn(entry) { entry.node.name == node.name }) {
    Ok(entry) -> entry.pin
    Error(Nil) -> <<>>
  }
}

fn system(plan: Plan, issued: List(Issued)) -> System {
  System(
    nodes: list.map(issued, fn(entry) {
      let node = entry.node
      SystemNode(
        name: node.name,
        role: node.role,
        erlang_node: node.erlang_node,
        host: node.host,
        listen_port: node.listen_port,
        bundle_dir: node.bundle_dir,
        pin: distribution_bundle.pin_hex(entry.pin),
        peers: list.map(distribution_plan.peers(plan, node), fn(peer) {
          peer.name
        }),
        executors: node.executors,
        workspaces: node.workspaces,
      )
    }),
  )
}

// --- the output directory ----------------------------------------------------

fn check_empty(output: String, overwrite: Overwrite) -> Result(Nil, String) {
  case overwrite, simplifile.read_directory(output) {
    ReplaceExisting, _ -> Ok(Nil)
    RefuseExisting, Ok([_, ..]) ->
      Error(
        output
        <> " is not empty; choose a new directory, or pass --force to write "
        <> "into it",
      )
    RefuseExisting, _ -> Ok(Nil)
  }
}

// --- the description ---------------------------------------------------------

fn optional(
  key: String,
  value: Option(a),
  encoder: fn(a) -> json.Json,
) -> List(#(String, json.Json)) {
  case value {
    Some(inner) -> [#(key, encoder(inner))]
    None -> []
  }
}

// The decoder yields a `Result` so the marker check can word its refusal; the
// caller flattens it.
fn system_decoder() -> decode.Decoder(Result(System, String)) {
  use marker <- decode.field("format", decode.string)
  use nodes <- decode.field("nodes", decode.list(node_decoder()))
  case marker == system_format {
    True -> decode.success(Ok(System(nodes:)))
    False ->
      decode.success(Error(
        system_file <> " is not a " <> system_format <> " description",
      ))
  }
}

fn node_decoder() -> decode.Decoder(SystemNode) {
  use name <- decode.field("name", decode.string)
  use role_word <- decode.field("role", decode.string)
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
  use pin <- decode.field("pin", decode.string)
  use peers <- decode.field("peers", decode.list(decode.string))
  use used <- decode.field("executors", decode.list(decode.string))
  use workspaces <- decode.field("workspaces", decode.list(workspace_decoder()))
  case distribution_plan.role_from_word(role_word) {
    Ok(role) ->
      decode.success(SystemNode(
        name:,
        role:,
        erlang_node:,
        host:,
        listen_port:,
        bundle_dir:,
        pin:,
        peers:,
        executors: used,
        workspaces:,
      ))
    Error(_) ->
      decode.failure(
        SystemNode(
          name:,
          role: Orchestrator,
          erlang_node:,
          host:,
          listen_port:,
          bundle_dir:,
          pin:,
          peers:,
          executors: used,
          workspaces:,
        ),
        "a role of orchestrator or executor",
      )
  }
}

fn workspace_decoder() -> decode.Decoder(Workspace) {
  use name <- decode.field("name", decode.string)
  use root <- decode.field("root", decode.string)
  decode.success(distribution_plan.Workspace(name:, root:))
}

fn names(values: List(String)) -> String {
  case values {
    [] -> "nobody"
    _ -> string.join(values, ", ")
  }
}

fn detail(node: SystemNode) -> String {
  case node.role, node.executors, node.workspaces {
    Orchestrator, [_, ..], _ ->
      " (uses " <> string.join(node.executors, ", ") <> ")"
    Executor, _, [_, ..] ->
      " (workspaces "
      <> string.join(list.map(node.workspaces, fn(w) { w.name }), ", ")
      <> ")"
    _, _, _ -> ""
  }
}
