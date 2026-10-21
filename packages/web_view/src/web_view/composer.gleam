//// The new-session composer's state and rules: where the agent runs, where the
//// code lives, which model, and when a press may start a session (the placement
//// revamp,
//// [`docs/design-notes/placement-revamp.md`](../../../../docs/design-notes/placement-revamp.md),
//// sections 3 and 4).
////
//// The composer asks two questions and keeps them apart. The Agent chip says which
//// machine runs the agent loop. The Code chip says where the files are and where
//// commands run: a folder on the agent's machine, a workspace registered on an
//// executor, or a workspace on any machine of a pool. In this slice the agent is
//// always the daemon serving the page, because a page can only create and open
//// sessions on its own daemon, so the Agent chip has one choice and says why there
//// is no other. The Model chip merges a profile and a main model, which the
//// daemon already treats as independent.
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

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/text_hygiene
import web_view/creations
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

/// The composer's state.
pub type State {
  State(
    /// Which chip's list is open.
    open: Open,
    /// The code target the person chose, or `None` for the default.
    target: Option(Target),
    /// The profile and model the person chose.
    roles: creations.Roles,
    /// The code picker's search text, bounded by `search_limit`.
    search: String,
    /// Whether a creation is out.
    sending: Sending,
    /// The fixed words of the last refusal, drawn under the form, or `None`.
    refusal: Option(String),
    /// The ticket path of a session that was created and kept but did not take
    /// its first message, until the person opens it. It is the daemon's text and
    /// is never drawn.
    unsent: Option(String),
  )
}

/// Everything a person can do to the composer. None carries text the page did
/// not draw except `Searched` and `Started`, whose text is bounded and judged.
pub type Msg {
  /// A chip was pressed: open its list, or close it if it is open.
  Toggled(chip: Chip)

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

  /// The form was submitted: the first message, and the one other field the
  /// chosen target needs, if any. The message is the browser's text: it names the
  /// session by its first line and, when it is not empty, is sent to the new
  /// session as its first user message. It is bounded here and never drawn.
  Started(prompt: String, typed: Typed)

  /// The "Open the session" button, drawn after a creation whose first message
  /// was not sent: depart for the session the daemon kept.
  OpenedUnsent
}

/// What the page owes after a message.
pub type Intent {
  /// Nothing.
  Stay

  /// The Code chip opened: read the executors and pools again, so their states
  /// are current.
  ReadPlacements

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
    /// The daemon's own name, the machine every session here runs its agent on.
    machine: String,
    /// The folders on the agent's machine the page drew, newest first.
    folders: List(String),
    /// The executors and pools, with the daemon's report once it answered.
    cards: placements.Cards,
    /// The profile names the daemon read from its configuration.
    profiles: List(String),
    /// The model keys the daemon read from its configuration.
    models: List(String),
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
    target: None,
    roles: creations.default_roles,
    search: "",
    sending: Ready,
    refusal: None,
    unsent: None,
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
    Dismissed -> #(State(..state, open: Shut, search: ""), Stay)
    ChoseTarget(target:) -> #(chose_target(state, offers, target), Stay)
    ChoseProfile(profile:) -> #(chose_profile(state, offers, profile), Stay)
    ChoseModel(model:) -> #(chose_model(state, offers, model), Stay)
    Searched(text:) -> #(searched(state, text), Stay)
    Started(prompt:, typed:) -> started(state, offers, recent, prompt, typed)
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
    TypedFolder -> True
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
    Folder(workspace:) -> listing.short_path(workspace)
    TypedFolder -> "a folder you type"
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

// The words that finish a sentence about a registered workspace: its name, or the
// request to type one.
fn in_workspace(workspace: Option(String)) -> List(Piece) {
  case workspace {
    Some(name) -> [Plain(", in the "), Named(name), Plain(" workspace.")]
    None -> [Plain(", in the workspace you name.")]
  }
}

// The words for a message past the bound.
const too_long =
  "That message is too long to send. Shorten it, or send the rest from the session's page."

// The words for a form that still needs a workspace name.
const unnamed = "Name the workspace, or choose another."

// A chip's press opens its list, or closes it when it is the one open. The Code
// chip's opening also owes a read of the placements, so what the list says of
// each executor is current.
fn toggled(state: State, chip: Chip) -> #(State, Intent) {
  case state.open {
    Showing(chip: open) if open == chip -> #(
      State(..state, open: Shut, search: ""),
      Stay,
    )
    Showing(_) | Shut -> #(
      State(..state, open: Showing(chip), search: ""),
      case chip {
        CodeChip -> ReadPlacements
        AgentChip | ModelChip -> Stay
      },
    )
  }
}

// A row of the Code chip's list: honoured only for a target the page drew, and it
// closes the list. A message for a target the page did not draw changes nothing.
fn chose_target(state: State, offers: Offers, target: Target) -> State {
  case offered(offers, target) {
    True ->
      State(
        ..state,
        open: Shut,
        target: Some(target),
        search: "",
        refusal: None,
      )
    False -> state
  }
}

// A profile of the Model chip's list: the default, or one the daemon's
// configuration named. The list stays open, since a main model is chosen beside it.
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

// A main model of the Model chip's list, held as a profile is.
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

// Search text applies only while the Code chip's list is open, is cut to the
// bound on a character boundary and keeps no control character.
fn searched(state: State, text: String) -> State {
  case state.open {
    Showing(chip: CodeChip) -> State(..state, search: bounded(text))
    Showing(_) | Shut -> state
  }
}

// The start of a session: nothing happens while one is out or when no target is
// in force; the roles must still be ones the page offers; and the place must be
// buildable from what the form sent. Otherwise the creation is asked for and
// nothing else is held but the fact that it is out.
fn started(
  state: State,
  offers: Offers,
  recent: List(Recent),
  prompt: String,
  typed: Typed,
) -> #(State, Intent) {
  case state.sending, chosen(state, offers, recent) {
    Out, _ | Ready, None -> #(state, Stay)
    Ready, Some(target) ->
      case
        in_list(offers.profiles, state.roles.profile)
        && in_list(offers.models, state.roles.model),
        string.byte_size(prompt) > prompt_limit,
        place(target, typed)
      {
        False, _, _ -> #(state, Stay)
        True, True, _ -> #(State(..state, refusal: Some(too_long)), Stay)
        True, False, Error(words) -> #(
          State(..state, refusal: Some(words)),
          Stay,
        )
        True, False, Ok(place) -> #(
          State(..state, sending: Out, refusal: None, unsent: None),
          Create(
            place:,
            name: session_name(prompt),
            prompt: string.trim(prompt),
            roles: state.roles,
          ),
        )
      }
  }
}

// Whether a workspace of a drawn executor or pool is one the page offers: a name
// the daemon listed, or, where it listed none, a typed field or a name that could
// be typed.
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

// The target a catalogue row stands for.
fn target_of(entry: Entry) -> Target {
  case entry.executor {
    Some(executor) -> OnExecutor(executor, Some(entry.workspace))
    None -> Folder(entry.workspace)
  }
}

// A role is offered when it is the default or a name the configuration listed.
fn in_list(listed: List(String), chosen: Option(String)) -> Bool {
  case chosen {
    None -> True
    Some(text) -> list.contains(listed, text)
  }
}

// Search text cut to `search_limit` bytes on a character boundary, with controls
// removed.
fn bounded(text: String) -> String {
  let clean =
    string.to_utf_codepoints(text)
    |> list.filter(fn(point) { string.utf_codepoint_to_int(point) >= 32 })
    |> string.from_utf_codepoints

  take_bytes(string.to_graphemes(clean), search_limit, "")
}

// Graphemes joined while they fit the byte bound.
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
