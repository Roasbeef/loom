//// The host half of the project tools: the closures `tools/project` takes,
//// filled over the project actor.
////
//// A session gets its seam when it is built, from its standing. The seam
//// carries the session's own id, because a tool call does not (the tool
//// context names a strand, not a session), and the actor judges a worker's
//// report against the assignment bound to that session. A router's tools are
//// refused to any session but the project's router, so even a seam handed to
//// the wrong session would answer `NotPermitted` and nothing more.

import client/daemon/project_host.{type Handle}
import tools/project as tools

/// The seam for the session `session` of the project `handle` serves.
///
/// ## Examples
///
/// ```gleam
/// // projectseam.seam(handle, session_id)
/// ```
pub fn seam(handle: Handle, session: String) -> tools.Projects {
  tools.Projects(
    route: fn(_ctx, items) {
      use Nil <- as_router(handle, session)
      project_host.route(handle, items)
    },
    read: fn(_ctx, resource) {
      use Nil <- as_router(handle, session)
      project_host.read(handle, resource)
    },
    reply: fn(_ctx, queued) {
      use Nil <- as_router(handle, session)
      project_host.queue_reply(handle, queued)
    },
    report: fn(_ctx, report) { project_host.report(handle, session, report) },
    handback: fn(_ctx, handback) {
      project_host.hand_back(handle, session, handback)
    },
  )
}

/// The router's tools answer the router and no one else.
fn as_router(
  handle: Handle,
  session: String,
  then: fn(Nil) -> Result(a, tools.Refusal),
) -> Result(a, tools.Refusal) {
  case session == handle.router_session {
    True -> then(Nil)
    False ->
      Error(tools.NotPermitted("only the project's router may use this tool"))
  }
}
