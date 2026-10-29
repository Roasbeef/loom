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

import client/daemon/manager
import client/daemon/profiles
import client/delegate_host
import client/deployment
import client/peer_mail
import client/relayed_session.{type Endpoint}
import client/remote/orchestrator_port
import client/remote_top.{type Placement, type Refusal}
import client/spawners.{type Spawner, type TopLevel}
import core/ids
import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
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
  orchestrator_port.TopHost(
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

      // Decide how to handle manager.resolve(context.registry, session) {.
      case manager.resolve(context.registry, session) {
        Ok(instance) -> context.endpoint(instance).stop()

        // A session that is not running has no run to stop.
        Error(_) -> Ok(Nil)
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
  case listing.pool, listing.executor {
    "", "" -> remote_top.Folder(path: listing.workspace)
    "", executor -> remote_top.Workspace(executor:, name: listing.workspace)
    pool, _ -> remote_top.Pooled(pool:, name: listing.workspace)
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
) -> Result(Endpoint, Refusal) {
  let waited =
    poll.until(within: open_budget_ms, every: open_poll_ms, attempt: fn() {
      case manager.get(context.registry, session) {
        Error(error) ->
          poll.Fail(
            remote_top.StoreFailure(reason: delegate_host.describe(error)),
          )
        Ok(manager.View(status: manager.Resident(_), ..)) ->
          case manager.resolve(context.registry, session) {
            Ok(instance) -> poll.Done(context.endpoint(instance))
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
