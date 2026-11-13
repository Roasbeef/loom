//// This orchestrator's answer to the page of a spawner that wants to start and
//// drive sessions here (protocol-change/094).
////
//// The orchestrator port receives eight messages from a laptop whose page the
//// box's owner has opted in with a `[spawners.<name>.top_level]` table
//// (`client/remote_top` is their vocabulary). This module is the daemon's half:
//// it judges each message against the table and serves it from the registry and
//// from the sessions themselves. The browser never reaches this daemon. The page
//// asks its own daemon, which asks here, and the box sends nothing on its own.
////
//// ## What is judged, and in what order
////
//// 1. The node the message came from must be a configured spawner's
////    (`UnknownSpawner`), and that spawner must have a `top_level` table
////    (`TopLevelOff`).
//// 2. A create is judged against the table before anything is reserved: the
////    placement must be one the table lists (`NotOffered`), a folder must also
////    be remembered by this daemon and pass the folder checks of
////    protocol-change/074 (`InvalidArgument` with the check's words), the
////    profile must be one the table lists, and the model one this daemon's
////    catalogue has.
//// 3. Every message other than `Placements` and `TopCreate` names a session,
////    and the session must be in `catalogue_relayed_sessions` for this spawner
////    (`NotRelayed`). A session the owner started, or another spawner did, is
////    refused whatever its state, so the table is the whole of what a page can
////    reach.
////
//// ## A create is two steps and a resend finishes it
////
//// The registry reserves the session in one catalogue transaction that counts
//// both caps (`manager.reserve_relayed`), and only then is the session's store
//// made, by the same `create` that turns any reservation into a session. A crash
//// or a lost answer between the two leaves a reservation, and a create resent
//// with the same request id finds it by its row and finishes it. Nothing here
//// sweeps an unfinished reservation. It stays listed, counts against
//// `max_sessions`, and is deleted on this daemon's own page, which removes the
//// registration and its row together.
////
//// ## Reaching a session
////
//// A read of a session that is not resident opens it first, as the web view
//// does when a person selects it. The wait is `open_budget_ms`, inside the
//// seven seconds the sender gives these calls, and a session that does not open
//// in time answers `NotYetOpen`, which the sender asks again about. A listing
//// never opens anything: a saved session is listed idle with no requests, and
//// the requests it holds are read when the page opens it.
////
//// ## Flow
////
//// `host` → `judged` → `create` → `offers` → `sessions` → `row_of` → `reached`
//// → `archive`
////
//// 1. `host` builds the functions the orchestrator port calls.
//// 2. `judged` resolves the sender's node to its spawner and the table that
////    lets its page start sessions.
//// 3. `create` judges a placement and reserves and makes the session.
//// 4. `offers` states what the table lets the page pick, and `sessions` pages
////    the spawner's rows, each built by `row_of`.
//// 5. `reached` finds a relayed session's endpoint, opening it if it is saved,
////    and the messages that name a session start there.
//// 6. `archive` stops the session and hides it once it has drained.

import broker/token
import client/daemon/manager
import client/daemon/profiles
import client/delegate_host
import client/deployment
import client/gateway
import client/peer_mail
import client/relayed_session.{type Endpoint}
import client/remote/feed_directory
import client/remote/feed_host
import client/remote/orchestrator_port
import client/remote_escalation
import client/remote_feed
import client/remote_top.{type Placement, type Refusal}
import client/spawners.{type Spawner, type TopLevel}
import core/ids
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import storage/access
import storage/catalogue
import storage/domain
import web_view/placements as page
import weft
import weft/poll

/// The longest a message about a saved session waits for it to open, in
/// milliseconds. The sender gives these calls seven seconds, and the answer has
/// to arrive inside them.
pub const open_budget_ms = 5000

/// How often the wait looks at the registry, in milliseconds.
const open_poll_ms = 100

/// The longest an archive waits for the session's slot to drain, in
/// milliseconds.
const archive_budget_ms = 5000

/// The longest a listing waits for the resident sessions to say what they are
/// doing, in milliseconds.
const overview_budget_ms = 2000

/// What the daemon supplies the host: its tables, its registry, and the few
/// things only the daemon can do.
pub type Context(instance) {
  Context(
    /// The `[spawners.<name>]` tables, read once at start.
    spawners: List(Spawner),
    /// The registry that reserves, opens and archives the sessions.
    registry: manager.Manager(instance),
    /// Projects the questions a resident session answers out of the instance.
    endpoint: fn(instance) -> Endpoint,
    /// The directory new conversation files are placed in.
    sessions_directory: String,
    /// The daemon-wide domain configuration a new session's mapping carries.
    domain_configuration: String,
    /// Mints the generator a creation draws its session identity from.
    generator: fn() -> ids.Generator,
    /// The current time in Unix milliseconds.
    now_ms: fn() -> Int,
    /// Whether an `[executors.<name>]` of this name is configured now.
    has_executor: fn(String) -> Bool,
    /// Whether a `[pools.<name>]` of this name is configured.
    has_pool: fn(String) -> Bool,
    /// The executors and pools as the home page's creation form reads them,
    /// each executor with its health and workspaces. It connects to the
    /// executors, so it runs apart from the registry.
    survey: fn() -> deployment.Placements,
    /// The canonical folder a typed or remembered path names, or the fixed words
    /// that say why a session may not start there (protocol-change/074).
    check_folder: fn(String) -> Result(String, String),
    /// Records the session before it is served when this daemon is a member of a
    /// session directory (protocol-change/083), and does nothing otherwise.
    record: fn(String) -> Result(Nil, String),
    /// Tells the daemon's movers that a local session now exists.
    covered: fn() -> Nil,
    /// The daemon's epoch, which a live feed's attach answer carries and its
    /// gateway binding is made under (protocol-change/108).
    epoch: String,
    /// The gateway of a resident session.
    gateway: fn(instance) -> gateway.Gateway,
    /// The box's owner, the principal a live feed attaches as. A feed acts with
    /// the box owner's standing at the Operator authority and no more.
    owner: access.Principal,
    /// Reserves one of the daemon's connection permits for a live feed. It runs
    /// in the process that answers the attach and returns the capability that
    /// transfers the permit to the feed's own process, because a permit is
    /// released when the process that holds it exits.
    admit: fn() -> Result(fn() -> Result(Nil, String), String),
    /// How long a live feed lives with no poll, and how long an ended one is
    /// kept, in milliseconds. `remote_feed.lease_ms` in the daemon.
    feed_lease_ms: Int,
  )
}

/// Builds the functions the orchestrator port calls for the eight messages.
///
/// ## Examples
///
/// ```gleam
/// // orchestrator_port.start_with_top(name, held, peer, describe, importer, spawns, children, holds, reads, top_host.host(context))
/// ```
pub fn host(context: Context(instance)) -> orchestrator_port.TopHost {
  // The directory of live feeds is started with the host, so every feed of this
  // daemon is found in one place. A directory that cannot start leaves the daemon
  // serving no feed, which a laptop meets as the 094 page.
  let feeds = case feed_directory.start() {
    Ok(directory) -> serving_feeds(context, directory)
    Error(_) -> remote_feed.declining()
  }

  orchestrator_port.TopHost(
    feeds:,
    placements: fn(node) {
      use #(_spawner, table) <- result.map(judged(context, node))
      remote_top.encode_offers(remote_top.bounded(offers(context, table)))
    },
    create: fn(node, request_id, placement, profile, model) {
      use #(spawner, table) <- result.try(judged(context, node))
      create(context, spawner, table, request_id, placement, profile, model)
    },
    sessions: fn(node, after, limit) {
      use #(spawner, table) <- result.try(judged(context, node))
      sessions(context, spawner, table, after, limit)
    },
    history: fn(node, session, cursor, limit) {
      use #(spawner, _table) <- result.try(judged(context, node))
      use endpoint <- result.try(reached(context, spawner, session))
      endpoint.history(cursor, limit)
    },
    send: fn(node, session, message_id, text) {
      use #(spawner, _table) <- result.try(judged(context, node))
      use endpoint <- result.try(reached(context, spawner, session))
      use landing <- result.map(endpoint.send(message_id, text))

      // The first prompt becomes the session's subtitle, as the hub does for a
      // prompt typed on the page, and the write is once only.
      manager.seed_subtitle(context.registry, session, text)
      landing
    },
    stop: fn(node, session) {
      use #(spawner, _table) <- result.try(judged(context, node))
      use Nil <- result.try(relayed(context, spawner, session))

      // A saved or unfinished creation has no run. A resident must still be
      // the incarnation observed here; a transition or failed lookup cannot
      // prove that the requested stop has already happened.
      use view <- result.try(
        manager.get(context.registry, session)
        |> result.map_error(fn(error) {
          remote_top.StoreFailure(reason: delegate_host.describe(error))
        }),
      )

      // Only a confirmed resident incarnation can receive this stop.
      case view.status {
        manager.Saved | manager.Reserved | manager.FailedStart(..) -> Ok(Nil)
        manager.Resident(incarnation) -> {
          use instance <- result.try(
            manager.resolve_incarnation(context.registry, session, incarnation)
            |> result.map_error(fn(error) {
              remote_top.StoreFailure(reason: delegate_host.describe(error))
            }),
          )
          context.endpoint(instance).stop()
        }
        manager.Opening(..)
        | manager.Stopping(..)
        | manager.RecoveryBlocked(..) ->
          Error(remote_top.NotYetOpen("the session is changing state"))
      }
    },
    archive: fn(node, session) {
      use #(spawner, _table) <- result.try(judged(context, node))
      use Nil <- result.try(relayed(context, spawner, session))
      archive(context, spawner, session)
    },
    resolve: fn(node, session, escalation_id, decision, expected_seq, decider) {
      use #(spawner, table) <- result.try(judged(context, node))
      use endpoint <- result.try(reached(context, spawner, session))
      endpoint.resolve(
        relayed_session.Terms(
          spawner: spawner.name,
          ceiling: table.approval_ceiling,
        ),
        escalation_id,
        decision,
        expected_seq,
        decider,
      )
    },
  )
}

/// The spawner a message came from and its `top_level` table. A node no
/// `[spawners.<name>]` names is `UnknownSpawner`, and a spawner without the
/// table is `TopLevelOff`, so a daemon that opted in nobody refuses all eight
/// messages and says which of the two it is.
///
/// ## Examples
///
/// ```gleam
/// // top_host.judged(context, "laptop@100.64.0.5") == Ok(#(spawner, table))
/// ```
pub fn judged(
  context: Context(instance),
  node: String,
) -> Result(#(Spawner, TopLevel), Refusal) {
  use spawner <- result.try(
    spawners.by_node(context.spawners, node)
    |> result.replace_error(remote_top.UnknownSpawner(node:)),
  )

  // Decide how to handle spawner.top_level {.
  case spawner.top_level {
    Some(table) -> Ok(#(spawner, table))
    None -> Error(remote_top.TopLevelOff)
  }
}

// --- what the page may pick -----------------------------------------------------

// The offers the table lets the page pick, read afresh. A folder is offered only
// when the table allows folders, and only a remembered one that this daemon's own
// folder check still passes, so the page is never offered a folder (one a terminal
// made outside the home directory, or one since removed) that a create would then
// refuse; an executor or a
// pool only when the table lists it; a profile when the table lists it, or every
// profile when it lists none. The survey connects to the executors, so a table
// that lists none asks no one.

/// Establishes offers for the caller, keeping its validation and result policy at this boundary.
fn offers(context: Context(instance), table: TopLevel) -> remote_top.Offers {
  // Decide how to handle let folders =  table.folders {.
  let folders = case table.folders {
    spawners.NoFolders -> []
    spawners.RecentFolders ->
      case manager.recent_folders(context.registry) {
        Ok(remembered) ->
          list.filter(remembered, fn(folder) {
            result.is_ok(context.check_folder(folder.workspace))
          })
          |> list.map(fn(folder) {
            remote_top.FolderOffer(
              path: folder.workspace,
              label: label_of(folder.workspace),
            )
          })
        Error(_) -> []
      }
  }

  // Decide how to handle let surveyed =  table.executors, table.pools {.
  let surveyed = case table.executors, table.pools {
    [], [] -> page.Placements(executors: [], pools: [])
    _, _ -> deployment.for_page(context.survey())
  }

  remote_top.Offers(
    folders:,
    executors: offered_executors(table, surveyed),
    pools: offered_pools(table, surveyed),
    profiles: allowed_profiles(context, table),
    models: model_keys(context),
  )
}

// The last segment of a path, which is what the daemon's own page labels a
// folder with.
fn label_of(path: String) -> String {
  case list.last(string.split(path, "/")) {
    Ok("") | Error(Nil) -> path
    Ok(label) -> label
  }
}

/// Establishes offered executors for the caller, keeping its validation and result policy at this boundary.
fn offered_executors(
  table: TopLevel,
  surveyed: page.Placements,
) -> List(remote_top.ExecutorOffer) {
  list.map(table.executors, fn(name) {
    let report =
      list.find(surveyed.executors, fn(entry) { entry.name == name })
      |> result.try(fn(entry) { option.to_result(entry.report, Nil) })

    // Decide how to handle report {.
    case report {
      Ok(found) ->
        remote_top.ExecutorOffer(
          name:,
          state: state_of(found.state),
          free_scopes: found.free_scopes,
          workspaces: found.workspaces,
        )
      Error(Nil) ->
        remote_top.ExecutorOffer(
          name:,
          state: remote_top.Down,
          free_scopes: None,
          workspaces: [],
        )
    }
  })
}

/// Establishes state of for the caller, keeping its validation and result policy at this boundary.
fn state_of(state: page.State) -> remote_top.ExecutorState {
  case state {
    page.Ready -> remote_top.Ready
    page.Degraded -> remote_top.Degraded
    page.Full -> remote_top.Full
    page.Down -> remote_top.Down
  }
}

/// Establishes offered pools for the caller, keeping its validation and result policy at this boundary.
fn offered_pools(
  table: TopLevel,
  surveyed: page.Placements,
) -> List(remote_top.PoolOffer) {
  list.map(table.pools, fn(name) {
    let report =
      list.find(surveyed.pools, fn(entry) { entry.name == name })
      |> result.try(fn(entry) { option.to_result(entry.report, Nil) })

    // Decide how to handle report {.
    case report {
      Ok(found) ->
        remote_top.PoolOffer(
          name:,
          ready: list.length(found.eligible),
          workspaces: found.workspaces,
        )
      Error(Nil) -> remote_top.PoolOffer(name:, ready: 0, workspaces: [])
    }
  })
}

// The profiles a session may start with: the table's list, or every profile the
// daemon's configuration defines.

/// Establishes allowed profiles for the caller, keeping its validation and result policy at this boundary.
fn allowed_profiles(
  context: Context(instance),
  table: TopLevel,
) -> List(String) {
  case table.profiles {
    Some(listed) -> listed
    None ->
      profiles.names(profiles.effective("", context.domain_configuration))
      |> result.unwrap([])
  }
}

fn model_keys(context: Context(instance)) -> List(String) {
  profiles.model_keys(profiles.effective("", context.domain_configuration))
  |> result.unwrap([])
}

// --- create ------------------------------------------------------------------------

// Judges a create and makes the session. Everything the table can refuse is
// refused before the registry is asked, so a refusal reserves nothing and counts
// against no cap.

/// Establishes create for the caller, keeping its validation and result policy at this boundary.
fn create(
  context: Context(instance),
  spawner: Spawner,
  table: TopLevel,
  request_id: String,
  placement: Placement,
  profile: String,
  model: Option(String),
) -> Result(String, Refusal) {
  // Decide how to handle use Nil <- result.try( catalogue.is_request_id(request_id) {.
  use Nil <- result.try(case catalogue.is_request_id(request_id) {
    True -> Ok(Nil)
    False ->
      Error(remote_top.InvalidArgument(
        reason: "the request id is not one to 64 letters, numbers or hyphens",
      ))
  })

  use place <- result.try(placed(context, table, placement))
  use Nil <- result.try(profile_allowed(context, table, profile))
  use Nil <- result.try(model_known(context, model))
  use Nil <- result.try(
    profiles.check_choice(
      profiles.effective("", context.domain_configuration),
      Some(profile),
      model,
    )
    |> result.map_error(fn(refusal) {
      remote_top.InvalidArgument(reason: choice_words(refusal))
    }),
  )
  let creation =
    manager.Creation(
      request_key: catalogue.relayed_key(spawner.name, request_id),
      workspace: place.workspace,
      name: spawner.name <> " session",
      configuration: "",
      profile: Some(profile),
      model:,
      executor: place.executor,
      pool: place.pool,
    )
  use reserved <- result.try(
    manager.reserve_relayed(
      context.registry,
      manager.RelayRequest(
        spawner: spawner.name,
        request_id:,
        creation:,
        directory: context.sessions_directory,
        generator: context.generator(),
        configuration: context.domain_configuration,
        limits: catalogue.RelayedLimits(
          max_sessions: table.max_sessions,
          max_per_hour: table.max_per_hour,
          now_ms: context.now_ms(),
        ),
      ),
    )
    |> result.map_error(reservation_refusal),
  )

  // Decide how to handle reserved.state {.
  case reserved.state {
    // The store was made by an earlier attempt, or by this one before it was
    // answered. There is nothing to finish.
    catalogue.Saved -> Ok(reserved.session_id)
    catalogue.Reserved -> {
      // A session on a registered workspace is recorded before it is served
      // when this daemon is a member of a session directory. A folder on this
      // host is a lookup hint the movers write on their next pass.
      use Nil <- result.try(case placement {
        remote_top.Folder(_) -> Ok(Nil)
        remote_top.Workspace(..) | remote_top.Pooled(..) ->
          context.record(reserved.session_id)
          |> result.map_error(fn(reason) {
            remote_top.StoreFailure(reason: reason)
          })
      })

      use made <- result.map(
        manager.create_scoped(
          context.registry,
          creation,
          directory: context.sessions_directory,
          generator: context.generator(),
          scope: domain.SessionOnly,
          configuration: context.domain_configuration,
        )
        |> result.map_error(creation_refusal),
      )

      // A folder is remembered once its session exists, so the owner's own page
      // offers it again, and a folder that failed leaves no trace.
      case placement {
        remote_top.Folder(_) -> {
          manager.remember_folder(context.registry, place.workspace)
          context.covered()
        }
        remote_top.Workspace(..) | remote_top.Pooled(..) -> Nil
      }

      made.registration.id
    }
  }
}

// Where the creation puts the session once the table has judged the placement:
// the workspace text the registration holds, and the executor or pool it names.
type Place {
  Place(workspace: String, executor: String, pool: String)
}

/// Establishes placed for the caller, keeping its validation and result policy at this boundary.
fn placed(
  context: Context(instance),
  table: TopLevel,
  placement: Placement,
) -> Result(Place, Refusal) {
  // Decide how to handle placement {.
  case placement {
    remote_top.Folder(path:) -> {
      // Decide how to handle use Nil <- result.try( table.folders {.
      use Nil <- result.try(case table.folders {
        spawners.NoFolders ->
          Error(remote_top.NotOffered(remote_top.OfferedFolder, path))
        spawners.RecentFolders -> remembered(context, path)
      })

      // Validate this branch before continuing, preserving the owning operation’s failure boundary.
      use canonical <- result.try(
        context.check_folder(path)
        |> result.map_error(fn(words) {
          remote_top.InvalidArgument(reason: words)
        }),
      )

      // A folder the laptop could not read back in a listing is not started in.
      case remote_top.fits(canonical) {
        True -> Ok(Place(workspace: canonical, executor: "", pool: ""))
        False ->
          Error(remote_top.InvalidArgument(
            reason: "that folder's path is too long to relay",
          ))
      }
    }
    remote_top.Workspace(executor:, name:) -> {
      // Confirm the requested resource was offered to this host before returning its placement.
      use Nil <- result.try(
        // Decide how to handle the branch input.
        case
          list.contains(table.executors, executor)
          && context.has_executor(executor)
        {
          True -> Ok(Nil)
          False ->
            Error(remote_top.NotOffered(remote_top.OfferedExecutor, executor))
        },
      )

      use Nil <- result.map(workspace_name(name))
      Place(workspace: name, executor:, pool: "")
    }
    remote_top.Pooled(pool:, name:) -> {
      // Confirm the requested resource was offered to this host before returning its placement.
      use Nil <- result.try(
        // Decide how to handle list.contains(table.pools, pool) && context.has_pool(pool) {.
        case list.contains(table.pools, pool) && context.has_pool(pool) {
          True -> Ok(Nil)
          False -> Error(remote_top.NotOffered(remote_top.OfferedPool, pool))
        },
      )

      use Nil <- result.map(workspace_name(name))
      Place(workspace: name, executor: "", pool:)
    }
  }
}

/// Establishes workspace name for the caller, keeping its validation and result policy at this boundary.
fn workspace_name(name: String) -> Result(Nil, Refusal) {
  case catalogue.is_workspace_name(name) {
    True -> Ok(Nil)
    False ->
      Error(remote_top.InvalidArgument(
        reason: "the workspace name is not 1 to 128 bytes with no / and no NUL",
      ))
  }
}

// A folder is offered only when this daemon remembers it, so a page cannot name
// a path it was not shown. The comparison is of the text the daemon holds, which
// is canonical.

/// Establishes remembered for the caller, keeping its validation and result policy at this boundary.
fn remembered(
  context: Context(instance),
  path: String,
) -> Result(Nil, Refusal) {
  case manager.recent_folders(context.registry) {
    Ok(folders) ->
      case list.any(folders, fn(folder) { folder.workspace == path }) {
        True -> Ok(Nil)
        False -> Error(remote_top.NotOffered(remote_top.OfferedFolder, path))
      }
    Error(error) ->
      Error(remote_top.StoreFailure(reason: delegate_host.describe(error)))
  }
}

/// Establishes profile allowed for the caller, keeping its validation and result policy at this boundary.
fn profile_allowed(
  context: Context(instance),
  table: TopLevel,
  profile: String,
) -> Result(Nil, Refusal) {
  case list.contains(allowed_profiles(context, table), profile) {
    True -> Ok(Nil)
    False -> Error(remote_top.NotOffered(remote_top.OfferedProfile, profile))
  }
}

/// Establishes model known for the caller, keeping its validation and result policy at this boundary.
fn model_known(
  context: Context(instance),
  model: Option(String),
) -> Result(Nil, Refusal) {
  case model {
    None -> Ok(Nil)
    Some(key) ->
      case list.contains(model_keys(context), key) {
        True -> Ok(Nil)
        False -> Error(remote_top.NotOffered(remote_top.OfferedModel, key))
      }
  }
}

/// Establishes choice words for the caller, keeping its validation and result policy at this boundary.
fn choice_words(refusal: profiles.Refusal) -> String {
  case refusal {
    profiles.UnknownProfile(words) -> words
    profiles.UnknownModel(words) -> words
    profiles.UnusableConfiguration(words) -> words
  }
}

// What the registry's reservation refusal is to the page. A cap is a cap with
// its own value, and nothing else the registry can say is a reason to give up.

/// Establishes reservation refusal for the caller, keeping its validation and result policy at this boundary.
fn reservation_refusal(error: manager.RelayError) -> Refusal {
  case error {
    manager.RelayCapped(cap: catalogue.RelayedSessions, limit:) ->
      remote_top.CapReached(cap: remote_top.MaxSessions, limit:)
    manager.RelayCapped(cap: catalogue.RelayedPerHour, limit:) ->
      remote_top.CapReached(cap: remote_top.MaxPerHour, limit:)
    manager.RelayForeign ->
      remote_top.InvalidArgument(reason: "that request id is already in use")
    manager.RelayFailed(error:) ->
      remote_top.StoreFailure(reason: delegate_host.describe(error))
  }
}

// What the registry's refusal to make the reserved session's store is to the
// page. The reservation stands, so the same create resent finishes it, and the
// page is told to ask again.
fn creation_refusal(error: manager.Error) -> Refusal {
  remote_top.NotYetOpen(reason: delegate_host.describe(error))
}

// --- the sessions a spawner holds ------------------------------------------------------

// One page of the spawner's sessions, newest first. The catalogue is asked for
// the rows, and each resident session is asked, apart from the registry and
// under one deadline, what it is doing and what it is waiting for. A saved or
// unfinished creation has no runtime; a transitional or unanswered resident
// session makes the page retry rather than falsely claiming that it is idle.

/// Establishes sessions for the caller, keeping its validation and result policy at this boundary.
fn sessions(
  context: Context(instance),
  spawner: Spawner,
  table: TopLevel,
  after: String,
  limit: Int,
) -> Result(JsonValue, Refusal) {
  let bound = int.max(1, int.min(limit, remote_top.max_rows))
  use views <- result.try(
    manager.relayed_sessions(
      context.registry,
      spawner.name,
      after:,
      limit: bound,
    )
    |> result.map_error(fn(error) {
      remote_top.StoreFailure(reason: delegate_host.describe(error))
    }),
  )
  use overviews <- result.try(overviews_of(context, table, views))
  let rows =
    list.map2(views, overviews, fn(view, overview) { row_of(view, overview) })

  // Decide how to handle let more =  list.length(views) >= bound {.
  let more = case list.length(views) >= bound {
    True -> remote_top.Further
    False -> remote_top.Last
  }

  Ok(remote_top.encode_page(remote_top.page_of(rows, more)))
}

// What each resident row says of itself, in the order of the rows. The asks run
// together under one deadline. A failed answer refuses the page, preserving the
// reader's last observation instead of inventing an idle row.

/// Reads every resident overview under one deadline. Saved and unfinished
/// creation rows have no runtime; transitional or failed resident observations
/// refuse the page so the reader can retain its previous observation.
fn overviews_of(
  context: Context(instance),
  table: TopLevel,
  views: List(manager.RelayedView),
) -> Result(List(Option(relayed_session.Overview)), Refusal) {
  let unavailable = remote_top.StoreFailure("a session overview is unavailable")
  use asks <- result.try(
    list.try_map(views, fn(view) {
      // Saved and unfinished creations have no runtime. A resident must still
      // be the observed incarnation, and a transition cannot prove idleness.
      case view.view.status {
        manager.Saved | manager.Reserved | manager.FailedStart(..) -> Ok(None)
        manager.Resident(incarnation) -> {
          use instance <- result.try(
            manager.resolve_incarnation(
              context.registry,
              view.listing.record.session_id,
              incarnation,
            )
            |> result.replace_error(unavailable),
          )
          let endpoint = context.endpoint(instance)
          Ok(Some(fn() { endpoint.overview(table.approval_ceiling) }))
        }
        manager.Opening(..)
        | manager.Stopping(..)
        | manager.RecoveryBlocked(..) -> Error(unavailable)
      }
    }),
  )

  // `weft.start` returns one outcome per ask, in input order. An absent or
  // failed answer cannot stand in for an idle session.
  use outcomes <- result.try(
    option.values(asks)
    |> weft.new
    |> weft.deadline(overview_budget_ms)
    |> weft.start
    |> list.try_map(fn(outcome) {
      case outcome {
        weft.Completed(value: overview, ..) -> Ok(Some(overview))
        weft.Failed(..)
        | weft.Crashed(..)
        | weft.Abandoned(..)
        | weft.NeverStarted(..)
        | weft.DrainProofLost(..)
        | weft.CancellationUnconfirmed(..) -> Error(unavailable)
      }
    }),
  )
  Ok(rejoin(asks, outcomes))
}

// Puts each outcome back at the row that asked, in order, and leaves a row that
// asked nothing without one.

/// Establishes rejoin for the caller, keeping its validation and result policy at this boundary.
fn rejoin(asks: List(Option(a)), outcomes: List(Option(b))) -> List(Option(b)) {
  case asks, outcomes {
    [], _ -> []
    [None, ..rest], _ -> [None, ..rejoin(rest, outcomes)]
    [Some(_), ..rest], [outcome, ..later] -> [outcome, ..rejoin(rest, later)]
    [Some(_), ..rest], [] -> [None, ..rejoin(rest, [])]
  }
}

// One row. The requests are cut to what a row may carry, oldest by seq, so the
// row is whole and the rest are counted in `more`.

/// Establishes row of for the caller, keeping its validation and result policy at this boundary.
fn row_of(
  view: manager.RelayedView,
  overview: Option(relayed_session.Overview),
) -> remote_top.Row {
  let listing = view.listing
  let registration = view.view.registration
  let record = listing.record

  // The first prompt names a session once it has one, and the daemon's label
  // names it until then.
  let name = case registration.subtitle {
    Some(subtitle) -> subtitle
    None -> listing.name
  }

  // An archived session says so whatever its runtime would say, and one that
  // is not resident or did not answer is idle, as its page would see it.
  let activity = case listing.visibility, overview {
    catalogue.Archived, _ -> remote_top.Archived
    catalogue.Active, Some(found) -> activity_of(found.doing)
    catalogue.Active, None -> remote_top.Idle
  }

  // Decide how to handle let updated_at =  overview {.
  let updated_at = case overview {
    Some(found) -> option.unwrap(found.updated_at, record.created_at)
    None -> record.created_at
  }

  // The row without its requests, which is what the requests are fitted under.
  let bare =
    remote_top.Row(
      session_id: record.session_id,
      request_id: record.request_id,
      name:,
      placement: placement_of(listing),
      activity:,
      updated_at:,
      requests: [],
      more: 0,
      children: case overview {
        Some(found) -> list.take(found.children, remote_top.max_row_children)
        None -> []
      },
    )

  // Decide how to handle let pending =  overview {.
  let pending = case overview {
    Some(found) -> found.pending
    None -> []
  }

  let rest = string.byte_size(json.to_string(remote_top.encode_row(bare)))
  let #(requests, more) = remote_top.fit_requests(pending, rest)
  remote_top.Row(..bare, requests:, more:)
}

/// Establishes activity of for the caller, keeping its validation and result policy at this boundary.
fn activity_of(doing: peer_mail.Doing) -> remote_top.Activity {
  case doing {
    peer_mail.NeedsAnswer -> remote_top.NeedsYou
    peer_mail.Running -> remote_top.Working
    peer_mail.Resting -> remote_top.Idle
  }
}

// Where a session's tools run, from what the registration holds. A pool is
// named even after its first attach chose an executor, because the page chose
// the pool.

/// Establishes placement of for the caller, keeping its validation and result policy at this boundary.
fn placement_of(listing: catalogue.RelayedListing) -> Placement {
  placement_in(listing.pool, listing.executor, listing.workspace)
}

/// Where a session's tools run, from the three fields a registration and a
/// relayed listing both hold.
fn placement_in(
  pool: String,
  executor: String,
  workspace: String,
) -> Placement {
  case pool, executor {
    "", "" -> remote_top.Folder(path: workspace)
    "", executor -> remote_top.Workspace(executor:, name: workspace)
    pool, _ -> remote_top.Pooled(pool:, name: workspace)
  }
}

// --- reaching one session ------------------------------------------------------------------

// Whether the session is relayed for the spawner. The row is read in the
// registry's turn, so a session another spawner started, or none, is refused
// the same way.

/// Establishes relayed for the caller, keeping its validation and result policy at this boundary.
fn relayed(
  context: Context(instance),
  spawner: Spawner,
  session: String,
) -> Result(Nil, Refusal) {
  case manager.relayed_of(context.registry, session) {
    Ok(Some(row)) if row.spawner == spawner.name -> Ok(Nil)
    Ok(Some(_)) | Ok(None) -> Error(remote_top.NotRelayed)
    Error(error) ->
      Error(remote_top.StoreFailure(reason: delegate_host.describe(error)))
  }
}

// The endpoint of a relayed session, opening the session first if it is saved.
// The wait is bounded, and a session that does not open in time answers
// `NotYetOpen` so the sender asks again. A session that was reserved and never
// created, or that the owner archived, is not opened: the first needs its create
// resent, and the second needs its owner.

/// Establishes reached for the caller, keeping its validation and result policy at this boundary.
fn reached(
  context: Context(instance),
  spawner: Spawner,
  session: String,
) -> Result(Endpoint, Refusal) {
  use #(_incarnation, instance) <- result.map(opened(context, spawner, session))
  context.endpoint(instance)
}

// The resident instance of a relayed session and the incarnation it runs as,
// opening the session first if it is saved. A live feed binds its gateway
// attachment to that incarnation.

/// Establishes opened for the caller, keeping its validation and result policy at this boundary.
fn opened(
  context: Context(instance),
  spawner: Spawner,
  session: String,
) -> Result(#(String, instance), Refusal) {
  use Nil <- result.try(relayed(context, spawner, session))

  // Decide how to handle use Nil <- result.try( manager.get(context.registry, session) {.
  use Nil <- result.try(case manager.get(context.registry, session) {
    Ok(manager.View(status: manager.Resident(_), ..)) -> Ok(Nil)
    Ok(manager.View(registration: record, ..)) ->
      case record.state {
        catalogue.Reserved ->
          Error(remote_top.NotYetOpen(
            reason: "the session was reserved and its creation never finished; send the create again",
          ))
        catalogue.Saved ->
          manager.open(context.registry, session)
          |> result.map(fn(_status) { Nil })
          |> result.map_error(open_refusal)
      }
    Error(error) ->
      Error(remote_top.StoreFailure(reason: delegate_host.describe(error)))
  })

  resident(context, session)
}

/// Establishes open refusal for the caller, keeping its validation and result policy at this boundary.
fn open_refusal(error: manager.Error) -> Refusal {
  case error {
    manager.SessionArchived ->
      remote_top.InvalidArgument(reason: "the session is archived")
    manager.Catalogue(_)
    | manager.NotInitialized
    | manager.Capacity
    | manager.Unavailable
    | manager.StaleOperation
    | manager.StartFailed(_)
    | manager.Preparation(_)
    | manager.SessionMoving(..)
    | manager.SessionMoved(_)
    | manager.SessionDeleting ->
      remote_top.NotYetOpen(reason: delegate_host.describe(error))
  }
}

// Waits for the session's slot to be resident and projects its endpoint. The
// registry's view is read each time, so a builder that failed ends the wait at
// once with the registry's own account of it.

/// Establishes resident for the caller, keeping its validation and result policy at this boundary.
fn resident(
  context: Context(instance),
  session: String,
) -> Result(#(String, instance), Refusal) {
  let waited =
    poll.until(within: open_budget_ms, every: open_poll_ms, attempt: fn() {
      case manager.get(context.registry, session) {
        Error(error) ->
          poll.Fail(
            remote_top.StoreFailure(reason: delegate_host.describe(error)),
          )
        Ok(manager.View(status: manager.Resident(incarnation), ..)) ->
          case
            manager.resolve_incarnation(context.registry, session, incarnation)
          {
            Ok(instance) -> poll.Done(#(incarnation, instance))
            Error(error) ->
              poll.Fail(
                remote_top.NotYetOpen(reason: delegate_host.describe(error)),
              )
          }
        Ok(manager.View(status: manager.Opening(_), ..)) -> poll.Retry
        Ok(manager.View(status: manager.FailedStart(reason:, ..), ..)) ->
          poll.Fail(remote_top.NotYetOpen(
            reason: "the session failed to start: " <> reason,
          ))
        Ok(manager.View(status: manager.Reserved, ..))
        | Ok(manager.View(status: manager.Saved, ..))
        | Ok(manager.View(status: manager.Stopping(_), ..))
        | Ok(manager.View(status: manager.RecoveryBlocked(_), ..)) ->
          poll.Fail(remote_top.NotYetOpen(reason: "the session did not open"))
      }
    })

  // Decide how to handle waited {.
  case waited {
    poll.Answered(endpoint) -> Ok(endpoint)
    poll.Failed(refusal) -> Error(refusal)
    poll.Expired ->
      Error(remote_top.NotYetOpen(reason: "the session did not open in time"))
  }
}

// --- archive ---------------------------------------------------------------------------------

// Stops the session and hides it once its slot has drained. Stopping a session
// with no slot is not an error, and archiving an archived session is not
// either, so a resend after a lost answer is the same call.

/// Establishes archive for the caller, keeping its validation and result policy at this boundary.
fn archive(
  context: Context(instance),
  spawner: Spawner,
  session: String,
) -> Result(Nil, Refusal) {
  let _stopping = manager.stop_session(context.registry, session)
  let waited =
    poll.until(within: archive_budget_ms, every: open_poll_ms, attempt: fn() {
      case manager.archive_relayed(context.registry, spawner.name, session) {
        Ok(_view) -> poll.Done(Nil)
        Error(manager.ArchiveBusy) -> poll.Retry
        Error(manager.ArchiveNotRelayed) -> poll.Fail(remote_top.NotRelayed)
        Error(manager.ArchiveFailed(error:)) ->
          poll.Fail(
            remote_top.StoreFailure(reason: delegate_host.describe(error)),
          )
      }
    })

  // Decide how to handle waited {.
  case waited {
    poll.Answered(Nil) -> Ok(Nil)
    poll.Failed(refusal) -> Error(refusal)
    poll.Expired ->
      Error(remote_top.NotYetOpen(reason: "the session is still stopping"))
  }
}

// --- live session feeds ----------------------------------------------------------------

// The four operations of a live session page (protocol-change/108). Each is judged
// against the spawner its node resolves to, as the eight of 094 are. A token is
// looked up only among that spawner's feeds before anything else is read, so a
// request for a feed that has ended, or that another spawner holds, learns that
// the feed has ended and touches nothing.

/// Builds the four callbacks over one directory of feeds. `host` calls it over the
/// directory it starts, and a test calls it over a directory it controls.
///
/// ## Examples
///
/// ```gleam
/// // top_host.serving_feeds(context, directory)
/// ```
pub fn serving_feeds(
  context: Context(instance),
  directory: feed_directory.Directory,
) -> remote_feed.Host {
  remote_feed.Host(
    attach: fn(node, attach) { attach_feed(context, directory, node, attach) },
    poll: fn(node, poll) {
      use feed <- result.try(held_feed(context, directory, node, poll.feed))
      feed_host.poll(feed, poll)
    },
    send: fn(node, piece) {
      use feed <- result.try(held_feed(context, directory, node, piece.feed))
      feed_host.send(feed, piece)
    },
    detach: fn(node, token) {
      use #(spawner, _table) <- result.try(judged(context, node))

      // Ending a feed that is gone is not a refusal, so a detach resent after a
      // lost answer is the same call. A directory that did not answer is one,
      // because the feed is still there and the laptop must ask again.
      case feed_directory.find(directory, spawner.name, token) {
        Ok(feed) -> Ok(feed_host.detach(feed))
        Error(feed_directory.Gone) -> Ok(Nil)
        Error(feed_directory.Unanswered) -> Error(not_answering())
      }
    },
  )
}

/// The feed a token names among the sender's spawner's feeds. A token that is
/// gone has ended or never was, and the refusal says `lapsed`, because starting
/// again from a fresh attach is what every such laptop does. A directory that did
/// not answer says nothing of the feed, so the refusal is `NotYetOpen`, as it is
/// for a feed that did not answer, and the laptop asks again.
fn held_feed(
  context: Context(instance),
  directory: feed_directory.Directory,
  node: String,
  token: String,
) -> Result(feed_host.Feed, Refusal) {
  use #(spawner, _table) <- result.try(judged(context, node))
  feed_directory.find(directory, spawner.name, token)
  |> result.map_error(fn(missing) {
    case missing {
      feed_directory.Gone -> remote_top.FeedEnded(remote_top.FeedLapsed)
      feed_directory.Unanswered -> not_answering()
    }
  })
}

/// The refusal for a directory that did not answer.
fn not_answering() -> Refusal {
  remote_top.NotYetOpen("the live pages of this daemon are not answering")
}

/// Opens a feed on a relayed session: the box checks the spawner, its table, its
/// `page` key, the relayed row and the feed cap, opens the session if it is saved,
/// starts the feed and answers its token.
fn attach_feed(
  context: Context(instance),
  directory: feed_directory.Directory,
  node: String,
  attach: remote_feed.Attach,
) -> Result(remote_feed.Attached, Refusal) {
  use #(spawner, table) <- result.try(judged(context, node))

  // A table that serves the transcript page refuses the live one, and the
  // laptop draws the page of 094.
  use Nil <- result.try(case table.page {
    spawners.LivePage -> Ok(Nil)
    spawners.PagedPage ->
      Error(remote_top.NotOffered(remote_top.OfferedPage, "live"))
  })

  use Nil <- result.try(relayed(context, spawner, attach.session))
  use token <- result.try(
    feed_directory.reserve(
      directory,
      spawner.name,
      process.self(),
      remote_feed.max_feeds,
    )
    |> result.map_error(fn(refused) {
      case refused {
        feed_directory.AtCap ->
          remote_top.CapReached(
            cap: remote_top.MaxFeeds,
            limit: remote_feed.max_feeds,
          )
        feed_directory.Unavailable -> not_answering()
      }
    }),
  )

  // A place was reserved, so every way out of here that does not register the
  // feed must give it back.
  case started_feed(context, directory, spawner, table, attach, token) {
    Ok(attached) -> Ok(attached)
    Error(refusal) -> {
      feed_directory.release(directory, token)
      Error(refusal)
    }
  }
}

/// Starts the feed once its place is reserved, and registers it.
fn started_feed(
  context: Context(instance),
  directory: feed_directory.Directory,
  spawner: Spawner,
  table: TopLevel,
  attach: remote_feed.Attach,
  token: String,
) -> Result(remote_feed.Attached, Refusal) {
  use #(incarnation, instance) <- result.try(opened(
    context,
    spawner,
    attach.session,
  ))
  use label <- result.try(heading_of(context, attach.session))
  use digest <- result.try(feed_digest(spawner.name))
  use transfer <- result.try(
    context.admit()
    |> result.map_error(fn(reason) { remote_top.NotYetOpen(reason:) }),
  )
  let session = attach.session

  // A spawner with an `approval_ceiling` can decide, and its feed counts as
  // someone being there. One without can only watch, and does not.
  let deciding = case table.approval_ceiling {
    Some(_) -> gateway.Decides
    None -> gateway.Watches
  }

  let authority = access.Participant(access.Operator)

  // The connection id goes into the gateway's presence roster and to every
  // subscribed connection, Observers included, so it is its own random id and
  // never the token that names the feed.
  let connection_id = "feed-" <> hex_entropy(8)
  use feed <- result.map(
    feed_host.start(feed_host.Settings(
      hub: context.gateway(instance),
      binding: gateway.Binding(
        session_id: session,
        epoch: context.epoch,
        incarnation:,
        connection_id: connection_id,
        principal: context.owner,
        authority:,
        digest:,
        signin: None,
        door: gateway.PeerDoor(spawner.name, deciding),
      ),
      check: feed_check(context, spawner.name, session, incarnation),
      failed_reader: fn() {
        let _ =
          manager.stop_if_incarnation(context.registry, session, incarnation)
        Nil
      },
      spawner: spawner.name,
      ceiling: table.approval_ceiling,
      decider: remote_escalation.Decider(
        principal: attach.principal,
        name: attach.name,
      ),
      admit: transfer,
      owner: process.self(),
      lease_ms: context.feed_lease_ms,
    ))
    |> result.map_error(fn(reason) { remote_top.NotYetOpen(reason:) }),
  )
  feed_directory.register(directory, token, feed)
  feed_host.registered(feed)
  remote_feed.Attached(feed: token, epoch: context.epoch, incarnation:, label:)
}

/// The gateway's check of a feed, run on every request and push. The spawner
/// must still have its table with `page = "live"`, the session must still be
/// relayed for it, and the session must still run as the incarnation the feed was
/// bound to. The table is read once when the daemon starts, so a table the owner
/// changed is met first by the restart that reads it. An answer of `Error` closes
/// the attachment, and the feed then ends `revoked`.
fn feed_check(
  context: Context(instance),
  spawner: String,
  session: String,
  incarnation: String,
) -> fn() -> Result(#(access.Principal, access.Authority), String) {
  fn() {
    case
      serves_live(context, spawner)
      && is_relayed(context, spawner, session)
      && runs_as(context, session, incarnation)
    {
      True -> Ok(#(context.owner, access.Participant(access.Operator)))
      False -> Error("the page's access to this session ended")
    }
  }
}

/// Whether the spawner still has its table with `page = "live"`.
fn serves_live(context: Context(instance), spawner: String) -> Bool {
  list.any(context.spawners, fn(held) {
    case held.name == spawner, held.top_level {
      True, Some(table) -> table.page == spawners.LivePage
      True, None | False, _ -> False
    }
  })
}

/// Whether the registry still holds a relayed row of this spawner for the
/// session. A registry that does not answer is not a yes.
fn is_relayed(
  context: Context(instance),
  spawner: String,
  session: String,
) -> Bool {
  case manager.relayed_of(context.registry, session) {
    Ok(Some(row)) -> row.spawner == spawner
    Ok(None) | Error(_) -> False
  }
}

/// Whether the session still runs as the incarnation the feed was bound to.
fn runs_as(
  context: Context(instance),
  session: String,
  incarnation: String,
) -> Bool {
  case manager.get(context.registry, session) {
    Ok(manager.View(status: manager.Resident(held), ..)) -> held == incarnation
    Ok(_) | Error(_) -> False
  }
}

/// What a feed's heading says of its session: the name, with the first prompt
/// once it has one, and where the session's tools run.
fn heading_of(
  context: Context(instance),
  session: String,
) -> Result(remote_feed.Label, Refusal) {
  use view <- result.map(
    manager.get(context.registry, session)
    |> result.map_error(fn(error) {
      remote_top.StoreFailure(reason: delegate_host.describe(error))
    }),
  )
  let registration = view.registration
  let name = option.unwrap(registration.subtitle, registration.name)
  remote_feed.Label(
    name: remote_top.clip(name),
    placement: placement_in(
      registration.pool,
      registration.executor,
      registration.workspace,
    ),
  )
}

/// `bytes` random bytes as lowercase hexadecimal.
fn hex_entropy(bytes: Int) -> String {
  token.production_entropy()(bytes)
  |> bit_array.base16_encode
  |> string.lowercase
}

/// The digest a feed's binding carries. It is derived from the spawner's name
/// and is no credential, so it matches no row that authenticates anything. The
/// gateway reads it only to name who approved a remembered grant, and a feed's
/// decisions do not go through that path.
fn feed_digest(spawner: String) -> Result(access.Digest, Refusal) {
  let hex =
    bit_array.from_string("loom-live-feed:" <> spawner)
    |> bootstrap.sha256
    |> bit_array.base16_encode
    |> string.lowercase
  access.credential_digest(hex)
  |> result.replace_error(remote_top.StoreFailure(
    reason: "the feed's identity could not be made",
  ))
}
