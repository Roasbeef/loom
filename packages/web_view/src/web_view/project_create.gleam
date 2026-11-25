//// Creating a project from the owner's home: the steps of the page and the
//// rules that move it between them (protocol-change/106, the addendum on
//// creating a project from the web view).
////
//// A project is a long-lived router session for one repository, so making one is
//// the owner's act and the page never decides more of it than the daemon's own
//// command would. The page takes the owner through four steps and holds no fact
//// the daemon did not tell it: which folder (chosen from folders the page's own
//// lists drew, or typed, and judged by the daemon either way), what the daemon
//// proposes for that folder's check and setup (a read that runs nothing), what
//// the owner confirms or types instead, and what the daemon made. Nothing is
//// created before the owner presses Create, and a folder is read for a proposal
//// only after the daemon has judged it as it judges a new session's folder.
////
//// This module is pure. The home owns the effects, and a view draws the state.
//// Keeping the moves here lets a test walk every step, including the two that
//// can go wrong: a folder the daemon refuses, and a project that was made while
//// its settings were not stored.
////
//// ## Flow
////
//// `open` → `chose` → `proposal_heard` → `confirmed` → `settled`
////
//// 1. `open` starts at the choice of a folder.
//// 2. `chose` names a folder and waits for the daemon's proposal for it.
//// 3. `proposal_heard` shows the proposal, or sends the person back to choose
////    with the daemon's reason.
//// 4. `confirmed` takes the owner's check and setup, as typed, and waits for the
////    daemon to make the project.
//// 5. `settled` shows the project that was made, or returns to the confirmation
////    with the reason, keeping what the person typed.
////
//// ## Examples
////
//// ```gleam
//// let creation = project_create.open()
//// assert project_create.workspace(creation) == None
//// ```

import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/project_settings_view.{type Proposed}
import web_view/creations
import web_view/projects

/// The most bytes of a command the page sends. The daemon's own rule for a
/// command is stricter and is applied when the settings are stored.
pub const command_limit = 4096

/// Where the owner is in making a project.
pub type Creation {
  Creation(
    /// The step the page shows.
    step: Step,
  )
}

/// One step of the page.
pub type Step {
  /// The owner is choosing a folder.
  Choosing(
    /// What went wrong with the last choice, in words, or none.
    notice: Option(String),
  )

  /// A folder was chosen and the daemon is reading it for a proposal.
  Reading(
    /// The folder as the owner chose it.
    workspace: String,
  )

  /// The proposal is shown, with the check and setup that will be stored.
  Reviewing(
    /// The folder as the owner chose it.
    workspace: String,
    /// What the daemon proposed, for the reasons beside each command.
    proposed: Proposed,
    /// The check as the box holds it. It starts as the proposal and is the
    /// owner's own text after an edit.
    check: String,
    /// The setup as the box holds it, on the same terms.
    setup: String,
    /// What went wrong with the last attempt to create, in words, or none.
    notice: Option(String),
  )

  /// The owner pressed Create and the daemon is making the project.
  Creating(
    /// The folder as the owner chose it.
    workspace: String,
    /// What the daemon proposed.
    proposed: Proposed,
    /// The check that was sent, as typed.
    check: String,
    /// The setup that was sent, as typed.
    setup: String,
  )

  /// The project exists.
  Done(
    /// The project's id.
    project: String,
    /// The folder the project is bound to.
    workspace: String,
    /// The daemon's sentence about settings that were confirmed and not stored,
    /// or none when they were stored or there were none.
    unsettled: Option(String),
  )
}

/// The page's first step: a folder to choose.
///
/// ## Examples
///
/// ```gleam
/// assert project_create.open() == project_create.Creation(project_create.Choosing(None))
/// ```
pub fn open() -> Creation {
  Creation(Choosing(None))
}

/// The folder a step is about, once one was chosen.
///
/// ## Examples
///
/// ```gleam
/// assert project_create.workspace(project_create.open()) == None
/// ```
pub fn workspace(creation: Creation) -> Option(String) {
  case creation.step {
    Choosing(_) -> None
    Reading(workspace:)
    | Reviewing(workspace:, ..)
    | Creating(workspace:, ..)
    | Done(workspace:, ..) -> Some(workspace)
  }
}

/// A folder was chosen. Only a step that is choosing takes a choice, so a late press during a read or a creation changes nothing.
/// An empty choice is no choice.
///
/// ## Examples
///
/// ```gleam
/// let moved = project_create.chose(project_create.open(), "/work/loom")
/// assert project_create.workspace(moved) == Some("/work/loom")
/// ```
pub fn chose(creation: Creation, workspace: String) -> Creation {
  case creation.step, string.trim(workspace) {
    _, "" -> creation
    Choosing(_), chosen -> Creation(Reading(workspace: chosen))
    Reading(_), _ | Reviewing(..), _ | Creating(..), _ | Done(..), _ -> creation
  }
}

/// The daemon's answer to a request for a proposal. An answer for a folder the
/// page is no longer reading is dropped. A refusal sends the person back to
/// choose with the fixed words for the reason, and a proposal fills the two
/// boxes with the daemon's own commands.
///
/// ## Examples
///
/// ```gleam
/// let reading = project_create.chose(project_create.open(), "/work/loom")
/// let moved = project_create.proposal_heard(
///   reading,
///   "/work/loom",
///   projects.ProposalRefused(creations.NotAFolder),
/// )
/// assert moved.step != reading.step
/// ```
pub fn proposal_heard(
  creation: Creation,
  workspace: String,
  read: projects.Proposal,
) -> Creation {
  case creation.step, read {
    Reading(workspace: asked), projects.Proposed(body:) if asked == workspace ->
      case project_settings_view.decode_proposed(body) {
        Ok(proposed) ->
          Creation(Reviewing(
            workspace:,
            proposed:,
            check: commands(proposed.check),
            setup: commands(proposed.setup),
            notice: None,
          ))
        Error(_) ->
          Creation(
            Choosing(Some("The daemon's proposal could not be read. Try again.")),
          )
      }
    Reading(workspace: asked), projects.ProposalRefused(reason:)
      if asked == workspace
    -> Creation(Choosing(Some(creations.reason_words(reason))))
    Reading(_), _
    | Choosing(_), _
    | Reviewing(..), _
    | Creating(..), _
    | Done(..), _
    -> creation
  }
}

/// The text a proposal puts in a box: the command, or nothing when the daemon
/// found none.
fn commands(found: Option(project_settings_view.Suggestion)) -> String {
  case found {
    Some(suggestion) -> suggestion.command
    None -> ""
  }
}

/// What the owner confirmed: the check and the setup as typed, each of which is
/// none when blank. The result is `Error` for a command past the limit, with the
/// step that says so, and otherwise the step that waits for the daemon.
///
/// ## Examples
///
/// ```gleam
/// // project_create.confirmed(reviewing, "make test", "")
/// ```
pub fn confirmed(
  creation: Creation,
  check: String,
  setup: String,
) -> Result(#(Creation, Option(String), Option(String)), Creation) {
  case creation.step {
    Reviewing(workspace:, proposed:, ..) ->
      case
        string.length(check) > command_limit,
        string.length(setup) > command_limit
      {
        False, False ->
          Ok(#(
            Creation(Creating(workspace:, proposed:, check:, setup:)),
            blank_is_none(check),
            blank_is_none(setup),
          ))
        True, _ | _, True ->
          Error(
            Creation(Reviewing(
              workspace:,
              proposed:,
              check:,
              setup:,
              notice: Some("A command is longer than the page sends."),
            )),
          )
      }
    Choosing(_) | Reading(_) | Creating(..) | Done(..) -> Error(creation)
  }
}

/// A command as the daemon is told it: trimmed, and none when nothing is left.
fn blank_is_none(text: String) -> Option(String) {
  case string.trim(text) {
    "" -> None
    command -> Some(command)
  }
}

/// The daemon's answer to a request to create. The step keeps what the person
/// typed when the daemon refuses, so a refusal costs a retry and not a retype. A
/// project that was made while its settings were refused is shown as made, with
/// the sentence, because the project exists and a retry would find it.
///
/// ## Examples
///
/// ```gleam
/// // project_create.settled(creating, "/work/loom", projects.NotMade(creations.NotKnown))
/// ```
pub fn settled(
  creation: Creation,
  workspace: String,
  made: projects.Creation,
) -> Creation {
  case creation.step {
    Creating(workspace: sent, proposed:, check:, setup:) if sent == workspace ->
      case made {
        projects.Made(project:, settled: projects.SettingsHeld) ->
          Creation(Done(project:, workspace:, unsettled: None))
        projects.Made(project:, settled: projects.SettingsRefused(words:)) ->
          Creation(Done(project:, workspace:, unsettled: Some(words)))
        projects.Existing(project:) ->
          Creation(
            Choosing(Some(
              "That folder already has a project, "
              <> project
              <> ". Its settings were not changed.",
            )),
          )
        projects.NotMade(reason:) ->
          again(
            workspace,
            proposed,
            check,
            setup,
            creations.reason_words(reason),
          )
        projects.MakeFailed(words:) ->
          again(workspace, proposed, check, setup, words)
      }
    Choosing(_) | Reading(_) | Reviewing(..) | Creating(..) | Done(..) ->
      creation
  }
}

/// The confirmation again, with what the person typed and why it was refused.
fn again(
  workspace: String,
  proposed: Proposed,
  check: String,
  setup: String,
  why: String,
) -> Creation {
  Creation(Reviewing(workspace:, proposed:, check:, setup:, notice: Some(why)))
}
