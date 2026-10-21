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
//// ## Flow
////
//// `view` → `banner` → `recent` → `form` → `chips` → `summary`
////
//// 1. `view` lays the pane out: the banner, the heading, then the rest.
//// 2. `banner` is the phone's line for the session that needs the person, and
////    `recent` is the places a session worked in.
//// 3. `form` draws the message box, the field the target needs and Start, with
////    `start_fields` as its submit's decoder and `fields` as its one rule.
//// 4. `chips` draws the three chips, each with its list while open
////    (`agent_list`, `code_list`, `model_list`), and `summary` the sentence.
//// 5. `refusal` and `unsent` say what a refused or half-done start left.
////
//// ## Examples
////
//// ```gleam
//// // new_session.view(pane)
//// ```

import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import lustre/event
import web_view/composer.{
  type Chip, type Offers, type Piece, type Recent, type State, type Target,
  type Typed,
}
import web_view/listing
import web_view/placements
import web_view/sessions.{type Entry}

/// The messages a page's buttons send, as constructors the view applies to the
/// values it draws. They are the caller's, fixed when the tree is drawn.
pub type Presses(message) {
  Presses(
    /// A chip was pressed.
    toggle: fn(Chip) -> message,
    /// The scrim behind an open list was pressed.
    dismiss: message,
    /// A row of the Code list, or a recent place, was pressed.
    choose: fn(Target) -> message,
    /// A profile was pressed, or the default.
    profile: fn(Option(String)) -> message,
    /// A main model was pressed, or the default.
    model: fn(Option(String)) -> message,
    /// The code list's search text changed.
    search: fn(String) -> message,
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
    /// What the page's buttons send.
    presses: Presses(message),
  )
}

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

  case names, rest, needs {
    [#(_, name)], [], NameOnly -> Ok(#(name, composer.Nothing))
    [#(_, name)], [#("path", text)], NameAndPath ->
      Ok(#(name, composer.Path(text)))
    [#(_, name)], [#("workspace", text)], NameAndWorkspace ->
      Ok(#(name, composer.Workspace(text)))
    _, _, _ -> Error(Nil)
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
        html.h1([], [html.text("What should the agent work on?")]),
        html.p([attribute.class("lede")], [
          html.text(
            "Choose where the agent runs and where the code is, then describe the task.",
          ),
        ]),
        recent(pane),
        form(pane),
        chips(pane),
        summary(pane),
        refusal(pane.state),
        unsent(pane),
        html.p([attribute.class("new-old")], [
          html.button(
            [
              attribute.type_("button"),
              attribute.class("link-button"),
              event.on_click(pane.presses.listing),
            ],
            [html.text("Show the full session list")],
          ),
        ]),
      ]),
    ]),
  ])
}

// The phone's banner: the session that most needs the person, with a count of
// the others. A press opens that session. The stylesheet draws it only on a
// narrow window, where the sidebar is closed most of the time.
fn banner(pane: Pane(message)) -> Element(message) {
  case pane.waiting {
    [] -> element.none()
    [first, ..rest] -> {
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

// "Start again where you worked": one button for each recent place, which sets
// the Code chip to it. Nothing is drawn for a daemon with no session yet.
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

// The one form: the name, the field the target needs, and Start. The form's
// handler is built for the fields this tree draws, so the decoder refuses any
// other set. A creation that is out disables the button and says so.
fn form(pane: Pane(message)) -> Element(message) {
  let needed = needs(pane.target)
  let working = pane.state.sending == composer.Out
  let extra = case needed {
    NameOnly -> []
    NameAndPath -> [typed_field("path", "Folder path, for example ~/code/app")]
    NameAndWorkspace -> [
      typed_field("workspace", "Workspace name on that machine"),
    ]
  }

  html.form(
    [
      attribute.class("composer"),
      event.on("submit", start_fields(needed, pane.presses.start))
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
      ..list.append(extra, [
        html.div([attribute.class("cbar")], [
          html.button(
            [
              attribute.type_("submit"),
              attribute.class("send"),
              attribute.disabled(working),
              attribute.aria_label("Start session"),
            ],
            [
              icon(Send),
              html.span([attribute.class("send-word")], [
                html.text(case pane.state.sending {
                  composer.Out -> "Starting"
                  composer.Ready -> "Start"
                }),
              ]),
            ],
          ),
        ]),
      ])
    ],
  )
}

// A text field the target needs. It is uncontrolled and the server never writes
// it back, so what the person typed is not echoed, even after a refusal.
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

// The submit's decoder, for the fields this tree drew. A set of fields the form
// was not drawn with fails to decode, so the runtime drops the event.
fn start_fields(
  needed: Needs,
  start: fn(String, Typed) -> message,
) -> decode.Decoder(message) {
  use listed <- decode.subfield(
    ["detail", "formData"],
    decode.list(form_field()),
  )

  case fields(listed, needed) {
    Ok(#(name, typed)) -> decode.success(start(name, typed))
    Error(Nil) -> decode.failure(start("", composer.Nothing), "composer form")
  }
}

fn form_field() -> decode.Decoder(#(String, String)) {
  use name <- decode.field(0, decode.string)
  use value <- decode.field(1, decode.string)
  decode.success(#(name, value))
}

// The three chips, each with its list while it is the open one. The scrim comes
// first so the lists sit above it.
fn chips(pane: Pane(message)) -> Element(message) {
  let open = pane.state.open
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
    [attribute.class("chips")],
    list.append(scrim, [
      chip(
        pane,
        composer.AgentChip,
        Laptop,
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
          None -> "choose"
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
    ]),
  )
}

// One chip: a button that says what it holds, and the list under it while open.
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
        attribute.class("chip"),
        attribute.attribute("aria-haspopup", "listbox"),
        attribute.attribute("aria-expanded", expanded(pane.state.open, which)),
        event.on_click(pane.presses.toggle(which)),
      ],
      [
        icon(glyph),
        html.span([attribute.class("chip-key")], [html.text(label)]),
        html.span([attribute.class("chip-value")], [html.text(words)]),
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

// The Agent chip's list. Only the serving daemon is offered, and a line says why
// no other machine is.
fn agent_list(pane: Pane(message)) -> Element(message) {
  html.div(
    [
      attribute.class("pop"),
      attribute.role("listbox"),
      attribute.aria_label("Where the agent runs"),
    ],
    [
      html.div([attribute.class("opt"), attribute.class("on")], [
        icon(Laptop),
        html.span([attribute.class("opt-text")], [
          html.span([], [html.text(pane.offers.machine)]),
          html.small([], [html.text("The daemon serving this page")]),
        ]),
        icon(Check),
      ]),
      html.p([attribute.class("pop-foot")], [
        html.text(
          "A session on another machine is started from that machine's page.",
        ),
      ]),
    ],
  )
}

// The Model chip's list: the profiles, then the main models, each with the
// configuration's own first. Both sections are always drawn so the person sees
// what is configured, and a daemon with neither says so.
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
      choice("Default", pick(roles.profile, None), presses.profile(None)),
      ..list.append(
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
      )
    ],
  )
}

// A row of the Model list.
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

// The Code chip's list: a search field, then the sections in their fixed order.
// Rows the search does not match are not drawn, nor are headings left with no
// row. A search that matches nothing says so.
fn code_list(pane: Pane(message)) -> Element(message) {
  let needle = string.lowercase(pane.state.search)
  let sections =
    list.flatten([
      folder_section(pane, needle),
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
      attribute.role("listbox"),
      attribute.aria_label("Where the code is"),
    ],
    [
      html.div([attribute.class("search")], [
        icon(Search),
        html.input([
          attribute.type_("search"),
          attribute.class("search-field"),
          attribute.aria_label("Search folders and workspaces"),
          attribute.placeholder("Search folders and workspaces"),
          attribute.autocomplete("off"),
          event.on_input(pane.presses.search),
        ]),
      ]),
      ..case sections {
        [] -> [
          html.p([attribute.class("pop-foot")], [
            html.text("Nothing matches that search."),
          ]),
        ]
        some -> some
      }
    ],
  )
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

  // The row cannot work, and says why in words.
  Unavailable(reason: String)
}

// The folders on the agent's machine: those the page drew, then the one that
// asks for a typed path.
fn folder_section(
  pane: Pane(message),
  needle: String,
) -> List(Element(message)) {
  let machine = pane.offers.machine
  let folders =
    list.map(pane.offers.folders, fn(path) {
      Row(
        label: listing.short_path(path),
        detail: path,
        glyph: Folder,
        standing: Pressable(composer.Folder(path)),
      )
    })
  let typed =
    Row(
      label: "Choose a folder…",
      detail: "Type a path in the form",
      glyph: Folder,
      standing: Pressable(composer.TypedFolder),
    )

  section(pane, needle, "On " <> machine, "", list.append(folders, [typed]))
}

// An executor's section: the workspaces it reported, or a row that asks for a
// name when it reported none, or the reason it cannot be used.
fn executor_section(
  pane: Pane(message),
  needle: String,
  each: placements.Executor,
) -> List(Element(message)) {
  let name = each.name
  let choice_ = placements.OnExecutor(name)
  let reported = placements.workspaces(pane.offers.cards, choice_)
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

// A pool's section, as an executor's is: "Any machine in" the pool.
fn pool_section(
  pane: Pane(message),
  needle: String,
  each: placements.Pool,
) -> List(Element(message)) {
  let name = each.name
  let reported =
    placements.workspaces(pane.offers.cards, placements.InPool(name))
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

  section(pane, needle, "Any machine in " <> name, "", rows)
}

// The rows for a place's workspaces: one for each the daemon listed, or the one
// row that asks for a name when it listed none.
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

// A section: its heading and the rows the search keeps, or nothing when the
// search keeps none.
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

  case kept {
    [] -> []
    _ -> [section_head(title, gloss), ..list.map(kept, row(pane, _))]
  }
}

// One code row: a button that chooses its target, or a disabled row that says
// why it cannot. The row of the target in force is marked.
fn row(pane: Pane(message), shown: Row(message)) -> Element(message) {
  let body = [
    icon(shown.glyph),
    html.span([attribute.class("opt-text")], [
      html.span([], [html.text(shown.label)]),
      ..detail(shown.detail)
    ]),
  ]

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

// The sentence under the chips, with the names it is about in heavier weight.
fn summary(pane: Pane(message)) -> Element(message) {
  html.p(
    [attribute.class("sum")],
    list.map(composer.sentence(pane.offers.machine, pane.target), piece),
  )
}

fn piece(piece: Piece) -> Element(message) {
  case piece {
    composer.Plain(text:) -> html.text(text)
    composer.Named(text:) -> html.b([], [html.text(text)])
  }
}

// After a creation whose session was kept and did not take its first message:
// one plain line and a button that opens the session. The button's handler is the
// page's own message; the ticket it opens is held in the state and never drawn.
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

// The words of a refused creation, under the sentence, in the danger colour.
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
    listing.Registered(..) -> ""
  }
}

// The glyph for a target: a folder, or a chip for a registered workspace.
fn code_icon(target: Target) -> Icon {
  case target {
    composer.Folder(_) | composer.TypedFolder -> Folder
    composer.OnExecutor(..) -> Cpu
    composer.InPool(..) -> Pool
  }
}

/// A glyph of the page: a fixed outline drawn with the text's colour, holding no
/// text and no value from the page.
type Icon {
  Laptop
  Folder
  Cpu
  Pool
  Spark
  Search
  Send
  Check
  Chevron
}

// An icon: an svg whose path is one of a few fixed outlines.
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

// The outline of each icon, in a 16 by 16 box.
fn outline(which: Icon) -> String {
  case which {
    Laptop -> "M3 3.5h10v7H3zM1.5 12.5h13"
    Folder ->
      "M2 4.5a1 1 0 011-1h3l1.5 1.5H13a1 1 0 011 1v6a1 1 0 01-1 1H3a1 1 0 01-1-1z"
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
