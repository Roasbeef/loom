//// The new-session view: a centred composer, the places a session worked in
//// recently, three chips (Agent, Code, Model) and a sentence that says what the
//// chips add up to (the placement revamp,
//// [`docs/design-notes/placement-revamp.md`](../../../../../docs/design-notes/placement-revamp.md),
//// sections 4.1 to 4.3 and 5).
////
//// It is the home's centre while the person is making a session, and it is
//// drawn only for the owner's operating page, which is the one page that holds
//// `Start.create`. A member's or an observer's home draws the list instead and
//// has no composer to press.
////
//// ## What it draws, and what the page decides
////
//// The view draws a state and decides nothing. `web_view/composer` holds the
//// state and the rules: which target is in force, what an `Offers` list admits,
//// when a start may go to the daemon. This module turns them into a tree whose
//// every button carries a message the server built from the lists it holds, so a
//// browser's event names only the path it fired at (`docs/lustre.md`, "Only
//// events you attach can arrive").
////
//// ## The three chips
////
//// A chip is a button that opens a list: a popover on a wide window, a bottom
//// sheet on a phone. The two are one tree, and the stylesheet decides which they
//// look like, so the list has the same rows and the same reasons either way. An
//// open list has a scrim behind it that closes it when pressed, so the page needs
//// no listener on the document.
////
//// The Agent list has a row for this daemon and one for each orchestrator the
//// daemon relays for (protocol-change/094). An orchestrator that has not
//// answered, or refused this page, is a row that cannot be pressed and says why.
//// Once another orchestrator is the agent, the Code list below is that
//// orchestrator's: its folders, executors and pools, no typed path (the daemon
//// serving the page cannot judge a path on another machine), and one disabled row
//// saying that the other machine's files are out of its reach.
////
//// The Code list is the one that grows. Its sections come in a fixed order:
//// folders on the agent's machine, then one section for each executor with the
//// workspaces it reported, then one for each pool. A search field narrows every
//// section at once. An executor the daemon reached and found down draws one
//// disabled row with its reason, and a row that cannot work looks different from
//// one that can, and says why in words. An executor that reported no workspaces
//// offers one row that asks for a name, and the name is typed into the form below.
////
//// ## The one form
////
//// The composer is one form. It has a message box, the one other field the chosen
//// target needs (a folder's path, or a workspace's name, and only for those
//// targets), and a Start button. `fields` accepts exactly that and nothing else,
//// and refuses an event with an extra field, a repeat or a missing one, as every
//// form of this page does. The target, the profile and the model are not fields:
//// they are state the page holds, which the chips' buttons set.
////
//// The box is the session's first message. The daemon creates the session as it
//// always did, names it from the message's first line, sends the message to the
//// main strand as the owner's first prompt and opens the page. The text is the
//// browser's and is never drawn back: the box is uncontrolled, the server never
//// writes into it, and the session's own page draws the message as a user line,
//// as text. A message that was not accepted leaves the session kept, and this view
//// says so in one line with a button that opens it.
////
//// Every name, folder, executor, pool, profile and model is a text node. A folder's
//// whole path is a `title` Lustre escapes. The only strings that become classes
//// are fixed words chosen by `case`.
////
//// ## The first run
////
//// A daemon with no session yet gets a pane of its own words (`History`): a
//// heading that says this is the first session, one line about what will be
//// listed once sessions exist, and, while the daemon's configuration lists no
//// model, a note that says what the page can and cannot know about that. The
//// page is given only the model keys a `loom.toml` names
//// (`docs/configuration.md`, "Choosing a model for one session"). A daemon with
//// no file builds one catalogue entry from the `LOOM_*` environment variables,
//// and that entry is not in the list, so an empty list does not prove that a
//// start would fail. The note therefore informs and does not block Start. What
//// does block it is a fact the page holds: no folder is chosen yet, and a start
//// with no target is a press that does nothing. The button is disabled and the
//// reason is written beside it.
////
//// ## The advanced limits
////
//// The subagent limits are behind an "Advanced" disclosure under the chips,
//// with plain labels and the daemon's own defaults (`core/agency_limits`) as
//// field values. The fields sit outside the `form` element in the tree and
//// belong to it through the `form` attribute, so the submit carries them and
//// the decoder's rule (`fields_with_limits`) is the one it always was.
////
//// ## Flow
////
//// `view` → `banner` → `recent` → `form` → `chips` → `advanced` → `summary`
////
//// 1. `view` lays the pane out: the banner, the links to the other lists, the
////    heading, then the rest.
//// 2. `banner` is the phone's line for the session that needs the person, and
////    `recent` is the places a session worked in.
//// 3. `form` draws the message box, the field the target needs and Start, with
////    `start_fields_with_limits` as its submit's decoder and `fields` as its one
////    rule. `readiness` decides whether Start can be pressed and why not.
//// 4. `chips` draws the three chips, each with its list while open
////    (`agent_list`, `code_list`, `model_list`), `advanced` the limits
////    disclosure, and `summary` the sentence once a folder is chosen.
//// 5. `refusal` and `unsent` say what a refused or half-done start left.
////
//// ## Examples
////
//// ```gleam
//// // new_session.view(pane)
//// ```

import core/agency_limits
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import lustre/event
import web_view/composer.{
  type Agent, type Chip, type Offers, type Piece, type Recent, type State,
  type Target, type Typed,
}
import web_view/folder_browse.{type Child, type Listing}
import web_view/listing
import web_view/placements
import web_view/sessions.{type Entry}

/// The messages a page's buttons send, as constructors the view applies to the
/// values it draws. They are the caller's, fixed when the tree is drawn.
pub type Presses(message) {
  Presses(
    /// A chip was pressed.
    toggle: fn(Chip) -> message,
    /// A row of the Agent list was pressed.
    agent: fn(Agent) -> message,
    /// The scrim behind an open list was pressed.
    dismiss: message,
    /// A row of the Code list, or a recent place, was pressed.
    choose: fn(Target) -> message,
    /// A profile was pressed, or the default.
    profile: fn(Option(String)) -> message,
    /// A main model was pressed, or the default.
    model: fn(Option(String)) -> message,
    /// The Subagent limits disclosure toggle was pressed.
    toggle_limits: message,
    /// The Worktree toggle was pressed.
    toggle_worktree: message,
    /// The form was submitted carrying optional subagent limit fields.
    start_with_limits: fn(String, Typed, composer.LimitsInput) -> message,
    /// The code list's search text changed.
    search: fn(String) -> message,
    /// A found folder's row was pressed, by its index in the hits the page holds.
    found: fn(Int) -> message,
    /// Enter was pressed in the search field.
    enter: message,
    /// "Open folder…" was pressed: open the folder picker.
    browse: message,
    /// A child directory's row of the picker was pressed, by its index in the
    /// listing the page holds.
    descend: fn(Int) -> message,
    /// A breadcrumb or the way up was pressed, by the depth of the ancestor.
    ascend: fn(Int) -> message,
    /// "Use this folder" was pressed.
    pick: message,
    /// "Back to the list" was pressed.
    leave_browser: message,
    /// The form was submitted with this message and this typed field.
    start: fn(String, Typed) -> message,
    /// The "Open the session" button, shown after a creation whose first message
    /// was not sent.
    depart: message,
    /// A session's row, in the banner, was pressed.
    open: fn(String) -> message,
    /// The link to the full session list was pressed.
    listing: message,
  )
}

/// Everything the view draws from.
pub type Pane(message) {
  Pane(
    /// The composer's state.
    state: State,
    /// The lists the page draws its choices from.
    offers: Offers,
    /// The target in force (`composer.chosen`).
    target: Option(Target),
    /// The places sessions worked in recently.
    recent: List(Recent),
    /// The sessions waiting on an approval, newest first. The phone's banner
    /// names the first.
    waiting: List(Entry),
    /// Whether the daemon has any session to list yet.
    history: History,
    /// What the page's buttons send.
    presses: Presses(message),
  )
}

/// Whether the daemon lists a session yet. A daemon with none is on its first
/// run, and the pane says what will appear here once one exists.
pub type History {
  /// The list is empty: the first run.
  NoSessions

  /// The list has at least one session, running or saved.
  HasSessions
}

/// Whether Start can be pressed, and when it cannot, why.
pub type Readiness {
  /// The press would create a session.
  Startable

  /// A creation is already out, so the button waits for its answer.
  Starting

  /// The press would do nothing yet, for the reason written here.
  Held(reason: String)
}

/// The id the form carries, so fields drawn outside it can belong to it.
const form_id = "new-session-form"

/// The id of the sentence that says why Start is disabled.
const reason_id = "start-reason"

/// The id of the advanced limits, which the disclosure's button controls.
const advanced_id = "advanced-limits"

/// Which extra field a target needs the form to carry.
pub type Needs {
  /// Only the message.
  NameOnly

  /// The message and a folder's path.
  NameAndPath

  /// The message and a workspace's name.
  NameAndWorkspace
}

/// What the form needs for a target: a typed folder asks for a path, and an
/// executor or pool that reported no workspaces asks for a name. Every other
/// target is complete without more.
///
/// ## Examples
///
/// ```gleam
/// assert new_session.needs(Some(composer.TypedFolder)) == new_session.NameAndPath
/// assert new_session.needs(None) == new_session.NameOnly
/// ```
pub fn needs(target: Option(Target)) -> Needs {
  case target {
    Some(composer.TypedFolder) -> NameAndPath
    Some(composer.OnExecutor(workspace: None, ..))
    | Some(composer.InPool(workspace: None, ..)) -> NameAndWorkspace
    Some(composer.Folder(_))
    | Some(composer.Project(_))
    | Some(composer.Picked(_))
    | Some(composer.OnExecutor(workspace: Some(_), ..))
    | Some(composer.InPool(workspace: Some(_), ..))
    | None -> NameOnly
  }
}

/// The message and the typed field a submitted form's fields stand for, given what
/// the form was drawn to carry: exactly one `prompt`, the one other field `needs`
/// names and, for `NameOnly`, nothing else. A repeat, an unknown field or a
/// missing one refuses the event.
///
/// ## Examples
///
/// ```gleam
/// assert new_session.fields([#("prompt", "x")], new_session.NameOnly)
///   == Ok(#("x", composer.Nothing))
/// assert new_session.fields([#("prompt", "x"), #("path", "/w")], new_session.NameOnly)
///   == Error(Nil)
/// assert new_session.fields([#("path", "/w"), #("prompt", "x")], new_session.NameAndPath)
///   == Ok(#("x", composer.Path("/w")))
/// ```
pub fn fields(
  listed: List(#(String, String)),
  needs: Needs,
) -> Result(#(String, Typed), Nil) {
  let names = list.filter(listed, fn(field) { field.0 == "prompt" })
  let rest = list.filter(listed, fn(field) { field.0 != "prompt" })

  // Dispatch on fields state.
  case names, rest, needs {
    [#(_, name)], [], NameOnly -> Ok(#(name, composer.Nothing))
    [#(_, name)], [#("path", text)], NameAndPath ->
      Ok(#(name, composer.Path(text)))
    [#(_, name)], [#("workspace", text)], NameAndWorkspace ->
      Ok(#(name, composer.Workspace(text)))
    _, _, _ -> Error(Nil)
  }
}

/// Decodes form fields including optional collapsed subagent limit inputs.
///
/// ## Examples
///
/// ```gleam
/// assert new_session.fields_with_limits([#("prompt", "x")], new_session.NameOnly, composer.LimitsClosed)
///   == Ok(#("x", composer.Nothing, composer.default_limits_input))
/// ```
pub fn fields_with_limits(
  listed: List(#(String, String)),
  needs: Needs,
  limits_open: composer.LimitsDisclosure,
) -> Result(#(String, Typed, composer.LimitsInput), Nil) {
  // Dispatch on whether the subagent limits disclosure is expanded.
  case limits_open {
    composer.LimitsClosed ->
      case fields(listed, needs) {
        Ok(#(prompt, typed)) ->
          Ok(#(prompt, typed, composer.default_limits_input))
        Error(Nil) -> Error(Nil)
      }
    composer.LimitsOpen -> decode_open_limits_fields(listed, needs)
  }
}

/// Decodes form fields when the subagent limits disclosure is expanded.
fn decode_open_limits_fields(
  listed: List(#(String, String)),
  needs: Needs,
) -> Result(#(String, Typed, composer.LimitsInput), Nil) {
  let base =
    list.filter(listed, fn(pair) {
      pair.0 != "fan_out"
      && pair.0 != "session_strands"
      && pair.0 != "depth_mode"
      && pair.0 != "depth_cap"
    })
  let fan_outs = list.filter(listed, fn(pair) { pair.0 == "fan_out" })
  let session_strands =
    list.filter(listed, fn(pair) { pair.0 == "session_strands" })
  let depth_modes = list.filter(listed, fn(pair) { pair.0 == "depth_mode" })
  let depth_caps = list.filter(listed, fn(pair) { pair.0 == "depth_cap" })

  // Reject missing or repeated limit inputs beside the base form fields.
  case fields(base, needs), fan_outs, session_strands, depth_modes, depth_caps {
    Ok(#(prompt, typed)),
      [#(_, fan_out)],
      [#(_, session_strands)],
      [#(_, depth_mode)],
      [#(_, depth_cap)]
    ->
      Ok(#(
        prompt,
        typed,
        composer.LimitsInput(
          fan_out:,
          session_strands:,
          depth_mode:,
          depth_cap:,
        ),
      ))
    _, _, _, _, _ -> Error(Nil)
  }
}

/// The composer's view.
///
/// ## Examples
///
/// ```gleam
/// // new_session.view(pane)
/// ```
pub fn view(pane: Pane(message)) -> Element(message) {
  html.div([attribute.class("new-pane")], [
    banner(pane),
    html.div([attribute.class("new-wrap")], [
      html.div([attribute.class("new-col")], [
        links(pane),
        heading(pane.history),
        setup_note(pane),
        recent(pane),
        form(pane),
        chips(pane),
        advanced(pane),
        summary(pane),
        refusal(pane.state),
        unsent(pane),
      ]),
    ]),
  ])
}

/// The heading and the one line under it. A daemon with no session says what
/// will be listed once there is one; a daemon with sessions asks the question
/// and needs nothing more, since the chips below say where the agent runs and
/// where the code is.
fn heading(history: History) -> Element(message) {
  // The first run has a line about what the page becomes.
  case history {
    NoSessions ->
      html.div([attribute.class("new-head")], [
        html.h1([], [html.text("Start your first session")]),
        html.p([attribute.class("lede")], [
          html.text(
            "Sessions you start are listed in the sidebar, with the ones that need you first.",
          ),
        ]),
      ])
    HasSessions ->
      html.div([attribute.class("new-head")], [
        html.h1([], [html.text("What should the agent work on?")]),
      ])
  }
}

/// The link to the full session list, in a row above the heading, once there are
/// sessions to list. A daemon with none draws no row. The way back to the inbox
/// is the rail's folders, which every page of the home draws.
fn links(pane: Pane(message)) -> Element(message) {
  case pane.history {
    NoSessions -> element.none()
    HasSessions ->
      html.nav([attribute.class("new-links")], [
        link("All sessions", pane.presses.listing),
      ])
  }
}

/// One link-styled button of the row above the heading.
fn link(words: String, press: message) -> Element(message) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class("link-button"),
      event.on_click(press),
    ],
    [html.text(words)],
  )
}

/// What the page knows about models on a first run, drawn only for a daemon with
/// no session whose configuration lists no model. The page sees the keys of
/// `[models.<name>]` tables and nothing else, so it cannot tell a daemon with no
/// model from one that reads the `LOOM_*` environment variables
/// (`docs/configuration.md`, "How the file is found"). The note says both, and
/// Start is left to the folder rule.
fn setup_note(pane: Pane(message)) -> Element(message) {
  case
    pane.history,
    pane.offers.models,
    pane.offers.profiles,
    pane.state.agent
  {
    NoSessions, [], [], composer.Here ->
      html.div([attribute.class("setup-note"), attribute.role("note")], [
        html.p([attribute.class("setup-title")], [
          html.text("No model is listed in a loom.toml"),
        ]),
        html.p([], [
          html.text(
            "A session uses the model that the LOOM_MODEL, LOOM_BASE_URL and API-key environment variables name, if they are set; this page cannot see them. To choose models, add a [models.<name>] table to your loom.toml and start loomd or loom with --config <path>. docs/configuration.md lists every key.",
          ),
        ]),
      ])
    _, _, _, _ -> element.none()
  }
}

/// The phone's banner: the session that most needs the person, with a count of
/// the others. A press opens that session. The stylesheet draws it only on a
/// narrow window, where the sidebar is closed most of the time.
fn banner(pane: Pane(message)) -> Element(message) {
  // Dispatch on banner state.
  case pane.waiting {
    [] -> element.none()
    [first, ..rest] -> {
      // Dispatch on banner state.
      let others = case rest {
        [] -> ""
        _ -> " · and " <> count_words(list.length(rest)) <> " more need you"
      }

      html.button(
        [
          attribute.type_("button"),
          attribute.class("banner"),
          event.on_click(pane.presses.open(first.id)),
        ],
        [
          html.span(
            [attribute.class("banner-dot"), attribute.aria_hidden(True)],
            [],
          ),
          html.span([attribute.class("banner-text")], [
            html.span([attribute.class("banner-title")], [
              html.text(sessions.label(first) <> " needs you"),
            ]),
            html.span([attribute.class("banner-sub")], [
              html.text(
                pane.offers.machine
                <> " → "
                <> listing.entry_words(
                  first,
                  listing.place(first, pane.offers.machine),
                )
                <> others,
              ),
            ]),
          ]),
          html.span([attribute.class("banner-go")], [html.text("Review")]),
        ],
      )
    }
  }
}

// A count as words: the digits, since a count here is small.
fn count_words(count: Int) -> String {
  string.inspect(count)
}

/// "Start again where you worked": one button for each recent place, which sets
/// the Code chip to it. Nothing is drawn for a daemon with no session yet.
fn recent(pane: Pane(message)) -> Element(message) {
  case pane.recent {
    [] -> element.none()
    rows ->
      html.div(
        [
          attribute.class("recent"),
          attribute.role("group"),
          attribute.aria_label("Recent places"),
        ],
        [
          html.p([attribute.class("recent-head")], [
            html.text("Start again where you worked"),
          ]),
          html.ul(
            [attribute.class("recent-list")],
            list.map(rows, fn(row) {
              html.li([], [
                html.button(
                  [
                    attribute.type_("button"),
                    attribute.class("recent-row"),
                    event.on_click(pane.presses.choose(row.target)),
                  ],
                  [
                    html.span([attribute.class("recent-place")], [
                      icon(Laptop),
                      html.span([attribute.class("recent-agent")], [
                        html.text(row.place.agent),
                      ]),
                      html.span(
                        [attribute.class("arrow"), attribute.aria_hidden(True)],
                        [
                          html.text("→"),
                        ],
                      ),
                      icon(code_icon(row.target)),
                      html.span([attribute.title(code_title(row.place.code))], [
                        html.text(listing.code_words(row.place.code)),
                      ]),
                    ]),
                    html.span([attribute.class("recent-hint")], [
                      html.text(composer.hint(row.names)),
                    ]),
                  ],
                ),
              ])
            }),
          ),
        ],
      )
  }
}

/// The one form: the name, the field the target needs, and Start. The form's
/// handler is built for the fields this tree draws, so the decoder refuses any
/// other set. A creation that is out disables the button and says so.
fn form(pane: Pane(message)) -> Element(message) {
  let needed = needs(pane.target)

  // Dispatch on form state.
  let extra = case needed {
    NameOnly -> []
    NameAndPath -> [typed_field("path", "Folder path, for example ~/code/app")]
    NameAndWorkspace -> [
      typed_field("workspace", "Workspace name on that machine"),
    ]
  }

  let body = list.append(extra, [cbar(pane)])

  html.form(
    [
      attribute.id(form_id),
      attribute.class("place-composer"),
      event.on(
        "submit",
        start_fields_with_limits(
          needed,
          pane.state.limits,
          pane.presses.start_with_limits,
        ),
      )
        |> event.prevent_default,
    ],
    [
      html.textarea(
        [
          attribute.name("prompt"),
          attribute.class("composer-name"),
          attribute.aria_label("Task"),
          attribute.placeholder("Describe a task or ask a question"),
          attribute.attribute("rows", "3"),
          attribute.attribute("maxlength", "16000"),
        ],
        "",
      ),
      ..body
    ],
  )
}

/// Whether Start can be pressed. A creation that is out waits for its answer.
/// With no folder chosen the press would do nothing at all (`composer.started`
/// returns without a creation), so the page says so instead of offering it. The
/// words are fixed here.
///
/// ## Examples
///
/// ```gleam
/// // new_session.readiness(pane) == new_session.Held("Choose a folder first.")
/// ```
pub fn readiness(pane: Pane(message)) -> Readiness {
  case pane.state.sending, pane.target {
    composer.Out, _ -> Starting
    composer.Ready, None -> Held("Choose a folder first.")
    composer.Ready, Some(_) -> Startable
  }
}

/// Renders the submit bar of the new-session composer form: the reason Start is
/// disabled, when it is, at the left, and the button at the right.
fn cbar(pane: Pane(message)) -> Element(message) {
  let ready = readiness(pane)

  // The reason is written only while Start is held.
  let reason = case ready {
    Held(words) -> [
      html.span([attribute.id(reason_id), attribute.class("send-reason")], [
        html.text(words),
      ]),
    ]
    Startable | Starting -> []
  }

  // The button names the reason so a screen reader reads it with the button.
  let described = case ready {
    Held(_) -> [attribute.attribute("aria-describedby", reason_id)]
    Startable | Starting -> []
  }

  html.div([attribute.class("cbar")], [
    html.span([attribute.class("cbar-note")], reason),
    html.button(
      list.append(
        [
          attribute.type_("submit"),
          attribute.class("place-send"),
          attribute.disabled(ready != Startable),
          attribute.aria_label("Start session"),
        ],
        described,
      ),
      [
        icon(Send),
        html.span([attribute.class("send-word")], [
          html.text(case ready {
            Starting -> "Starting"
            Startable | Held(_) -> "Start"
          }),
        ]),
      ],
    ),
  ])
}

/// The Advanced disclosure under the chips: a button, and while it is open the
/// four subagent limits in plain words. Only a session on this daemon has them.
fn advanced(pane: Pane(message)) -> Element(message) {
  let expanded = pane.state.limits == composer.LimitsOpen

  let toggle =
    html.button(
      [
        attribute.type_("button"),
        attribute.class("adv-toggle"),
        attribute.aria_expanded(expanded),
        attribute.attribute("aria-controls", advanced_id),
        event.on_click(pane.presses.toggle_limits),
      ],
      [
        html.text("Advanced"),
        html.span(
          [attribute.class("adv-chevron"), attribute.aria_hidden(True)],
          [
            icon(Chevron),
          ],
        ),
      ],
    )

  // Only a session on this daemon has limits to set, and they are drawn only
  // while the disclosure is open.
  case pane.state.agent, pane.state.limits {
    composer.Orchestrator(_), _ -> element.none()
    composer.Here, composer.LimitsClosed ->
      html.div([attribute.class("adv")], [toggle])
    composer.Here, composer.LimitsOpen ->
      html.div([attribute.class("adv")], [toggle, limits_fields()])
  }
}

/// The four limits, each a label, a control showing the value in force and a line
/// that says what it does. The values are the daemon's own defaults, so a start
/// that leaves them alone asks for what it would have got.
fn limits_fields() -> Element(message) {
  html.div([attribute.id(advanced_id), attribute.class("limits-grid")], [
    limit_field(
      "Subagents at once",
      "How many subagents may run at the same time.",
      limit_number_input(
        "fan_out",
        agency_limits.default_fan_out,
        agency_limits.max_fan_out,
      ),
    ),
    limit_field(
      "Subagents per session",
      "How many subagents one session may start in all.",
      limit_number_input(
        "session_strands",
        agency_limits.default_session_strands,
        agency_limits.max_session_strands,
      ),
    ),
    limit_field(
      "Nesting",
      "Whether a subagent may start subagents of its own.",
      depth_mode_select(),
    ),
    limit_field(
      "Levels of nesting",
      "Used when nesting is limited to a number of levels.",
      limit_number_input(
        "depth_cap",
        agency_limits.default_depth_cap,
        agency_limits.max_depth_cap,
      ),
    ),
  ])
}

/// One labelled limit: the label's words above, its control, and the line under.
fn limit_field(
  label: String,
  help: String,
  control: Element(message),
) -> Element(message) {
  html.label([attribute.class("adv-field")], [
    html.span([attribute.class("adv-label")], [html.text(label)]),
    control,
    html.span([attribute.class("adv-help")], [html.text(help)]),
  ])
}

/// Renders one uncontrolled numeric input of the limits, showing its default as
/// a value. It belongs to the composer's form by the `form` attribute.
fn limit_number_input(name: String, value: Int, max: Int) -> Element(message) {
  html.input([
    attribute.type_("number"),
    attribute.name(name),
    attribute.attribute("form", form_id),
    attribute.class("adv-input"),
    attribute.value(int.to_string(value)),
    attribute.attribute("min", "1"),
    attribute.attribute("max", int.to_string(max)),
  ])
}

/// Renders the nesting selector (`default`, `bounded`, `unlimited`).
fn depth_mode_select() -> Element(message) {
  html.select(
    [
      attribute.name("depth_mode"),
      attribute.attribute("form", form_id),
      attribute.class("adv-input"),
    ],
    [
      html.option(
        [attribute.value("default")],
        "Default ("
          <> int.to_string(agency_limits.default_depth_cap)
          <> " level)",
      ),
      html.option([attribute.value("bounded")], "Limit to the levels below"),
      html.option([attribute.value("unlimited")], "No limit"),
    ],
  )
}

/// A text field the target needs. It is uncontrolled and the server never writes
/// it back, so what the person typed is not echoed, even after a refusal.
fn typed_field(name: String, placeholder: String) -> Element(message) {
  html.input([
    attribute.type_("text"),
    attribute.name(name),
    attribute.class("composer-typed"),
    attribute.aria_label(placeholder),
    attribute.placeholder(placeholder),
    attribute.attribute("maxlength", "4096"),
    attribute.autocomplete("off"),
  ])
}

/// The submit's decoder, for the fields this tree drew. A set of fields the form
/// was not drawn with fails to decode, so the runtime drops the event.
fn start_fields_with_limits(
  needed: Needs,
  limits_open: composer.LimitsDisclosure,
  start: fn(String, Typed, composer.LimitsInput) -> message,
) -> decode.Decoder(message) {
  use listed <- decode.subfield(
    ["detail", "formData"],
    decode.list(form_field()),
  )

  // Dispatch on start_fields state.
  case fields_with_limits(listed, needed, limits_open) {
    Ok(#(name, typed, limits)) -> decode.success(start(name, typed, limits))
    Error(Nil) ->
      decode.failure(
        start("", composer.Nothing, composer.default_limits_input),
        "composer form",
      )
  }
}

fn form_field() -> decode.Decoder(#(String, String)) {
  use name <- decode.field(0, decode.string)
  use value <- decode.field(1, decode.string)
  decode.success(#(name, value))
}

/// The three chips, each with its list while it is the open one. The scrim comes
/// first so the lists sit above it.
fn chips(pane: Pane(message)) -> Element(message) {
  let open = pane.state.open

  // Dispatch on chips state.
  let scrim = case open {
    composer.Showing(_) -> [
      html.button(
        [
          attribute.type_("button"),
          attribute.class("pop-scrim"),
          attribute.aria_label("Close the list"),
          event.on_click(pane.presses.dismiss),
        ],
        [],
      ),
    ]
    composer.Shut -> []
  }

  html.div(
    [attribute.class("place-chips")],
    list.append(scrim, [
      chip(
        pane,
        composer.AgentChip,
        agent_icon(pane.state.agent),
        "Agent",
        pane.offers.machine,
        agent_list(pane),
      ),
      chip(
        pane,
        composer.CodeChip,
        option.map(pane.target, code_icon) |> option.unwrap(Folder),
        "Code",
        case pane.target {
          Some(target) -> composer.target_words(target)
          None -> "Choose a folder…"
        },
        code_list(pane),
      ),
      chip(
        pane,
        composer.ModelChip,
        Spark,
        "Model",
        composer.role_words(pane.state.roles),
        model_list(pane),
      ),
      worktree_toggle(pane),
    ]),
  )
}

/// The Worktree toggle beside the chips: pressed, the session works in its own
/// Git worktree of the folder and its changes stay out of the folder. It is
/// drawn only where it can be honoured, for a folder on this daemon's machine,
/// and its state is the page's, so the form carries no field for it.
fn worktree_toggle(pane: Pane(message)) -> Element(message) {
  // Dispatch on whether the target in force is a folder on this machine.
  case pane.state.agent, pane.target {
    composer.Here, Some(composer.Folder(_))
    | composer.Here, Some(composer.TypedFolder)
    | composer.Here, Some(composer.Picked(_))
    ->
      html.button(
        [
          attribute.type_("button"),
          attribute.class("place-chip"),
          attribute.attribute("aria-pressed", case pane.state.worktree {
            composer.InTree -> "true"
            composer.InFolder -> "false"
          }),
          event.on_click(pane.presses.toggle_worktree),
        ],
        [
          html.span([attribute.class("place-chip-key")], [html.text("Worktree")]),
          html.span([attribute.class("place-chip-value")], [
            html.text(case pane.state.worktree {
              composer.InTree -> "on"
              composer.InFolder -> "off"
            }),
          ]),
        ],
      )
    composer.Here, _ | composer.Orchestrator(_), _ -> element.none()
  }
}

/// One chip: a button that says what it holds, and the list under it while open.
fn chip(
  pane: Pane(message),
  which: Chip,
  glyph: Icon,
  label: String,
  words: String,
  list_: Element(message),
) -> Element(message) {
  let showing = pane.state.open == composer.Showing(which)

  html.div([attribute.class("cw")], [
    html.button(
      [
        attribute.type_("button"),
        attribute.class("place-chip"),
        attribute.attribute("aria-haspopup", "listbox"),
        attribute.attribute("aria-expanded", expanded(pane.state.open, which)),
        event.on_click(pane.presses.toggle(which)),
      ],
      [
        icon(glyph),
        html.span([attribute.class("place-chip-key")], [html.text(label)]),
        html.span([attribute.class("place-chip-value")], [html.text(words)]),
        icon(Chevron),
      ],
    ),
    case showing {
      True -> list_
      False -> element.none()
    },
  ])
}

// The words of a chip's `aria-expanded`.
fn expanded(open: composer.Open, which: Chip) -> String {
  case open == composer.Showing(which) {
    True -> "true"
    False -> "false"
  }
}

/// The Agent chip's list: this daemon, then each orchestrator it relays for. A row
/// that can be chosen is a button whose message names the machine the page drew.
/// A row that cannot yet, or at all, is text with its reason, so a press the page
/// would refuse is never offered. The note says what a switch does to the other
/// choices, which is what `composer.kept` does.
fn agent_list(pane: Pane(message)) -> Element(message) {
  html.div(
    [
      attribute.class("pop"),
      attribute.role("listbox"),
      attribute.aria_label("Where the agent runs"),
    ],
    [
      section_head(
        "Agent runs on",
        "holds the conversation and calls the model",
      ),
      ..list.append(list.map(pane.offers.agents, agent_row(pane, _)), [
        html.p([attribute.class("pop-foot")], [
          html.text(
            "Switching keeps the workspace choice when the new machine offers it, and clears it otherwise.",
          ),
        ]),
      ])
    ],
  )
}

/// One row of the Agent list. The machine in force is marked.
fn agent_row(
  pane: Pane(message),
  candidate: composer.Candidate,
) -> Element(message) {
  let current = pick(pane.state.agent, candidate.agent)
  let body = fn(detail: String) {
    [
      icon(agent_icon(candidate.agent)),
      html.span([attribute.class("opt-text")], [
        html.span([], [html.text(candidate.name)]),
        ..case detail {
          "" -> []
          words -> [html.small([], [html.text(words)])]
        }
      ]),
    ]
  }

  // Dispatch on agent_row state.
  case candidate.standing {
    composer.Choosable(detail:) ->
      html.button(
        [
          attribute.type_("button"),
          attribute.class("opt"),
          attribute.role("option"),
          attribute.aria_selected(selected(current)),
          event.on_click(pane.presses.agent(candidate.agent)),
        ],
        list.append(body(detail), check_if(current)),
      )
    composer.Checking ->
      html.div(
        [
          attribute.class("opt"),
          attribute.role("option"),
          attribute.aria_disabled(True),
        ],
        list.append(body(""), [
          html.span([attribute.class("opt-state")], [html.text("checking")]),
        ]),
      )
    composer.Unavailable(reason:) ->
      html.div(
        [
          attribute.class("opt"),
          attribute.role("option"),
          attribute.aria_disabled(True),
        ],
        list.append(body(reason), [
          html.span([attribute.class("opt-state")], [html.text("unavailable")]),
        ]),
      )
  }
}

// The glyph of an agent: a laptop for this daemon, a server for another
// orchestrator.
fn agent_icon(agent: Agent) -> Icon {
  case agent {
    composer.Here -> Laptop
    composer.Orchestrator(_) -> Server
  }
}

/// The Model chip's list: the profiles, then the main models, each with the
/// configuration's own first. Both sections are always drawn so the person sees
/// what is configured, and a daemon with neither says so.
fn model_list(pane: Pane(message)) -> Element(message) {
  let roles = pane.state.roles
  let presses = pane.presses

  html.div(
    [
      attribute.class("pop"),
      attribute.role("listbox"),
      attribute.aria_label("Which model"),
    ],
    [
      section_head("Profile", "a set of models for each job"),
      ..list.append(
        default_profile(pane),
        list.append(
          list.map(pane.offers.profiles, fn(name) {
            choice(
              name,
              pick(roles.profile, Some(name)),
              presses.profile(Some(name)),
            )
          }),
          [
            html.div([attribute.class("sep")], []),
            section_head("Main model", "pins the main role"),
            choice("Default", pick(roles.model, None), presses.model(None)),
            ..list.map(pane.offers.models, fn(name) {
              choice(
                name,
                pick(roles.model, Some(name)),
                presses.model(Some(name)),
              )
            })
          ],
        ),
      )
    ],
  )
}

/// The profile list's "Default" row. A box has no default profile, since a create
/// there must name one (`composer.kept`), so a box's list holds only the profiles it
/// offers.
fn default_profile(pane: Pane(message)) -> List(Element(message)) {
  case pane.state.agent, pane.offers.profiles {
    composer.Orchestrator(_), [_, ..] -> []
    composer.Orchestrator(_), [] | composer.Here, _ -> [
      choice(
        "Default",
        pick(pane.state.roles.profile, None),
        pane.presses.profile(None),
      ),
    ]
  }
}

/// A row of the Model list.
fn choice(label: String, pick: Pick, press: message) -> Element(message) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class("opt"),
      attribute.role("option"),
      attribute.aria_selected(selected(pick)),
      event.on_click(press),
    ],
    [
      html.span([attribute.class("opt-text")], [
        html.span([], [html.text(label)]),
      ]),
      ..check_if(pick)
    ],
  )
}

// A section's heading inside a list, with a quiet gloss.
fn section_head(title: String, gloss: String) -> Element(message) {
  html.p([attribute.class("pop-head")], [
    html.text(title),
    html.small([], [html.text(gloss)]),
  ])
}

/// The Code chip's list: the folder picker while "Open folder…" has it open, and
/// the list of places otherwise. Both sit inside `<loom-picklist>`, which moves
/// focus with the arrow keys, closes the list on Escape and focuses the search
/// field when the list opens, none of which the server need hear of.
fn code_list(pane: Pane(message)) -> Element(message) {
  // The list of places is the default; the picker takes its place once it is open.
  let body = case pane.state.browser {
    composer.Closed -> code_places(pane)
    composer.Reading(..) | composer.Browsing(..) | composer.Failed(_) ->
      picker(pane)
  }

  element.element("loom-picklist", [], [body])
}

/// The list of places: a search field, then the folders, the way to open another
/// and the executors and pools in their fixed order. Rows the search does not
/// match are not drawn, nor are headings left with no row. A search that matches
/// nothing says so.
fn code_places(pane: Pane(message)) -> Element(message) {
  let needle = string.lowercase(string.trim(pane.state.search))
  let choices = composer.choices(pane.state, pane.offers)
  let folders = folder_groups(pane, choices)
  let elsewhere =
    list.flatten([
      other_folders(pane, needle),
      list.flat_map(pane.offers.cards.placements.executors, fn(each) {
        executor_section(pane, needle, each)
      }),
      list.flat_map(pane.offers.cards.placements.pools, fn(each) {
        pool_section(pane, needle, each)
      }),
    ])

  html.div(
    [
      attribute.class("pop"),
      attribute.class("wide"),
      attribute.class("places"),
      attribute.role("listbox"),
      attribute.aria_label("Where the code is"),
    ],
    list.flatten([
      [search_field(pane)],
      folders,
      [opener(pane)],
      elsewhere,
      nothing_note(pane, needle, folders, elsewhere),
    ]),
  )
}

/// The search field, in a form so that Enter is a submit the server hears. The
/// field is uncontrolled: the person's text is not drawn back into it.
fn search_field(pane: Pane(message)) -> Element(message) {
  html.form(
    [
      attribute.class("search"),
      event.on("submit", decode.success(pane.presses.enter))
        |> event.prevent_default,
    ],
    [
      icon(Search),
      html.input([
        attribute.type_("search"),
        attribute.class("search-field"),
        attribute.aria_label("Search folders"),
        attribute.placeholder("Search folders…"),
        attribute.autocomplete("off"),
        attribute.attribute("enterkeyhint", "go"),
        event.on_input(pane.presses.search),
      ]),
    ],
  )
}

/// The folders of this daemon: the remembered ones, the ones the daemon found
/// under the home, and the owner's projects, each under its own heading and drawn
/// only when it has a row. With another orchestrator as the agent they are that
/// orchestrator's folders under the machine's name.
fn folder_groups(
  pane: Pane(message),
  choices: composer.Choices,
) -> List(Element(message)) {
  // Another orchestrator's folders are named for the machine, since it has no home to
  // search.
  let recent_title = case pane.offers.typing {
    composer.MayType -> "Recent"
    composer.MayNotType -> "On " <> pane.offers.machine
  }

  list.flatten([
    group(pane, recent_title, "", choices.recent),
    group(pane, "Folders", "found under your home", choices.found),
    seek_note(pane),
    group(pane, "Projects", "", choices.projects),
  ])
}

/// A heading and its folder rows, or nothing when there are none.
fn group(
  pane: Pane(message),
  title: String,
  gloss: String,
  choices: List(composer.Choice),
) -> List(Element(message)) {
  case choices {
    [] -> []
    [_, ..] -> [
      section_head(title, gloss),
      ..list.map(choices, fn(each) { folder_row(pane, each) })
    ]
  }
}

/// One folder: its own name with where it lives dimmed beside it, so two folders
/// of one name are told apart. Both are text nodes. The folder in force is marked.
fn folder_row(pane: Pane(message), each: composer.Choice) -> Element(message) {
  let current = pick(pane.target, Some(each.target))

  // A found folder is pressed by its index among the hits the page holds, and
  // every other row by the target the page drew.
  let press = case each.found {
    Some(index) -> pane.presses.found(index)
    None -> pane.presses.choose(each.target)
  }

  html.button(
    [
      attribute.type_("button"),
      attribute.class("opt"),
      attribute.role("option"),
      attribute.aria_selected(selected(current)),
      event.on_click(press),
    ],
    [
      icon(Folder),
      html.span([attribute.class("opt-line")], [
        html.span([attribute.class("opt-name")], [html.text(each.name)]),
        html.small([attribute.class("opt-dim")], [html.text(each.parent)]),
      ]),
      ..check_if(current)
    ],
  )
}

/// What the search says of itself under the found folders, once something is
/// typed: that the index is being built, that the daemon refused to build one, or
/// that the build stopped before it had looked everywhere.
fn seek_note(pane: Pane(message)) -> List(Element(message)) {
  // Nothing is said until something is typed, since the rows already show the
  // remembered folders.
  let typing = case folder_browse.needle(pane.state.search) {
    Ok(_) -> True
    Error(Nil) -> False
  }

  // Once something is typed, the note says what the index is doing or why it
  // has nothing to rank.
  case typing, pane.state.seek {
    False, _ | True, composer.Unindexed -> []
    True, composer.Indexing(before: None) -> [
      html.p([attribute.class("pop-foot")], [
        html.text("Indexing your folders…"),
      ]),
    ]
    True, composer.Indexing(before: Some(_)) -> []
    True, composer.Unindexable(..) -> [
      html.p([attribute.class("pop-foot")], [
        html.text(
          "The folder list took too long to build. Type a path, or try again.",
        ),
      ]),
    ]
    True, composer.Indexed(index:, ..) ->
      case index.reach {
        folder_browse.Covered -> []
        folder_browse.Stopped -> [
          html.p([attribute.class("pop-foot")], [
            html.text(
              "Not every folder was searched. Type more of the name, or open a folder.",
            ),
          ]),
        ]
      }
  }
}

/// The row that opens the folder picker, drawn only where a path may be typed,
/// since the picker names a directory on the daemon serving the page.
fn opener(pane: Pane(message)) -> Element(message) {
  case pane.offers.typing {
    composer.MayType ->
      row(
        pane,
        Row(
          label: "Open folder…",
          detail: "Browse your folders",
          glyph: Folder,
          standing: Opens,
        ),
      )
    composer.MayNotType -> element.none()
  }
}

/// The sentence for a search that matches nothing: drawn when text was typed and
/// neither the folders nor the other places have a row for it, and no search is
/// still out that might find one.
fn nothing_note(
  pane: Pane(message),
  needle: String,
  folders: List(Element(message)),
  elsewhere: List(Element(message)),
) -> List(Element(message)) {
  // A search that is out may still find a row, so it holds the note back.
  let waiting = case pane.state.seek {
    composer.Indexing(before: None) -> True
    composer.Indexing(before: Some(_))
    | composer.Unindexed
    | composer.Indexed(..)
    | composer.Unindexable(..) -> False
  }

  // The note is for text that matched no row anywhere and is not waiting for one.
  case needle, folders, elsewhere, waiting {
    "", _, _, _ | _, _, _, True | _, [_, ..], _, _ | _, _, [_, ..], _ -> []
    _, [], [], False -> [
      html.p([attribute.class("pop-foot")], [
        html.text("Nothing matches that search."),
      ]),
    ]
  }
}

// What a code row says: its words, a smaller line under them, and the target a
// press chooses, or the reason it cannot be chosen.
type Row(message) {
  Row(label: String, detail: String, glyph: Icon, standing: Standing(message))
}

// Whether a code row can be pressed.
type Standing(message) {
  // The row chooses this target.
  Pressable(target: Target)

  // The row opens the folder picker.
  Opens

  // The row cannot work, and says why in words.
  Unavailable(reason: String)
}

/// The folders of this daemon, when another orchestrator is the agent: one
/// disabled row that says why they cannot be chosen, so a person who looks for
/// them finds the reason and the way back.
fn other_folders(
  pane: Pane(message),
  needle: String,
) -> List(Element(message)) {
  case pane.state.agent {
    composer.Here -> []
    composer.Orchestrator(_) ->
      section(pane, needle, "On " <> pane.offers.here, "", [
        Row(
          label: "Folders on " <> pane.offers.here,
          detail: pane.offers.machine
            <> " cannot read "
            <> pane.offers.here
            <> "'s files. Set Agent to "
            <> pane.offers.here
            <> " to use them.",
          glyph: Folder,
          standing: Unavailable("Not offered"),
        ),
      ])
  }
}

/// An executor's section: the workspaces it reported, or a row that asks for a
/// name when it reported none, or the reason it cannot be used.
fn executor_section(
  pane: Pane(message),
  needle: String,
  each: placements.Executor,
) -> List(Element(message)) {
  let name = each.name
  let choice_ = placements.OnExecutor(name)
  let reported = placements.workspaces(pane.offers.cards, choice_)

  // Dispatch on executor_section state.
  let rows = case each.report {
    Some(placements.Report(state: placements.Down, ..)) -> [
      Row(
        label: name,
        detail: "Not answering. Try again in a moment.",
        glyph: Cpu,
        standing: Unavailable("Not answering"),
      ),
    ]
    Some(_) | None -> workspace_rows(reported, name, composer.OnExecutor)
  }

  section(pane, needle, name, state_gloss(each.report), rows)
}

/// A pool's section, as an executor's is, headed by what the pool picks from.
///
/// The header promises only what the report carries. When the report names the
/// pool's executors, the header lists them. The remote box reports how many
/// machines can take a session and not which, so then the header counts them.
/// Before any report the header says only that the pool is a group. A pool whose
/// one executor is already drawn with the same workspaces adds no choice, so it
/// is not drawn at all.
fn pool_section(
  pane: Pane(message),
  needle: String,
  each: placements.Pool,
) -> List(Element(message)) {
  let name = each.name
  let reported =
    placements.workspaces(pane.offers.cards, placements.InPool(name))

  // Dispatch on pool_section state.
  let rows = case each.report {
    Some(placements.PoolReport(eligible: [], ..)) -> [
      Row(
        label: name,
        detail: "No machine in it is answering. Try again in a moment.",
        glyph: Pool,
        standing: Unavailable("None answering"),
      ),
    ]
    Some(_) | None -> workspace_rows(reported, name, composer.InPool)
  }

  // Dispatch on pool_section state.
  case repeats_executor(pane.offers.cards, each) {
    True -> []
    False -> section(pane, needle, pool_heading(each), "", rows)
  }
}

/// Whether a pool is the single executor it names: the report lists one executor,
/// that executor answered, and the executor's own section offers the same
/// workspaces. Only then do the two sections offer the same rows.
fn repeats_executor(cards: placements.Cards, pool: placements.Pool) -> Bool {
  case pool.report {
    Some(placements.PoolReport(
      executors: [only],
      eligible: [reached],
      workspaces:,
    ))
      if only == reached && workspaces != []
    -> workspaces == placements.workspaces(cards, placements.OnExecutor(only))

    _ -> False
  }
}

/// The pool section's heading, from what the report holds.
fn pool_heading(pool: placements.Pool) -> String {
  case pool.report {
    Some(placements.PoolReport(executors: [_, ..] as names, ..)) ->
      "Any of " <> pool.name <> ": " <> string.join(names, ", ")

    // The remote box counts the machines that can take a session and does not
    // name them, so the heading counts and names nothing.
    Some(placements.PoolReport(executors: [], eligible: [_], ..)) ->
      pool.name <> " pool, 1 machine"

    Some(placements.PoolReport(executors: [], eligible: [_, _, ..] as some, ..)) ->
      "Any of "
      <> int.to_string(list.length(some))
      <> " machines in "
      <> pool.name

    Some(_) | None -> "Any machine in " <> pool.name
  }
}

/// The rows for a place's workspaces: one for each the daemon listed, or the one
/// row that asks for a name when it listed none.
fn workspace_rows(
  reported: List(String),
  holder: String,
  target: fn(String, Option(String)) -> Target,
) -> List(Row(message)) {
  case reported {
    [] -> [
      Row(
        label: "Name a workspace…",
        detail: "Type its name in the form",
        glyph: Cpu,
        standing: Pressable(target(holder, None)),
      ),
    ]
    listed ->
      list.map(listed, fn(workspace) {
        Row(
          label: holder <> " · " <> workspace,
          detail: "",
          glyph: Cpu,
          standing: Pressable(target(holder, Some(workspace))),
        )
      })
  }
}

/// A section: its heading and the rows the search keeps, or nothing when the
/// search keeps none.
fn section(
  pane: Pane(message),
  needle: String,
  title: String,
  gloss: String,
  rows: List(Row(message)),
) -> List(Element(message)) {
  let kept =
    list.filter(rows, fn(row) {
      needle == ""
      || string.contains(string.lowercase(row.label), needle)
      || string.contains(string.lowercase(row.detail), needle)
      || string.contains(string.lowercase(title), needle)
    })

  // Dispatch on section state.
  case kept {
    [] -> []
    _ -> [section_head(title, gloss), ..list.map(kept, row(pane, _))]
  }
}

/// One code row: a button that chooses its target, or a disabled row that says
/// why it cannot. The row of the target in force is marked.
fn row(pane: Pane(message), shown: Row(message)) -> Element(message) {
  let body = [
    icon(shown.glyph),
    html.span([attribute.class("opt-text")], [
      html.span([], [html.text(shown.label)]),
      ..detail(shown.detail)
    ]),
  ]

  // Dispatch on row state.
  case shown.standing {
    Pressable(target:) -> {
      let current = pick(pane.target, Some(target))

      html.button(
        [
          attribute.type_("button"),
          attribute.class("opt"),
          attribute.role("option"),
          attribute.aria_selected(selected(current)),
          event.on_click(pane.presses.choose(target)),
        ],
        list.append(body, check_if(current)),
      )
    }
    Opens ->
      html.button(
        [
          attribute.type_("button"),
          attribute.class("opt"),
          attribute.role("option"),
          event.on_click(pane.presses.browse),
        ],
        body,
      )
    Unavailable(reason:) ->
      html.div(
        [
          attribute.class("opt"),
          attribute.role("option"),
          attribute.aria_disabled(True),
        ],
        list.append(body, [
          html.span([attribute.class("opt-state")], [html.text(reason)]),
        ]),
      )
  }
}

// A quiet second line, when there is something to say.
fn detail(words: String) -> List(Element(message)) {
  case words {
    "" -> []
    _ -> [html.small([], [html.text(words)])]
  }
}

// What an executor's report says of it, as a short gloss on its heading.
fn state_gloss(report: Option(placements.Report)) -> String {
  case report {
    Some(report) -> placements.state_words(report.state)
    None -> ""
  }
}

// Whether a row stands for what is in force.
type Pick {
  // The row is the one in force.
  Picked

  // The row is another choice.
  Unpicked
}

// The pick of a row whose value is `row`, given the value in force.
fn pick(in_force: a, row: a) -> Pick {
  case in_force == row {
    True -> Picked
    False -> Unpicked
  }
}

// The checkmark of the row in force, or nothing.
fn check_if(pick: Pick) -> List(Element(message)) {
  case pick {
    Picked -> [icon(Check)]
    Unpicked -> []
  }
}

// A row's `aria-selected`.
fn selected(pick: Pick) -> Bool {
  case pick {
    Picked -> True
    Unpicked -> False
  }
}

/// The sentence under the chips, with the names it is about in heavier weight.
fn summary(pane: Pane(message)) -> Element(message) {
  // The Code chip already asks for a folder, so the sentence waits for one.
  case pane.target {
    None -> element.none()
    Some(_) ->
      html.p(
        [attribute.class("sum")],
        list.map(
          composer.sentence_for(
            pane.state.agent,
            pane.offers.machine,
            pane.target,
          ),
          piece,
        ),
      )
  }
}

fn piece(piece: Piece) -> Element(message) {
  case piece {
    composer.Plain(text:) -> html.text(text)
    composer.Named(text:) -> html.b([], [html.text(text)])
  }
}

/// After a creation whose session was kept and did not take its first message:
/// one plain line and a button that opens the session. The button's handler is the
/// page's own message; the ticket it opens is held in the state and never drawn.
fn unsent(pane: Pane(message)) -> Element(message) {
  case pane.state.unsent {
    Some(_) ->
      html.p([attribute.class("new-refusal"), attribute.role("alert")], [
        html.text(
          "The session was created, but its first message was not sent. Open it and check the session before sending the message again, since it may have arrived. ",
        ),
        html.button(
          [
            attribute.type_("button"),
            attribute.class("link-button"),
            event.on_click(pane.presses.depart),
          ],
          [html.text("Open the session")],
        ),
      ])
    None -> element.none()
  }
}

/// The words of a refused creation, under the sentence, in the danger colour.
fn refusal(state: State) -> Element(message) {
  case state.refusal {
    Some(words) ->
      html.p([attribute.class("new-refusal"), attribute.role("alert")], [
        html.text(words),
      ])
    None -> element.none()
  }
}

// The whole path of a code place as a `title`, or an empty one for a registered
// workspace, whose name is its own words.
fn code_title(code: listing.Code) -> String {
  case code {
    listing.Folder(path:) -> path
    listing.Registered(..) | listing.Pooled(..) -> ""
  }
}

/// How many of the page's remembered folders the picker offers above the home's
/// own folders.
const recent_shown = 5

/// Whether the listing in view may be chosen with "Use this folder": every
/// directory but the home, where a session may not start.
type Use {
  Usable
  Unusable
}

/// Whether the breadcrumb's parts can be pressed: they can while a listing is on
/// screen, and cannot while the next one is being read.
type Walk {
  Walkable
  Waiting
}

/// The folder picker (protocol-change/132), drawn in the Code chip's place while
/// "Open folder…" has it open. It draws what the page holds of the daemon's
/// answer: a breadcrumb, the child directories as rows, and the ways out. Every
/// directory's name is a text node, and every press carries an index or a depth
/// the server built, which the composer checks against its own listing.
fn picker(pane: Pane(message)) -> Element(message) {
  let presses = pane.presses

  // The three states of the picker each draw a head and a body; the footer is
  // shared, with "Use this folder" only beside a listing that may be used.
  let #(head, body, standing) = case pane.state.browser {
    composer.Browsing(listing:, refusal:) -> #(
      crumbs(listing.trail, Walkable, presses.ascend),
      browsing(pane, listing, refusal),
      case listing.trail {
        [] -> Unusable
        [_, ..] -> Usable
      },
    )
    composer.Reading(trail:, ..) -> #(
      crumbs(trail, Waiting, presses.ascend),
      [html.p([attribute.class("pop-foot")], [html.text("Reading…")])],
      Unusable,
    )
    composer.Failed(refusal:) -> #(element.none(), [refused(refusal)], Unusable)
    composer.Closed -> #(element.none(), [], Unusable)
  }

  html.div(
    [
      attribute.class("pop"),
      attribute.class("wide"),
      attribute.class("picker"),
      attribute.role("group"),
      attribute.aria_label("Choose a folder"),
    ],
    [
      head,
      html.div([attribute.class("pick-rows")], body),
      footer(pane, standing),
    ],
  )
}

/// The breadcrumb: the home, then each directory of the trail. Every part but the
/// last presses to that ancestor while a listing is on screen, and the last is the
/// directory in view.
fn crumbs(
  trail: List(String),
  walk: Walk,
  ascend: fn(Int) -> message,
) -> Element(message) {
  let last = list.length(trail)
  let names = ["~", ..trail]

  html.nav(
    [attribute.class("pick-path"), attribute.aria_label("Folder path")],
    list.index_map(names, fn(name, depth) {
      // The directory in view is text, an ancestor is a button while a listing is
      // on screen, and either is text while the next listing is being read.
      let part = case walk, depth == last {
        Walkable, True | Waiting, True ->
          html.span(
            [
              attribute.class("crumb"),
              attribute.attribute("aria-current", "page"),
            ],
            [html.text(name)],
          )
        Waiting, False ->
          html.span([attribute.class("crumb")], [html.text(name)])
        Walkable, False ->
          html.button(
            [
              attribute.type_("button"),
              attribute.class("crumb"),
              event.on_click(ascend(depth)),
            ],
            [html.text(name)],
          )
      }

      // Every part after the home follows a separator, which is not announced.
      case depth == 0 {
        True -> part
        False ->
          html.span([], [
            html.span(
              [attribute.class("crumb-sep"), attribute.aria_hidden(True)],
              [html.text("/")],
            ),
            part,
          ])
      }
    }),
  )
}

/// The rows of a listing: the way up, the remembered folders at the home, the
/// child directories and the note on what is not listed.
fn browsing(
  pane: Pane(message),
  shown: Listing,
  refusal: Option(folder_browse.Refusal),
) -> List(Element(message)) {
  let depth = list.length(shown.trail)

  // The last press's refusal is worded above the rows, which stay in view.
  let notice = case refusal {
    Some(why) -> [refused(why)]
    None -> []
  }

  // The way up is drawn everywhere but the home, which has no parent in view.
  let up = case shown.trail {
    [] -> []
    [_, ..] -> [
      html.button(
        [
          attribute.type_("button"),
          attribute.class("opt"),
          event.on_click(pane.presses.ascend(depth - 1)),
        ],
        [
          icon(Up),
          html.span([attribute.class("opt-text")], [
            html.span([], [html.text("Up one folder")]),
          ]),
        ],
      ),
    ]
  }

  // The remembered folders head the home's listing, so a place the owner already
  // works in is one press away, and are not repeated in a subdirectory.
  let recent = case pane.offers.folders {
    [_, ..] if depth == 0 -> [
      section_head("Recent", "where you started sessions"),
      ..list.map(list.take(pane.offers.folders, recent_shown), fn(path) {
        html.button(
          [
            attribute.type_("button"),
            attribute.class("opt"),
            event.on_click(pane.presses.choose(composer.Folder(path))),
          ],
          [
            icon(Folder),
            html.span([attribute.class("opt-text")], [
              html.span([], [html.text(listing.short_path(path))]),
              html.small([], [html.text(path)]),
            ]),
          ],
        )
      })
    ]
    [_, ..] | [] -> []
  }

  // A heading separates the remembered folders from the home's own, and is only
  // needed when there are some.
  let heading = case recent {
    [] -> []
    [_, ..] -> [section_head("Your home", "")]
  }

  list.flatten([
    notice,
    up,
    recent,
    heading,
    list.index_map(shown.children, fn(child, index) {
      child_row(pane, child, index)
    }),
    [cut_note(shown)],
  ])
}

/// A child directory's row. A Git checkout says so under its name.
fn child_row(
  pane: Pane(message),
  child: Child,
  index: Int,
) -> Element(message) {
  // A Git checkout says so under its name, so a repository is told from a folder.
  let mark = case child.marker {
    folder_browse.Repository -> [html.small([], [html.text("Git repository")])]
    folder_browse.Plain -> []
  }

  html.button(
    [
      attribute.type_("button"),
      attribute.class("opt"),
      event.on_click(pane.presses.descend(index)),
    ],
    [
      icon(Folder),
      html.span([attribute.class("opt-text")], [
        html.span([], [html.text(child.name)]),
        ..mark
      ]),
    ],
  )
}

/// What the listing leaves out, in words: nothing when it is whole and has rows,
/// the cap when it was cut, and the depth when it stopped there.
fn cut_note(shown: Listing) -> Element(message) {
  // What the listing leaves out is said in words: nothing for a whole listing
  // with rows, the cap for a cut one, and the depth where the listing stopped.
  case shown.cut, shown.children {
    folder_browse.Whole, [] ->
      html.p([attribute.class("pop-foot")], [html.text("No folders here.")])
    folder_browse.Whole, [_, ..] -> element.none()
    folder_browse.CutShort, _ ->
      html.p([attribute.class("pop-foot")], [
        html.text(
          "Showing the first "
          <> int.to_string(folder_browse.shown_limit)
          <> " folders. Type a path for one that is not listed.",
        ),
      ])
    folder_browse.AtDepthLimit, _ ->
      html.p([attribute.class("pop-foot")], [
        html.text(
          "Folders below this one are not listed. Use this folder, or type a path.",
        ),
      ])
  }
}

/// A refusal's fixed words, announced to a screen reader.
fn refused(why: folder_browse.Refusal) -> Element(message) {
  html.p([attribute.class("new-refusal"), attribute.role("alert")], [
    html.text(folder_browse.refusal_words(why)),
  ])
}

/// The picker's footer: "Use this folder" for the directory in view when it may
/// be used, and the two ways out, back to the list of places and to a typed path.
fn footer(pane: Pane(message), standing: Use) -> Element(message) {
  let presses = pane.presses

  // "Use this folder" is drawn only where the directory in view may be chosen.
  let chosen = case standing {
    Usable ->
      html.button(
        [
          attribute.type_("button"),
          attribute.class("pick-use"),
          event.on_click(presses.pick),
        ],
        [html.text("Use this folder")],
      )
    Unusable ->
      html.span([attribute.class("pick-note")], [
        html.text("Open a folder to use it."),
      ])
  }

  html.div([attribute.class("pick-bar")], [
    html.div([attribute.class("pick-alts")], [
      html.button(
        [
          attribute.type_("button"),
          attribute.class("pick-alt"),
          event.on_click(presses.leave_browser),
        ],
        [html.text("Back to the list")],
      ),
      html.button(
        [
          attribute.type_("button"),
          attribute.class("pick-alt"),
          event.on_click(presses.choose(composer.TypedFolder)),
        ],
        [html.text("Type a path instead")],
      ),
    ]),
    chosen,
  ])
}

/// The glyph for a target: a folder, or a chip for a registered workspace.
fn code_icon(target: Target) -> Icon {
  case target {
    composer.Folder(_)
    | composer.TypedFolder
    | composer.Picked(_)
    | composer.Project(_) -> Folder
    composer.OnExecutor(..) -> Cpu
    composer.InPool(..) -> Pool
  }
}

/// A glyph of the page: a fixed outline drawn with the text's colour, holding no
/// text and no value from the page.
type Icon {
  Laptop
  Server
  Folder
  Up
  Cpu
  Pool
  Spark
  Search
  Send
  Check
  Chevron
}

/// An icon: an svg whose path is one of a few fixed outlines.
fn icon(which: Icon) -> Element(message) {
  svg.svg(
    [
      attribute.class("i"),
      attribute.attribute("viewBox", "0 0 16 16"),
      attribute.aria_hidden(True),
    ],
    [svg.path([attribute.attribute("d", outline(which))])],
  )
}

/// The outline of each icon, in a 16 by 16 box.
fn outline(which: Icon) -> String {
  case which {
    Laptop -> "M3 3.5h10v7H3zM1.5 12.5h13"
    Server -> "M2.5 3.5h11v4h-11zM2.5 8.5h11v4h-11zM5 5.5h.01M5 10.5h.01"
    Folder ->
      "M2 4.5a1 1 0 011-1h3l1.5 1.5H13a1 1 0 011 1v6a1 1 0 01-1 1H3a1 1 0 01-1-1z"
    Up -> "M8 13V3M3.5 7.5L8 3l4.5 4.5"
    Cpu ->
      "M4 4h8v8H4zM6.5 1.5v2M9.5 1.5v2M6.5 12.5v2M9.5 12.5v2M1.5 6.5h2M1.5 9.5h2M12.5 6.5h2M12.5 9.5h2"
    Pool -> "M2 4h5v8H2zM9 4h5v8H9z"
    Spark -> "M8 2l1.6 3.8L13.5 7l-3.9 1.2L8 12l-1.6-3.8L2.5 7l3.9-1.2z"
    Search -> "M11.5 7a4.5 4.5 0 11-9 0 4.5 4.5 0 019 0zM10.5 10.5L14 14"
    Send -> "M8 13V3M3.5 7.5L8 3l4.5 4.5"
    Check -> "M3 8.5l3.2 3L13 4.5"
    Chevron -> "M4 6l4 4 4-4"
  }
}
