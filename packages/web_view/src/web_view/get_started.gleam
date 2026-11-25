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
//// A step the page cannot read is drawn as `Unread` with the way to do it from
//// a terminal, and never as done or as missing, because saying either would be
//// a guess. That includes a step whose read has not answered yet: the page
//// carries whether each read has been heard (`Heard`), and an unheard read is
//// `Unread`, not "not done". A person may skip a step that is not done for as
//// long as the page lives (`Skipped`). The rail's entry stays until every step
//// is done, skipped or not this page's to do (`finished`), so an unread step
//// never takes the way back to the checklist with it. The first-session hint
//// (`hint`) is the same derivation narrowed to the one step that is the
//// person's next move.
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

/// Whether a read has answered at least once on this page.
pub type Heard {
  /// The read has answered, so what the page holds is what the daemon said.
  Heard

  /// The read has not answered yet, so an empty list says nothing.
  Unheard
}

/// Whether the page lists any session. Only the question matters, so it is
/// asked of the list's emptiness and not of its length.
pub type Presence {
  /// At least one session is listed.
  Present

  /// No session is listed.
  Absent
}

/// What the page holds that bears on setup.
pub type Facts {
  Facts(
    /// Whether the page lists a session, whatever its state.
    sessions: Presence,
    /// Whether the session list has been read.
    listing: Heard,
    /// The folder the person used most recently, as the composer offers it.
    folder: Option(String),
    /// The keys of the `[models.<name>]` tables the configuration lists. Empty
    /// for a daemon with no file, which cannot tell the page what it runs.
    models: List(String),
    /// How many projects the page lists.
    projects: Int,
    /// Whether the projects' boards have been read.
    boards: Heard,
    /// Whether the page may make one.
    making: Making,
    /// The steps the person skipped on this page.
    skipped: List(Key),
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

  /// The page cannot read this step, or has not heard its read yet.
  Unread

  /// The person skipped the step.
  Skipped
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
/// let none = get_started.Facts(get_started.Absent, get_started.Heard, None, [], 0, get_started.Heard, get_started.MayMake, [])
/// assert list.length(get_started.checklist(none)) == 5
/// ```
pub fn checklist(facts: Facts) -> List(Step) {
  [
    folder_step(facts),
    Step(
      key: Worktree,
      title: "Worktree default",
      state: Unread,
      detail: "Chosen for each session with the Worktree toggle in the composer. A worktree keeps one session's changes out of the folder.",
    ),
    project_step(facts),
    Step(
      key: Publish,
      title: "GitHub publish",
      state: Unread,
      detail: "Needs gh logged in on the daemon's machine. In the project's folder, run `loom project set publish pull_request`; it prints the URL and the exact command to confirm.",
    ),
    Step(
      key: Extras,
      title: "Extras",
      state: Unread,
      detail: "A cheaper model for summaries is the `summarize` role in loom.toml; docs/configuration.md describes it.",
    ),
  ]
  |> list.map(skipping(_, facts.skipped))
}

/// A step the person skipped reads as skipped, unless it is done or not this
/// page's: those say more than a skip does.
fn skipping(step: Step, skipped: List(Key)) -> Step {
  case step.state, list.contains(skipped, step.key) {
    Open, True | Unread, True -> Step(..step, state: Skipped)
    _, _ -> step
  }
}

/// Whether a step offers "Skip": any step that is not done, except the folder,
/// which is not optional and completes by itself.
///
/// ## Examples
///
/// ```gleam
/// assert !get_started.skippable(get_started.Step(get_started.Folder, "Default folder", get_started.Open, ""))
/// ```
pub fn skippable(step: Step) -> Bool {
  case step.key, step.state {
    Folder, _ -> False
    _, Open | _, Unread -> True
    _, Done | _, NotHere | _, Skipped -> False
  }
}

/// The folder step: done when the person has used a folder, and unread until
/// the session list has answered.
fn folder_step(facts: Facts) -> Step {
  let title = "Default folder"

  case facts.listing, facts.folder {
    Unheard, _ ->
      Step(
        key: Folder,
        title:,
        state: Unread,
        detail: "Reading this daemon's sessions.",
      )
    Heard, Some(path) ->
      Step(key: Folder, title:, state: Done, detail: "Last used: " <> path)
    Heard, None ->
      Step(
        key: Folder,
        title:,
        state: Open,
        detail: "No folder yet. Choose one when you start a session.",
      )
  }
}

/// The project step: done when a project exists, unread until the boards have
/// answered, open for the page that may make one, and not this page's
/// otherwise.
fn project_step(facts: Facts) -> Step {
  let title = "First project"

  case facts.projects, facts.making, facts.boards {
    0, MayMake, Unheard ->
      Step(
        key: FirstProject,
        title:,
        state: Unread,
        detail: "Reading this daemon's projects.",
      )
    0, MayMake, Heard ->
      Step(
        key: FirstProject,
        title:,
        state: Open,
        detail: "A project is one router for one repository. Choose a folder and Loom proposes how to check its work.",
      )
    0, MayNot, Heard | 0, MayNot, Unheard ->
      Step(
        key: FirstProject,
        title:,
        state: NotHere,
        detail: "Only the owner's page makes a project.",
      )
    count, MayMake, Heard
    | count, MayMake, Unheard
    | count, MayNot, Heard
    | count, MayNot, Unheard
    ->
      Step(
        key: FirstProject,
        title:,
        state: Done,
        detail: int.to_string(count) <> " in this daemon.",
      )
  }
}

/// Whether every step is done, skipped or not this page's, which lets the
/// rail's entry hide. A step that is still `Unread` or `Open` keeps it, so the
/// way back to the checklist outlives the steps this page cannot read.
///
/// ## Examples
///
/// ```gleam
/// // get_started.finished(facts)
/// ```
pub fn finished(facts: Facts) -> Bool {
  list.all(checklist(facts), fn(step) {
    case step.state {
      Done | NotHere | Skipped -> True
      Open | Unread -> False
    }
  })
}

/// Whether to suggest a project: both reads have answered, the person has a
/// session, has no project, has not skipped the step, and the page may make one.
///
/// ## Examples
///
/// ```gleam
/// // get_started.hint(facts)
/// ```
pub fn hint(facts: Facts) -> Bool {
  case facts.listing, facts.boards, facts.making {
    Heard, Heard, MayMake ->
      case facts.sessions, facts.projects {
        Present, 0 -> !list.contains(facts.skipped, FirstProject)
        Present, _ | Absent, _ -> False
      }
    Unheard, _, _ | _, Unheard, _ | _, _, MayNot -> False
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
