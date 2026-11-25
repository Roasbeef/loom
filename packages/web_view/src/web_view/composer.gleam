//// The new-session composer's state and rules: where the agent runs, where the
//// code lives, which model, and when a press may start a session (the placement
//// revamp,
//// [`docs/design-notes/placement-revamp.md`](../../../../docs/design-notes/placement-revamp.md),
//// sections 3 and 4).
////
//// The composer asks two questions and keeps them apart. The Agent chip says which
//// machine runs the agent loop. The Code chip says where the files are and where
//// commands run: a folder on the agent's machine, a workspace registered on an
//// executor, or a workspace on any machine of a pool. The agent is the daemon
//// serving the page until the person chooses another orchestrator the daemon
//// relays for (protocol-change/094). Then the Code chip lists what that
//// orchestrator offers, its folders, executors and pools, and a start asks that
//// orchestrator to create the session and relays it. The Model chip merges a
//// profile and a main model, which the daemon already treats as independent.
////
//// ## What the page may send
////
//// Every choice a person makes is a button the server drew, and a button's message
//// carries a value the server built from the lists it holds: a `Target` drawn
//// from the offered folders, executors and pools, a profile name or a model key
//// from the daemon's configuration. The browser's event names only the path it
//// fired at. `update` still checks each message against `Offers`, the lists the
//// page was drawn from, so a message that arrived after the lists changed, or one a
//// client forged into a socket, names nothing the page offered and changes
//// nothing. That is the page's half of the rule that the daemon re-checks every
//// choice when the creation runs (`ui_socket.create_for`); the page only offers.
////
//// Three pieces of text come from the browser, and each is bounded and judged
//// before it can reach the daemon: the session's name (`creations.chosen_name`
//// runs in the daemon), a typed folder path (`creations.typed_path`, then the
//// daemon's filesystem rules) and, where an executor reported no workspaces, a
//// typed workspace name (`creations.registered_name`). The search text of the
//// code picker only narrows the rows the page drew, and is cut to
//// `search_limit` bytes. None of them is ever written into an attribute, a class
//// or a key.
////
//// ## Flow
////
//// `update` → `chosen` → `place` → the home asks `Start.create`
////
//// 1. `update` applies one message to the state and says what the page owes:
////    `Stay`, a read of the placements when the Code chip opens, or a creation.
//// 2. `chosen` is the code target in force: the person's choice, or the default
////    the page falls back to (the newest place a session worked in).
//// 3. `place` turns that target and the text the form sent into the
////    `creations.Place` the daemon is asked for, or the words saying why it cannot.
//// 4. `recents`, `folders_offered`, `sentence` and the label functions are the
////    pure parts the view draws from.

import core/agency_limits.{
  type AgencyLimits, AgencyLimits, BoundedDepth, UnlimitedDepth,
}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/text_hygiene
import web_view/creations
import web_view/folder_browse
import web_view/listing
import web_view/placements
import web_view/sessions.{type Entry}

/// The most bytes of a first message the composer sends. A longer one is refused
/// on the form with words, and nothing is created, so a person never loses a
/// session's worth of text to a bound they could not see.
pub const prompt_limit = 16_384

/// The most characters of a session's name taken from the first line of its
/// first message.
pub const name_limit = 80

/// The most bytes of search text the code picker keeps. It narrows rows the page
/// drew and nothing else, so a short bound is enough.
pub const search_limit = 64

/// How many places "Start again where you worked" lists.
pub const recent_limit = 3

/// Where the agent runs, as a person chose it from the Agent chip's list.
pub type Agent {
  /// The daemon serving the page.
  Here

  /// Another orchestrator this daemon relays for (protocol-change/094). The name
  /// is an `[orchestrators.<name>]` key the page drew a row for.
  Orchestrator(
    /// The orchestrator's key.
    name: String,
  )
}

/// Whether the form may ask for a typed folder path. The daemon serving the page
/// judges a typed path against its own filesystem, so only that daemon may be
/// given one: another orchestrator offers the folders it remembers and nothing the
/// page types.
pub type Typing {
  /// The form may ask for a typed path.
  MayType

  /// The form never asks for one.
  MayNotType
}

/// One row of the Agent chip's list: a machine the agent may run on, and whether
/// it can be chosen now.
pub type Candidate {
  Candidate(
    /// The machine.
    agent: Agent,
    /// Its name, as the row and the chip say it.
    name: String,
    /// Whether it can be chosen.
    standing: Standing,
  )
}

/// Whether an Agent chip's row can be chosen.
pub type Standing {
  /// The machine can be chosen.
  Choosable(
    /// The words under the name, such as how many sessions run on it.
    detail: String,
  )

  /// A read of what the machine offers is out, so the row cannot be chosen yet.
  Checking

  /// The machine cannot be chosen now, and the row says why in plain words.
  Unavailable(
    /// The reason.
    reason: String,
  )
}

/// A chip that opens a list of choices.
pub type Chip {
  /// Where the agent runs.
  AgentChip

  /// Where the code lives.
  CodeChip

  /// Which profile and main model.
  ModelChip
}

/// Which chip's list is open, if any.
pub type Open {
  /// No list is open.
  Shut

  /// This chip's list is open.
  Showing(
    /// The chip.
    chip: Chip,
  )
}

/// Where the code is, as a person chose it from the Code chip's list.
pub type Target {
  /// A folder the page drew on the agent's machine: one the owner holds a session
  /// in, or one of the owner's remembered folders.
  Folder(
    /// The folder's canonical path, as the catalogue or the daemon wrote it.
    workspace: String,
  )

  /// A folder the owner will type into the form. The path is the browser's text
  /// and is never drawn back.
  TypedFolder

  /// A folder the owner chose from the picker (protocol-change/132): the
  /// trail of directory names below the daemon's home, which the daemon listed
  /// and the page kept. It is built only by `ChosePicked`, from a listing the page
  /// holds, and the creation judges it as it judges a typed path.
  Picked(
    /// The canonical trail below the home, outermost first, never empty.
    trail: List(String),
  )

  /// A project's workspace, chosen from the Code list's Projects heading. It is
  /// a folder the daemon wrote into the page with its projects
  /// (`Offers.projects`), and the creation judges it as it judges a typed path.
  Project(
    /// The workspace, as the daemon's project list gave it.
    workspace: String,
  )

  /// A workspace on an executor. With a `workspace` it is one the page drew,
  /// from the executor's report or a session's catalogue row; with `None` the
  /// executor reported none and the form asks for a name.
  OnExecutor(
    /// The `[executors.<name>]` key the page drew.
    executor: String,
    /// The workspace's registered name, or `None` to type one.
    workspace: Option(String),
  )

  /// A workspace on any machine of a pool, as `OnExecutor` is on one.
  InPool(
    /// The `[pools.<name>]` key the page drew.
    pool: String,
    /// The workspace's registered name, or `None` to type one.
    workspace: Option(String),
  )
}

/// The folder picker inside the Code chip's list (protocol-change/132). The page
/// holds the listing it last drew, and a press names an index into it, so the
/// browser never names a path.
pub type Browser {
  /// No picker is open: the Code list shows.
  Closed

  /// A read of this trail is out. `behind` is the listing the person was looking
  /// at, kept so that a refusal leaves them where they were.
  Reading(
    /// The trail the daemon was asked for, which only its answer may settle.
    trail: List(String),
    /// The listing on screen before the press, if there was one.
    behind: Option(folder_browse.Listing),
  )

  /// A directory, and the words of the last refusal over it, if any.
  Browsing(
    /// What the daemon listed.
    listing: folder_browse.Listing,
    /// Why the last press was refused, or `None`.
    refusal: Option(folder_browse.Refusal),
  )

  /// The first read was refused, so there is no directory to show.
  Failed(
    /// Why.
    refusal: folder_browse.Refusal,
  )
}

/// Where the folder index stands. The Code list's search ranks one index of the
/// folder names below the home, which the daemon builds once when the list opens
/// (protocol-change/132, the addendum on searching) and the page keeps for
/// `folder_browse.index_ttl_ms`. A keystroke then costs a ranking in memory and
/// asks the daemon for nothing, so at most one build is ever out.
pub type Seek {
  /// No index is held and none is out.
  Unindexed

  /// The daemon was asked for an index and has not answered. An index held from
  /// before stays drawn until the new one arrives.
  Indexing(
    /// The index held before, if there was one.
    before: Option(folder_browse.Index),
  )

  /// The daemon answered.
  Indexed(
    /// The folder names.
    index: folder_browse.Index,
    /// The page's clock when it arrived, in milliseconds.
    at: Int,
  )

  /// The daemon refused to build one, in fixed words. The next open of the list
  /// asks again, and a keystroke does not.
  Unindexable(
    /// Why.
    why: folder_browse.Refusal,
    /// The index held before the refused refresh, which stays in use.
    before: Option(folder_browse.Index),
  )
}

/// Whether a creation is out.
pub type Sending {
  /// Nothing is out, and a press may start a session.
  Ready

  /// The daemon is creating a session, and a second press asks nothing.
  Out
}

/// What the form carried besides the name.
pub type Typed {
  /// No further field.
  Nothing

  /// A folder path, for `TypedFolder`.
  Path(
    /// The text as typed, judged by `creations.typed_path`.
    text: String,
  )

  /// A workspace name, for an executor or pool that reported none.
  Workspace(
    /// The text as typed, judged by `creations.registered_name`.
    text: String,
  )
}

/// Whether the optional subagent limits disclosure is open in the composer.
pub type LimitsDisclosure {
  LimitsClosed
  LimitsOpen
}

/// Raw text fields submitted by the optional subagent limits disclosure.
pub type LimitsInput {
  LimitsInput(
    fan_out: String,
    session_strands: String,
    depth_mode: String,
    depth_cap: String,
  )
}

/// Empty limits input inheriting every daemon/Agency default.
pub const default_limits_input =
  LimitsInput(
    fan_out: "",
    session_strands: "",
    depth_mode: "default",
    depth_cap: "",
  )

/// The composer's state.
pub type State {
  State(
    /// Which chip's list is open.
    open: Open,
    /// Where the agent runs, as the person chose it: the daemon serving the page
    /// until another is chosen from the Agent chip.
    agent: Agent,
    /// The code target the person chose, or `None` for the default.
    target: Option(Target),
    /// The profile and model the person chose.
    roles: creations.Roles,
    /// The code picker's search text, bounded by `search_limit`.
    search: String,
    /// Where the folder search stands: whether the daemon was asked to search the
    /// home for the text, and what it found.
    seek: Seek,
    /// The folder picker, when "Open folder…" opened it.
    browser: Browser,
    /// Whether a creation is out.
    sending: Sending,
    /// The fixed words of the last refusal, drawn under the form, or `None`.
    refusal: Option(String),
    /// The ticket path of a session that was created and kept but did not take
    /// its first message, until the person opens it. It is the daemon's text and
    /// is never drawn.
    unsent: Option(String),
    /// Whether the optional subagent limits disclosure is expanded.
    limits: LimitsDisclosure,
    /// Whether the session works in its folder or in a worktree of it, as the
    /// Worktree toggle left it (protocol-change/133).
    worktree: Worktree,
  )
}

/// Where a session on this daemon works.
pub type Worktree {
  /// In the folder itself.
  InFolder

  /// In a Git worktree of the folder, on a branch of its own, started from
  /// `HEAD`.
  InTree
}

/// Everything a person can do to the composer. None carries text the page did
/// not draw except `Searched` and `Started`, whose text is bounded and judged.
pub type Msg {
  /// A chip was pressed: open its list, or close it if it is open.
  Toggled(chip: Chip)

  /// A row of the Agent chip's list was pressed. It is honoured only for a row the
  /// page drew that can be chosen, so a machine the page did not offer, or one
  /// that was not answering, changes nothing.
  ChoseAgent(agent: Agent)

  /// The scrim behind an open list was pressed: close it.
  Dismissed

  /// A row of the Code chip's list, or a recent place, was pressed.
  ChoseTarget(target: Target)

  /// A profile of the Model chip's list was pressed, or the default.
  ChoseProfile(profile: Option(String))

  /// A main model of the Model chip's list was pressed, or the default.
  ChoseModel(model: Option(String))

  /// The code picker's search text changed.
  Searched(text: String)

  /// A found folder's row was pressed. The index is into the hits the page holds,
  /// and one outside them changes nothing, so the browser never names a path.
  ChoseFound(index: Int)

  /// Enter was pressed in the search field: choose the first row the list shows.
  /// With no row to choose it changes nothing.
  Entered

  /// "Open folder…" was pressed: open the picker at the home. It is honoured
  /// only where the page may type a path, which is where the daemon serving the
  /// page is the agent.
  OpenedBrowser

  /// A child directory's row was pressed. The index is into the listing the page
  /// holds, and one outside it changes nothing.
  Descended(index: Int)

  /// A breadcrumb or the way up was pressed: the ancestor this many directories
  /// below the home, `0` for the home. The listing's own depth and anything
  /// beyond it change nothing.
  Ascended(depth: Int)

  /// "Use this folder" was pressed: choose the directory on screen. It is refused
  /// for the home itself, where a session may not start.
  ChosePicked

  /// "Back to the list" was pressed: close the picker.
  ClosedBrowser

  /// The form was submitted: the first message, and the one other field the
  /// chosen target needs, if any. The message is the browser's text: it names the
  /// session by its first line and, when it is not empty, is sent to the new
  /// session as its first user message. It is bounded here and never drawn.
  Started(prompt: String, typed: Typed)

  /// Toggle the optional subagent limits disclosure on the local machine.
  ToggledLimits

  /// The Worktree toggle was pressed: the next session works in its own Git
  /// worktree of the folder, or in the folder again. It is honoured only for a
  /// folder on this daemon's machine.
  ToggledWorktree

  /// Submit the composer carrying optional subagent limits fields.
  StartedWithLimits(prompt: String, typed: Typed, limits: LimitsInput)

  /// The "Open the session" button, drawn after a creation whose first message
  /// was not sent: depart for the session the daemon kept.
  OpenedUnsent
}

/// What the page owes after a message.
pub type Intent {
  /// Nothing.
  Stay

  /// The Code chip opened on this daemon: read the executors and pools again, so
  /// their states are current.
  ReadPlacements

  /// The Agent chip opened: read what every orchestrator offers again
  /// (protocol-change/094), so a machine that came back or went away is drawn as
  /// it now is.
  ReadAgents

  /// The Code chip opened on another orchestrator: read what it offers again.
  ReadOn(
    /// The orchestrator's key, the agent in force.
    orchestrator: String,
  )

  /// Ask the daemon to list this directory for the picker (protocol-change/132).
  /// The trail is the page's own, built from the listing it holds.
  Browse(
    /// The directory below the home, outermost first.
    trail: List(String),
  )

  /// Ask the daemon to create a session and send it its first message.
  Create(
    /// Where, as the daemon is asked.
    place: creations.Place,
    /// The session's name, from the message's first line, or empty for the
    /// daemon's default.
    name: String,
    /// The first message, or empty to send none.
    prompt: String,
    /// The profile and model.
    roles: creations.Roles,
    /// Optional per-session subagent limits (`protocol-change/113`).
    agency: AgencyLimits,
    /// The commit-ish the session's own worktree starts from, or `None` for a
    /// session in the folder (protocol-change/133).
    worktree: Option(String),
  )

  /// Ask the daemon to start a session on another orchestrator and send it its
  /// first message (protocol-change/094). The place is one the orchestrator
  /// offered, never a typed path.
  CreateOn(
    /// The orchestrator's key, the agent in force.
    orchestrator: String,
    /// Where its tools run, as the orchestrator is asked.
    place: creations.Place,
    /// The first message, or empty to send none.
    prompt: String,
    /// The profile and model, each one the orchestrator offered or the default.
    roles: creations.Roles,
  )

  /// Depart for a session whose ticket the daemon minted.
  Depart(
    /// The ticket's exchange path, which the daemon wrote.
    path: String,
  )
}

/// The lists the page was drawn from. A choice is honoured only if it names
/// something in them.
pub type Offers {
  Offers(
    /// The name of the machine the agent runs on: the daemon serving the page
    /// until another orchestrator is chosen, then that orchestrator's key.
    machine: String,
    /// The folders on the agent's machine the page drew, newest first.
    folders: List(String),
    /// The executors and pools, with the report once it answered.
    cards: placements.Cards,
    /// The profile names the agent's machine's configuration offers.
    profiles: List(String),
    /// The model keys the agent's machine's configuration offers.
    models: List(String),
    /// The agent these lists are for, which is the one in force.
    agent: Agent,
    /// The name of the daemon serving the page, which is what "the folders on the
    /// other machine" means once another orchestrator is the agent.
    here: String,
    /// The Agent chip's rows: this daemon, then each orchestrator it relays for,
    /// each with whether it can be chosen. A daemon with no orchestrator has the
    /// one row.
    agents: List(Candidate),
    /// Whether the form may ask for a typed folder.
    typing: Typing,
    /// The workspaces of the owner's projects on this daemon, which the Code list
    /// offers under its own heading. Empty for a page that lists no project and
    /// for another orchestrator.
    projects: List(String),
    /// The page's clock in milliseconds, which dates the folder index.
    now: Int,
  )
}

/// A place a session worked recently, for "Start again where you worked".
pub type Recent {
  Recent(
    /// The choice the row makes when pressed.
    target: Target,
    /// The tag: the agent and the code.
    place: listing.Place,
    /// The sessions that used it, newest first.
    names: List(String),
  )
}

/// A piece of the summary sentence: plain words, or a machine or place the
/// sentence names, which the view draws in a heavier weight.
pub type Piece {
  /// Words with no emphasis.
  Plain(text: String)

  /// A name the sentence is about.
  Named(text: String)
}

/// The composer before anything was chosen.
///
/// ## Examples
///
/// ```gleam
/// assert composer.new().sending == composer.Ready
/// ```
pub fn new() -> State {
  State(
    open: Shut,
    agent: Here,
    target: None,
    roles: creations.default_roles,
    search: "",
    seek: Unindexed,
    browser: Closed,
    sending: Ready,
    refusal: None,
    unsent: None,
    limits: LimitsClosed,
    worktree: InFolder,
  )
}

/// Applies one message and says what the page owes.
///
/// A choice is applied only when `offers` holds it. The Code chip's opening asks
/// for the placements to be read, and a start is `Create` only when a target is in
/// force, no creation is out, the roles are offered and `place` can build a
/// place from what the form sent; otherwise the state carries the words saying
/// why not.
///
/// ## Examples
///
/// ```gleam
/// let #(state, intent) = composer.update(composer.new(), composer.Toggled(composer.CodeChip), offers, [])
/// assert intent == composer.ReadPlacements
/// ```
pub fn update(
  state: State,
  message: Msg,
  offers: Offers,
  recent: List(Recent),
) -> #(State, Intent) {
  case message {
    Toggled(chip:) -> toggled(state, chip)
    ChoseAgent(agent:) -> #(chose_agent(state, offers, agent), Stay)
    Dismissed -> #(
      State(..state, open: Shut, search: "", browser: Closed),
      Stay,
    )
    ChoseTarget(target:) -> #(chose_target(state, offers, target), Stay)
    ChoseProfile(profile:) -> #(chose_profile(state, offers, profile), Stay)
    ChoseModel(model:) -> #(chose_model(state, offers, model), Stay)
    Searched(text:) -> #(searched(state, text), Stay)
    ChoseFound(index:) -> #(chose_found(state, offers, index), Stay)
    Entered -> #(entered(state, offers), Stay)
    OpenedBrowser -> opened_browser(state, offers)
    Descended(index:) -> descended(state, index)
    Ascended(depth:) -> ascended(state, depth)
    ChosePicked -> #(chose_picked(state, offers), Stay)
    ClosedBrowser -> #(State(..state, browser: Closed), Stay)
    ToggledLimits -> #(toggled_limits(state), Stay)
    ToggledWorktree -> #(toggled_worktree(state), Stay)
    Started(prompt:, typed:) ->
      started(state, offers, recent, prompt, typed, default_limits_input)
    StartedWithLimits(prompt:, typed:, limits:) ->
      started(state, offers, recent, prompt, typed, limits)
    OpenedUnsent ->
      case state.unsent {
        Some(path) -> #(state, Depart(path))
        None -> #(state, Stay)
      }
  }
}

/// Words saying the daemon's refusal of a creation, kept for the form to draw
/// and the creation no longer out.
///
/// ## Examples
///
/// ```gleam
/// let state = composer.refused(composer.new(), "That folder is not available.")
/// assert state.refusal == Some("That folder is not available.")
/// ```
pub fn refused(state: State, words: String) -> State {
  State(..state, sending: Ready, refusal: Some(words))
}

/// The state after a creation the daemon accepted: nothing is out. A page that
/// is departing leaves the state as it is, since the next page is a new one.
///
/// ## Examples
///
/// ```gleam
/// assert composer.settled(composer.State(..composer.new(), sending: composer.Out)).sending == composer.Ready
/// ```
pub fn settled(state: State) -> State {
  State(..state, sending: Ready, refusal: None, unsent: None)
}

/// The state after a creation whose session was kept and did not take its first
/// message: nothing is out, and the person is offered the session.
///
/// ## Examples
///
/// ```gleam
/// assert composer.unsent(composer.new(), "/ui/sessions/S?ticket=T").unsent
///   == Some("/ui/sessions/S?ticket=T")
/// ```
pub fn unsent(state: State, path: String) -> State {
  State(..state, sending: Ready, refusal: None, unsent: Some(path))
}

/// The name a first message gives its session: the first line that has any text,
/// made safe for one line, trimmed and cut to `name_limit` characters on a
/// character boundary. A message with no text gives none, so the daemon names the
/// session for its folder as it always did.
///
/// ## Examples
///
/// ```gleam
/// assert composer.session_name("\n  fix the retry test \nthen more") == "fix the retry test"
/// assert composer.session_name("   ") == ""
/// ```
pub fn session_name(prompt: String) -> String {
  let first =
    string.split(prompt, "\n")
    |> list.map(string.trim)
    |> list.find(fn(line) { line != "" })
    |> result.unwrap("")

  text_hygiene.single_line(first)
  |> string.trim
  |> string.to_graphemes
  |> list.take(name_limit)
  |> string.concat
  |> string.trim
}

/// The code target in force: the person's choice while the page still offers it,
/// else the newest place a session worked in, else the first folder the page
/// drew, else nothing.
///
/// ## Examples
///
/// ```gleam
/// assert composer.chosen(composer.new(), offers, []) == None
/// ```
pub fn chosen(
  state: State,
  offers: Offers,
  recent: List(Recent),
) -> Option(Target) {
  case state.target {
    Some(target) ->
      case offered(offers, target) {
        True -> Some(target)
        False -> default_target(offers, recent)
      }
    None -> default_target(offers, recent)
  }
}

/// The target a page falls back to when the person has chosen none.
///
/// ## Examples
///
/// ```gleam
/// assert composer.default_target(offers, []) == None
/// ```
pub fn default_target(offers: Offers, recent: List(Recent)) -> Option(Target) {
  let from_recent =
    list.find(recent, fn(each) { offered(offers, each.target) })
    |> result.map(fn(each) { each.target })

  // Fall back to the first offered folder when no recent target matches.
  case from_recent, offers.folders {
    Ok(target), _ -> Some(target)
    Error(Nil), [first, ..] -> Some(Folder(first))
    Error(Nil), [] -> None
  }
}

/// Whether the page drew a row for this target. A target the page did not draw is
/// never honoured. A workspace of an executor the daemon reported on must be one
/// it listed; where it listed none, any name that can be a registered workspace is
/// drawn as a typed field, so it is offered too.
///
/// ## Examples
///
/// ```gleam
/// assert !composer.offered(offers, composer.Folder("/nowhere"))
/// ```
pub fn offered(offers: Offers, target: Target) -> Bool {
  case target {
    Folder(workspace:) -> list.contains(offers.folders, workspace)
    TypedFolder -> offers.typing == MayType
    Picked(trail:) ->
      offers.typing == MayType && trail != [] && folder_browse.trail_ok(trail)
    Project(workspace:) -> list.contains(offers.projects, workspace)
    OnExecutor(executor:, workspace:) ->
      placements.offers(offers.cards, placements.OnExecutor(executor))
      && workspace_offered(offers, placements.OnExecutor(executor), workspace)
    InPool(pool:, workspace:) ->
      placements.offers(offers.cards, placements.InPool(pool))
      && workspace_offered(offers, placements.InPool(pool), workspace)
  }
}

/// The place the daemon is asked for, from the target in force and what the form
/// sent, or the fixed words saying what the form still needs.
///
/// ## Examples
///
/// ```gleam
/// assert composer.place(composer.Folder("/w"), composer.Nothing) == Ok(creations.Drawn("/w"))
/// assert composer.place(composer.TypedFolder, composer.Nothing) |> result.is_error
/// ```
pub fn place(target: Target, typed: Typed) -> Result(creations.Place, String) {
  case target, typed {
    Folder(workspace:), _ -> Ok(creations.Drawn(workspace))
    TypedFolder, Path(text:) ->
      creations.typed_path(text)
      |> result.map(creations.Typed)
      |> result.replace_error("Type the folder's path, or choose another.")
    TypedFolder, Nothing | TypedFolder, Workspace(_) ->
      Error("Type the folder's path, or choose another.")
    Picked(trail:), _ -> Ok(creations.Typed(folder_browse.trail_text(trail)))
    Project(workspace:), _ -> Ok(creations.Typed(workspace))
    OnExecutor(executor:, workspace: Some(workspace)), _ ->
      Ok(creations.Registered(executor, workspace))
    OnExecutor(executor:, workspace: None), Workspace(text:) ->
      creations.registered_name(text)
      |> result.map(creations.Registered(executor, _))
      |> result.replace_error(unnamed)
    OnExecutor(workspace: None, ..), Nothing
    | OnExecutor(workspace: None, ..), Path(_)
    -> Error(unnamed)
    InPool(pool:, workspace: Some(workspace)), _ ->
      Ok(creations.Pooled(pool, workspace))
    InPool(pool:, workspace: None), Workspace(text:) ->
      creations.registered_name(text)
      |> result.map(creations.Pooled(pool, _))
      |> result.replace_error(unnamed)
    InPool(workspace: None, ..), Nothing
    | InPool(workspace: None, ..), Path(_)
    -> Error(unnamed)
  }
}

/// The folders the page draws on the agent's machine: the directories the
/// owner's local sessions run in, newest session first, then the remembered
/// folders no session shows, in the order the daemon gave them.
///
/// ## Examples
///
/// ```gleam
/// assert composer.folders_offered([], []) == []
/// ```
pub fn folders_offered(
  entries: List(Entry),
  remembered: List(creations.Recent),
) -> List(String) {
  let from_sessions =
    list.filter_map(entries, fn(entry) {
      case entry.executor {
        None -> Ok(entry.workspace)
        Some(_) -> Error(Nil)
      }
    })

  list.append(from_sessions, list.map(remembered, fn(each) { each.path }))
  |> list.unique
}

/// The places sessions worked in recently, newest first and at most
/// `recent_limit`, each with the names of the sessions that used it.
///
/// ## Examples
///
/// ```gleam
/// assert composer.recents([], "laptop") == []
/// ```
pub fn recents(entries: List(Entry), machine: String) -> List(Recent) {
  let tagged =
    list.map(entries, fn(entry) {
      let place = listing.place(entry, machine)
      #(place, target_of(entry), sessions.label(entry))
    })

  list.map(tagged, fn(row) { row.0 })
  |> list.unique
  |> list.take(recent_limit)
  |> list.filter_map(fn(place) {
    let used = list.filter(tagged, fn(row) { row.0 == place })

    // Construct a recent row with its session names when present.
    case used {
      [#(_, target, _), ..] ->
        Ok(Recent(target:, place:, names: list.map(used, fn(row) { row.2 })))
      [] -> Error(Nil)
    }
  })
}

/// The hint a recent place carries: its sessions' names when there are one or two
/// of them, and the newest with a count of the rest otherwise.
///
/// ## Examples
///
/// ```gleam
/// assert composer.hint(["a", "b", "c", "d"]) == "a, 3 more"
/// ```
pub fn hint(names: List(String)) -> String {
  case names {
    [] -> ""
    [one] -> one
    [first, second] -> first <> ", " <> second
    [first, ..rest] ->
      first <> ", " <> int.to_string(list.length(rest)) <> " more"
  }
}

/// The words on the Code chip for a target.
///
/// ## Examples
///
/// ```gleam
/// assert composer.target_words(composer.OnExecutor("exec", Some("repo"))) == "exec · repo"
/// ```
pub fn target_words(target: Target) -> String {
  case target {
    Folder(workspace:) -> name_of(workspace)
    TypedFolder -> "a folder you type"
    Picked(trail:) -> name_of(folder_browse.trail_text(trail))
    Project(workspace:) -> name_of(workspace)
    OnExecutor(executor:, workspace: Some(workspace)) ->
      executor <> " · " <> workspace
    OnExecutor(executor:, workspace: None) -> executor <> " · name it below"
    InPool(pool:, workspace: Some(workspace)) -> pool <> " pool · " <> workspace
    InPool(pool:, workspace: None) -> pool <> " pool · name it below"
  }
}

/// The words on the Model chip: the profile and the model, each "default" while
/// the configuration's own is in force, or just "default" when both are.
///
/// ## Examples
///
/// ```gleam
/// assert composer.role_words(creations.default_roles) == "default"
/// assert composer.role_words(creations.Roles(Some("fast"), Some("glm"))) == "fast · glm"
/// ```
pub fn role_words(roles: creations.Roles) -> String {
  case roles.profile, roles.model {
    None, None -> "default"
    Some(profile), None -> profile
    None, Some(model) -> "default · " <> model
    Some(profile), Some(model) -> profile <> " · " <> model
  }
}

/// The sentence under the chips, written from what is chosen: where the agent
/// runs, where commands run, and what the code is. With no target it asks for
/// one.
///
/// ## Examples
///
/// ```gleam
/// assert composer.sentence("laptop", Some(composer.Folder("/a/b/c")))
///   == [Plain("The agent runs on "), Named("laptop"), Plain(". Commands run on "), Named("laptop"), Plain(", in "), Named("…/b/c"), Plain(".")]
/// ```
pub fn sentence(machine: String, target: Option(Target)) -> List(Piece) {
  let agent = [Plain("The agent runs on "), Named(machine), Plain(". ")]

  // Build the summary sentence describing where commands will execute.
  case target {
    None -> [
      Plain("The agent runs on "),
      Named(machine),
      Plain(". Choose where the code is."),
    ]
    Some(Folder(workspace:)) ->
      list.append(agent, [
        Plain("Commands run on "),
        Named(machine),
        Plain(", in "),
        Named(listing.short_path(workspace)),
        Plain("."),
      ])
    Some(TypedFolder) ->
      list.append(agent, [
        Plain("Commands run on "),
        Named(machine),
        Plain(", in the folder you type."),
      ])
    Some(Picked(trail:)) ->
      list.append(agent, [
        Plain("Commands run on "),
        Named(machine),
        Plain(", in "),
        Named(folder_browse.trail_text(trail)),
        Plain("."),
      ])
    Some(Project(workspace:)) ->
      list.append(agent, [
        Plain("Commands run on "),
        Named(machine),
        Plain(", in "),
        Named(listing.short_path(workspace)),
        Plain("."),
      ])
    Some(OnExecutor(executor:, workspace:)) ->
      list.append(agent, [
        Plain("Commands run on "),
        Named(executor),
        ..in_workspace(workspace)
      ])
    Some(InPool(pool:, workspace:)) ->
      list.append(agent, [
        Plain("Commands run on whichever machine of "),
        Named(pool),
        Plain(" answers first"),
        ..in_workspace(workspace)
      ])
  }
}

/// The sentence under the chips for the agent in force. For this daemon it is
/// `sentence`. For another orchestrator it adds the one fact that differs: this
/// page relays the session, so approvals come here.
///
/// ## Examples
///
/// ```gleam
/// assert composer.sentence_for(composer.Here, "laptop", None)
///   == composer.sentence("laptop", None)
/// ```
pub fn sentence_for(
  agent: Agent,
  machine: String,
  target: Option(Target),
) -> List(Piece) {
  case agent {
    Here -> sentence(machine, target)
    Orchestrator(_) ->
      list.append(sentence(machine, target), [
        Plain(" This page relays it: approvals come here."),
      ])
  }
}

// The words that finish a sentence about a registered workspace: its name, or the
// request to type one.
fn in_workspace(workspace: Option(String)) -> List(Piece) {
  case workspace {
    Some(name) -> [Plain(", in the "), Named(name), Plain(" workspace.")]
    None -> [Plain(", in the workspace you name.")]
  }
}

// The words for a profile or model the page no longer offers.
const roles_gone =
  "That profile or model is no longer offered. Choose the Model chip again."

// The words for an agent the page no longer offers or that stopped answering.
const agent_gone =
  "That machine is not answering now. Choose the Agent chip again."

// The words for a message past the bound.
const too_long =
  "That message is too long to send. Shorten it, or send the rest from the session's page."

// The words for a form that still needs a workspace name.
const unnamed = "Name the workspace, or choose another."

// A chip's press opens its list, or closes it when it is the one open. The Code
// chip's opening also owes a read of the placements, so what the list says of
// each executor is current: this daemon's own when it is the agent, and the
// agent orchestrator's when another one is. The Agent chip's opening owes a read
// of every orchestrator, so a machine that came back or went away is drawn as it
/// Toggles the specified chip open or shut, returning the next state and intent.
fn toggled(state: State, chip: Chip) -> #(State, Intent) {
  case state.open {
    Showing(chip: open) if open == chip -> #(
      State(..state, open: Shut, search: "", browser: Closed),
      Stay,
    )
    Showing(_) | Shut -> #(
      State(
        ..state,
        open: Showing(chip),
        search: "",
        seek: retried(state.seek),
        browser: Closed,
      ),
      case chip, state.agent {
        CodeChip, Here -> ReadPlacements
        CodeChip, Orchestrator(name:) -> ReadOn(orchestrator: name)
        AgentChip, _ -> ReadAgents
        ModelChip, _ -> Stay
      },
    )
  }
}

/// What an index state becomes when a list opens: a refused build is forgotten so
/// the open asks again, and an index kept through a refused refresh is made stale
/// so the open refreshes it. This is the only place a refusal is retried, so a
/// keystroke after one asks the daemon for nothing.
fn retried(seek: Seek) -> Seek {
  case seek {
    Unindexable(_, Some(index)) ->
      Indexed(index:, at: 0 - folder_browse.index_ttl_ms)
    Unindexable(_, None) -> Unindexed
    Unindexed | Indexing(_) | Indexed(..) -> seek
  }
}

/// A row of the Agent chip's list, honoured only for a machine the page drew that
/// can be chosen. It closes the list. The code choice is not judged here, because
/// the lists it is judged against are the new machine's, which the caller builds
/// once the agent has changed (`kept`).
fn chose_agent(state: State, offers: Offers, agent: Agent) -> State {
  // Refuse an agent row that was not offered.
  case choosable(offers, agent) {
    True -> {
      // Collapse the local-only limits disclosure when leaving the local daemon.
      let limits = case agent {
        Here -> state.limits
        Orchestrator(_) -> LimitsClosed
      }

      State(
        ..state,
        agent:,
        open: Shut,
        search: "",
        browser: Closed,
        refusal: None,
        limits:,
      )
    }
    False -> state
  }
}

/// Whether the Agent chip's list has a row for this machine that can be chosen.
///
/// ## Examples
///
/// ```gleam
/// assert !composer.choosable(offers, composer.Orchestrator("nowhere"))
/// ```
pub fn choosable(offers: Offers, agent: Agent) -> Bool {
  list.any(offers.agents, fn(candidate) {
    candidate.agent == agent
    && case candidate.standing {
      Choosable(_) -> True
      Checking | Unavailable(_) -> False
    }
  })
}

/// The state after the agent changed, given the new machine's offers: a workspace
/// of an executor or pool stays chosen when the new machine offers it, since it
/// names a machine that does not move with the agent, and a folder never does,
/// since the same path on another machine is another folder. A profile or model
/// the new machine does not offer goes back to the default.
///
/// ## Examples
///
/// ```gleam
/// assert composer.kept(composer.State(..composer.new(), target: Some(composer.Folder("/w"))), offers).target == None
/// ```
pub fn kept(state: State, offers: Offers) -> State {
  // Retain the current target if it remains offered by the updated environment.
  let target = case state.target {
    Some(OnExecutor(..) as target) | Some(InPool(..) as target) ->
      case offered(offers, target) {
        True -> Some(target)
        False -> None
      }
    Some(Folder(_))
    | Some(TypedFolder)
    | Some(Picked(_))
    | Some(Project(_))
    | None -> None
  }

  // Retain selected roles when still offered or fall back to defaults.
  let roles =
    creations.Roles(
      profile: kept_profile(offers, state.roles.profile),
      model: case in_list(offers.models, state.roles.model) {
        True -> state.roles.model
        False -> None
      },
    )

  State(..state, target:, roles:)
}

/// The profile that stays chosen after a switch. A box has no profile named for the
/// default and a create must name one, so a switch to a box names its first listed
/// profile, which is the one the create sends, and the chip says so. This daemon's
/// default is the configuration's own, so a switch back keeps a profile only where
/// it is listed.
fn kept_profile(offers: Offers, profile: Option(String)) -> Option(String) {
  case offers.agent, in_list(offers.profiles, profile), offers.profiles {
    _, True, _ if profile != None -> profile
    Orchestrator(_), _, [first, ..] -> Some(first)
    _, _, _ -> None
  }
}

/// A row of the Code chip's list: honoured only for a target the page drew, and it
/// closes the list. A message for a target the page did not draw changes nothing.
fn chose_target(state: State, offers: Offers, target: Target) -> State {
  // A picked folder is made only by `ChosePicked`, from the listing the page
  // holds, so a message that carries one is refused whatever the lists offer.
  case target {
    Picked(_) -> state
    Folder(_) | TypedFolder | Project(_) | OnExecutor(..) | InPool(..) ->
      case offered(offers, target) {
        True ->
          State(
            ..state,
            open: Shut,
            target: Some(target),
            search: "",
            browser: Closed,
            refusal: None,
          )
        False -> state
      }
  }
}

/// "Open folder…": open the picker at the home and owe the daemon a read of
/// it. It is honoured only where the page may type a path, since only the daemon
/// serving the page can list its own directories.
fn opened_browser(state: State, offers: Offers) -> #(State, Intent) {
  case offers.typing {
    MayType -> #(
      State(..state, search: "", browser: Reading(trail: [], behind: None)),
      Browse(trail: []),
    )
    MayNotType -> #(state, Stay)
  }
}

/// A child directory's row: read the directory below the one on screen. The index
/// is checked against the listing the page holds, so a press the page did not
/// draw reads nothing, and the trail asked for is built here, never taken from the
/// browser.
fn descended(state: State, index: Int) -> #(State, Intent) {
  case state.browser {
    Browsing(listing:, ..) ->
      case folder_browse.below(listing, index) {
        Ok(trail) -> reading(state, trail, listing)
        Error(Nil) -> #(state, Stay)
      }
    Closed | Reading(..) | Failed(_) -> #(state, Stay)
  }
}

/// A breadcrumb or the way up: read an ancestor of the directory on screen.
fn ascended(state: State, depth: Int) -> #(State, Intent) {
  case state.browser {
    Browsing(listing:, ..) ->
      case folder_browse.above(listing, depth) {
        Ok(trail) -> reading(state, trail, listing)
        Error(Nil) -> #(state, Stay)
      }
    Closed | Reading(..) | Failed(_) -> #(state, Stay)
  }
}

/// The state while a read of `trail` is out, and the read the daemon is owed. The
/// listing on screen is kept as `behind`, so a refusal of this read leaves the
/// person where they were, and `browsed` settles the read when its answer arrives.
fn reading(
  state: State,
  trail: List(String),
  behind: folder_browse.Listing,
) -> #(State, Intent) {
  #(
    State(..state, browser: Reading(trail:, behind: Some(behind))),
    Browse(trail:),
  )
}

/// The daemon's answer to a `Browse`. It is applied only when the picker is still
/// waiting for that trail, so an answer that arrives after the person pressed
/// something else, or closed the picker, is dropped. A refusal keeps the listing
/// the person was on and says why, and a first read's refusal shows the words
/// alone.
///
/// ## Examples
///
/// ```gleam
/// let state = composer.State(..composer.new(), browser: composer.Reading([], None))
/// let listing = folder_browse.Listing([], [], folder_browse.Whole)
/// assert composer.browsed(state, [], Ok(listing)).browser == composer.Browsing(listing, None)
/// ```
pub fn browsed(
  state: State,
  trail: List(String),
  answer: folder_browse.Answer,
) -> State {
  case state.browser {
    Reading(trail: waiting, behind:) if waiting == trail ->
      case answer, behind {
        Ok(listing), _ -> State(..state, browser: Browsing(listing, None))
        Error(why), Some(listing) ->
          State(..state, browser: Browsing(listing, Some(why)))
        Error(why), None -> State(..state, browser: Failed(why))
      }
    Reading(..) | Closed | Browsing(..) | Failed(_) -> state
  }
}

/// "Use this folder": the directory on screen becomes the code target and the
/// list closes. The home itself is refused, since a session may not start there
/// (`creations.inside`), so the press changes nothing and the view draws no button
/// for it.
fn chose_picked(state: State, offers: Offers) -> State {
  case state.browser, offers.typing {
    Browsing(listing: folder_browse.Listing(trail: [_, ..] as trail, ..), ..),
      MayType
    ->
      State(
        ..state,
        open: Shut,
        target: Some(Picked(trail)),
        search: "",
        browser: Closed,
        refusal: None,
      )
    Browsing(..), _ | Closed, _ | Reading(..), _ | Failed(_), _ -> state
  }
}

/// A profile of the Model chip's list: the default, or one the daemon's
/// configuration named. The list stays open, since a main model is chosen beside it.
fn chose_profile(
  state: State,
  offers: Offers,
  profile: Option(String),
) -> State {
  case in_list(offers.profiles, profile) {
    True ->
      State(
        ..state,
        roles: creations.Roles(..state.roles, profile:),
        refusal: None,
      )
    False -> state
  }
}

/// A main model of the Model chip's list, held as a profile is.
fn chose_model(state: State, offers: Offers, model: Option(String)) -> State {
  case in_list(offers.models, model) {
    True ->
      State(
        ..state,
        roles: creations.Roles(..state.roles, model:),
        refusal: None,
      )
    False -> state
  }
}

/// Updates the search text while the Code chip is showing. The text only ranks
/// the index the page holds, so it asks the daemon for nothing.
fn searched(state: State, text: String) -> State {
  // The field exists only inside the Code list, so text from any other state is a
  // stale or forged message and is ignored.
  case state.open {
    Showing(chip: CodeChip) -> State(..state, search: bounded(text))
    Showing(_) | Shut -> state
  }
}

/// Whether the page owes the daemon an index, and the state that says it is out.
/// It is owed while the Code list is open on a page that may type a path, when no
/// index is held, the last build was refused, or the held one has outlived
/// `folder_browse.index_ttl_ms`. The seeds are the remembered folders, which the
/// daemon reads the parents of first. A build already out is never asked twice.
///
/// ## Examples
///
/// ```gleam
/// let state = composer.State(..composer.new(), open: composer.Showing(composer.CodeChip))
/// let #(asking, seeds) = composer.indexing(state, offers)
/// assert asking.seek == composer.Indexing(None)
/// ```
pub fn indexing(
  state: State,
  offers: Offers,
) -> #(State, Option(List(String))) {
  // An index is owed when the Code list is open on a page that may type a path and
  // none is held, or the held one is past its lifetime. A refusal is not owed
  // again here: `retried` forgets it when the list next opens.
  let owed = case state.open, offers.typing, state.seek {
    Showing(chip: CodeChip), MayType, Unindexed -> Some(None)
    Showing(chip: CodeChip), MayType, Indexed(index:, at:) ->
      case offers.now - at >= folder_browse.index_ttl_ms {
        True -> Some(Some(index))
        False -> None
      }
    _, _, _ -> None
  }

  // A build is out from here on, with the index held before it kept in use, so
  // nothing asks again until the answer arrives.
  case owed {
    Some(before) -> #(
      State(..state, seek: Indexing(before:)),
      Some(offers.folders),
    )
    None -> #(state, None)
  }
}

/// The daemon's answer to an index request, taken at the page's clock `now`. It is
/// applied only while a build is out, so a late duplicate changes nothing. A
/// refusal keeps the index held before, if any, so a daemon that is slow once does
/// not empty the list.
///
/// ## Examples
///
/// ```gleam
/// let state = composer.State(..composer.new(), seek: composer.Indexing(None))
/// let index = folder_browse.Index("/h", [], folder_browse.Covered)
/// assert composer.indexed(state, Ok(index), 5).seek == composer.Indexed(index, 5)
/// ```
pub fn indexed(
  state: State,
  answer: folder_browse.IndexAnswer,
  now: Int,
) -> State {
  case state.seek, answer {
    Indexing(_), Ok(index) -> State(..state, seek: Indexed(index:, at: now))
    Indexing(before:), Error(why) ->
      State(..state, seek: Unindexable(why:, before:))
    Unindexed, _ | Indexed(..), _ | Unindexable(..), _ -> state
  }
}

/// A found folder's row: the hit at the index becomes the picked folder and the
/// list closes. The index is checked against the hits the page holds, and the
/// trail is built from them, never from the browser.
fn chose_found(state: State, offers: Offers, index: Int) -> State {
  let shown = shown_hits(state)

  // The hit is chosen only on a page that may type a path, and only if the page holds it.
  case offers.typing, folder_browse.hit_trail(shown, index) {
    MayType, Ok(trail) -> picked(state, trail)
    MayType, Error(Nil) | MayNotType, _ -> state
  }
}

/// The state with this trail chosen and the list closed.
fn picked(state: State, trail: List(String)) -> State {
  State(
    ..state,
    open: Shut,
    target: Some(Picked(trail)),
    search: "",
    browser: Closed,
    refusal: None,
  )
}

/// Enter in the search field: the first row the list draws is chosen, in the
/// list's order, which is the remembered folders, then the found ones, then the
/// projects. With nothing to choose it changes nothing.
fn entered(state: State, offers: Offers) -> State {
  case first_choice(choices(state, offers)) {
    Some(Choice(target: Picked(trail:), ..)) -> picked(state, trail)
    Some(Choice(target:, ..)) -> chose_target(state, offers, target)
    None -> state
  }
}

/// What a row of the Code list's folders names, and the words it is drawn with.
pub type Choice {
  Choice(
    /// What a press chooses.
    target: Target,
    /// The directory's own name.
    name: String,
    /// Where it lives, shortened, which tells two folders of one name apart.
    parent: String,
    /// The index among the page's found hits when the row is one, which is what a
    /// press names.
    found: Option(Int),
  )
}

/// The folder rows of the Code list, in the groups the list draws them in.
pub type Choices {
  Choices(
    /// The remembered folders the text matches, most recent first, at most
    /// `menu_recent` of them.
    recent: List(Choice),
    /// The directories the daemon found that no remembered folder already shows.
    found: List(Choice),
    /// The projects' workspaces the text matches.
    projects: List(Choice),
  )
}

/// The most remembered folders the Code list draws.
pub const menu_recent = 8

/// The folder rows for the text in the search field. Every group is matched by a
/// fragment anywhere in the folder's path, without regard to case, so a short
/// text narrows the remembered folders at once while the daemon's search, which
/// needs two characters, is on its way.
///
/// ## Examples
///
/// ```gleam
/// let offers = Offers(..offers, folders: ["/src/loom", "/src/weft"])
/// let state = State(..composer.new(), search: "we")
/// assert list.map(composer.choices(state, offers).recent, fn(c) { c.name }) == ["weft"]
/// ```
pub fn choices(state: State, offers: Offers) -> Choices {
  let text = string.lowercase(string.trim(state.search))
  let holds = fn(path: String) {
    text == "" || string.contains(string.lowercase(path), text)
  }

  let recent =
    list.filter(offers.folders, holds)
    |> list.take(menu_recent)
    |> list.map(fn(path) {
      Choice(
        target: Folder(path),
        name: name_of(path),
        parent: parent_of(path),
        found: None,
      )
    })

  let shown = shown_hits(state)

  // The home the index was built under, which turns an entry's trail into the
  // whole path a remembered folder is compared with.
  let home = case state.seek {
    Indexed(index:, ..)
    | Indexing(before: Some(index))
    | Unindexable(_, Some(index)) -> index.home
    Unindexed | Unindexable(_, None) | Indexing(before: None) -> ""
  }

  // A found folder is left out only when a remembered folder drawn above it is the
  // same directory, compared by whole path, so a folder of the same name
  // elsewhere is still offered.
  let recent_paths =
    list.filter(offers.folders, holds) |> list.take(menu_recent)
  let found =
    list.index_map(shown, fn(trail, index) { #(trail, index) })
    |> list.filter(fn(each) {
      !list.contains(recent_paths, home <> "/" <> string.join(each.0, "/"))
    })
    |> list.map(fn(each) {
      let text = folder_browse.trail_text(each.0)

      Choice(
        target: Picked(each.0),
        name: name_of(text),
        parent: parent_of(text),
        found: Some(each.1),
      )
    })

  let projects =
    list.filter(offers.projects, holds)
    |> list.map(fn(path) {
      Choice(
        target: Project(path),
        name: name_of(path),
        parent: parent_of(path),
        found: None,
      )
    })

  Choices(recent:, found:, projects:)
}

/// The first row of the groups in the order the list draws them.
///
/// ## Examples
///
/// ```gleam
/// assert composer.first_choice(composer.Choices([], [], [])) == None
/// ```
pub fn first_choice(choices: Choices) -> Option(Choice) {
  case choices.recent, choices.found, choices.projects {
    [first, ..], _, _ | [], [first, ..], _ | [], [], [first, ..] -> Some(first)
    [], [], [] -> None
  }
}

/// The folders the list draws from the index: the best entries for the fragment
/// now typed, ranked. A stale index stays in use while its replacement is out.
fn shown_hits(state: State) -> List(List(String)) {
  // Any index in hand is used, including the one kept through a refused refresh.
  let held = case state.seek {
    Indexed(index:, ..)
    | Indexing(before: Some(index))
    | Unindexable(_, Some(index)) -> Ok(index)
    Unindexed | Unindexable(_, None) | Indexing(before: None) -> Error(Nil)
  }

  // With text too short to rank, or no index yet, there is nothing to show.
  case held, folder_browse.needle(state.search) {
    Ok(index), Ok(fragment) -> folder_browse.rank(index.entries, fragment)
    Ok(_), Error(Nil) | Error(Nil), _ -> []
  }
}

/// A folder's own name: the last component of its path. A path with none, such
/// as `/` or `~`, is its own name.
///
/// ## Examples
///
/// ```gleam
/// assert composer.name_of("/src/loom") == "loom"
/// assert composer.name_of("~") == "~"
/// ```
pub fn name_of(path: String) -> String {
  case list.last(components(path)) {
    Ok(name) -> name
    Error(Nil) -> path
  }
}

/// Where a folder lives: its path without the last component, shortened to the
/// last two components so a long path stays one line. A folder directly below the
/// root or the home says that.
///
/// ## Examples
///
/// ```gleam
/// assert composer.parent_of("/a/b/c/loom") == "…/b/c"
/// assert composer.parent_of("~/loom") == "~"
/// ```
pub fn parent_of(path: String) -> String {
  let kept = list.reverse(components(path)) |> list.drop(1) |> list.reverse

  // The parent is the path without its last component, with the root kept.
  let prefix = case string.starts_with(path, "/") {
    True -> "/"
    False -> ""
  }

  // A folder directly below the root or the home has the root or the home alone.
  case kept {
    [] -> prefix
    _ -> listing.short_path(prefix <> string.join(kept, "/"))
  }
}

/// The non-empty parts of a path.
fn components(path: String) -> List(String) {
  string.split(path, "/") |> list.filter(fn(part) { part != "" })
}

/// The start of a session: nothing happens while one is out or when no target is
/// in force; the roles must still be ones the page offers; and the place must be
/// buildable from what the form sent. Otherwise the creation is asked for and
/// nothing else is held but the fact that it is out.
fn started(
  state: State,
  offers: Offers,
  recent: List(Recent),
  prompt: String,
  typed: Typed,
  limits: LimitsInput,
) -> #(State, Intent) {
  // Validate target, roles, prompt size, typed place, and optional limits.
  case
    state.sending,
    chosen(state, offers, recent),
    choosable(offers, state.agent)
  {
    Out, _, _ | Ready, None, _ -> #(state, Stay)
    Ready, Some(_), False -> #(State(..state, refusal: Some(agent_gone)), Stay)
    Ready, Some(target), True ->
      case
        in_list(offers.profiles, state.roles.profile)
        && in_list(offers.models, state.roles.model),
        string.byte_size(prompt) > prompt_limit,
        place(target, typed),
        parse_limits(limits)
      {
        False, _, _, _ -> #(State(..state, refusal: Some(roles_gone)), Stay)
        True, True, _, _ -> #(State(..state, refusal: Some(too_long)), Stay)
        True, False, Error(words), _ -> #(
          State(..state, refusal: Some(words)),
          Stay,
        )
        True, False, Ok(_), Error(_) -> #(
          State(
            ..state,
            refusal: Some(creations.reason_words(creations.InvalidLimits)),
          ),
          Stay,
        )
        True, False, Ok(place), Ok(agency) -> #(
          State(..state, sending: Out, refusal: None, unsent: None),
          to_create(
            state.agent,
            place,
            prompt,
            state.roles,
            agency,
            state.worktree,
          ),
        )
      }
  }
}

/// Flips the Worktree toggle when the agent is this daemon and the target is a
/// folder on it. An executor's or a pool's workspace chooses its own mode, and
/// another orchestrator's folders are out of this daemon's reach, so for those
/// the press changes nothing.
fn toggled_worktree(state: State) -> State {
  // Dispatch on the agent and the target the toggle would apply to.
  case state.agent, state.target {
    Here, Some(Folder(_)) | Here, Some(TypedFolder) | Here, Some(Picked(_)) ->
      State(..state, worktree: case state.worktree {
        InFolder -> InTree
        InTree -> InFolder
      })
    Here, Some(OnExecutor(..))
    | Here, Some(InPool(..))
    | Here, None
    | Orchestrator(_), _
    -> state
  }
}

/// Toggle the subagent limits disclosure when targeting the local machine.
fn toggled_limits(state: State) -> State {
  // Only local sessions expose configurable agency limits.
  case state.agent, state.limits {
    Here, LimitsClosed -> State(..state, limits: LimitsOpen, open: Shut)
    Here, LimitsOpen -> State(..state, limits: LimitsClosed)
    Orchestrator(_), _ -> state
  }
}

/// Parses and validates optional subagent limit fields from the composer form.
pub fn parse_limits(input: LimitsInput) -> Result(AgencyLimits, String) {
  use fan_out <- result.try(parse_optional_limit_int(input.fan_out))
  use session_strands <- result.try(parse_optional_limit_int(
    input.session_strands,
  ))
  use depth_cap <- result.try(parse_depth_input(
    input.depth_mode,
    input.depth_cap,
  ))
  agency_limits.validate(AgencyLimits(fan_out:, session_strands:, depth_cap:))
}

/// Parses an optional positive integer field from trimmed form text.
fn parse_optional_limit_int(raw: String) -> Result(Option(Int), String) {
  case string.trim(raw) {
    "" -> Ok(None)
    text ->
      result.map(int.parse(text), Some)
      |> result.replace_error("expected integer")
  }
}

/// Parses depth mode and optional numeric cap into DepthCap override.
fn parse_depth_input(
  mode: String,
  cap_raw: String,
) -> Result(Option(agency_limits.DepthCap), String) {
  let cap_text = string.trim(cap_raw)

  // Dispatch on the selected depth mode.
  case string.trim(mode) {
    "" | "default" ->
      case cap_text {
        "" -> Ok(None)
        other ->
          result.map(int.parse(other), fn(n) { Some(BoundedDepth(n)) })
          |> result.replace_error("expected integer depth")
      }
    "bounded" ->
      result.map(int.parse(cap_text), fn(n) { Some(BoundedDepth(n)) })
      |> result.replace_error("expected integer depth")
    "unlimited" -> Ok(Some(UnlimitedDepth))
    _ -> Error("invalid depth mode")
  }
}

/// What a start asks for: a session in this daemon's own catalogue, named from
/// the message's first line, or a session another orchestrator names itself.
fn to_create(
  agent: Agent,
  place: creations.Place,
  prompt: String,
  roles: creations.Roles,
  agency: AgencyLimits,
  worktree: Worktree,
) -> Intent {
  // Dispatch between local and relayed session creation.
  case agent {
    Here ->
      Create(
        place:,
        name: session_name(prompt),
        prompt: string.trim(prompt),
        roles:,
        agency:,
        worktree: case worktree, place {
          InTree, creations.Drawn(_) | InTree, creations.Typed(_) ->
            Some("HEAD")
          InTree, _ | InFolder, _ -> None
        },
      )
    Orchestrator(name:) ->
      CreateOn(orchestrator: name, place:, prompt: string.trim(prompt), roles:)
  }
}

/// Whether a workspace of a drawn executor or pool is one the page offers: a name
/// the daemon listed, or, where it listed none, a typed field or a name that could
/// be typed.
fn workspace_offered(
  offers: Offers,
  choice: placements.Choice,
  workspace: Option(String),
) -> Bool {
  case placements.workspaces(offers.cards, choice), workspace {
    [], None -> True
    [], Some(name) -> result.is_ok(creations.registered_name(name))
    listed, Some(name) -> list.contains(listed, name)
    _, None -> False
  }
}

/// The target a catalogue row stands for.
fn target_of(entry: Entry) -> Target {
  case entry.executor {
    Some(executor) -> OnExecutor(executor, Some(entry.workspace))
    None -> Folder(entry.workspace)
  }
}

/// A role is offered when it is the default or a name the configuration listed.
fn in_list(listed: List(String), chosen: Option(String)) -> Bool {
  case chosen {
    None -> True
    Some(text) -> list.contains(listed, text)
  }
}

/// Search text cut to `search_limit` bytes on a character boundary, with controls
/// removed.
fn bounded(text: String) -> String {
  let clean =
    string.to_utf_codepoints(text)
    |> list.filter(fn(point) { string.utf_codepoint_to_int(point) >= 32 })
    |> string.from_utf_codepoints

  take_bytes(string.to_graphemes(clean), search_limit, "")
}

/// Graphemes joined while they fit the byte bound.
fn take_bytes(graphemes: List(String), left: Int, kept: String) -> String {
  case graphemes {
    [] -> kept
    [next, ..rest] ->
      case string.byte_size(next) <= left {
        True -> take_bytes(rest, left - string.byte_size(next), kept <> next)
        False -> kept
      }
  }
}
