//// The other orchestrators a session may start children on, as a record of
//// functions (protocol-change/084, slice S3).
////
//// The Agency asks two questions of another orchestrator: start a child, and
//// report on children. It must not know how they are sent. The orchestrator port
//// and its addresses sit above the Agency in the module graph (the owner port
//// reaches the Agency through the notice module), so the Agency depends on this
//// record and the daemon fills it from the sending end
//// (`client/remote/remote_spawner`). A test fills it with two closures that play
//// the other orchestrator.
////
//// The port also takes a `RunEnded` message, which stops the children a finished
//// run owns, and the sending end does not use it: a remote child is always
//// detached, so nothing on this side tells an orchestrator that a run ended.
//// The record has no function for it. It does have `release`, which tells an
//// orchestrator that a parent session was deleted. The parent's session is gone
//// by then, so the caller is not an Agency but the daemon's release drainer,
//// which asks through a `Reach` built for the deleted session.
////
//// The functions answer as a call to another orchestrator can end, and the same
//// two ways peer mail's endpoints do (`client/peer_mail.Failure`).
////
//// | What happened | The call returns |
//// | --- | --- |
//// | The orchestrator answered | `Ok(answer)` |
//// | The orchestrator looked and said no | `Error(Refused(reason))` |
//// | Nobody answered: the node is gone, no port is registered, or no answer came in time | `Error(Unreachable)` |
////
//// `Refused` is definitive and settles whatever asked. `Unreachable` means the
//// orchestrator may have acted and lost its reply, and what happens next belongs
//// to the caller: a spawn is resent, because the receiver adopts the child its
//// call site already made, and a join is not queued. The reason a refusal carries
//// is already a sentence for the parent's model (`remote_spawn.describe_refusal`).

import client/peer_mail.{type Failure}
import client/remote_spawn.{
  type CallSite, type Joined, type Parent, type Request, type Spawned,
}
import tools/agent.{type Handle}

/// The longest one `Spawn` waits for its answer, in milliseconds. The first spawn
/// for a parent opens the other orchestrator's delegate session, which on an
/// executor placement includes an attach, so the bound is not short. A caller
/// that has less time than this left passes the smaller number.
pub const spawn_ms = 30_000

/// Everything a session may ask of the other orchestrators.
///
/// Each function takes the name of the `[orchestrators.<name>]` to ask and
/// answers as the table above says. A name that is not configured is a
/// definitive `Refused`, not silence: asking again cannot make it exist.
pub type Reach {
  Reach(
    /// The canonical identity of the session that asks. A message names its
    /// parent as this session and a strand.
    session: String,
    /// The orchestrators `agent_spawn` may name in `on`, in configuration order.
    orchestrators: List(String),
    /// Whether this session may start a child elsewhere now. The design offers it
    /// only in a session its owner holds alone, and that changes when a member is
    /// invited, so it is asked at each spawn and not fixed when the session opens.
    offered: fn() -> Bool,
    /// Starts a child, or has the orchestrator answer the one this call site
    /// already started. The arguments are the orchestrator, the parent, the call
    /// site, the parent's depth, its tools, the request, and the most the call
    /// may wait for an answer in milliseconds, which a caller bounded by a
    /// window of its own sets to what is left of it.
    spawn: fn(String, Parent, CallSite, Int, List(String), Request, Int) ->
      Result(Spawned, Failure),
    /// Waits for children and reports each one's position. The arguments are the
    /// orchestrator, the parent, the handles and the window the orchestrator
    /// waits, in milliseconds.
    join: fn(String, Parent, List(Handle), Int) -> Result(List(Joined), Failure),
    /// Tells the orchestrator that the parent session was deleted, so it stops
    /// every child it holds for it and deletes the session that held them, and
    /// answers how many children it stopped. The arguments are the orchestrator
    /// and the parent. A parent the orchestrator holds nothing for answers zero.
    release: fn(String, Parent) -> Result(Int, Failure),
  )
}

/// The reach of a session that has nowhere to start a child: no orchestrators
/// are offered, and every question is refused as naming one that is not
/// configured.
///
/// ## Examples
///
/// ```gleam
/// assert remote_reach.none("0198c0de-0000-7000-8000-000000000001").orchestrators == []
/// ```
pub fn none(session: String) -> Reach {
  Reach(
    session:,
    orchestrators: [],
    offered: fn() { False },
    spawn: fn(name, _parent, _site, _depth, _tools, _request, _within_ms) {
      Error(not_configured(name))
    },
    join: fn(name, _parent, _handles, _window_ms) {
      Error(not_configured(name))
    },
    release: fn(name, _parent) { Error(not_configured(name)) },
  )
}

/// The refusal for a name no `[orchestrators.<name>]` carries.
///
/// ## Examples
///
/// ```gleam
/// assert remote_reach.not_configured("box") == peer_mail.Refused("`box` is not a configured orchestrator")
/// ```
pub fn not_configured(name: String) -> Failure {
  peer_mail.Refused("`" <> name <> "` is not a configured orchestrator")
}

/// The parent a message names: this session and a strand of it.
///
/// ## Examples
///
/// ```gleam
/// assert remote_reach.parent(reach, "main") == remote_spawn.Parent(session: reach.session, strand: "main")
/// ```
pub fn parent(reach: Reach, strand: String) -> Parent {
  remote_spawn.Parent(session: reach.session, strand:)
}
