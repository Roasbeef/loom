//// The `[executors.<name>]` tables: the machines an orchestrator may place a
//// session's workspace on (protocol-change/078).
////
//// A session created with an `executor` names a workspace that is registered
//// on another machine, so the orchestrator has to know which executors exist
//// before it reserves anything. This module is that list and nothing else. An
//// executor is a name the operator chooses and the peer node that answers to
//// it, and the node has to be one of the `[[distribution.peers]]` the operator
//// already pinned, so a reference here can only point at a machine the daemon
//// trusts as an Erlang peer. It opens no connection and reads no file; the
//// slices that attach a workspace use the node this table names.
////
//// Like `[distribution]` and `[peers]`, the daemon reads the table once, when
//// it starts, and never rereads it: a running daemon's executors are the ones
//// its owner configured before it listened. The catalogue parser validates the
//// same table (`client/catalog`), so a typo is refused wherever the file is
//// read rather than only at startup.
////
//// Absence is the safe answer. With no `[executors]` table every creation that
//// names an executor is refused, and every creation that does not is exactly
//// what it was before this table existed.
////
//// ## Declarations
////
//// An executor may also declare what its operator says the machine provides:
//// its `platform`, whether its sandbox helper `enforcement` is intact, and the
//// `toolchains` it carries. A declaration is a claim made in the
//// orchestrator's file, not something discovered. Two things read it. A
//// `[pools.<name>]` that requires a platform, an enforcement or a toolchain
//// skips the executors whose declaration does not say so (`client/pools`), and
//// the attach compares the census the executor answers with against the
//// declaration (`contradiction`), so a claim that is wrong is refused when the
//// session opens and not believed.
////
//// ## Flow
////
//// `from_document` → `row` → `platform_of` → `enforcement_of` →
//// `toolchains_of`
////
//// 1. `from_document` reads the table and requires the distribution table.
//// 2. `row` validates one entry's name and keys.
//// 3. `platform_of`, `enforcement_of` and `toolchains_of` read the three
////    optional declarations. `client/pools` reads the same three keys as a
////    pool's requirements, so they are public.
//// 4. `find` resolves a name, and `contradiction` compares a declaration with
////    an attach census.

import client/distribution
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import storage/catalogue
import tom

/// Whether an executor's sandbox helper confines what it runs.
pub type Enforcement {
  /// The helper enforces every layer its demand asks for.
  Enforced

  /// The helper is degraded or would not start.
  Degraded
}

/// One configured executor: the name sessions refer to it by, the pinned peer
/// node that serves it, and what its operator declared about the machine.
pub type Executor {
  Executor(
    /// The `[executors.<name>]` key, which satisfies
    /// `catalogue.is_executor_name`.
    name: String,
    /// The peer's full node name, one of the `[[distribution.peers]]` nodes.
    node: String,
    /// The declared platform in the label the prompt carries,
    /// `<os>/<architecture>` such as `linux/x86_64` or `macos/arm64`, or `None`
    /// when the operator declared none.
    platform: Option(String),
    /// The declared sandbox enforcement, or `None` when none was declared.
    enforcement: Option(Enforcement),
    /// The declared toolchains, each a name that `Observed.toolchains` can
    /// contain: `codemode` for the code-mode toolchain, or an `[lsp.<name>]`
    /// key. Empty when none was declared.
    toolchains: List(String),
  )
}

/// What an attach census says about the machine, reduced to the three facts
/// a declaration makes claims about.
pub type Observed {
  Observed(
    /// The platform label, as `system_prompt.platform` words it.
    platform: String,
    /// Whether the helper enforces.
    enforcement: Enforcement,
    /// The toolchains the machine provides: `codemode` when it has the
    /// code-mode toolchain, then the name of each language server it serves.
    toolchains: List(String),
  )
}

/// An executor that declares nothing about its machine.
///
/// ## Examples
///
/// ```gleam
/// assert executors.plain("box", "exec@10.0.0.2").toolchains == []
/// ```
pub fn plain(name: String, node: String) -> Executor {
  Executor(name:, node:, platform: None, enforcement: None, toolchains: [])
}

/// The wording of an enforcement in the configuration file.
///
/// ## Examples
///
/// ```gleam
/// assert executors.enforcement_word(executors.Enforced) == "enforced"
/// ```
pub fn enforcement_word(enforcement: Enforcement) -> String {
  case enforcement {
    Enforced -> "enforced"
    Degraded -> "degraded"
  }
}

/// Reads the executors from configuration text, for callers that hold no
/// parsed document.
///
/// ## Examples
///
/// ```gleam
/// assert executors.parse("") == Ok([])
/// ```
pub fn parse(text: String) -> Result(List(Executor), String) {
  use document <- result.try(
    tom.parse(text)
    |> result.map_error(fn(error) {
      "invalid daemon configuration: " <> string.inspect(error)
    }),
  )
  from_document(document)
}

/// Validates the `[executors.<name>]` tables of a parsed configuration
/// document and returns the executors sorted by name.
///
/// Omission is an empty list. Each table names `node`, which must be a
/// configured distribution peer, and may declare `platform`, `enforcement`
/// and `toolchains`. A document with executors and no `[distribution]` table
/// is refused rather than left to fail when a session is created. A name outside the executor grammar, a key it
/// does not know and a value of the wrong type are each refused with the key's
/// full name, so the owner can find the line.
///
/// ## Examples
///
/// ```gleam
/// assert executors.from_document(dict.new()) == Ok([])
/// ```
pub fn from_document(
  document: Dict(String, tom.Toml),
) -> Result(List(Executor), String) {
  case dict.get(document, "executors") {
    Error(Nil) -> Ok([])
    Ok(tom.Table(tables)) -> {
      use configured <- result.try(
        dict.to_list(tables)
        |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
        |> list.try_map(fn(entry) { row(entry.0, entry.1) }),
      )
      use peers <- result.try(peer_nodes(document))
      use Nil <- result.try(
        list.try_each(configured, fn(executor) {
          case list.contains(peers, executor.node) {
            True -> Ok(Nil)
            False ->
              Error(
                "executors."
                <> executor.name
                <> ".node "
                <> executor.node
                <> " is not a node in [[distribution.peers]]",
              )
          }
        }),
      )
      Ok(configured)
    }
    Ok(_) -> Error("executors must be a table of [executors.<name>] tables")
  }
}

/// Finds the executor with this name.
///
/// ## Examples
///
/// ```gleam
/// assert executors.find([], "build-box") == Error(Nil)
/// ```
pub fn find(configured: List(Executor), name: String) -> Result(Executor, Nil) {
  list.find(configured, fn(executor) { executor.name == name })
}

// The pinned peers an executor may name. An executor with no distribution
// table has no peer to be served by, which is a different mistake from a
// mistyped node, so it is worded as the missing table.
fn peer_nodes(
  document: Dict(String, tom.Toml),
) -> Result(List(String), String) {
  use found <- result.try(distribution.from_document(document))
  case found {
    Some(settings) -> Ok(distribution.peer_nodes(settings))
    None -> Error("executors needs a [distribution] table naming its peers")
  }
}

fn row(name: String, value: tom.Toml) -> Result(Executor, String) {
  use Nil <- result.try(case catalogue.is_executor_name(name) {
    True -> Ok(Nil)
    False ->
      Error(
        "executors."
        <> name
        <> " is not an executor name: lowercase letters, numbers, _ and -, "
        <> "starting with a letter, at most 32 characters",
      )
  })
  case value {
    tom.Table(fields) -> {
      use Nil <- result.try(known_keys(
        dict.keys(fields),
        ["node", "platform", "enforcement", "toolchains"],
        "[executors." <> name <> "]",
      ))
      use node <- result.try(case dict.get(fields, "node") {
        Ok(tom.String(node)) -> Ok(node)
        Ok(_) -> Error("executors." <> name <> ".node must be a string")
        Error(Nil) -> Error("executors." <> name <> ".node is required")
      })
      let place = "executors." <> name
      use platform <- result.try(platform_of(fields, place))
      use enforcement <- result.try(enforcement_of(fields, place))
      use toolchains <- result.map(toolchains_of(fields, place))
      Executor(name:, node:, platform:, enforcement:, toolchains:)
    }
    _ -> Error("executors." <> name <> " must be a table")
  }
}

/// Reads the optional `platform` key of an executor row, or of a pool's
/// requirements. `place` is the table's full name, such as `executors.box`, so
/// a refusal names the key.
///
/// ## Examples
///
/// ```gleam
/// assert executors.platform_of(dict.new(), "executors.box") == Ok(None)
/// ```
pub fn platform_of(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(Option(String), String) {
  case dict.get(fields, "platform") {
    Error(Nil) -> Ok(None)
    Ok(tom.String(label)) ->
      case is_platform(label) {
        True -> Ok(Some(label))
        False -> Error(platform_words(place))
      }
    Ok(_) -> Error(platform_words(place))
  }
}

fn platform_words(place: String) -> String {
  place
  <> ".platform must be a string of the form <os>/<architecture>, such as "
  <> "linux/x86_64 or macos/arm64"
}

// Two nonempty runs of lowercase letters, digits and `_` around one `/`.
fn is_platform(label: String) -> Bool {
  case string.split(label, "/") {
    [os, architecture] -> is_word(os) && is_word(architecture)
    _ -> False
  }
}

fn is_word(text: String) -> Bool {
  text != ""
  && list.all(string.to_graphemes(text), fn(grapheme) {
    string.contains("abcdefghijklmnopqrstuvwxyz0123456789_", grapheme)
  })
}

/// Reads the optional `enforcement` key of an executor row, or of a pool's
/// requirements: `"enforced"` or `"degraded"`.
///
/// ## Examples
///
/// ```gleam
/// assert executors.enforcement_of(dict.new(), "executors.box") == Ok(None)
/// ```
pub fn enforcement_of(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(Option(Enforcement), String) {
  case dict.get(fields, "enforcement") {
    Error(Nil) -> Ok(None)
    Ok(tom.String("enforced")) -> Ok(Some(Enforced))
    Ok(tom.String("degraded")) -> Ok(Some(Degraded))
    Ok(_) -> Error(place <> ".enforcement must be \"enforced\" or \"degraded\"")
  }
}

/// Reads the optional `toolchains` key of an executor row, or of a pool's
/// requirements: a list of distinct lowercase names.
///
/// ## Examples
///
/// ```gleam
/// assert executors.toolchains_of(dict.new(), "executors.box") == Ok([])
/// ```
pub fn toolchains_of(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(List(String), String) {
  let words =
    place
    <> ".toolchains must be a list of distinct lowercase names, such as "
    <> "[\"codemode\"]"
  case dict.get(fields, "toolchains") {
    Error(Nil) -> Ok([])
    Ok(tom.Array(items)) -> {
      use names <- result.try(
        list.try_map(items, fn(item) {
          case item {
            tom.String(name) ->
              case catalogue.is_profile_name(name) {
                True -> Ok(name)
                False -> Error(words)
              }
            _ -> Error(words)
          }
        }),
      )
      case list.length(list.unique(names)) == list.length(names) {
        True -> Ok(names)
        False -> Error(words)
      }
    }
    Ok(_) -> Error(words)
  }
}

/// Compares an executor's declaration with what its attach census reported.
///
/// Only what the operator declared is checked. A platform or an enforcement
/// declared must equal the observed one, and each declared toolchain must be
/// among the observed ones; an executor that provides more than it declared is
/// not contradicted. The refusal names the executor, the declared value and the
/// observed one, so the operator can see which side of the file is wrong.
///
/// ## Examples
///
/// ```gleam
/// let observed = executors.Observed("linux/x86_64", executors.Enforced, [])
/// assert executors.contradiction(box, observed) == Ok(Nil)
/// ```
pub fn contradiction(
  executor: Executor,
  observed: Observed,
) -> Result(Nil, String) {
  let named = "executor " <> executor.name <> " declares "
  use Nil <- result.try(case executor.platform {
    Some(declared) if declared != observed.platform ->
      Error(
        named
        <> "platform "
        <> declared
        <> " but its census reports "
        <> observed.platform,
      )
    _ -> Ok(Nil)
  })
  use Nil <- result.try(case executor.enforcement {
    Some(declared) if declared != observed.enforcement ->
      Error(
        named
        <> "enforcement "
        <> enforcement_word(declared)
        <> " but its census reports "
        <> enforcement_word(observed.enforcement),
      )
    _ -> Ok(Nil)
  })
  case
    list.find(executor.toolchains, fn(declared) {
      !list.contains(observed.toolchains, declared)
    })
  {
    Ok(missing) ->
      Error(
        named
        <> "toolchain "
        <> missing
        <> " but its census reports ["
        <> string.join(observed.toolchains, ", ")
        <> "]",
      )
    Error(Nil) -> Ok(Nil)
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
