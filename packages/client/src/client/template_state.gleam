//// Where a project's template stands (protocol-change/106, "The template").
////
//// A person reads four things off a project's template: it is being prepared,
//// it is ready at a commit, its `setup` failed, or its own check is red on the
//// clean base. This module is those states and the moves between them, as pure
//// functions with no clock and no I/O, so that the actor (`project_host`) holds
//// one value and a test can walk the whole space without a process.
////
//// The actor persists two facts, a build that finished and a build that failed
//// (`project_records`), and replays them through `recorded`. Everything else
//// here is memory: when the next look at the base commit is due, and whether a
//// rebuild is under way. A restart therefore rediscovers the template from the
//// ledger and looks again at once.
////
//// ## Flow
////
//// `start` → `building` → `built` or `unchanged` or `failed`
////
//// 1. `start` gives a project with a setup command the state `Preparing`, and
////    a project without one `Unmanaged`, which changes nothing about how workers
////    and checks start.
//// 2. `building` marks a build under way. From `Ready` it is a rebuild, and the
////    last good template stays in use.
//// 3. `built`, `unchanged` and `failed` take the build's answer. A failure
////    after a good template is a note on a `Ready` state, and a failure with no
////    template is `Broken`.
//// 4. `looks_due` says when the actor should look at the base again, and
////    `admits` says whether a worker may start.
////
//// ## Transitions
////
//// <!-- transitions: client/template_state.Standing -->
////
//// | Constructor | Meaning | Leaves by |
//// | --- | --- | --- |
//// | `Unmanaged` | The project has no `setup` | Never |
//// | `Preparing` | No usable template, a build is queued or under way | `built`, `failed` |
//// | `Ready` | A template stands at a commit | `building`, `failed` |
//// | `Broken` | No usable template, the last build failed | `building`, `built` |

import client/project_template.{type Failure, Failure}
import gleam/option.{type Option, None, Some}
import gleam/string

/// Where the template stands.
pub type Standing {
  /// The project has no `setup`, so it has no template. Every worker and check
  /// is cut as it was before templates, and nothing waits.
  Unmanaged

  /// There is no usable template yet. A build is queued or under way, and a new
  /// assignment waits for it.
  Preparing(
    /// When this build was asked for.
    since_ms: Int,
  )

  /// A template stands at a commit and workers may start.
  Ready(
    /// The commit it was built at.
    commit: String,
    /// The digest of the `setup` and `check` commands it was built with, so a
    /// changed command builds again.
    digest: String,
    /// When the actor should next look at the base commit.
    look_at_ms: Int,
    /// What a rebuild is doing.
    upkeep: Upkeep,
  )

  /// There is no usable template and the last build failed. No worker starts,
  /// and the board says what failed.
  Broken(
    /// What failed.
    failure: Failure,
    /// When the actor should try again without being asked.
    retry_at_ms: Int,
  )
}

/// What the actor is doing to a template that is already ready.
pub type Upkeep {
  /// Nothing: the last build, if any, succeeded.
  Quiet

  /// A rebuild is under way. Workers go on using the template they have.
  Rebuilding(
    /// When it began.
    since_ms: Int,
  )

  /// The last rebuild failed. The old template is still in use, and the board
  /// carries the failure as a note.
  Stale(
    /// What failed.
    failure: Failure,
  )
}

/// The state of a project the first time its actor runs, before any record is
/// read.
///
/// ## Examples
///
/// ```gleam
/// assert template_state.start(None, 0) == template_state.Unmanaged
/// assert template_state.start(Some("make deps"), 5) == template_state.Preparing(5)
/// ```
pub fn start(setup: Option(String), now_ms: Int) -> Standing {
  case setup {
    None -> Unmanaged
    Some(_) -> Preparing(now_ms)
  }
}

/// Takes a record the actor read from the ledger or just wrote: a build that
/// finished at a commit, or one that failed. A finished build is ready and is
/// looked at again at once. A failure leaves a ready template in use with a
/// note, and breaks a project with none.
///
/// ## Examples
///
/// ```gleam
/// let ready = template_state.recorded_build("abc1234", "d1")
/// assert template_state.admits(ready)
/// ```
pub fn recorded_build(commit: String, digest: String) -> Standing {
  Ready(commit:, digest:, look_at_ms: 0, upkeep: Quiet)
}

/// Takes a recorded failure. See `recorded_build`.
///
/// ## Examples
///
/// ```gleam
/// let failure = project_template.Failure(project_template.Setup, "exit status 1")
/// assert !template_state.admits(template_state.recorded_failure(template_state.Preparing(0), failure))
/// ```
pub fn recorded_failure(before: Standing, failure: Failure) -> Standing {
  case before {
    Ready(commit:, digest:, look_at_ms:, upkeep: _) ->
      Ready(commit:, digest:, look_at_ms:, upkeep: Stale(failure))
    Unmanaged | Preparing(_) | Broken(..) -> Broken(failure:, retry_at_ms: 0)
  }
}

/// The state after the records are read, at the start of a run. A template
/// built with other commands than the project has now is not trusted, so it
/// is prepared again, and a state that was only memory is rediscovered.
///
/// ## Examples
///
/// ```gleam
/// assert template_state.after_replay(template_state.Unmanaged, None, "d", 0) == template_state.Unmanaged
/// ```
pub fn after_replay(
  replayed: Standing,
  setup: Option(String),
  digest: String,
  now_ms: Int,
) -> Standing {
  case setup, replayed {
    None, _ -> Unmanaged
    Some(_), Ready(digest: built, ..) if built != digest -> Preparing(now_ms)
    Some(_), Ready(..) -> replayed
    Some(_), Broken(failure:, retry_at_ms: _) ->
      Broken(failure:, retry_at_ms: now_ms)
    Some(_), Unmanaged | Some(_), Preparing(_) -> Preparing(now_ms)
  }
}

/// Marks a build under way. A broken project is prepared again, a ready one is
/// rebuilding, and the others are as they were.
///
/// ## Examples
///
/// ```gleam
/// assert template_state.building(template_state.Unmanaged, 1) == template_state.Unmanaged
/// ```
pub fn building(before: Standing, now_ms: Int) -> Standing {
  case before {
    Unmanaged -> Unmanaged
    Preparing(_) -> before
    Broken(..) -> Preparing(now_ms)
    Ready(commit:, digest:, look_at_ms:, upkeep: _) ->
      Ready(commit:, digest:, look_at_ms:, upkeep: Rebuilding(now_ms))
  }
}

/// A build finished at a commit. The next look is `look_at_ms`.
///
/// ## Examples
///
/// ```gleam
/// assert template_state.admits(template_state.built("abc1234", "d1", 600_000))
/// ```
pub fn built(commit: String, digest: String, look_at_ms: Int) -> Standing {
  Ready(commit:, digest:, look_at_ms:, upkeep: Quiet)
}

/// A build found the base where the template already is.
///
/// ## Examples
///
/// ```gleam
/// assert template_state.unchanged(template_state.Unmanaged, 5) == template_state.Unmanaged
/// ```
pub fn unchanged(before: Standing, look_at_ms: Int) -> Standing {
  case before {
    Ready(commit:, digest:, look_at_ms: _, upkeep: _) ->
      Ready(commit:, digest:, look_at_ms:, upkeep: Quiet)
    Unmanaged | Preparing(_) | Broken(..) -> before
  }
}

/// A build failed. A ready template stays in use with the failure as a note,
/// and anything else is broken until the next try at `retry_at_ms`.
///
/// ## Examples
///
/// ```gleam
/// let failure = project_template.Failure(project_template.BaseCheck, "exit status 2")
/// let broken = template_state.failed(template_state.Preparing(0), failure, 600_000)
/// assert broken == template_state.Broken(failure, 600_000)
/// ```
pub fn failed(before: Standing, failure: Failure, look_at_ms: Int) -> Standing {
  case before {
    Ready(commit:, digest:, look_at_ms: _, upkeep: _) ->
      Ready(commit:, digest:, look_at_ms:, upkeep: Stale(failure))
    Unmanaged | Preparing(_) | Broken(..) ->
      Broken(failure:, retry_at_ms: look_at_ms)
  }
}

/// Whether a person's retry starts a build now: the project has a template or
/// had one, and no build is under way.
///
/// ## Examples
///
/// ```gleam
/// assert !template_state.retryable(template_state.Preparing(0))
/// ```
pub fn retryable(standing: Standing) -> Bool {
  case standing {
    Unmanaged | Preparing(_) -> False
    Ready(upkeep: Rebuilding(_), ..) -> False
    Ready(..) | Broken(..) -> True
  }
}

/// Whether a new worker may start. A project without a template, and one with a
/// ready template, admit one. A project still preparing or broken does not, and
/// its tickets wait.
///
/// ## Examples
///
/// ```gleam
/// assert template_state.admits(template_state.Unmanaged)
/// assert !template_state.admits(template_state.Preparing(0))
/// ```
pub fn admits(standing: Standing) -> Bool {
  case standing {
    Unmanaged | Ready(..) -> True
    Preparing(_) | Broken(..) -> False
  }
}

/// Whether the actor should start a build because the time for the next look
/// has come. A rebuild already under way is not started twice, and neither is
/// the first build, which is queued when the state is made.
///
/// ## Examples
///
/// ```gleam
/// assert !template_state.looks_due(template_state.Unmanaged, 100)
/// assert template_state.looks_due(template_state.built("abc1234", "d", 50), 100)
/// ```
pub fn looks_due(standing: Standing, now_ms: Int) -> Bool {
  case standing {
    Unmanaged | Preparing(_) -> False
    Ready(upkeep: Rebuilding(_), ..) -> False
    Ready(look_at_ms:, ..) -> look_at_ms <= now_ms
    Broken(retry_at_ms:, ..) -> retry_at_ms <= now_ms
  }
}

/// The commit a build may skip because the template already stands there, or
/// none when it should always build, because the project's commands changed.
///
/// ## Examples
///
/// ```gleam
/// assert template_state.current(template_state.built("abc1234", "d", 0), "d") == Some("abc1234")
/// assert template_state.current(template_state.built("abc1234", "d", 0), "e") == None
/// ```
pub fn current(standing: Standing, digest: String) -> Option(String) {
  case standing {
    Ready(commit:, digest: built, ..) if built == digest -> Some(commit)
    Ready(..) | Unmanaged | Preparing(_) | Broken(..) -> None
  }
}

/// The failure a person should see, if any: the one that broke the project, or
/// the note on a template that is still in use.
///
/// ## Examples
///
/// ```gleam
/// assert template_state.failure_of(template_state.Unmanaged) == None
/// ```
pub fn failure_of(standing: Standing) -> Option(Failure) {
  case standing {
    Broken(failure:, ..) | Ready(upkeep: Stale(failure), ..) -> Some(failure)
    Ready(..) | Unmanaged | Preparing(_) -> None
  }
}

/// A word for the board's state: `preparing`, `ready`, `failed` or
/// `base_check_red`, and none for a project with no template.
///
/// ## Examples
///
/// ```gleam
/// assert template_state.word(template_state.Preparing(0)) == Some("preparing")
/// ```
pub fn word(standing: Standing) -> Option(String) {
  case standing {
    Unmanaged -> None
    Preparing(_) -> Some("preparing")
    Ready(..) -> Some("ready")
    Broken(failure: Failure(stage: project_template.BaseCheck, ..), ..) ->
      Some("base_check_red")
    Broken(..) -> Some("failed")
  }
}

/// The sentence the board shows for the state, or none when there is nothing to
/// say. It names the project's setup and not any ticket, because no ticket
/// caused it.
///
/// ## Examples
///
/// ```gleam
/// assert template_state.note(template_state.Unmanaged) == None
/// ```
pub fn note(standing: Standing) -> Option(String) {
  case standing {
    Unmanaged -> None
    Preparing(_) ->
      Some(
        "The project's template is being prepared. New tickets wait for it and none has failed.",
      )
    Ready(upkeep: Stale(failure), commit:, ..) ->
      Some(
        "The project's rebuild of its template failed ("
        <> stage_words(failure)
        <> "), so workers still use the template at "
        <> short(commit)
        <> ".",
      )
    Ready(..) -> None
    Broken(failure:, ..) ->
      Some(
        "The project's setup failed ("
        <> stage_words(failure)
        <> "), so no worker starts. This is the project's setup and not any ticket.",
      )
  }
}

/// The words for the step that failed, with the first line of what it printed.
fn stage_words(failure: Failure) -> String {
  // Each step says in words what was being done when it failed.
  let what = case failure.stage {
    project_template.Cutting -> "the host could not make the template tree"
    project_template.Setup -> "the setup command failed"
    project_template.BaseCheck -> "the check is red on the clean base commit"
  }

  // The first line of the output is the exit status or the reason the step did
  // not run, and the rest is on the row beside the note. An empty output adds
  // nothing to say.
  case string.split(failure.output, "\n") {
    [first, ..] if first != "" -> what <> ": " <> string.slice(first, 0, 200)
    _ -> what
  }
}

fn short(commit: String) -> String {
  case commit {
    "" -> "no commit"
    other -> string.slice(other, 0, 12)
  }
}

/// When the build now under way was asked for, or none when none is. A person
/// reads the build's duration off this and the time it ends.
///
/// ## Examples
///
/// ```gleam
/// assert template_state.began_ms(template_state.Preparing(7)) == Some(7)
/// assert template_state.began_ms(template_state.Unmanaged) == None
/// ```
pub fn began_ms(standing: Standing) -> Option(Int) {
  case standing {
    Preparing(since_ms:) | Ready(upkeep: Rebuilding(since_ms:), ..) ->
      Some(since_ms)
    Unmanaged | Ready(..) | Broken(..) -> None
  }
}
