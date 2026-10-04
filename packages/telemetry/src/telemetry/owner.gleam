//// The ownership label an external inspector reads: which session and
//// strand a process works for, and what it does there.
////
//// Pickglass, the independent BEAM inspector attached to a
//// `loomd --profile` node, has no way to learn from a pid alone which
//// session accounts for its heap or its reductions. Registration, links
//// and supervision are evidence, not proof (issue #720). So a Loom
//// process declares its owner itself, once, with OTP's process label:
//// `proc_lib:set_label({pickglass_owner, 1, Path, Role})`, where `Path`
//// is the list of `{Kind, Id}` binary pairs outermost first and `Role`
//// is a binary. `protocol-change/065-pickglass-owner-label.md` freezes
//// that shape and the closed set of roles below.
////
//// ## Why it lives beside the logger
////
//// `log.adopt` already runs once at the top of exactly the processes
//// whose owner matters: the strand driver and every effect worker it
//// spawns. Those call sites hold a `Logger`, and a logger's context
//// already names the session and the strand. Deriving the path from it
//// means the label and the log lines cannot disagree about who owns a
//// process. A process with no logger in reach, such as the daemon's
//// page-session table, calls `label` with a path it supplies.
////
//// ## What a label is not
////
//// A process has one label, and `proc_lib:set_label/1` replaces whatever
//// the process labelled itself earlier. Loom therefore uses the label
//// for ownership and for nothing else. The label is read, never
//// interpreted, by Loom itself: nothing here decides a behaviour, and a
//// process that never calls `label` is shown by the inspector as
//// `unknown`.

import gleam/list
import gleam/option.{type Option, None, Some}
import telemetry/context.{type Context}
import telemetry/internal/ffi_logger

/// What a process does for its owner. The set is closed and frozen by
/// `protocol-change/065`: an inspector groups by the lowercase snake case
/// name, so a new role is a protocol change and not an edit at a call
/// site.
///
pub type Role {
  /// The strand's driver, the actor that runs the strand's loop.
  StrandDriver

  /// A process running one tool, hook or timer effect for a strand.
  EffectWorker

  /// A process running one provider request for a strand. It is the
  /// top-level drain witness for the stream it owns.
  ProviderEffectWorker

  /// A session's gateway actor, the door a client's calls pass through.
  Gateway

  /// The process serving one web view page's socket. It owns the page's
  /// Lustre component and ends with it.
  PageSocket

  /// The daemon's table of web view tickets and UI sessions. It belongs
  /// to no Loom session.
  PageSessions
}

/// The role's wire name: lowercase snake case, as the protocol freezes it.
///
/// ## Examples
///
/// ```gleam
/// owner.role_name(owner.StrandDriver)
/// // -> "strand_driver"
/// ```
///
pub fn role_name(role: Role) -> String {
  case role {
    StrandDriver -> "strand_driver"
    EffectWorker -> "effect_worker"
    ProviderEffectWorker -> "provider_effect_worker"
    Gateway -> "gateway"
    PageSocket -> "page_socket"
    PageSessions -> "page_sessions"
  }
}

/// The owner path a context names, outermost first: the session, then
/// the strand, each only if the context knows it. A context with neither
/// yields the empty path, which the protocol reads as "not owned by a
/// session".
///
/// ## Examples
///
/// ```gleam
/// owner.path(context.for_session("s1") |> context.with_strand("main"))
/// // -> [#("session", "s1"), #("strand", "main")]
/// ```
///
pub fn path(of context: Context) -> List(#(String, String)) {
  [pair("session", context.session), pair("strand", context.strand)]
  |> list.flatten
}

fn pair(kind: String, id: Option(String)) -> List(#(String, String)) {
  case id {
    Some(id) -> [#(kind, id)]
    None -> []
  }
}

/// Labels the calling process as `role` under `path`, replacing any label
/// it set before. Call it once at the top of the process's own body: the
/// label is per process and is not inherited by a spawn. It costs one
/// process-dictionary write.
///
/// ## Examples
///
/// ```gleam
/// owner.label([#("session", "s1")], owner.Gateway)
/// ```
///
pub fn label(path: List(#(String, String)), role: Role) -> Nil {
  ffi_logger.set_owner_label(path, role_name(role))
}

/// Labels the calling process as `role`, owned by whatever session and
/// strand `context` names. This is what `log.adopt` calls.
///
/// ## Examples
///
/// ```gleam
/// owner.label_for(context.for_session("s1"), owner.EffectWorker)
/// ```
///
pub fn label_for(context: Context, role: Role) -> Nil {
  label(path(of: context), role)
}
