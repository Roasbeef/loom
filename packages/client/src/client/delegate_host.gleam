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
//// ## Flow
////
//// `resolver` → `creation` → `terms_of`
////
//// 1. `resolver` returns the function the spawn host calls for every message.
//// 2. `creation` builds the registration a first spawn makes, from the
////    spawner's placement and profile.
//// 3. `terms_of` turns the spawner's table into the plain figures the Agency
////    judges a spawn by.

import client/agency
import client/daemon/manager
import client/remote_spawn.{type Parent, type SpawnRefusal}
import client/spawners.{type Spawner, InDirectory, InPool, OnExecutor}
import core/ids
import gleam/option.{None, Some}
import gleam/result
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
  manager.Creation(
    request_key: "delegate:" <> spawner.name <> ":" <> parent.session,
    workspace:,
    name: "delegate " <> spawner.name <> " " <> parent.session,
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
  fn(spawner, parent) {
    use made <- result.try(creation(spawner, parent))
    use delegated <- result.try(
      manager.delegate_session(
        context.registry,
        manager.DelegateRequest(
          spawner: spawner.name,
          parent_session: parent.session,
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

// The Agency of a session once it is resident. The registry's view is read each
// time and not the slot alone, so a session whose builder failed ends the wait
// at once with the registry's account instead of running out the budget.
fn resident(
  context: Context(instance),
  session_id: String,
) -> Result(agency.DelegateEndpoint, SpawnRefusal) {
  let waited =
    poll.until(within: open_budget_ms, every: open_poll_ms, attempt: fn() {
      case manager.get(context.registry, session_id) {
        Error(error) -> poll.Fail(describe(error))
        Ok(manager.View(status: manager.Opening(_), ..)) -> poll.Retry
        Ok(manager.View(status: manager.Resident(_), ..)) ->
          case manager.resolve(context.registry, session_id) {
            Ok(instance) -> poll.Done(context.endpoint(instance))
            Error(error) -> poll.Fail(describe(error))
          }
        Ok(manager.View(status: manager.Reserved, ..)) ->
          poll.Fail("the delegate session was reserved and never created")
        Ok(manager.View(status: manager.Saved, ..)) ->
          poll.Fail("the delegate session did not open")
        Ok(manager.View(status: manager.Stopping(_), ..)) ->
          poll.Fail("the delegate session is stopping")
        Ok(manager.View(status: manager.RecoveryBlocked(reason:), ..)) ->
          poll.Fail("the delegate session cannot recover: " <> reason)
      }
    })
  case waited {
    poll.Answered(endpoint) -> Ok(endpoint)
    poll.Failed(reason) -> Error(remote_spawn.StoreFailure(reason:))
    poll.Expired ->
      Error(remote_spawn.StoreFailure(
        reason: "the delegate session did not open in time",
      ))
  }
}

fn refused(error: manager.DelegateError) -> SpawnRefusal {
  case error {
    manager.DelegateAtLimit(held:) ->
      remote_spawn.CapReached(cap: remote_spawn.MaxSessions, limit: held)
    manager.DelegateFailed(manager.Catalogue(catalogue.Invalid(_))) ->
      remote_spawn.InvalidArgument(
        reason: "the parent session is not a session identity",
      )
    manager.DelegateFailed(error:) ->
      remote_spawn.StoreFailure(reason: describe(error))
  }
}

// What the registry's error says, in words for a spawner. A catalogue failure
// is named by its kind and not by its detail, which can hold a path.
fn describe(error: manager.Error) -> String {
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
