//// The `[spawners.<name>]` tables: which other orchestrators may start
//// subagents on this one, and on what terms (protocol-change/084, slice S1).
////
//// A model on one orchestrator, a laptop say, can ask for a child that runs on
//// another, the box. The box decides whether to honour that, and this table is
//// where it says so. Each entry names the spawning orchestrator by its pinned
//// distribution node, the one place every delegate session of that spawner is
//// put (an executor and a registered workspace, a pool and a workspace, or a
//// directory on this machine), the profile that seeds those sessions, the
//// ceiling on the tools their children may hold, and the limits on how deep,
//// how wide and how long a child may run. The table is the only authority: the
//// spawning side has no switch of its own that could disagree with it.
////
//// The limits bound an honest peer and a model that spawns too much. They are
//// not a security boundary. A pinned distribution peer is fully trusted by
//// `client/distribution`, so a compromised spawner does not have to send the
//// messages these limits judge, and the design note says so in section 5.
////
//// The table is separate from `[orchestrators.<name>]` on purpose. An
//// orchestrator row says whom this daemon asks about sessions and may move
//// sessions to, and under the Khepri directory (protocol-change/083) every such
//// node of a member daemon must itself be a member of the store. A roaming
//// laptop should be able to spawn here without holding a replica, so a spawner
//// needs only to be a pinned peer.
////
//// Like `[executors.<name>]`, the daemon reads the table once, when it starts,
//// and never rereads it, and the catalogue parser validates the same table
//// (`client/catalog`) so a typo is refused wherever the file is read. Absence
//// is the safe answer: a daemon with no `[spawners]` table accepts no spawn.
//// The table opens no connection and reads no file.
////
//// ## Windows
////
//// Three durations constrain each other, and the decoder checks the pairs
//// because each check protects a different thing. `default_within_s` is what a
//// spawn gets when it names no deadline, so it cannot exceed the cap
//// `max_within_s`. `retain_s` is how long a delegate session with no message
//// from its spawner is kept before the sweep deletes it. A child stops at
//// its deadline at the latest, so with `retain_s` at or above `max_within_s` a
//// session past retention holds no child that could still be running.
////
//// `idle_close_s` is separate and bounds nothing else: a resident delegate
//// session never hibernates and so holds an executor scope, and the hourly
//// sweep closes one whose children have all ended and whose spawner has been
//// silent that long. Closing is not deleting, so it needs no relation to the
//// other three.
////
//// ## Metering
////
//// Three optional keys bound what a spawner's children may spend on this
//// machine. `token_budget_per_day` bounds the tokens (input plus output) used by
//// every child of the spawner over a rolling day, `max_per_day` bounds the
//// spawns admitted over the same day, and `child_token_budget` bounds one
//// child's tokens. A key that is absent bounds nothing, which is how a spawner
//// behaved before the keys existed. `metered` says whether any of the three is
//// set, and the daemon records spend only for a spawner that is metered.
//// Like the other limits they bound an honest spawner and a model that spawns
//// too much, and are not a boundary against a compromised peer.
////
//// ## Transcripts
////
//// `transcript` says whether the spawning orchestrator may read its children's
//// transcripts here (protocol-change/090). `"hidden"`, the default, keeps them
//// on this machine: a `ChildHistory` is refused with `TranscriptHidden`, and
//// the spawner sees a child's result, notes and glances and nothing of its
//// working. `"visible"` lets it read one bounded page at a time of a child's
//// branch. The box owner decides, because the transcript is recorded here and
//// may hold what this machine's tools returned.
////
//// ## Flow
////
//// `from_document` → `row` → `placement_of` → `tools_of` → `windows` →
//// `transcript_of`
////
//// 1. `from_document` reads the table and requires the distribution table.
//// 2. `row` validates one entry: its name, its keys, its node and its profile.
//// 3. `placement_of` requires exactly one placement and resolves it against the
////    executors and pools this file configures.
//// 4. `tools_of` reads the ceiling, or builds the default one.
//// 5. `windows` checks the three durations against each other, and
////    `budget_of` reads one of the three optional metering keys.
//// 6. `transcript_of` reads whether children's transcripts may be read from
////    the spawning orchestrator.
//// 7. `standing` tells the sweep what a session's spawner allows, or that it
////    was removed. `find` and `by_node` resolve a configured spawner by name or by the node
////    a message came from.

import client/approval_ceiling.{type Ceiling}
import client/distribution
import client/executors.{type Executor}
import client/ledger_reference
import client/pools.{type Pool}
import client/tool_placement
import client/workspaces
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import storage/catalogue
import tom

/// The most delegate sessions one spawner may hold. An executor admits sixteen
/// scopes that are not cleanly closed, and each delegate session on an executor
/// holds one, so a larger number could never be honoured.
pub const sessions_limit = 16

/// `max_depth` when the table names none: children may not spawn.
pub const default_max_depth = 1

/// `max_sessions` when the table names none.
pub const default_max_sessions = 4

/// `max_within_s` when the table names none: four hours.
pub const default_max_within_s = 14_400

/// `default_within_s` when the table names none: thirty minutes.
pub const default_default_within_s = 1800

/// `retain_s` when the table names none: seven days.
pub const default_retain_s = 604_800

/// `idle_close_s` when the table names none: one hour.
pub const default_idle_close_s = 3600

/// Whether the spawning orchestrator may read its children's transcripts here.
pub type Transcript {
  /// It may not. A `ChildHistory` is refused with `TranscriptHidden`. This is
  /// the default.
  Hidden

  /// It may read one bounded page of a child's branch at a time.
  Visible
}

/// Where every delegate session of one spawner is put.
pub type Placement {
  /// On a configured executor, in a workspace registered on that machine.
  OnExecutor(
    /// The `[executors.<name>]` key.
    executor: String,
    /// The workspace name registered on that executor.
    workspace: String,
  )

  /// On any executor of a configured pool, in a workspace every member is
  /// expected to register.
  InPool(
    /// The `[pools.<name>]` key.
    pool: String,
    /// The workspace name registered on the pool's executors.
    workspace: String,
  )

  /// In a directory on this machine, with no executor.
  InDirectory(
    /// An absolute path with no `..` segment.
    path: String,
  )
}

/// One configured spawner.
pub type Spawner {
  Spawner(
    /// The `[spawners.<name>]` key, which satisfies
    /// `catalogue.is_profile_name`. It names the spawner in a delegate
    /// session's record.
    name: String,
    /// The spawning orchestrator's full node name. In static mode it is one of
    /// the `[[distribution.peers]]` nodes; in ledger mode the daemon compares
    /// it with the ledger at start.
    node: String,
    /// Where each delegate session of this spawner is put.
    placement: Placement,
    /// The `[profiles.<name>]` key that seeds every delegate session.
    profile: String,
    /// The tool ceiling. A child's tools are narrowed by the request and by the
    /// parent's own set, and never widened past this list.
    tools: List(String),
    /// The deepest child allowed. One means children may not spawn.
    max_depth: Int,
    /// The delegate sessions this spawner may hold, at most `sessions_limit`.
    max_sessions: Int,
    /// The longest deadline a spawn may ask for, in seconds.
    max_within_s: Int,
    /// The deadline a spawn gets when it names none, in seconds. At most
    /// `max_within_s`.
    default_within_s: Int,
    /// How long a delegate session with no message from its spawner is kept, in
    /// seconds. At least `max_within_s`.
    retain_s: Int,
    /// How long a resident delegate session with no live child and no message
    /// from its spawner is kept open before the hourly sweep closes it, in
    /// seconds. Closing frees the executor scope the session holds and deletes
    /// nothing, so the next spawn or join reopens it.
    idle_close_s: Int,
    /// The tokens, input plus output, that every child of this spawner may use
    /// over a rolling day. `None` bounds nothing. A spawn is refused once the
    /// day's total has reached it, and a running child is not stopped by it:
    /// the budget judges admission.
    token_budget_per_day: Option(Int),
    /// The tokens one child may use. `None` bounds nothing. A child that has
    /// reached it is stopped after the request that took it there, so it
    /// overshoots by at most one request.
    child_token_budget: Option(Int),
    /// The spawns admitted for this spawner over a rolling day. `None` bounds
    /// nothing.
    max_per_day: Option(Int),
    /// What the spawning orchestrator's operator may approve for a child that
    /// asks for more than its sandbox allows (protocol-change/089). `None` means
    /// the table has no ceiling: the delegate session counts as unattended and
    /// no decision from the spawner is accepted. `Some` makes a refused call park
    /// while the spawner's node is connected, and bounds what a decision may
    /// grant.
    approval_ceiling: Option(Ceiling),
    /// Whether the spawner may read its children's transcripts here.
    transcript: Transcript,
  )
}

// What the rows of one document are checked against, read once so that each row
// does not reread the document.
type Known {
  Known(
    peers: ledger_reference.Peers,
    executors: List(Executor),
    pools: List(Pool),
    profiles: List(String),
  )
}

/// The tool ceiling a spawner gets when its table names none: every built-in
/// tool except the ones that reach state beyond the delegate session. Those are
/// `agent_spawn`, `remember`, the `peer_*` tools and the `schedule_*` tools.
/// There is no built-in tool that installs a skill, so there is nothing more to
/// withhold on that account.
///
/// ## Examples
///
/// ```gleam
/// assert !list.contains(spawners.default_tools(), "agent_spawn")
/// assert list.contains(spawners.default_tools(), "bash")
/// ```
pub fn default_tools() -> List(String) {
  list.append(tool_placement.workspace_names, tool_placement.owner_names())
  |> list.filter(fn(name) { !reaches_beyond_the_session(name) })
}

/// Reads the spawners from configuration text, for callers that hold no parsed
/// document.
///
/// ## Examples
///
/// ```gleam
/// assert spawners.parse("") == Ok([])
/// ```
pub fn parse(text: String) -> Result(List(Spawner), String) {
  use document <- result.try(
    tom.parse(text)
    |> result.map_error(fn(error) {
      "invalid daemon configuration: " <> string.inspect(error)
    }),
  )
  from_document(document)
}

/// Validates the `[spawners.<name>]` tables of a parsed configuration document
/// and returns the spawners sorted by name.
///
/// Omission is an empty list. Each table names `node`, which must be a
/// configured distribution peer that no other spawner uses, exactly one
/// placement, and a `profile` that is a configured `[profiles.<name>]`. The
/// remaining keys are optional and have the defaults above. A document with
/// spawners and no `[distribution]` table is refused rather than left to fail
/// when the first spawn arrives. A name outside the grammar, a key the table
/// does not know, a value of the wrong type, a reference that does not resolve
/// and a limit outside its range are each refused with the key's full name, so
/// the owner can find the line.
///
/// ## Examples
///
/// ```gleam
/// assert spawners.from_document(dict.new()) == Ok([])
/// ```
pub fn from_document(
  document: Dict(String, tom.Toml),
) -> Result(List(Spawner), String) {
  case dict.get(document, "spawners") {
    Error(Nil) -> Ok([])
    Ok(tom.Table(tables)) -> {
      use peers <- result.try(peer_nodes(document))
      use configured_executors <- result.try(executors.from_document(document))
      use configured_pools <- result.try(pools.from_document(document))
      let known =
        Known(
          peers:,
          executors: configured_executors,
          pools: configured_pools,
          profiles: profile_names(document),
        )
      use configured <- result.try(
        dict.to_list(tables)
        |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
        |> list.try_map(fn(entry) { row(entry.0, entry.1, known) }),
      )
      use Nil <- result.map(distinct_nodes(configured))
      configured
    }
    Ok(_) -> Error("spawners must be a table of [spawners.<name>] tables")
  }
}

/// Finds the spawner with this name.
///
/// ## Examples
///
/// ```gleam
/// assert spawners.find([], "laptop") == Error(Nil)
/// ```
pub fn find(configured: List(Spawner), name: String) -> Result(Spawner, Nil) {
  list.find(configured, fn(spawner) { spawner.name == name })
}

/// What the retention sweep needs to know about the spawner of one delegate
/// session.
pub type Standing {
  /// The spawner is still configured, with its two windows.
  Configured(
    /// How long a session with no message from the spawner is kept before it
    /// is deleted, in milliseconds.
    retain_ms: Int,
    /// How long a resident session with no live child and no message is kept
    /// open before it is closed, in milliseconds.
    idle_close_ms: Int,
  )

  /// The table has been removed since the session was made. Nothing can send
  /// the session a message again, so it is deleted whatever its age.
  Removed
}

/// The standing of a delegate session's spawner, for the retention sweep
/// (protocol-change/084).
///
/// ## Examples
///
/// ```gleam
/// assert spawners.standing([], "gone") == spawners.Removed
/// ```
pub fn standing(configured: List(Spawner), name: String) -> Standing {
  find(configured, name)
  |> result.map(fn(spawner) {
    Configured(
      retain_ms: spawner.retain_s * 1000,
      idle_close_ms: spawner.idle_close_s * 1000,
    )
  })
  |> result.unwrap(Removed)
}

/// Finds the spawner that a node is the spawning orchestrator of. This is how
/// the orchestrator port turns the node a message came from into the policy
/// that judges it.
///
/// ## Examples
///
/// ```gleam
/// assert spawners.by_node([], "laptop@100.64.0.5") == Error(Nil)
/// ```
pub fn by_node(
  configured: List(Spawner),
  node: String,
) -> Result(Spawner, Nil) {
  list.find(configured, fn(spawner) { spawner.node == node })
}

/// Whether the spawner sets any of the three metering keys. A spawner that sets
/// none is unmetered: the daemon counts nothing for it and refuses nothing on
/// its account.
///
/// ## Examples
///
/// ```gleam
/// assert !spawners.metered(unbounded)
/// assert spawners.metered(Spawner(..unbounded, max_per_day: Some(20)))
/// ```
pub fn metered(spawner: Spawner) -> Bool {
  option.is_some(spawner.token_budget_per_day)
  || option.is_some(spawner.child_token_budget)
  || option.is_some(spawner.max_per_day)
}

// The peers a spawner may name. A spawner with no distribution table has no
// peer to be messaged by, which is a different mistake from a mistyped node, so
// it is worded as the missing table.
fn peer_nodes(
  document: Dict(String, tom.Toml),
) -> Result(ledger_reference.Peers, String) {
  use found <- result.try(distribution.from_document(document))
  case found {
    Some(settings) -> Ok(ledger_reference.peers(settings))
    None -> Error("spawners needs a [distribution] table naming its peers")
  }
}

// The keys of `[profiles]`. The catalogue parser owns the profiles' contents;
// this module only needs to know which names exist. A malformed `profiles`
// value is that parser's refusal to make, and here it names no profile.
fn profile_names(document: Dict(String, tom.Toml)) -> List(String) {
  case dict.get(document, "profiles") {
    Ok(tom.Table(entries)) | Ok(tom.InlineTable(entries)) -> dict.keys(entries)
    Ok(_) | Error(Nil) -> []
  }
}

// Two names for one node would let a message be judged by whichever policy
// sorts first, so the file cannot say it. Names are sorted, so the second of a
// pair is the one reported.
fn distinct_nodes(configured: List(Spawner)) -> Result(Nil, String) {
  case configured {
    [] -> Ok(Nil)
    [first, ..rest] ->
      case by_node(rest, first.node) {
        Ok(other) ->
          Error(
            "spawners."
            <> other.name
            <> ".node "
            <> other.node
            <> " is already the node of spawners."
            <> first.name,
          )
        Error(Nil) -> distinct_nodes(rest)
      }
  }
}

fn row(name: String, value: tom.Toml, known: Known) -> Result(Spawner, String) {
  let place = "spawners." <> name
  use Nil <- result.try(case catalogue.is_profile_name(name) {
    True -> Ok(Nil)
    False ->
      Error(
        place
        <> " is not a spawner name: lowercase letters, numbers, _ and -, "
        <> "starting with a letter, at most 32 characters",
      )
  })
  case value {
    tom.Table(fields) -> {
      use Nil <- result.try(known_keys(
        dict.keys(fields),
        [
          "node", "executor", "pool", "directory", "workspace", "profile",
          "tools", "max_depth", "max_sessions", "max_within_s",
          "default_within_s", "retain_s", "idle_close_s", "token_budget_per_day",
          "child_token_budget", "max_per_day", "approval_ceiling", "transcript",
        ],
        "[spawners." <> name <> "]",
      ))
      use node <- result.try(node_of(fields, place, known.peers))
      use placement <- result.try(placement_of(fields, place, known))
      use profile <- result.try(profile_of(fields, place, known.profiles))
      use tools <- result.try(tools_of(fields, place))

      // The limits are what the remote enforces on an honest spawner: how deep
      // a child may nest, how many delegate sessions the spawner holds, and
      // the three durations (`windows` checks them against each other). They
      // bound a model that spawns too much or for too long, and nothing here
      // is a boundary against a compromised peer.
      use max_depth <- result.try(count_of(
        fields,
        place,
        "max_depth",
        default_max_depth,
      ))
      use max_sessions <- result.try(sessions_of(fields, place))
      use max_within_s <- result.try(count_of(
        fields,
        place,
        "max_within_s",
        default_max_within_s,
      ))
      use default_within_s <- result.try(count_of(
        fields,
        place,
        "default_within_s",
        default_default_within_s,
      ))
      use retain_s <- result.try(count_of(
        fields,
        place,
        "retain_s",
        default_retain_s,
      ))
      use idle_close_s <- result.try(count_of(
        fields,
        place,
        "idle_close_s",
        default_idle_close_s,
      ))
      use token_budget_per_day <- result.try(budget_of(
        fields,
        place,
        "token_budget_per_day",
      ))
      use child_token_budget <- result.try(budget_of(
        fields,
        place,
        "child_token_budget",
      ))
      use max_per_day <- result.try(budget_of(fields, place, "max_per_day"))
      use approval_ceiling <- result.try(ceiling_of(fields, place))
      use transcript <- result.try(transcript_of(fields, place))
      use Nil <- result.map(windows(
        place,
        max_within_s,
        default_within_s,
        retain_s,
      ))
      Spawner(
        name:,
        node:,
        placement:,
        profile:,
        tools:,
        max_depth:,
        max_sessions:,
        max_within_s:,
        default_within_s:,
        retain_s:,
        idle_close_s:,
        token_budget_per_day:,
        child_token_budget:,
        max_per_day:,
        approval_ceiling:,
        transcript:,
      )
    }
    _ -> Error(place <> " must be a table")
  }
}

// The optional ceiling on what the spawner's operator may approve. A table that
// is absent is no ceiling, which is different from a table that is present and
// admits nothing: the second asks the operator and can only be told no.
fn ceiling_of(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(Option(Ceiling), String) {
  let key = place <> ".approval_ceiling"
  case dict.get(fields, "approval_ceiling") {
    Error(Nil) -> Ok(None)
    Ok(tom.Table(table)) | Ok(tom.InlineTable(table)) ->
      approval_ceiling.from_table(table, key) |> result.map(Some)
    Ok(_) -> Error(key <> " must be a table")
  }
}

fn node_of(
  fields: Dict(String, tom.Toml),
  place: String,
  peers: ledger_reference.Peers,
) -> Result(String, String) {
  case dict.get(fields, "node") {
    Ok(tom.String(node)) ->
      case ledger_reference.accepts(peers, node) {
        True -> Ok(node)
        False ->
          Error(
            place
            <> ".node "
            <> node
            <> " is not a peer of this node: pin it in [[distribution.peers]]",
          )
      }
    Ok(_) -> Error(place <> ".node must be a string")
    Error(Nil) -> Error(place <> ".node is required")
  }
}

// Exactly one of `executor`, `pool` and `directory`. The first two also need a
// `workspace`, the name registered on the machine that will hold the checkout.
// A directory is itself the workspace, so `workspace` beside it would say two
// things about one place and is refused. The match names every combination of
// the three keys, so adding a fourth placement is a compile error here.
fn placement_of(
  fields: Dict(String, tom.Toml),
  place: String,
  known: Known,
) -> Result(Placement, String) {
  use executor <- result.try(optional_string(fields, place, "executor"))
  use pool <- result.try(optional_string(fields, place, "pool"))
  use directory <- result.try(optional_string(fields, place, "directory"))
  use workspace <- result.try(optional_string(fields, place, "workspace"))
  case executor, pool, directory {
    Some(executor), None, None -> {
      use Nil <- result.try(
        case executors.find(known.executors, executor), known.peers {
          Ok(_), _ -> Ok(Nil)

          // In ledger mode the ledger may give this executor a row. Parsing
          // checks the name's shape, and the daemon compares it with the ledger
          // when it starts (`ledger_reference.audit_names`).
          Error(Nil), ledger_reference.Ledgered ->
            case catalogue.is_executor_name(executor) {
              True -> Ok(Nil)
              False ->
                Error(
                  place
                  <> ".executor "
                  <> executor
                  <> " is not an executor name",
                )
            }
          Error(Nil), ledger_reference.Pinned(_) ->
            Error(
              place
              <> ".executor "
              <> executor
              <> " is not a configured [executors.<name>]",
            )
        },
      )
      use workspace <- result.map(workspace_of(workspace, place, "executor"))
      OnExecutor(executor:, workspace:)
    }
    None, Some(pool), None -> {
      use Nil <- result.try(case pools.find(known.pools, pool) {
        Ok(_) -> Ok(Nil)
        Error(Nil) ->
          Error(
            place <> ".pool " <> pool <> " is not a configured [pools.<name>]",
          )
      })
      use workspace <- result.map(workspace_of(workspace, place, "pool"))
      InPool(pool:, workspace:)
    }
    None, None, Some(path) ->
      case workspace {
        Some(_) ->
          Error(
            place
            <> ".workspace is not used with directory: the directory is the"
            <> " workspace",
          )
        None ->
          workspaces.absolute(path)
          |> result.map_error(fn(reason) { place <> ".directory " <> reason })
          |> result.replace(InDirectory(path:))
      }
    None, None, None ->
      Error(
        place
        <> " needs a placement: executor with workspace, pool with workspace,"
        <> " or directory",
      )
    Some(_), Some(_), None
    | Some(_), None, Some(_)
    | None, Some(_), Some(_)
    | Some(_), Some(_), Some(_)
    ->
      Error(
        place
        <> " names more than one placement: executor, pool and directory are"
        <> " alternatives",
      )
  }
}

// The workspace beside an executor or a pool. It is a name registered on that
// machine, so this module checks only its grammar; whether the machine serves it
// is learned at the attach.
fn workspace_of(
  workspace: Option(String),
  place: String,
  beside: String,
) -> Result(String, String) {
  case workspace {
    None -> Error(place <> ".workspace is required with " <> beside)
    Some(name) ->
      case catalogue.is_workspace_name(name) {
        True -> Ok(name)
        False ->
          Error(
            place
            <> ".workspace is not a workspace name: 1 to 128 bytes, no / and"
            <> " no NUL",
          )
      }
  }
}

fn profile_of(
  fields: Dict(String, tom.Toml),
  place: String,
  profiles: List(String),
) -> Result(String, String) {
  case dict.get(fields, "profile") {
    Ok(tom.String(profile)) ->
      case list.contains(profiles, profile) {
        True -> Ok(profile)
        False ->
          Error(
            place
            <> ".profile "
            <> profile
            <> " is not a configured [profiles.<name>]",
          )
      }
    Ok(_) -> Error(place <> ".profile must be a string")
    Error(Nil) -> Error(place <> ".profile is required")
  }
}

// The ceiling is a nonempty list of distinct names. A name is not checked
// against the built-in tools, because an extension's tool is whatever its
// manifest says; a name no tool answers to narrows the ceiling and nothing
// else, so a typo can only make a child less capable.
fn tools_of(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(List(String), String) {
  let words = place <> ".tools must be a nonempty array of tool names"
  case dict.get(fields, "tools") {
    Error(Nil) -> Ok(default_tools())
    Ok(tom.Array([])) -> Error(words)
    Ok(tom.Array(items)) -> {
      use names <- result.try(
        list.try_map(items, fn(item) {
          case item {
            tom.String("") -> Error(words)
            tom.String(name) -> Ok(name)
            _ -> Error(words)
          }
        }),
      )
      case first_repeat(names) {
        Ok(repeated) ->
          Error(place <> ".tools lists " <> repeated <> " more than once")
        Error(Nil) -> Ok(names)
      }
    }
    Ok(_) -> Error(words)
  }
}

fn first_repeat(names: List(String)) -> Result(String, Nil) {
  case names {
    [] -> Error(Nil)
    [first, ..rest] ->
      case list.contains(rest, first) {
        True -> Ok(first)
        False -> first_repeat(rest)
      }
  }
}

// `max_sessions` is a count like the others, with the ceiling an executor's
// scope limit imposes.
fn sessions_of(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(Int, String) {
  use sessions <- result.try(count_of(
    fields,
    place,
    "max_sessions",
    default_max_sessions,
  ))
  case sessions > sessions_limit {
    False -> Ok(sessions)
    True ->
      Error(
        place
        <> ".max_sessions "
        <> int.to_string(sessions)
        <> " is above "
        <> int.to_string(sessions_limit)
        <> ", the number of scopes an executor admits",
      )
  }
}

// A positive integer, or `default` when the key is absent. The seconds and the
// depth are all counts that must be at least one: a deadline of zero ends a
// child before it starts and a depth of zero admits no child at all.
fn count_of(
  fields: Dict(String, tom.Toml),
  place: String,
  key: String,
  default: Int,
) -> Result(Int, String) {
  case dict.get(fields, key) {
    Error(Nil) -> Ok(default)
    Ok(tom.Int(value)) if value >= 1 -> Ok(value)
    Ok(tom.Int(_)) -> Error(place <> "." <> key <> " must be positive")
    Ok(_) -> Error(place <> "." <> key <> " must be an integer")
  }
}

// A metering key: absent is no bound, and a bound is a positive integer. Zero is
// refused because it would admit nothing, which is a spawner that should not be
// listed, and the same words as for the other counts say so.
fn budget_of(
  fields: Dict(String, tom.Toml),
  place: String,
  key: String,
) -> Result(Option(Int), String) {
  case dict.has_key(fields, key) {
    False -> Ok(None)
    True -> count_of(fields, place, key, 1) |> result.map(Some)
  }
}

// The `transcript` key: `"hidden"` when absent, and one of the two words when
// present. Anything else is refused, so a typo never opens a transcript.
fn transcript_of(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(Transcript, String) {
  use word <- result.try(optional_string(fields, place, "transcript"))
  case word {
    None | Some("hidden") -> Ok(Hidden)
    Some("visible") -> Ok(Visible)
    Some(_) -> Error(place <> ".transcript must be \"visible\" or \"hidden\"")
  }
}

fn optional_string(
  fields: Dict(String, tom.Toml),
  place: String,
  key: String,
) -> Result(Option(String), String) {
  case dict.get(fields, key) {
    Error(Nil) -> Ok(None)
    Ok(tom.String(text)) -> Ok(Some(text))
    Ok(_) -> Error(place <> "." <> key <> " must be a string")
  }
}

// The two pairs of durations that constrain each other (see the module doc). A
// refusal names both values, because either may have come from a default the
// file never wrote.
fn windows(
  place: String,
  max_within_s: Int,
  default_within_s: Int,
  retain_s: Int,
) -> Result(Nil, String) {
  case default_within_s > max_within_s, retain_s < max_within_s {
    True, _ ->
      Error(
        place
        <> ".default_within_s ("
        <> int.to_string(default_within_s)
        <> ") is above max_within_s ("
        <> int.to_string(max_within_s)
        <> "): lower default_within_s or raise max_within_s",
      )
    False, True ->
      Error(
        place
        <> ".retain_s ("
        <> int.to_string(retain_s)
        <> ") is below max_within_s ("
        <> int.to_string(max_within_s)
        <> "): a delegate session could be deleted while a child it holds is"
        <> " still running",
      )
    False, False -> Ok(Nil)
  }
}

// Whether a built-in tool reaches state beyond the delegate session, which is
// why the default ceiling leaves it out.
fn reaches_beyond_the_session(name: String) -> Bool {
  name == "agent_spawn"
  || name == "remember"
  || string.starts_with(name, "peer_")
  || string.starts_with(name, "schedule_")
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
