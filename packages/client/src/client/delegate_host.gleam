//// Finding the delegate session a subagent message is for
//// (protocol-change/084, slice S2).
////
//// Another orchestrator's subagents run in a session of this daemon that exists
//// only to serve them, one per (spawner, parent session) pair. The orchestrator
//// port receives the messages, `client/daemon/main.spawn_host` judges the sender
//// against its `[spawners.<name>]` table, and this module is the step between:
//// given the spawner and the parent, it returns the Agency of the right
//// delegate session, creating the session on the pair's first message and
//// opening it when it is not resident.
////
//// ## Why creation is the registry's turn
////
//// A first spawn must find nothing, count the spawner's sessions, create one and
//// record it, and two first spawns for different parents must not both pass the
//// cap. The registry (`client/daemon/manager`) is already the one process that
//// serializes session creation, so the whole step is one command to it
//// (`manager.delegate_session`) and this module adds no lock of its own. The
//// creation's request key is derived from the pair, so a crash between the
//// registration and the record is retried onto the same registration.
////
//// ## Opening
////
//// The registry answers when the session is admitted, which for a session that
//// is not resident is when its builder starts. The first message for a pair, or
//// the first after a restart or a close, therefore waits here for the session to
//// become resident. On an executor placement that includes attaching to the
//// executor, so the wait is bounded by `open_budget_ms`, a little inside the
//// 30 second window the sender gives a spawn. A session that fails to open ends
//// the wait with the registry's own account of the failure.
////
//// ## Releasing
////
//// A `Release` says the parent session was deleted, so the pair's session is to
//// be stopped and deleted. It must not go through `resolver`: that creates the
//// session of a pair that has none, which is right for a `Spawn` and would make
//// a session only to delete it for a `Release` that arrived first or twice.
//// `resolve_existing` reads the pair's row and finds the Agency only when a
//// session is open and resident, and `releaser` stops its children, then hands
//// the session to the registry to delete when its slot drains. A pair with no
//// row answers zero and creates nothing, so a `Spawn` that arrives after its
//// `Release` is the only thing that can make the session, and it is then
//// refused when the row says released.
////
//// The release cascades (protocol-change/084, phase 4), and nothing here does it.
//// A child here may have started children of its own on a third orchestrator,
//// and the session's stubs are the only record of them. The registry reads the
//// stubs from the closed file in the turn that deletes the drained session and
//// writes a release row for each orchestrator they name, as a laptop's deletion
//// does (`manager.release_delegate`). Writing them any earlier would let the
//// session, still running, resend a spawn that reaches the third orchestrator
//// after its release.
////
//// ## Reading
////
//// A `ChildHistory` reads a child's transcript (protocol-change/090). Like a
//// release it must create nothing, so it goes through `existing_endpoint`, the
//// same function a send and a decision use, which is `resolve_existing`
//// answering only the Agency of a resident session. A
//// session that is closed holds no running child and is not opened to be
//// read: the parent sees its result through a join.
////
//// ## A session for one child
////
//// A seeded child on an executor or a pool is started from a copy of its
//// parent's workspace, and a session has one workspace, so the child needs a
//// session of its own (protocol-change/107, slice 4b). It is the delegate session
//// of a (spawner, parent session, child) triple. `children` returns the four
//// functions that serve it: `resolve` creates or opens the session for a spawn,
//// `open` opens one that exists and creates nothing, for a join and a return,
//// `live` lists the resident ones of a parent, for the end of a run, and
//// `release` ends one when its child has settled. The parent's own release walks
//// the pair's session and every child's, so a deleted parent leaves none behind.
//// A child's session counts against the spawner's `max_sessions` like any other,
//// which is why a settled child's is released and does not wait for the sweep.
////
//// ## Flow
////
//// `resolver` → `creation` → `terms_of` → `resolve_existing` →
//// `existing_endpoint` → `releaser` → `children`
////
//// 1. `resolver` returns the function the spawn host calls for every message.
//// 2. `creation` builds the registration a first spawn makes, from the
////    spawner's placement and profile.
//// 3. `terms_of` turns the spawner's table into the plain figures the Agency
////    judges a spawn by.
//// 4. `resolve_existing` finds the Agency of a pair that already has a session,
////    and creates nothing.
//// 5. `existing_endpoint` returns the function the spawn host calls for a message
////    about a child that exists or a read of its transcript, and creates and
////    opens no session.
//// 6. `releaser` returns the function the spawn host calls for a `Release`.
//// 7. `children` returns the functions that serve the sessions of seeded
////    children.

import client/agency
import client/daemon/manager
import client/remote_spawn.{type Parent, type SpawnRefusal}
import client/spawners.{type Spawner, InDirectory, InPool, OnExecutor}
import core/ids
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import storage/catalogue
import weft/poll

/// The longest the first message for a pair waits for its session to become
/// resident, in milliseconds. The sender gives a spawn thirty seconds, and the
/// wait has to end with room left for the Agency's answer.
pub const open_budget_ms = 20_000

/// How often the wait looks at the registry, in milliseconds.
const open_poll_ms = 200

/// What the registry needs to find or make a delegate session, and how to reach
/// its Agency once it is resident.
pub type Context(instance) {
  Context(
    /// The registry, which creates and admits the session.
    registry: manager.Manager(instance),
    /// The directory new conversation files are placed in.
    sessions_directory: String,
    /// The daemon-wide domain configuration a new session's mapping carries.
    domain_configuration: String,
    /// Mints the generator a creation draws its session identity from.
    generator: fn() -> ids.Generator,
    /// The current time in Unix milliseconds, for a pair's last contact.
    now_ms: fn() -> Int,
    /// Projects the delegate Agency out of a resident session.
    endpoint: fn(instance) -> agency.DelegateEndpoint,
  )
}

/// The figures of a spawner's table that the Agency judges a spawn by.
///
/// ## Examples
///
/// ```gleam
/// // delegate_host.terms_of(spawner).max_within_ms == spawner.max_within_s * 1000
/// ```
pub fn terms_of(spawner: Spawner) -> remote_spawn.Terms {
  remote_spawn.Terms(
    ceiling: spawner.tools,
    max_depth: spawner.max_depth,
    max_within_ms: spawner.max_within_s * 1000,
    default_within_ms: spawner.default_within_s * 1000,
  )
}

/// The registration a first spawn makes for a pair: the spawner's placement and
/// profile, a label that names the spawner and the parent, and a request key
/// derived from the pair.
///
/// A directory placement is canonicalized, as the control command does for a
/// session's workspace; an executor or pool placement is a registered workspace
/// name and is kept as written.
///
/// ## Examples
///
/// ```gleam
/// // delegate_host.creation(spawner, parent).request_key
/// // == "delegate:laptop:0198c0de-0000-7000-8000-000000000001"
/// ```
pub fn creation(
  spawner: Spawner,
  parent: Parent,
) -> Result(manager.Creation, SpawnRefusal) {
  creation_for(spawner, parent, "")
}

/// `creation` for one named child of the pair: the same placement and profile,
/// and a request key and label that name the child, so that a creation retried
/// after a crash lands on the registration it reserved and no other child's.
/// The empty `child` is the pair's own session.
///
/// ## Examples
///
/// ```gleam
/// // delegate_host.creation_for(spawner, parent, "seed-0123456789abcdef").request_key
/// // == "delegate:laptop:0198c0de-0000-7000-8000-000000000001:seed-0123456789abcdef"
/// ```
pub fn creation_for(
  spawner: Spawner,
  parent: Parent,
  child: String,
) -> Result(manager.Creation, SpawnRefusal) {
  // Map spawner placement configuration into directory, executor, or pool parameters.
  use #(workspace, executor, pool) <- result.map(case spawner.placement {
    OnExecutor(executor:, workspace:) -> Ok(#(workspace, executor, ""))
    InPool(pool:, workspace:) -> Ok(#(workspace, "", pool))
    InDirectory(path:) ->
      bootstrap.canonical_directory(path)
      |> result.map(fn(canonical) { #(canonical, "", "") })
      |> result.replace_error(remote_spawn.StoreFailure(
        reason: "the spawner's directory is unusable",
      ))
  })

  // The child's name follows the parent's, so no child's key is the pair's.
  let suffix = case child {
    "" -> ""
    named -> ":" <> named
  }

  manager.Creation(
    request_key: "delegate:" <> spawner.name <> ":" <> parent.session <> suffix,
    workspace:,
    name: "delegate "
      <> spawner.name
      <> " "
      <> parent.session
      <> string.replace(suffix, ":", " "),
    configuration: "",
    profile: Some(spawner.profile),
    model: None,
    executor:,
    pool:,
  )
}

/// The function the spawn host calls to reach the Agency of a spawner's
/// delegate session for a parent, creating or opening the session as needed.
///
/// A failure is a refusal the spawner reads: the cap is `CapReached(MaxSessions)`,
/// a parent that is not a session identity is an invalid argument, and anything
/// the registry could not do is a store failure with the registry's account.
///
/// ## Examples
///
/// ```gleam
/// // let resolve = delegate_host.resolver(context)
/// // resolve(spawner, parent) -> Ok(agency.DelegateEndpoint(..))
/// ```
pub fn resolver(
  context: Context(instance),
) -> fn(Spawner, Parent) -> Result(agency.DelegateEndpoint, SpawnRefusal) {
  let resolve = child_resolver(context)
  fn(spawner, parent) { resolve(spawner, parent, "") }
}

/// `resolver` for the session of one named child of a pair, which is created on
/// the child's first spawn and opened on every later one. The empty child is the
/// pair's own session.
///
/// ## Examples
///
/// ```gleam
/// // let resolve = delegate_host.child_resolver(context)
/// // resolve(spawner, parent, "seed-0123456789abcdef") -> Ok(agency.DelegateEndpoint(..))
/// ```
pub fn child_resolver(
  context: Context(instance),
) -> fn(Spawner, Parent, String) ->
  Result(agency.DelegateEndpoint, SpawnRefusal) {
  fn(spawner, parent, child) {
    use made <- result.try(creation_for(spawner, parent, child))
    use delegated <- result.try(
      manager.delegate_session(
        context.registry,
        manager.DelegateRequest(
          spawner: spawner.name,
          parent_session: parent.session,
          child:,
          creation: made,
          directory: context.sessions_directory,
          generator: context.generator(),
          configuration: context.domain_configuration,
          limit: spawner.max_sessions,
          now_ms: context.now_ms(),
        ),
      )
      |> result.map_error(refused),
    )
    resident(context, delegated.session_id)
  }
}

/// What a pair already has, as `resolve_existing` finds it.
pub type Existing {
  /// The pair has no delegate session, and none was made.
  NoSession

  /// The pair has a session.
  Existing(
    /// This daemon's identity for the session.
    session_id: String,
    /// How far its release has got.
    state: catalogue.DelegateState,
    /// Its Agency when the session is open and resident, or `None` when it is
    /// closed: nothing runs in a closed session, so there is nothing to stop.
    endpoint: Option(agency.DelegateEndpoint),
  )
}

/// The function the spawn host calls to find the session a pair already has,
/// without creating one.
///
/// Only a resident session has an Agency to ask. One that is opening, closed,
/// stopping or blocked holds no running child, and the answer says so.
///
/// ## Examples
///
/// ```gleam
/// // let find = delegate_host.resolve_existing(context)
/// // find(spawner, parent) == Ok(delegate_host.NoSession)
/// ```
pub fn resolve_existing(
  context: Context(instance),
) -> fn(Spawner, Parent) -> Result(Existing, SpawnRefusal) {
  let find = resolve_existing_child(context)
  fn(spawner, parent) { find(spawner, parent, "") }
}

/// `resolve_existing` for one named child of a pair. It creates nothing, so a
/// child that settled and was released is `NoSession`.
///
/// ## Examples
///
/// ```gleam
/// // let find = delegate_host.resolve_existing_child(context)
/// // find(spawner, parent, "seed-0123456789abcdef") == Ok(delegate_host.NoSession)
/// ```
pub fn resolve_existing_child(
  context: Context(instance),
) -> fn(Spawner, Parent, String) -> Result(Existing, SpawnRefusal) {
  fn(spawner: Spawner, parent: Parent, child: String) {
    use found <- result.try(
      manager.delegate_child(
        context.registry,
        spawner.name,
        parent.session,
        child,
      )
      |> result.map_error(fn(error) {
        remote_spawn.StoreFailure(reason: describe(error))
      }),
    )

    // Branch on whether the session exists in the registry.
    case found {
      None -> Ok(NoSession)
      Some(row) -> {
        use endpoint <- result.map(open_endpoint(context, row.session_id))
        Existing(session_id: row.session_id, state: row.state, endpoint:)
      }
    }
  }
}

/// Opens the Agency delegate endpoint if the session is currently resident, or returns None.
fn open_endpoint(
  context: Context(instance),
  session_id: String,
) -> Result(Option(agency.DelegateEndpoint), SpawnRefusal) {
  // This branch resolves manager get context registry session_id before the operation continues.
  case manager.get(context.registry, session_id) {
    Error(error) -> Error(remote_spawn.StoreFailure(reason: describe(error)))
    Ok(manager.View(status: manager.Resident(_), ..)) ->
      resident(context, session_id) |> result.map(Some)
    Ok(manager.View(status: manager.Opening(_), ..))
    | Ok(manager.View(status: manager.Reserved, ..))
    | Ok(manager.View(status: manager.FailedStart(..), ..))
    | Ok(manager.View(status: manager.Saved, ..))
    | Ok(manager.View(status: manager.Stopping(_), ..))
    | Ok(manager.View(status: manager.RecoveryBlocked(_), ..)) -> Ok(None)
  }
}

/// The function the spawn host calls for a message about a child that already
/// exists (a send into it, a decision about its request, or a read of its
/// transcript): the Agency of the
/// pair's session if one is open and resident, and `None` otherwise.
///
/// Unlike `resolver` it creates nothing. A message about a child cannot be the
/// first message of a pair, and a stale one (the child finished, the session was
/// released and deleted, and an operator answered the card afterwards) would
/// otherwise open a fresh session only to refuse the message.
///
/// ## Examples
///
/// ```gleam
/// // let find = delegate_host.existing_endpoint(context)
/// // find(spawner, parent) == Ok(option.None)
/// ```
pub fn existing_endpoint(
  context: Context(instance),
) -> fn(Spawner, Parent) ->
  Result(Option(agency.DelegateEndpoint), SpawnRefusal) {
  let find = resolve_existing(context)
  fn(spawner: Spawner, parent: Parent) {
    use found <- result.map(find(spawner, parent))

    // Extract the active delegate endpoint from the existing session if present.
    case found {
      Existing(endpoint:, ..) -> endpoint
      NoSession -> None
    }
  }
}

/// The function the spawn host calls for a `Release`: stops the pair's children
/// and has the registry delete its session, answering how many children it
/// stopped.
///
/// A deleted parent leaves a session for its pair and one for each seeded child
/// it started, so the release walks all of them (`manager.delegate_family`). Each
/// is released as `child_releaser` releases one, so a parent with none answers
/// `Ok(0)` and nothing is created.
///
/// ## Examples
///
/// ```gleam
/// // let release = delegate_host.releaser(context)
/// // release(spawner, parent) == Ok(0)
/// ```
pub fn releaser(
  context: Context(instance),
) -> fn(Spawner, Parent) -> Result(Int, SpawnRefusal) {
  let release = child_releaser(context)
  fn(spawner: Spawner, parent: Parent) {
    use family <- result.try(
      manager.delegate_family(context.registry, spawner.name, parent.session)
      |> result.map_error(fn(error) {
        remote_spawn.StoreFailure(reason: describe(error))
      }),
    )

    // The pair's own session is released even when its row is absent, which
    // answers zero, and then every child that is listed, one after another.
    let children = list.map(family, fn(row) { row.child })
    list.try_fold(list.unique(["", ..children]), 0, fn(stopped, child) {
      release(spawner, parent, child)
      |> result.map(fn(more) { stopped + more })
    })
  }
}

/// The function the spawn host calls to end the session of one child, because
/// the child has settled or its parent was deleted: stops the child's run and
/// has the registry delete the session, answering how many children it stopped.
///
/// A child with no row answers zero and nothing is created, so a repeat, or a
/// release that arrives after the sweep has deleted the session, is harmless.
/// A row already releasing or released answers zero without asking the Agency
/// again, and is still handed to the registry, which finishes a deletion that
/// failed. The stop comes before the hand-over, so every child is recorded
/// stopped with its reason before the session can go. The registry writes the
/// releasing state before it stops the slot, so a daemon that dies after that
/// leaves a row the sweep deletes, and one that dies before it leaves an open
/// row that the parent's release or the sweep's silence window ends.
///
/// ## Examples
///
/// ```gleam
/// // let release = delegate_host.child_releaser(context)
/// // release(spawner, parent, "seed-0123456789abcdef") == Ok(0)
/// ```
pub fn child_releaser(
  context: Context(instance),
) -> fn(Spawner, Parent, String) -> Result(Int, SpawnRefusal) {
  let find = resolve_existing_child(context)
  let registry = context.registry
  let sessions = context.sessions_directory
  fn(spawner: Spawner, parent: Parent, child: String) {
    use existing <- result.try(find(spawner, parent, child))

    // Release the session or return zero if no session is registered.
    case existing {
      NoSession -> Ok(0)
      Existing(state:, endpoint:, ..) -> {
        // Release child operations through the open endpoint or return 0 for non-open states.
        use stopped <- result.try(case state, endpoint {
          catalogue.Open, Some(endpoint) -> endpoint.release()
          catalogue.Open, None
          | catalogue.Releasing, _
          | catalogue.Released, _
          -> Ok(0)
        })

        use Nil <- result.map(
          manager.release_delegate_child(
            registry,
            spawner.name,
            parent.session,
            child,
            sessions,
          )
          |> result.map_error(fn(error) {
            remote_spawn.StoreFailure(reason: describe(error))
          }),
        )
        stopped
      }
    }
  }
}

/// The functions that serve the sessions of seeded children
/// (protocol-change/107, slice 4b), each over one registry.
pub type ChildSessions {
  ChildSessions(
    /// The session of a child, created on its first spawn and opened on every
    /// later one, given the spawner, the parent and the child's name.
    resolve: fn(Spawner, Parent, String) ->
      Result(agency.DelegateEndpoint, SpawnRefusal),
    /// The session of a child that already has one, opened if it is not
    /// resident, and never created: a child that settled and was released has
    /// none, and a join about it must not make one.
    open: fn(Spawner, Parent, String) ->
      Result(agency.DelegateEndpoint, SpawnRefusal),
    /// The resident sessions of a parent's seeded children, for the end of a
    /// run. A session that is not resident holds no running child.
    live: fn(Spawner, Parent) ->
      Result(List(agency.DelegateEndpoint), SpawnRefusal),
    /// Ends one child's session, answering how many children it stopped.
    release: fn(Spawner, Parent, String) -> Result(Int, SpawnRefusal),
  )
}

/// The functions that serve the sessions of seeded children over a registry.
///
/// ## Examples
///
/// ```gleam
/// // let sessions = delegate_host.children(context)
/// // sessions.open(spawner, parent, "seed-0123456789abcdef")
/// ```
pub fn children(context: Context(instance)) -> ChildSessions {
  ChildSessions(
    resolve: child_resolver(context),
    open: child_opener(context),
    live: live_children(context),
    release: child_releaser(context),
  )
}

/// A value for a daemon that starts no seeded child on an executor: nothing
/// resolves or opens, nothing is live, and releasing any child stops none.
///
/// ## Examples
///
/// ```gleam
/// assert delegate_host.no_children().live(spawner, parent) == Ok([])
/// ```
pub fn no_children() -> ChildSessions {
  let unused =
    remote_spawn.InvalidArgument(
      reason: "this orchestrator starts no seeded child on an executor",
    )
  ChildSessions(
    resolve: fn(_spawner, _parent, _child) { Error(unused) },
    open: fn(_spawner, _parent, _child) { Error(unused) },
    live: fn(_spawner, _parent) { Ok([]) },
    release: fn(_spawner, _parent, _child) { Ok(0) },
  )
}

/// Opens the session of a child that has one. A child with no row is refused
/// without creating a session, which a join about a settled child relies on;
/// one with a row goes through the registry's ordinary admission, which opens a
/// closed session and refuses a releasing one.
fn child_opener(
  context: Context(instance),
) -> fn(Spawner, Parent, String) ->
  Result(agency.DelegateEndpoint, SpawnRefusal) {
  let find = resolve_existing_child(context)
  let resolve = child_resolver(context)
  fn(spawner, parent, child) {
    use existing <- result.try(find(spawner, parent, child))

    // A child with no session has none to open.
    case existing {
      NoSession ->
        Error(remote_spawn.InvalidArgument(
          reason: "this orchestrator holds no such child for that parent",
        ))
      Existing(..) -> resolve(spawner, parent, child)
    }
  }
}

/// The Agency of each of a parent's seeded children that is open and resident.
fn live_children(
  context: Context(instance),
) -> fn(Spawner, Parent) -> Result(List(agency.DelegateEndpoint), SpawnRefusal) {
  fn(spawner: Spawner, parent: Parent) {
    use family <- result.try(
      manager.delegate_family(context.registry, spawner.name, parent.session)
      |> result.map_error(fn(error) {
        remote_spawn.StoreFailure(reason: describe(error))
      }),
    )

    // Only an open child session can have a run; the pair's own is not one.
    let open =
      list.filter(family, fn(row) {
        row.child != "" && row.state == catalogue.Open
      })
    list.try_map(open, fn(row) { open_endpoint(context, row.session_id) })
    |> result.map(option.values)
  }
}

/// Polls the session registry until the delegate session becomes resident or times out.
fn resident(
  context: Context(instance),
  session_id: String,
) -> Result(agency.DelegateEndpoint, SpawnRefusal) {
  let failed = fn(reason) { poll.Fail(remote_spawn.StoreFailure(reason:)) }
  let waited =
    poll.until(within: open_budget_ms, every: open_poll_ms, attempt: fn() {
      // This branch resolves manager get context registry session_id before the operation continues.
      case manager.get(context.registry, session_id) {
        Error(error) -> failed(describe(error))
        Ok(manager.View(status: manager.Opening(_), ..)) -> poll.Retry
        Ok(manager.View(status: manager.Resident(_), ..)) ->
          // This branch resolves manager resolve context registry session_id before the operation continues.
          case manager.resolve(context.registry, session_id) {
            Ok(instance) -> poll.Done(context.endpoint(instance))
            Error(error) -> failed(describe(error))
          }

        Ok(manager.View(status: manager.Reserved, ..)) ->
          failed("the delegate session was reserved and never created")
        Ok(manager.View(status: manager.FailedStart(reason:, ..), ..)) ->
          failed("the delegate session failed to start: " <> reason)
        Ok(manager.View(status: manager.Saved, ..)) ->
          poll.Fail(remote_spawn.NotYetOpen(
            reason: "the delegate session did not open",
          ))

        // A failed open retains its slot while original custody drains.
        // Like Saved after that drain, this can open on a later spawn, so it
        // must not permanently refuse the sender's durable Requested stub.
        Ok(manager.View(status: manager.Stopping(_), ..)) ->
          poll.Fail(remote_spawn.NotYetOpen(
            reason: "the delegate session is stopping",
          ))
        Ok(manager.View(status: manager.RecoveryBlocked(reason:), ..)) ->
          failed("the delegate session cannot recover: " <> reason)
      }
    })

  // Transform the poll result into an answered endpoint or a classified spawn refusal.
  case waited {
    poll.Answered(endpoint) -> Ok(endpoint)
    poll.Failed(refusal) -> Error(refusal)
    poll.Expired ->
      Error(remote_spawn.NotYetOpen(
        reason: "the delegate session did not open in time",
      ))
  }
}

/// What a registry refusal is to a spawner: a cap is `CapReached` with the
/// cap's own limit, a released pair is `ParentRunEnded`, and anything the
/// registry could not do is a `StoreFailure` with its account. The Agency's
/// spawn claim uses it too, so a day cap reads the same wherever it is met.
///
/// ## Examples
///
/// ```gleam
/// assert delegate_host.refused(manager.DelegateAtLimit(held: 4))
///   == remote_spawn.CapReached(cap: remote_spawn.MaxSessions, limit: 4)
/// ```
pub fn refused(error: manager.DelegateError) -> SpawnRefusal {
  // This branch resolves error before the operation continues.
  case error {
    // The parent session was deleted, so there is no one for a child to report
    // to: the refusal a spawn under an ended run gets.
    manager.DelegateReleased -> remote_spawn.ParentRunEnded
    manager.DelegateAtLimit(held:) ->
      remote_spawn.CapReached(cap: remote_spawn.MaxSessions, limit: held)
    manager.DelegateDayCap(cap: manager.DayTokens, limit:) ->
      remote_spawn.CapReached(cap: remote_spawn.TokensPerDay, limit:)
    manager.DelegateDayCap(cap: manager.DaySpawns, limit:) ->
      remote_spawn.CapReached(cap: remote_spawn.SpawnsPerDay, limit:)
    manager.DelegateFailed(manager.Catalogue(catalogue.Invalid(_))) ->
      remote_spawn.InvalidArgument(
        reason: "the parent session is not a session identity",
      )
    manager.DelegateFailed(error:) ->
      remote_spawn.StoreFailure(reason: describe(error))
  }
}

/// What the registry's error says, in words for a spawner. A catalogue failure
/// is named by its kind and not by its detail, which can hold a path. The host
/// of a spawner's page (`client/top_host`) words its refusals the same way.
///
/// ## Examples
///
/// ```gleam
/// assert delegate_host.describe(manager.Capacity)
///   == "this daemon is at its session capacity"
/// ```
pub fn describe(error: manager.Error) -> String {
  // This branch resolves error before the operation continues.
  case error {
    manager.Catalogue(catalogue.Unsupported) ->
      "the catalogue is not one this build supports"
    manager.Catalogue(catalogue.Invalid(_)) ->
      "the catalogue holds invalid metadata"
    manager.Catalogue(catalogue.Conflict) ->
      "the catalogue holds a conflicting registration"
    manager.Catalogue(catalogue.Missing) -> "the session is not registered"
    manager.Catalogue(catalogue.Database(_)) -> "the catalogue could not answer"
    manager.NotInitialized -> "the session was reserved and never created"
    manager.SessionArchived -> "the session is archived"
    manager.Capacity -> "this daemon is at its session capacity"
    manager.Unavailable -> "this daemon is not admitting sessions"
    manager.StaleOperation -> "the session changed while it was opening"
    manager.StartFailed(reason:) -> "the session did not start: " <> reason
    manager.Preparation(reason:) -> "the session was not prepared: " <> reason
    manager.SessionMoving(..) | manager.SessionMoved(..) ->
      "the session belongs to another orchestrator"
    manager.SessionDeleting -> "the session is being deleted"
  }
}
