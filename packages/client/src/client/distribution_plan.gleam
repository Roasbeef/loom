//// The deployment plan that `loom distribution provision` reads.
////
//// A plan lists every Loom daemon in a deployment and says which orchestrators
//// use which executors. Nothing else about the deployment has to be written
//// down: the peer edges, the `[distribution]` tables and the pins all follow
//// from it, so the plan is the one place an operator edits and the one place
//// a mistake can be refused before a certificate is minted.
////
//// The plan has two spellings, TOML for people and JSON for programs, and
//// both parse into the same `Plan`. Each spelling is first read into a small
//// neutral tree, and one decoder then walks that tree, so the two cannot
//// disagree about a key, a bound or a refusal. Parsing is total and strict: an
//// unknown key, a value of the wrong type and a rule that the whole plan
//// breaks are each a worded `Error` that names the node and the key.
////
//// ## The rules a plan must satisfy
////
//// - A node `name` is an executor-grammar name (`catalogue.is_executor_name`),
////   because it becomes a file name, a directory name and, for an executor,
////   the key of an `[executors.<name>]` table. Names and Erlang node names are
////   each unique.
//// - `erlang_node` passes the grammar `distribution.configure` applies, so the
////   daemon accepts the name the certificate is minted for.
//// - `executors` appears on orchestrators only and names executor nodes.
////   `workspaces` appears on executors only. Workspace names follow
////   `catalogue.is_workspace_name` and roots are absolute.
//// - An executor that no orchestrator uses is an error, and so is an
////   orchestrator with nobody to peer with.
////
//// ## Peer edges
////
//// An orchestrator peers with every executor it uses and with every other
//// orchestrator. An executor peers with every orchestrator that uses it. Every
//// edge is symmetric, because a pin is checked by both ends of a connection.
////
//// ## The directory
////
//// A plan may list, under a top-level `directory`, the nodes that form the
//// session directory's Khepri cluster (protocol-change/079): three to seven
//// of them, orchestrators and executors. Every member peers with every other
//// member, because any member may become the cluster's leader, and each
//// member's bundle carries a `[directory]` table naming all of them.

import client/distribution
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import storage/catalogue
import tom

/// Which kind of daemon a node is.
pub type Role {
  /// Runs sessions and places their workspaces on executors.
  Orchestrator

  /// Serves registered workspaces to the orchestrators that use it.
  Executor
}

/// One registered workspace of an executor.
pub type Workspace {
  Workspace(
    /// The registered name, which satisfies `catalogue.is_workspace_name`.
    name: String,
    /// The absolute directory on the executor's machine.
    root: String,
  )
}

/// One Loom daemon in the deployment.
pub type Node {
  Node(
    /// The bundle name. An executor's name is also its `[executors.<name>]`
    /// key on every orchestrator that uses it.
    name: String,
    /// What the daemon does.
    role: Role,
    /// The full Erlang node name, which becomes the certificate's exact name.
    erlang_node: String,
    /// The DNS name or address other machines reach this node at, which the
    /// certificate also carries for the TLS host name check. It defaults to the
    /// host in `erlang_node`.
    host: String,
    /// The fixed distribution port, when the operator wants a firewall rule.
    listen_port: Option(Int),
    /// The directory the bundle's files will live in on that machine. When it
    /// is absent, `install` uses `<home>/.loom/distribution`.
    bundle_dir: Option(String),
    /// The executor node names an orchestrator uses, in plan order. Empty for
    /// an executor.
    executors: List(String),
    /// The workspaces an executor registers. Empty for an orchestrator.
    workspaces: List(Workspace),
  )
}

/// A validated plan: its nodes in the order the operator wrote them, and the
/// names of the nodes in the session directory's cluster, empty when the plan
/// has no directory.
pub type Plan {
  Plan(nodes: List(Node), directory: List(String))
}

/// How a plan file is spelled.
pub type Format {
  /// `.toml`
  TomlPlan

  /// `.json`
  JsonPlan
}

/// Chooses the spelling from a file name, so the operator never states it.
///
/// ## Examples
///
/// ```gleam
/// assert distribution_plan.format_of("plan.json") == Ok(JsonPlan)
/// assert result.is_error(distribution_plan.format_of("plan.yaml"))
/// ```
pub fn format_of(path: String) -> Result(Format, String) {
  case string.ends_with(path, ".toml"), string.ends_with(path, ".json") {
    True, _ -> Ok(TomlPlan)
    _, True -> Ok(JsonPlan)
    False, False ->
      Error(path <> " must end in .toml or .json so its format is known")
  }
}

/// A plan an operator can start from: a laptop that uses one development box.
/// It parses and validates, so `init` never writes a template that
/// `provision` would refuse.
pub const example =
  "# A Loom deployment plan. `loom distribution provision` reads this file and
# writes one `<node>.loombundle` per node, plus a system.json that describes
# the whole deployment without any private material.

# One [[node]] table per Loom daemon in the deployment.
[[node]]
# The bundle name. Lowercase letters, digits, _ and -, starting with a letter,
# at most 32 characters. Unique in this file.
name = \"laptop\"

# \"orchestrator\" runs sessions. \"executor\" serves workspaces to orchestrators.
role = \"orchestrator\"

# The Erlang node name: name@host, with a dot in the host. It becomes the exact
# name in this node's certificate.
erlang_node = \"loom@laptop.example\"

# Optional. The DNS name or address other machines reach this node at. It
# defaults to the host in erlang_node.
host = \"laptop.example\"

# Optional. A fixed distribution port, for a firewall rule.
listen_port = 4370

# Optional. Where the credential files will live on that machine. The default
# is <home>/.loom/distribution.
bundle_dir = \"/Users/me/.loom/distribution\"

# Orchestrators only: the executor nodes this one uses.
executors = [\"devbox\"]

[[node]]
name = \"devbox\"
role = \"executor\"
erlang_node = \"loom@devbox.example\"
host = \"devbox.example\"
listen_port = 4370
bundle_dir = \"/home/me/.loom/distribution\"

# Executors only: registered workspace name -> absolute directory.
[node.workspaces]
repo = \"/home/me/src/loom\"
"

/// Reads a plan from text in the given spelling and validates it.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(plan) = distribution_plan.parse(distribution_plan.example, TomlPlan)
/// assert list.length(plan.nodes) == 2
/// ```
pub fn parse(text: String, format: Format) -> Result(Plan, String) {
  use tree <- result.try(case format {
    TomlPlan -> toml_tree(text)
    JsonPlan -> json_tree(text)
  })
  use plan <- result.try(plan_of(tree))
  validate(plan)
}

/// Checks the rules that involve more than one node. `parse` calls it, so it
/// is only needed for a plan built by hand.
///
/// ## Examples
///
/// ```gleam
/// assert result.is_error(distribution_plan.validate(Plan(nodes: [], directory: [])))
/// ```
pub fn validate(plan: Plan) -> Result(Plan, String) {
  use Nil <- result.try(case plan.nodes {
    [] -> Error("the plan needs at least one [[node]]")
    _ -> Ok(Nil)
  })
  use Nil <- result.try(list.try_each(plan.nodes, check_node))
  use Nil <- result.try(unique_nodes(plan.nodes))
  use Nil <- result.try(
    list.try_each(plan.nodes, references_executors(plan, _)),
  )
  use Nil <- result.try(list.try_each(plan.nodes, valid_peers(plan, _)))
  use Nil <- result.try(valid_directory(plan))
  Ok(plan)
}

/// Whether a node is a member of the plan's directory.
///
/// ## Examples
///
/// ```gleam
/// distribution_plan.in_directory(plan, laptop) // -> True
/// ```
pub fn in_directory(plan: Plan, node: Node) -> Bool {
  list.contains(plan.directory, node.name)
}

/// The Erlang node names of the directory's members, in plan order, for a
/// node that is one of them; empty for any other node.
///
/// ## Examples
///
/// ```gleam
/// distribution_plan.directory_members(plan, laptop)
/// // -> ["loom@laptop.example", "loom@desk.example", "loom@devbox.example"]
/// ```
pub fn directory_members(plan: Plan, node: Node) -> List(String) {
  case in_directory(plan, node) {
    False -> []
    True ->
      list.filter_map(plan.directory, fn(name) {
        list.find(plan.nodes, fn(other) { other.name == name })
        |> result.map(fn(member) { member.erlang_node })
      })
  }
}

// A directory names plan nodes, once each, and enough of them that losing one
// still leaves a majority.
fn valid_directory(plan: Plan) -> Result(Nil, String) {
  case plan.directory {
    [] -> Ok(Nil)
    names -> {
      let count = list.length(names)
      use Nil <- result.try(case count >= 3 && count <= 7 {
        True -> Ok(Nil)
        False ->
          Error(
            "directory must list between 3 and 7 nodes, not "
            <> int.to_string(count),
          )
      })
      use Nil <- result.try(case list.unique(names) == names {
        True -> Ok(Nil)
        False -> Error("directory lists a node twice")
      })
      list.try_each(names, fn(name) {
        case list.any(plan.nodes, fn(node) { node.name == name }) {
          True -> Ok(Nil)
          False ->
            Error("directory names \"" <> name <> "\", which is not a node")
        }
      })
    }
  }
}

/// The nodes a node trusts as peers, in plan order: for an orchestrator, the
/// executors it uses and the other orchestrators, and for an executor the
/// orchestrators that use it. Two members of the directory always peer.
///
/// ## Examples
///
/// ```gleam
/// distribution_plan.peers(plan, laptop) // -> [devbox]
/// ```
pub fn peers(plan: Plan, node: Node) -> List(Node) {
  list.filter(plan.nodes, fn(other) {
    other.name != node.name
    && {
      case node.role, other.role {
        Orchestrator, Executor -> list.contains(node.executors, other.name)
        Orchestrator, Orchestrator -> True
        Executor, Orchestrator -> list.contains(other.executors, node.name)
        Executor, Executor -> False
      }
      || in_directory(plan, node)
      && in_directory(plan, other)
    }
  })
}

/// The executor nodes an orchestrator uses, as nodes.
///
/// ## Examples
///
/// ```gleam
/// distribution_plan.used_executors(plan, laptop) // -> [devbox]
/// ```
pub fn used_executors(plan: Plan, node: Node) -> List(Node) {
  list.filter(plan.nodes, fn(other) {
    other.role == Executor && list.contains(node.executors, other.name)
  })
}

/// The word a plan and a bundle use for a role.
///
/// ## Examples
///
/// ```gleam
/// assert distribution_plan.role_word(Executor) == "executor"
/// ```
pub fn role_word(role: Role) -> String {
  case role {
    Orchestrator -> "orchestrator"
    Executor -> "executor"
  }
}

/// Reads a role word, or says which words exist.
///
/// ## Examples
///
/// ```gleam
/// assert distribution_plan.role_from_word("executor") == Ok(Executor)
/// ```
pub fn role_from_word(word: String) -> Result(Role, String) {
  case word {
    "orchestrator" -> Ok(Orchestrator)
    "executor" -> Ok(Executor)
    other ->
      Error(
        "role must be \"orchestrator\" or \"executor\", got \"" <> other <> "\"",
      )
  }
}

/// The host part of a node name, which is the default `host`.
///
/// ## Examples
///
/// ```gleam
/// assert distribution_plan.host_of("loom@a.example") == "a.example"
/// ```
pub fn host_of(erlang_node: String) -> String {
  case string.split_once(erlang_node, "@") {
    Ok(#(_, host)) -> host
    Error(Nil) -> erlang_node
  }
}

/// Whether text is an absolute path that holds no control character, so it can
/// be written into a configuration file as one string.
///
/// ## Examples
///
/// ```gleam
/// assert distribution_plan.is_absolute_path("/home/me")
/// ```
pub fn is_absolute_path(path: String) -> Bool {
  string.starts_with(path, "/")
  && string.byte_size(path) <= 4096
  && !has_control_character(path)
}

/// Whether any code point of the text is a control character.
///
/// ## Examples
///
/// ```gleam
/// assert distribution_plan.has_control_character("a\nb")
/// ```
pub fn has_control_character(text: String) -> Bool {
  list.any(string.to_utf_codepoints(text), fn(point) {
    let code = string.utf_codepoint_to_int(point)
    code < 32 || code == 127
  })
}

// --- the neutral tree --------------------------------------------------------

// The two spellings meet here. A value is a string, a whole number, a list or a
// table of named values; the decoder below refuses anything else, so a float, a
// boolean or a date in a plan is a worded error rather than a silent skip.
type Tree {
  Text(String)
  Whole(Int)
  Items(List(Tree))
  Fields(Dict(String, Tree))
}

fn toml_tree(text: String) -> Result(Tree, String) {
  use document <- result.try(
    tom.parse(text)
    |> result.map_error(fn(error) { "invalid plan: " <> string.inspect(error) }),
  )
  from_toml(tom.Table(document))
}

fn from_toml(value: tom.Toml) -> Result(Tree, String) {
  case value {
    tom.String(text) -> Ok(Text(text))
    tom.Int(number) -> Ok(Whole(number))
    tom.Array(values) -> list.try_map(values, from_toml) |> result.map(Items)
    tom.ArrayOfTables(rows) ->
      list.try_map(rows, fn(row) { from_toml(tom.Table(row)) })
      |> result.map(Items)
    tom.Table(fields) | tom.InlineTable(fields) ->
      dict.to_list(fields)
      |> list.try_map(fn(entry) {
        from_toml(entry.1) |> result.map(fn(tree) { #(entry.0, tree) })
      })
      |> result.map(fn(entries) { Fields(dict.from_list(entries)) })
    _ -> Error("invalid plan: only strings, whole numbers, lists and tables")
  }
}

fn json_tree(text: String) -> Result(Tree, String) {
  json.parse(text, tree_decoder())
  |> result.map_error(fn(error) { "invalid plan: " <> string.inspect(error) })
}

fn tree_decoder() -> decode.Decoder(Tree) {
  decode.one_of(decode.string |> decode.map(Text), [
    decode.int |> decode.map(Whole),
    decode.list(decode.recursive(tree_decoder)) |> decode.map(Items),
    decode.dict(decode.string, decode.recursive(tree_decoder))
      |> decode.map(Fields),
  ])
}

// --- the plan decoder --------------------------------------------------------

fn plan_of(tree: Tree) -> Result(Plan, String) {
  use root <- result.try(table(tree, "the plan"))
  use Nil <- result.try(known_keys(root, ["node", "directory"], "the plan"))
  use directory <- result.try(optional_names(root, "directory", "the plan"))
  case dict.get(root, "node") {
    Error(Nil) -> Error("the plan needs at least one [[node]]")
    Ok(Items(rows)) ->
      list.index_map(rows, fn(row, index) { #(row, index) })
      |> list.try_map(fn(entry) { node_of(entry.0, entry.1) })
      |> result.map(fn(nodes) { Plan(nodes:, directory:) })
    Ok(_) -> Error("node must be a list of [[node]] tables")
  }
}

const node_keys = [
  "name", "role", "erlang_node", "host", "listen_port", "bundle_dir",
  "executors", "workspaces",
]

fn node_of(tree: Tree, index: Int) -> Result(Node, String) {
  let place = "node #" <> int.to_string(index + 1)
  use fields <- result.try(table(tree, place))
  use Nil <- result.try(known_keys(fields, node_keys, place))
  use name <- result.try(text_key(fields, "name", place))
  let place = "node " <> name
  use role_word <- result.try(text_key(fields, "role", place))
  use role <- result.try(
    role_from_word(role_word)
    |> result.map_error(fn(reason) { place <> ": " <> reason }),
  )
  use erlang_node <- result.try(text_key(fields, "erlang_node", place))
  use host <- result.try(optional_text(fields, "host", place))
  use listen_port <- result.try(optional_whole(fields, "listen_port", place))
  use bundle_dir <- result.try(optional_text(fields, "bundle_dir", place))
  use executors <- result.try(optional_names(fields, "executors", place))
  use workspaces <- result.try(optional_workspaces(fields, place))
  Ok(Node(
    name:,
    role:,
    erlang_node:,
    host: option.lazy_unwrap(host, fn() { host_of(erlang_node) }),
    listen_port:,
    bundle_dir:,
    executors:,
    workspaces:,
  ))
}

fn table(tree: Tree, place: String) -> Result(Dict(String, Tree), String) {
  case tree {
    Fields(fields) -> Ok(fields)
    Text(_) | Whole(_) | Items(_) -> Error(place <> " must be a table")
  }
}

fn text_key(
  fields: Dict(String, Tree),
  key: String,
  place: String,
) -> Result(String, String) {
  case dict.get(fields, key) {
    Ok(Text(value)) -> Ok(value)
    Ok(_) -> Error(place <> ": " <> key <> " must be a string")
    Error(Nil) -> Error(place <> ": " <> key <> " is required")
  }
}

fn optional_text(
  fields: Dict(String, Tree),
  key: String,
  place: String,
) -> Result(Option(String), String) {
  case dict.get(fields, key) {
    Ok(Text(value)) -> Ok(Some(value))
    Ok(_) -> Error(place <> ": " <> key <> " must be a string")
    Error(Nil) -> Ok(None)
  }
}

fn optional_whole(
  fields: Dict(String, Tree),
  key: String,
  place: String,
) -> Result(Option(Int), String) {
  case dict.get(fields, key) {
    Ok(Whole(value)) -> Ok(Some(value))
    Ok(_) -> Error(place <> ": " <> key <> " must be a whole number")
    Error(Nil) -> Ok(None)
  }
}

fn optional_names(
  fields: Dict(String, Tree),
  key: String,
  place: String,
) -> Result(List(String), String) {
  case dict.get(fields, key) {
    Error(Nil) -> Ok([])
    Ok(Items(values)) ->
      list.try_map(values, fn(value) {
        case value {
          Text(name) -> Ok(name)
          Whole(_) | Items(_) | Fields(_) ->
            Error(place <> ": " <> key <> " must be a list of strings")
        }
      })
    Ok(Text(_)) | Ok(Whole(_)) | Ok(Fields(_)) ->
      Error(place <> ": " <> key <> " must be a list of strings")
  }
}

// Workspaces are a table of name to root. The table is read in name order so a
// plan and a bundle made from it list them the same way every time.
fn optional_workspaces(
  fields: Dict(String, Tree),
  place: String,
) -> Result(List(Workspace), String) {
  case dict.get(fields, "workspaces") {
    Error(Nil) -> Ok([])
    Ok(Fields(entries)) ->
      dict.to_list(entries)
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
      |> list.try_map(fn(entry) {
        case entry.1 {
          Text(root) -> Ok(Workspace(name: entry.0, root:))
          Whole(_) | Items(_) | Fields(_) ->
            Error(
              place
              <> ": workspaces."
              <> entry.0
              <> " must be an absolute directory string",
            )
        }
      })
    Ok(_) -> Error(place <> ": workspaces must be a table of name = \"root\"")
  }
}

fn known_keys(
  fields: Dict(String, Tree),
  allowed: List(String),
  place: String,
) -> Result(Nil, String) {
  let unknown =
    dict.keys(fields)
    |> list.filter(fn(key) { !list.contains(allowed, key) })
    |> list.sort(string.compare)
  case unknown {
    [] -> Ok(Nil)
    [first, ..] ->
      Error(
        "unknown key `"
        <> first
        <> "` in "
        <> place
        <> " (allowed: "
        <> string.join(allowed, ", ")
        <> ")",
      )
  }
}

// --- validation --------------------------------------------------------------

/// The rules of one node on its own: the grammar of every name, the bounds of
/// the port and the directories, and which role may carry which key. A bundle
/// is checked with the same function, so an installed node satisfies exactly
/// what the plan required of it.
///
/// ## Examples
///
/// ```gleam
/// assert distribution_plan.check_node(node) == Ok(Nil)
/// ```
pub fn check_node(node: Node) -> Result(Nil, String) {
  let place = "node " <> node.name
  use Nil <- result.try(case catalogue.is_executor_name(node.name) {
    True -> Ok(Nil)
    False ->
      Error(
        place
        <> ": name must be lowercase letters, numbers, _ and -, starting with "
        <> "a letter, at most 32 characters",
      )
  })
  use Nil <- result.try(distribution.check_node_name(
    place <> ": erlang_node",
    node.erlang_node,
  ))
  use Nil <- result.try(valid_host(place, node.host))
  use Nil <- result.try(case node.listen_port {
    Some(port) if port < 1 || port > 65_535 ->
      Error(
        place
        <> ": listen_port must be between 1 and 65535, got "
        <> int.to_string(port),
      )
    _ -> Ok(Nil)
  })
  use Nil <- result.try(case node.bundle_dir {
    Some(directory) ->
      case is_absolute_path(directory) {
        True -> Ok(Nil)
        False ->
          Error(place <> ": bundle_dir must be an absolute path: " <> directory)
      }
    None -> Ok(Nil)
  })
  valid_role_keys(node, place)
}

fn valid_host(place: String, host: String) -> Result(Nil, String) {
  let allowed =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.:_"
  case
    host != ""
    && string.byte_size(host) <= 253
    && list.all(string.to_graphemes(host), string.contains(allowed, _))
  {
    True -> Ok(Nil)
    False ->
      Error(
        place
        <> ": host must be a DNS name or address of ASCII letters, digits, "
        <> "`-`, `.`, `_` and `:`, got \""
        <> host
        <> "\"",
      )
  }
}

fn valid_role_keys(node: Node, place: String) -> Result(Nil, String) {
  case node.role {
    Orchestrator ->
      case node.workspaces {
        [] -> Ok(Nil)
        _ ->
          Error(
            place
            <> ": workspaces belong on an executor, and this node is an "
            <> "orchestrator",
          )
      }
    Executor -> {
      use Nil <- result.try(case node.executors {
        [] -> Ok(Nil)
        _ ->
          Error(
            place
            <> ": executors belong on an orchestrator, and this node is an "
            <> "executor",
          )
      })
      list.try_each(node.workspaces, fn(workspace) {
        case
          catalogue.is_workspace_name(workspace.name),
          is_absolute_path(workspace.root)
        {
          True, True -> Ok(Nil)
          False, _ ->
            Error(
              place
              <> ": workspace name \""
              <> workspace.name
              <> "\" must be 1 to 128 bytes with no / and no NUL",
            )
          _, False ->
            Error(
              place
              <> ": workspaces."
              <> workspace.name
              <> " must be an absolute path, got \""
              <> workspace.root
              <> "\"",
            )
        }
      })
    }
  }
}

fn unique_nodes(nodes: List(Node)) -> Result(Nil, String) {
  let names = list.map(nodes, fn(node) { node.name })
  let erlang = list.map(nodes, fn(node) { node.erlang_node })
  let listeners =
    list.filter_map(nodes, fn(node) {
      case node.listen_port {
        Some(port) -> Ok(#(host_of(node.erlang_node), port))
        None -> Error(Nil)
      }
    })
  case
    list.unique(names) == names,
    list.unique(erlang) == erlang,
    list.unique(listeners) == listeners
  {
    False, _, _ -> Error("two nodes share a name; each node name is unique")
    _, False, _ ->
      Error("two nodes share an erlang_node; each Erlang node name is unique")
    _, _, False ->
      Error("two nodes on one host share a listen_port; each needs its own")
    True, True, True -> Ok(Nil)
  }
}

// Each name an orchestrator lists must be an executor in this plan, listed
// once. The converse, that every executor is used, is `valid_peers`.
fn references_executors(plan: Plan, node: Node) -> Result(Nil, String) {
  let place = "node " <> node.name
  use Nil <- result.try(case list.unique(node.executors) == node.executors {
    True -> Ok(Nil)
    False -> Error(place <> ": executors lists a node twice")
  })
  list.try_each(node.executors, fn(name) {
    case list.find(plan.nodes, fn(other) { other.name == name }) {
      Ok(Node(role: Executor, ..)) -> Ok(Nil)
      Ok(_) ->
        Error(
          place
          <> ": executors names \""
          <> name
          <> "\", which is not an executor",
        )
      Error(Nil) ->
        Error(
          place <> ": executors names \"" <> name <> "\", which is not a node",
        )
    }
  })
}

fn valid_peers(plan: Plan, node: Node) -> Result(Nil, String) {
  let place = "node " <> node.name
  let count = list.length(peers(plan, node))
  case node.role, count {
    Executor, 0 ->
      Error(
        place
        <> ": no orchestrator uses this executor; list it in an "
        <> "orchestrator's executors or remove it",
      )
    Orchestrator, 0 ->
      Error(
        place
        <> ": this orchestrator has no peers; list an executor it uses or add "
        <> "a second orchestrator",
      )
    _, count if count > 32 ->
      Error(
        place
        <> ": a node can have at most 32 peers, this one has "
        <> int.to_string(count),
      )
    _, _ -> Ok(Nil)
  }
}
