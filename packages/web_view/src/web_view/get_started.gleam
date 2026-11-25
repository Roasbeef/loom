//// The "Get started" checklist: what a new person has set up and what is left
//// (docs/design-notes/setup-wizard.md).
////
//// A person who has just installed Loom meets a page whose features hide in
//// places they have no reason to look. The checklist names each step of setup
//// once, in the order a person would do them, and says for each what the daemon
//// already has. Nothing here is asked of the daemon: every state is derived from
//// facts the page already holds (its sessions, its folders, its projects and
//// the model keys the configuration lists), so a person who set things up by
//// hand sees those steps done.
////
//// A step the page cannot read yet is drawn as `Unread` with the way to do it
//// from a terminal, and never as done or as missing, because saying either would
//// be a guess. The entry in the rail hides once every step the page can read is
//// done (`finished`), and the first-session hint (`hint`) is the same derivation
//// narrowed to the one step that is the person's next move.
////
//// This module is pure. The view draws it (`view/get_started`) and the home
//// holds the facts.
////
//// ## Flow
////
//// `checklist` → `finished` → `hint`
////
//// 1. `checklist` derives each step's state from the facts.
//// 2. `finished` says whether the rail's entry may hide.
//// 3. `hint` says whether to suggest the project step after a first session.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Whether the page may make a project, which only the owner's operating page
/// can.
pub type Making {
  /// The page holds the capability that makes a project.
  MayMake

  /// The page holds no such capability, so the project step is not its to do.
  MayNot
}

/// What the page holds that bears on setup.
pub type Facts {
  Facts(
    /// How many sessions the page lists, whatever their state.
    sessions: Int,
    /// The folder the person used most recently, as the composer offers it.
    folder: Option(String),
    /// The keys of the `[models.<name>]` tables the configuration lists. Empty
    /// for a daemon with no file, which cannot tell the page what it runs.
    models: List(String),
    /// How many projects the page lists.
    projects: Int,
    /// Whether the page may make one.
    making: Making,
  )
}

/// The steps, in the order a person does them.
pub type Key {
  /// The folder a session works in.
  Folder

  /// Whether a session works in the folder or in a worktree of it.
  Worktree

  /// The first project for a repository.
  FirstProject

  /// Publishing a verified ticket as a pull request through `gh`.
  Publish

  /// The summarize role and the Jev table.
  Extras
}

/// What the page can say about a step.
pub type State {
  /// The step is done.
  Done

  /// The step is not done and the page may do it.
  Open

  /// The step is not done and is not this page's to do.
  NotHere

  /// The page cannot read this step yet.
  Unread
}

/// One row of the checklist.
pub type Step {
  Step(
    /// Which step it is.
    key: Key,
    /// Its name, a fixed word of the page.
    title: String,
    /// What the page can say about it.
    state: State,
    /// One sentence saying what the state means and what to do next.
    detail: String,
  )
}

/// The checklist for the facts, always five rows in the same order so that the
/// page does not change shape as steps are done.
///
/// ## Examples
///
/// ```gleam
/// let none = get_started.Facts(0, None, [], 0, get_started.MayMake)
/// assert list.length(get_started.checklist(none)) == 5
/// ```
pub fn checklist(facts: Facts) -> List(Step) {
  [
    folder_step(facts),
    Step(
      key: Worktree,
      title: "Worktree default",
      state: Unread,
      detail: "Chosen for each session with the Worktree box in the composer. A worktree keeps one session's changes out of the folder.",
    ),
    project_step(facts),
    Step(
      key: Publish,
      title: "GitHub publish",
      state: Unread,
      detail: "Needs gh logged in on the daemon's machine. To turn it on, run: loom project set publish pull_request --publish-to <url>",
    ),
    Step(
      key: Extras,
      title: "Extras",
      state: Unread,
      detail: "A cheaper model for summaries is the summarize role in loom.toml. docs/configuration.md lists both.",
    ),
  ]
}

/// The folder step: done when the person has used a folder.
fn folder_step(facts: Facts) -> Step {
  case facts.folder {
    Some(path) ->
      Step(
        key: Folder,
        title: "Default folder",
        state: Done,
        detail: "Last used: " <> path,
      )
    None ->
      Step(
        key: Folder,
        title: "Default folder",
        state: Open,
        detail: "No folder yet. Choose one when you start a session.",
      )
  }
}

/// The project step: done when a project exists, open for the page that may make
/// one, and not this page's otherwise.
fn project_step(facts: Facts) -> Step {
  let title = "First project"

  case facts.projects, facts.making {
    0, MayMake ->
      Step(
        key: FirstProject,
        title:,
        state: Open,
        detail: "A project is one router for one repository. Choose a folder and Loom proposes how to check its work.",
      )
    0, MayNot ->
      Step(
        key: FirstProject,
        title:,
        state: NotHere,
        detail: "Only the owner's page makes a project.",
      )
    count, MayMake | count, MayNot ->
      Step(
        key: FirstProject,
        title:,
        state: Done,
        detail: int.to_string(count) <> " in this daemon.",
      )
  }
}

/// Whether every step the page can read is done, which lets the rail's entry
/// hide. A step that is `Unread` or `NotHere` does not hold it open, because the
/// page cannot do or read it.
///
/// ## Examples
///
/// ```gleam
/// let done = get_started.Facts(1, Some("/w"), [], 1, get_started.MayMake)
/// assert get_started.finished(done)
/// ```
pub fn finished(facts: Facts) -> Bool {
  list.all(checklist(facts), fn(step) {
    case step.state {
      Done | NotHere | Unread -> True
      Open -> False
    }
  })
}

/// Whether to suggest a project: the person has a session, has no project, and
/// the page may make one.
///
/// ## Examples
///
/// ```gleam
/// let facts = get_started.Facts(1, None, [], 0, get_started.MayMake)
/// assert get_started.hint(facts)
/// ```
pub fn hint(facts: Facts) -> Bool {
  case facts.sessions, facts.projects, facts.making {
    0, _, _ | _, _, MayNot -> False
    _, 0, MayMake -> True
    _, _, MayMake -> False
  }
}

/// The status line's words: whether the configuration lists a model, and which.
///
/// ## Examples
///
/// ```gleam
/// assert get_started.model_words([]) == "No model is listed in a loom.toml; a session uses the LOOM_* environment variables if they are set."
/// ```
pub fn model_words(models: List(String)) -> String {
  case models {
    [] ->
      "No model is listed in a loom.toml; a session uses the LOOM_* environment variables if they are set."
    keys -> "Models the configuration lists: " <> string.join(keys, ", ")
  }
}
