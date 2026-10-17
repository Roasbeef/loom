//// What a spawner's operator may approve for a child that runs here
//// (protocol-change/089, building on protocol-change/084).
////
//// A child on this machine can ask for more than its sandbox allows, and the
//// request becomes an escalation record in the delegate session like any other
//// (`docs/architecture/approvals.md`). With no one attached to the delegate
//// session nobody can answer it, so by default the child's call settles on the
//// refusal. A spawner's table may name an `approval_ceiling`, and then the
//// operator on the spawning orchestrator, the laptop, is asked and may approve:
//// but only grants that sit inside the ceiling. A decision that names anything
//// wider is refused and the record stays pending for the owner of this machine.
////
//// The ceiling has one key for each constructor of `broker/policy.Grant`, so an
//// operator reads off what it admits by reading the table.
////
//// | Key | Admits |
//// | --- | --- |
//// | `writable_roots` | a writable root equal to, or under, a listed path |
//// | `readable_roots` | a readable root equal to, or under, a listed path; a writable root admits reading as well |
//// | `network` | `"any"` for unrestricted network, or a list of `host:port` entries, each of which a proxy grant's allowlist may use |
//// | `env` | an environment variable by name |
//// | `limits` | a limit up to the listed maximum; a grant of `0` (unlimited) is never admitted |
//// | `scratch` | `"tmpfs"`, or a scratch path equal to, or under, a listed path |
////
//// A key that is absent admits nothing of its kind. A table that is absent means
//// the spawner has no ceiling at all, which is how a spawner behaved before the
//// table existed: the delegate session counts as unattended, and no decision
//// from the spawning orchestrator is accepted.
////
//// Like the rest of the spawn policy, the ceiling binds an honest spawner. A
//// spawner is a pinned distribution peer and is trusted as one, so the ceiling is
//// there to stop a mistaken or over-eager operator from granting more than the
//// owner of this machine intended, and is not a boundary against a compromised
//// peer.
////
//// ## Flow
////
//// `from_table` → `admits` → `admitted` → `admits_all`
////
//// 1. `from_table` reads the `[spawners.<name>.approval_ceiling]` table and
////    refuses anything it does not understand, naming the key.
//// 2. `admits` judges one grant. The match names every constructor of `Grant`, so
////    a new kind of grant is a compile error here until someone decides how a
////    ceiling bounds it.
//// 3. `admitted` keeps the grants of a list that the ceiling admits, and
////    `admits_all` says whether that is all of them.

import broker/policy.{type Grant, type LimitField}
import client/workspaces
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import tom

/// What the ceiling allows of the network.
pub type NetworkCeiling {
  /// No proxy allowlist and no unrestricted network. This is what an absent
  /// `network` key means.
  NoNetwork

  /// Any proxy grant whose every allowlist entry is listed here.
  Hosts(
    /// The `host:port` entries, as written in the table.
    allow: List(String),
  )

  /// Any network grant, including unrestricted network.
  AnyNetwork
}

/// A scratch directory the ceiling allows.
pub type ScratchCeiling {
  /// The most restrictive choice, a fresh tmpfs.
  TmpfsScratch

  /// A bind-mounted host path equal to, or under, this one.
  ScratchUnder(
    /// An absolute path.
    path: String,
  )
}

/// The grants the operator of a spawning orchestrator may approve.
pub type Ceiling {
  Ceiling(
    /// Writable roots may sit at or under these paths.
    writable_roots: List(String),
    /// Readable roots may sit at or under these paths.
    readable_roots: List(String),
    /// What the network grant may be.
    network: NetworkCeiling,
    /// Environment variable names that may be added to the allowlist.
    env: List(String),
    /// The most a limit may be raised to, for each limit the ceiling names.
    limits: List(#(LimitField, Int)),
    /// The scratch choices that may be granted.
    scratch: List(ScratchCeiling),
  )
}

/// The ceiling that admits nothing. A spawner whose table is present but empty
/// asks the operator and can only be told no.
///
/// ## Examples
///
/// ```gleam
/// assert !approval_ceiling.admits(approval_ceiling.nothing(), policy.GrantEnv("HOME"))
/// ```
pub fn nothing() -> Ceiling {
  Ceiling(
    writable_roots: [],
    readable_roots: [],
    network: NoNetwork,
    env: [],
    limits: [],
    scratch: [],
  )
}

/// Whether the ceiling admits one grant.
///
/// A grant that names a path is judged on a segment boundary, so a root of
/// `/srv/work` admits `/srv/work/a` and not `/srv/workshop`. A path with a `..`
/// segment is never admitted: the ceiling compares text, and a `..` would let the
/// text say one place while the path is another. Reading is implied by writing,
/// so a readable root is also admitted under a writable root.
///
/// ## Examples
///
/// ```gleam
/// let ceiling = approval_ceiling.Ceiling(..approval_ceiling.nothing(), writable_roots: ["/srv/work"])
/// assert approval_ceiling.admits(ceiling, policy.GrantWritableRoot("/srv/work/a"))
/// assert !approval_ceiling.admits(ceiling, policy.GrantWritableRoot("/srv/workshop"))
/// ```
pub fn admits(ceiling: Ceiling, grant: Grant) -> Bool {
  case grant {
    policy.GrantWritableRoot(path:) -> under_any(path, ceiling.writable_roots)
    policy.GrantReadableRoot(path:) ->
      under_any(path, ceiling.readable_roots)
      || under_any(path, ceiling.writable_roots)
    policy.GrantNetwork(network:) -> admits_network(ceiling.network, network)
    policy.GrantEnv(name:) -> list.contains(ceiling.env, name)
    policy.GrantLimit(field:, value:) ->
      case list.key_find(ceiling.limits, field) {
        Ok(most) -> value > 0 && value <= most
        Error(Nil) -> False
      }
    policy.GrantScratch(scratch:) -> admits_scratch(ceiling.scratch, scratch)
  }
}

/// The grants of a list that the ceiling admits, in their order.
///
/// ## Examples
///
/// ```gleam
/// assert approval_ceiling.admitted(approval_ceiling.nothing(), [policy.GrantEnv("HOME")]) == []
/// ```
pub fn admitted(ceiling: Ceiling, grants: List(Grant)) -> List(Grant) {
  list.filter(grants, admits(ceiling, _))
}

/// Whether the ceiling admits every grant of a list. The empty list is admitted,
/// and the caller decides whether an approval of nothing means anything.
///
/// ## Examples
///
/// ```gleam
/// assert approval_ceiling.admits_all(approval_ceiling.nothing(), [])
/// ```
pub fn admits_all(ceiling: Ceiling, grants: List(Grant)) -> Bool {
  list.all(grants, admits(ceiling, _))
}

fn admits_network(
  allowed: NetworkCeiling,
  wanted: policy.NetworkPolicy,
) -> Bool {
  case wanted, allowed {
    // No network widens nothing, so there is nothing for a ceiling to bound.
    policy.NetworkOff, _ -> True
    _, AnyNetwork -> True
    policy.NetworkFull, NoNetwork | policy.NetworkFull, Hosts(..) -> False
    policy.NetworkProxy(allow:, ..), Hosts(allow: listed) ->
      list.all(allow, list.contains(listed, _))
    policy.NetworkProxy(..), NoNetwork -> False
  }
}

fn admits_scratch(
  allowed: List(ScratchCeiling),
  wanted: policy.Scratch,
) -> Bool {
  case wanted {
    policy.ScratchTmpfs -> list.contains(allowed, TmpfsScratch)
    policy.ScratchPath(path:) ->
      list.any(allowed, fn(entry) {
        case entry {
          TmpfsScratch -> False
          ScratchUnder(path: root) -> under(path, root)
        }
      })
  }
}

fn under_any(path: String, roots: List(String)) -> Bool {
  list.any(roots, under(path, _))
}

// Whether a path is the root or sits beneath it, on a segment boundary. A path
// with a `..` segment is refused outright, because the comparison is of text.
fn under(path: String, root: String) -> Bool {
  case list.contains(string.split(path, "/"), "..") {
    True -> False
    False ->
      case root {
        "/" -> string.starts_with(path, "/")
        _ -> path == root || string.starts_with(path, root <> "/")
      }
  }
}

/// Reads the `[spawners.<name>.approval_ceiling]` table. `place` is the table's
/// full name, for the refusals.
///
/// Every key is optional and a key that is absent admits nothing of its kind.
/// The decoder refuses a key it does not know, a path that is not absolute or
/// that holds a `..` segment, a network entry that is not `host:port`, a limit
/// that is not a positive integer or that names no limit, and a value of the
/// wrong type, each with the key's full name.
///
/// ## Examples
///
/// ```gleam
/// assert approval_ceiling.from_table(dict.new(), "spawners.laptop.approval_ceiling")
///   == Ok(approval_ceiling.nothing())
/// ```
pub fn from_table(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(Ceiling, String) {
  use Nil <- result.try(known_keys(
    dict.keys(fields),
    [
      "writable_roots",
      "readable_roots",
      "network",
      "env",
      "limits",
      "scratch",
    ],
    place,
  ))
  use writable_roots <- result.try(paths_of(fields, place, "writable_roots"))
  use readable_roots <- result.try(paths_of(fields, place, "readable_roots"))
  use network <- result.try(network_of(fields, place))
  use env <- result.try(names_of(fields, place, "env"))
  use limits <- result.try(limits_of(fields, place))
  use scratch <- result.try(scratch_of(fields, place))
  Ok(Ceiling(
    writable_roots:,
    readable_roots:,
    network:,
    env:,
    limits:,
    scratch:,
  ))
}

// A list of absolute paths, each normalized to have no trailing slash. A path
// is a prefix on a segment boundary, so `/srv/work/` and `/srv/work` are one
// root; `//` and `.` segments would make two spellings of one place and are
// refused with the `..` ones.
fn paths_of(
  fields: Dict(String, tom.Toml),
  place: String,
  key: String,
) -> Result(List(String), String) {
  use items <- result.try(strings_of(fields, place, key))
  list.try_map(items, fn(path) { root_of(path, place <> "." <> key) })
}

fn root_of(path: String, key: String) -> Result(String, String) {
  use Nil <- result.try(
    workspaces.absolute(path) |> result.map_error(fn(why) { key <> " " <> why }),
  )
  let segments = string.split(path, "/")
  case list.contains(segments, "."), string.contains(path, "//") {
    True, _ | _, True ->
      Error(key <> " must not contain a . segment or an empty one")
    False, False ->
      case path != "/" && string.ends_with(path, "/") {
        True -> Ok(string.drop_end(path, 1))
        False -> Ok(path)
      }
  }
}

fn names_of(
  fields: Dict(String, tom.Toml),
  place: String,
  key: String,
) -> Result(List(String), String) {
  use items <- result.try(strings_of(fields, place, key))
  case list.find(items, fn(name) { name == "" }) {
    Ok(_) -> Error(place <> "." <> key <> " must not hold an empty name")
    Error(Nil) -> Ok(items)
  }
}

fn strings_of(
  fields: Dict(String, tom.Toml),
  place: String,
  key: String,
) -> Result(List(String), String) {
  let words = place <> "." <> key <> " must be an array of strings"
  case dict.get(fields, key) {
    Error(Nil) -> Ok([])
    Ok(tom.Array(items)) ->
      list.try_map(items, fn(item) {
        case item {
          tom.String(text) -> Ok(text)
          _ -> Error(words)
        }
      })
    Ok(_) -> Error(words)
  }
}

// `"any"`, or an array of `host:port` entries. The entry is the allowlist text a
// proxy grant carries, so a ceiling can only admit what a grant can say.
fn network_of(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(NetworkCeiling, String) {
  let key = place <> ".network"
  case dict.get(fields, "network") {
    Error(Nil) -> Ok(NoNetwork)
    Ok(tom.String("any")) -> Ok(AnyNetwork)
    Ok(tom.String(_)) ->
      Error(key <> " must be \"any\" or an array of host:port entries")
    Ok(tom.Array(_)) -> {
      use entries <- result.try(strings_of(fields, place, "network"))
      use Nil <- result.map(list.try_each(entries, host_port(_, key)))
      Hosts(allow: entries)
    }
    Ok(_) -> Error(key <> " must be \"any\" or an array of host:port entries")
  }
}

fn host_port(entry: String, key: String) -> Result(Nil, String) {
  let words = key <> " entry " <> entry <> " is not host:port"
  case string.split(entry, ":") {
    [host, port] ->
      case host != "", int.parse(port) {
        True, Ok(number) if number >= 1 && number <= 65_535 -> Ok(Nil)
        _, _ -> Error(words)
      }
    _ -> Error(words)
  }
}

// The limit maxima: a table of the six limit names to positive integers. It may
// be written as `[spawners.<name>.approval_ceiling.limits]` or inline.
fn limits_of(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(List(#(LimitField, Int)), String) {
  let key = place <> ".limits"
  case dict.get(fields, "limits") {
    Error(Nil) -> Ok([])
    Ok(tom.Table(table)) | Ok(tom.InlineTable(table)) -> {
      use Nil <- result.try(known_keys(
        dict.keys(table),
        list.map(limit_fields(), policy.limit_field_name),
        key,
      ))
      list.try_map(dict.to_list(table), fn(entry) {
        let #(name, value) = entry
        use field <- result.try(
          list.find(limit_fields(), fn(field) {
            policy.limit_field_name(field) == name
          })
          |> result.replace_error(key <> "." <> name <> " is not a limit"),
        )
        case value {
          tom.Int(most) if most >= 1 -> Ok(#(field, most))
          tom.Int(_) -> Error(key <> "." <> name <> " must be positive")
          _ -> Error(key <> "." <> name <> " must be an integer")
        }
      })
      |> result.map(
        list.sort(_, fn(a, b) {
          string.compare(
            policy.limit_field_name(a.0),
            policy.limit_field_name(b.0),
          )
        }),
      )
    }
    Ok(_) -> Error(key <> " must be a table of limit names to maxima")
  }
}

fn limit_fields() -> List(LimitField) {
  [
    policy.CpuSeconds,
    policy.WallSeconds,
    policy.MemBytes,
    policy.Pids,
    policy.FsizeBytes,
    policy.OutputBytes,
  ]
}

// `"tmpfs"` or an absolute path, each entry one scratch choice.
fn scratch_of(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(List(ScratchCeiling), String) {
  use items <- result.try(strings_of(fields, place, "scratch"))
  list.try_map(items, fn(item) {
    case item {
      "tmpfs" -> Ok(TmpfsScratch)
      path ->
        root_of(path, place <> ".scratch entry")
        |> result.map(fn(root) { ScratchUnder(path: root) })
    }
  })
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
