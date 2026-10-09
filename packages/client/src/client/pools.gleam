//// The `[pools.<name>]` tables: named groups of executors a session may be
//// placed on without naming one (protocol-change/078).
////
//// A session created with a `pool` names a workspace that every executor of
//// the pool is expected to register, and the orchestrator picks the executor
//// when the session first opens. This module is the list of pools and the
//// rule that turns a pool into an ordered list of candidates. It opens no
//// connection and reads no file.
////
//// ## What a pool says
////
//// A pool lists its `executors`, in the order they are tried. It may also
//// require a `platform`, an `enforcement` or `toolchains`: the same three
//// keys an `[executors.<name>]` row uses to declare what its machine
//// provides. An executor is a candidate only if the pool lists it and its
//// declaration says what the pool requires. An executor that declared
//// nothing cannot satisfy a requirement, because the orchestrator would be
//// guessing. A pool with no requirement admits every executor it lists.
////
//// Filtering is a function of configuration alone. Whether a machine really
//// provides what it declared is learned at the attach, which compares the
//// executor's census with its declaration (`executors.contradiction`), and
//// capacity is learned the same way, from the executor's refusal. The
//// orchestrator keeps no model of either.
////
//// Like `[executors.<name>]`, the daemon reads the table once, when it
//// starts, and the catalogue parser validates the same table, so a typo is
//// refused wherever the file is read.
////
//// ## Flow
////
//// `from_document` → `row` → `members` → `candidates`
////
//// 1. `from_document` reads the table after the executors it refers to.
//// 2. `row` validates one pool's name and keys, and `members` its list of
////    executors, which must be configured and distinct.
//// 3. `find` resolves the pool a session names, and `candidates` returns the
////    executors that may hold the session, in order.

import client/executors.{type Enforcement, type Executor}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import storage/catalogue
import tom

/// One configured pool.
pub type Pool {
  Pool(
    /// The `[pools.<name>]` key, which satisfies `catalogue.is_pool_name`.
    name: String,
    /// The executors of the pool in the order they are tried. Each is a
    /// configured `[executors.<name>]`.
    executors: List(String),
    /// The platform every candidate must declare, or `None` for any.
    platform: Option(String),
    /// The enforcement every candidate must declare, or `None` for any.
    enforcement: Option(Enforcement),
    /// The toolchains every candidate must declare. Empty requires none.
    toolchains: List(String),
  )
}

/// Reads the pools from configuration text, for callers that hold no parsed
/// document.
///
/// ## Examples
///
/// ```gleam
/// assert pools.parse("") == Ok([])
/// ```
pub fn parse(text: String) -> Result(List(Pool), String) {
  use document <- result.try(
    tom.parse(text)
    |> result.map_error(fn(error) {
      "invalid daemon configuration: " <> string.inspect(error)
    }),
  )
  from_document(document)
}

/// Validates the `[pools.<name>]` tables of a parsed configuration document and
/// returns the pools sorted by name.
///
/// Omission is an empty list. Each pool needs `executors`, a nonempty list of
/// distinct names that are each a configured `[executors.<name>]`, and may
/// carry the three requirements. A name outside the pool grammar, a key the
/// table does not know, a value of the wrong type and a member that is not a
/// configured executor are each refused with the key's full name.
///
/// ## Examples
///
/// ```gleam
/// assert pools.from_document(dict.new()) == Ok([])
/// ```
pub fn from_document(
  document: Dict(String, tom.Toml),
) -> Result(List(Pool), String) {
  case dict.get(document, "pools") {
    Error(Nil) -> Ok([])
    Ok(tom.Table(tables)) -> {
      use configured <- result.try(executors.from_document(document))
      dict.to_list(tables)
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
      |> list.try_map(fn(entry) { row(entry.0, entry.1, configured) })
    }
    Ok(_) -> Error("pools must be a table of [pools.<name>] tables")
  }
}

/// Finds the pool with this name.
///
/// ## Examples
///
/// ```gleam
/// assert pools.find([], "builders") == Error(Nil)
/// ```
pub fn find(configured: List(Pool), name: String) -> Result(Pool, Nil) {
  list.find(configured, fn(pool) { pool.name == name })
}

/// The executors that may hold a session created in this pool, in the order
/// they are tried.
///
/// A member is dropped when the pool requires a platform and it declared a
/// different one or none, when the pool requires an enforcement and it
/// declared a different one or none, or when it lacks a required toolchain.
/// A member that is not in `configured` is dropped as well; the parser cannot
/// leave one, so that only happens when the lists come from different files.
///
/// ## Examples
///
/// ```gleam
/// assert pools.candidates(pool, []) == []
/// ```
pub fn candidates(pool: Pool, configured: List(Executor)) -> List(Executor) {
  list.filter_map(pool.executors, fn(name) {
    case executors.find(configured, name) {
      Ok(executor) ->
        case admits(pool, executor) {
          True -> Ok(executor)
          False -> Error(Nil)
        }
      Error(Nil) -> Error(Nil)
    }
  })
}

/// Whether an executor's declaration says what the pool requires.
///
/// ## Examples
///
/// ```gleam
/// assert pools.admits(pool, executors.plain("box", "exec@10.0.0.2"))
/// ```
pub fn admits(pool: Pool, executor: Executor) -> Bool {
  required(pool.platform, executor.platform)
  && required(pool.enforcement, executor.enforcement)
  && list.all(pool.toolchains, fn(name) {
    list.contains(executor.toolchains, name)
  })
}

// A requirement of `None` admits anything. A requirement that is set admits
// only an executor that declared the same value.
fn required(wanted: Option(value), declared: Option(value)) -> Bool {
  case wanted {
    None -> True
    Some(_) -> wanted == declared
  }
}

/// The pool's requirements in words, for the refusal that says no executor
/// satisfies them. A pool with none is `no requirements`.
///
/// ## Examples
///
/// ```gleam
/// assert pools.requirements(pool) == "platform linux/x86_64"
/// ```
pub fn requirements(pool: Pool) -> String {
  let platform =
    option.map(pool.platform, fn(label) { "platform " <> label })
    |> option.to_result(Nil)
  let enforcement =
    option.map(pool.enforcement, fn(value) {
      "enforcement " <> executors.enforcement_word(value)
    })
    |> option.to_result(Nil)
  let toolchains = case pool.toolchains {
    [] -> Error(Nil)
    names -> Ok("toolchains " <> string.join(names, ", "))
  }
  case result.values([platform, enforcement, toolchains]) {
    [] -> "no requirements"
    stated -> string.join(stated, ", ")
  }
}

fn row(
  name: String,
  value: tom.Toml,
  configured: List(Executor),
) -> Result(Pool, String) {
  use Nil <- result.try(case catalogue.is_pool_name(name) {
    True -> Ok(Nil)
    False ->
      Error(
        "pools."
        <> name
        <> " is not a pool name: lowercase letters, numbers, _ and -, "
        <> "starting with a letter, at most 32 characters",
      )
  })
  case value {
    tom.Table(fields) -> {
      use Nil <- result.try(known_keys(
        dict.keys(fields),
        ["executors", "platform", "enforcement", "toolchains"],
        "[pools." <> name <> "]",
      ))
      let place = "pools." <> name
      use listed <- result.try(members(fields, place, configured))
      use platform <- result.try(executors.platform_of(fields, place))
      use enforcement <- result.try(executors.enforcement_of(fields, place))
      use toolchains <- result.map(executors.toolchains_of(fields, place))
      Pool(name:, executors: listed, platform:, enforcement:, toolchains:)
    }
    _ -> Error("pools." <> name <> " must be a table")
  }
}

// The members are the pool's whole purpose, so an empty list, a name twice and
// a name that is not a configured executor are each refused by the key.
fn members(
  fields: Dict(String, tom.Toml),
  place: String,
  configured: List(Executor),
) -> Result(List(String), String) {
  let key = place <> ".executors"
  case dict.get(fields, "executors") {
    Ok(tom.Array([_, ..] as items)) -> {
      use names <- result.try(
        list.try_map(items, fn(item) {
          case item {
            tom.String(name) -> Ok(name)
            _ -> Error(key <> " must be a list of executor names")
          }
        }),
      )
      use Nil <- result.try(
        case list.length(list.unique(names)) == list.length(names) {
          True -> Ok(Nil)
          False -> Error(key <> " names an executor twice")
        },
      )
      use Nil <- result.map(
        list.try_each(names, fn(name) {
          case executors.find(configured, name) {
            Ok(_) -> Ok(Nil)
            Error(Nil) ->
              Error(
                key
                <> " names "
                <> name
                <> ", which is not an [executors.<name>]",
              )
          }
        }),
      )
      names
    }
    Ok(tom.Array([])) -> Error(key <> " must name at least one executor")
    Ok(_) -> Error(key <> " must be a list of executor names")
    Error(Nil) -> Error(key <> " is required")
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
