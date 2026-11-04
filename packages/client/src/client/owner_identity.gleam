//// Who the orchestrator's operator commits as, for an executor that asks
//// (protocol-change/107, "Git identity on an executor", loom #1061).
////
//// A session whose workspace is on another machine has no sandbox broker on the
//// orchestrator to resolve an identity through, because a broker belongs to a
//// workspace the orchestrator runs itself. The identity it sends is not the
//// session's anyway. It is the operator's: the `user.name` and `user.email` of
//// the global Git configuration on the orchestrator's machine. This module reads
//// that, once for all sessions, through the sandboxed Git runner the daemon owns
//// (`client/worktree_git`), which is the one place Git starts for a repository
//// or a configuration the model may have influenced. Git does not run in the
//// daemon's VM.
////
//// ## How it is read
////
//// `resolve` runs `git config --global --includes --null --get-regexp` with the
//// operator's `HOME`, no network and nothing it may write. Its environment is
//// the runner's fixed allowlist plus the operator's own `XDG_CONFIG_HOME` and
//// `GIT_CONFIG_GLOBAL`, so a `GIT_CONFIG_COUNT`, a pager or a credential helper in
//// the daemon's environment never reaches Git, and `git config` reads values and
//// never runs them. Its answer is read by `git_identity.identity_of_query`, the
//// same parsing a session's own identity query uses. Whether the two values are
//// acceptable to send is decided later, by `owner_port.answered_identity`, with
//// the protocol's one check (`protocol.git_identity_of`).
////
//// ## A session build never waits on Git
////
//// The answer is held by one process, `start`, for `keep_ms`, a failure included,
//// so the sandbox is asked at most once a minute however many sessions open. A
//// query is bounded by `query_ms` and a lookup by the caller's own wait, and a
//// lookup that times out is no identity, so a Git that hangs delays one session
//// build by the lookup's wait and no more. A daemon that started no resolver
//// answers none at once.
////
//// ## Flow
////
//// `start` → `lookup` → `resolve`
////
//// 1. `start` registers the holder under a name, with the runner it asks and the
////    home it reads.
//// 2. `lookup` asks the holder by name and waits at most the time given.
//// 3. The holder answers from its cache or calls `resolve`, which is the one
////    sandboxed read.

import client/git_identity.{type Identity}
import client/internal/ffi_os
import client/internal/ffi_remote
import client/remote/address.{Address}
import client/worktree_git.{type Git}
import gleam/erlang/node
import gleam/erlang/process.{type Name, type Subject}
import gleam/option.{type Option, None, Some}
import gleam/result
import weft/actor

/// How long one sandboxed read may take, in milliseconds. A configuration read
/// is a few files, so a Git that takes longer is not going to answer.
pub const query_ms = 4000

/// How long a read, or the failure of one, is kept, in milliseconds.
pub const keep_ms = 60_000

/// What the holder is asked.
pub type Request {
  /// The operator's identity, if the global configuration has one.
  Lookup(
    /// Where the answer goes.
    reply: Subject(Option(Identity)),
  )
}

/// What the holder remembers: the last answer and when it was read.
type Held {
  Held(identity: Option(Identity), read_ms: Int)
}

/// The name the daemon's holder registers under.
///
/// ## Examples
///
/// ```gleam
/// // owner_identity.start(owner_identity.default(), git, home, reading)
/// ```
pub fn default() -> Name(Request) {
  ffi_remote.fixed_name("loom_owner_identity")
}

/// Reads the operator's global `user.name` and `user.email` through the sandboxed
/// Git runner, with `home` as `HOME`.
///
/// `reading` is how the daemon finds its own `XDG_CONFIG_HOME` and
/// `GIT_CONFIG_GLOBAL`, the only two names of its environment a query takes. An
/// `Error` is a call that did not run to an exit: the sandbox refused it, the
/// helper would not start, or it did not settle in `within_ms`. A configuration
/// with no identity is an `Ok` identity with nothing in it.
///
/// ## Examples
///
/// ```gleam
/// // owner_identity.resolve(git, "/home/operator", workspace_policy.env_text, owner_identity.query_ms)
/// ```
pub fn resolve(
  git: Git,
  home: String,
  reading: fn(String) -> Result(String, Nil),
  within_ms: Int,
) -> Result(Identity, String) {
  use output <- result.try(worktree_git.read_global_config(
    git,
    home,
    git_identity.operator_overrides(reading),
    ["config", "--global", ..git_identity.query_arguments],
    within_ms,
  ))
  git_identity.identity_of_query(output.code, output.stdout)
}

/// Starts the holder under `name`, linked to the caller. It reads nothing until
/// the first lookup.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = owner_identity.start(owner_identity.default(), git, home, env)
/// ```
pub fn start(
  name: Name(Request),
  git: Git,
  home: String,
  reading: fn(String) -> Result(String, Nil),
) -> Result(Nil, String) {
  actor.new(None)
  |> actor.on_message(fn(held: Option(Held), request: Request) {
    let Lookup(reply:) = request
    let current = current(held, git, home, reading)
    process.send(reply, current.identity)
    actor.continue(Some(current))
  })
  |> actor.named(name)
  |> actor.start
  |> result.replace(Nil)
  |> result.map_error(fn(_) { "the owner identity holder did not start" })
}

/// The held answer if it is young enough, and otherwise a fresh read.
fn current(
  held: Option(Held),
  git: Git,
  home: String,
  reading: fn(String) -> Result(String, Nil),
) -> Held {
  let now = ffi_os.system_time_ms()

  // A failed read is kept like a good one, so a sandbox that cannot start does
  // not cost every session build a full query's wait.
  case held {
    Some(Held(read_ms:, ..) as kept) if now - read_ms < keep_ms -> kept
    Some(_) | None ->
      Held(
        identity: resolve(git, home, reading, query_ms) |> option.from_result,
        read_ms: now,
      )
  }
}

/// The operator's identity, asked of the holder registered as `name`, waiting at
/// most `within_ms`. `None` is no identity, and it is also a holder that is not
/// running and one that did not answer in time, because a session build goes on
/// without an author in every one of those cases.
///
/// ## Examples
///
/// ```gleam
/// assert owner_identity.lookup(process.new_name("nobody"), 100) == option.None
/// ```
pub fn lookup(name: Name(Request), within_ms: Int) -> Option(Identity) {
  // A name nothing holds answers at once, instead of after the wait.
  case process.named(name) {
    Error(Nil) -> None
    Ok(_holder) -> {
      let reply = process.new_subject()
      address.deliver(Address(node: node.self(), name:), Lookup(reply:))

      // An answer after the wait is no answer: the build goes on without one.
      case process.receive(reply, within_ms) {
        Ok(found) -> found
        Error(Nil) -> None
      }
    }
  }
}
