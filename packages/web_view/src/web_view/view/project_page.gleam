//// A project's page (protocol-change/106, the addendum on the project page).
////
//// The page is the centre while one project is open. From the top it shows the
//// project's router and what it decided lately, a composer that posts a request
//// to the router, the project's tickets by stage with the worker each one has,
//// and the project's own settings with the form that changes them. It decides
//// nothing: `web_view/project_page` holds the state and the rules, and every
//// button carries a message the server built from a board it holds.
////
//// ## What is drawn
////
//// Every word the daemon sent, a ticket's title, a decision's actor, a command in
//// a setting, is a text node. A decision is drawn from the fixed sentences of
//// `session_view/project_board.decision_words`, which carry the ticket's id and
//// never a trigger's text. The two forms accept exactly their fields: the
//// composer one (`request`), and the settings form four (`check`, `setup`,
//// `max_workers`, `protected_paths`). The settings form is keyed by the revision
//// read, so a saved write refreshes the boxes and a refused one keeps the text.
////
//// ## Flow
////
//// `view` → `router_panel` → `composer` → `tickets` → `settings`
////
//// 1. `view` lays out the back button, the heading and the notice.
//// 2. `router_panel` draws the router's state, the way to its session and its
////    recent decisions.
//// 3. `composer` draws the request box.
//// 4. `tickets` draws the stage groups, or the line that says how many of the
////    project's tickets the board shows.
//// 5. `settings` draws each key with where its value came from, the form, and the
////    publishing buttons.

import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import session_view/project_board as board
import session_view/project_settings_view as settings
import web_view/project_page.{type Form, type Page, type Publishing}
import web_view/projects.{type Loaded}

/// What the page is given to draw.
pub type Offer(message) {
  Offer(
    /// The page's own state.
    page: Page,
    /// The project as the board read gave it, which holds the router's session.
    loaded: Loaded,
    /// The time of the last read, in Unix milliseconds, which ages count from.
    now: Int,
    /// The message a ticket's button sends, given the ticket's id.
    open_ticket: fn(String) -> message,
    /// The message that opens the router's session, or none when the page may
    /// not.
    open_router: Option(message),
    /// The message the composer sends, given the request's text.
    request: fn(String) -> message,
    /// The message the settings form sends, given what its boxes held.
    save: fn(Form) -> message,
    /// The message a publishing button sends, given what it asks for.
    publish: fn(Publishing) -> message,
    /// The message that closes the page.
    back: message,
  )
}

/// The page.
///
/// ## Examples
///
/// ```gleam
/// // project_page_view.view(offer)
/// ```
pub fn view(offer: Offer(message)) -> Element(message) {
  html.section(
    [
      attribute.class("home-group"),
      attribute.class("home-project-page"),
      attribute.aria_label("Project"),
    ],
    list.flatten([
      [
        html.div([attribute.class("home-group-head")], [
          html.button(
            [
              attribute.type_("button"),
              attribute.class("home-new"),
              event.on_click(offer.back),
            ],
            [html.text("Back")],
          ),
          html.h3([attribute.class("home-workspace")], [
            html.text(offer.loaded.workspace),
          ]),
        ]),
      ],
      noticed(offer.page.notice),
      router_panel(offer),
      composer(offer),
      tickets(offer),
      settings(offer),
    ]),
  )
}

/// What the page last said.
fn noticed(notice: Option(project_page.Note)) -> List(Element(message)) {
  case notice {
    None -> []
    Some(project_page.Told(words)) -> [
      html.p([attribute.class("home-note")], [html.text(words)]),
    ]
    Some(project_page.Refusal(words)) -> [
      html.p([attribute.class("home-note"), attribute.class("refused")], [
        html.text(words),
      ]),
    ]
  }
}

/// The router: whether a batch is out with it, the way to its session and what
/// it decided lately. A daemon that predates the read says nothing of the
/// router's state or its decisions, and the panel says so and keeps the button.
fn router_panel(offer: Offer(message)) -> List(Element(message)) {
  // The router's state is worded when the board carries it.
  let found = case offer.loaded.board {
    Some(held) -> Some(held)
    None -> None
  }

  [
    html.p([attribute.class("home-folder-path")], [html.text("ROUTER")]),
    html.p([attribute.class("home-card-fact")], [
      html.text(case option.then(found, fn(held) { held.router }) {
        Some(state) -> router_words(state)
        None -> "The daemon did not report the router's state."
      }),
    ]),
    case offer.open_router {
      Some(press) ->
        html.p([attribute.class("home-folder-path")], [
          html.button(
            [
              attribute.type_("button"),
              attribute.class("home-new"),
              event.on_click(press),
            ],
            [html.text("Open the router's session")],
          ),
        ])
      None -> element.none()
    },
    decisions(offer, found),
  ]
}

/// The router's state in a sentence.
fn router_words(state: board.Router) -> String {
  // The phase decides how the router's state is worded.
  let queued = case state.queued {
    0 -> "nothing waits for it"
    1 -> "1 request waits for it"
    count -> int.to_string(count) <> " requests wait for it"
  }

  // The phase decides how the router's state is worded.
  case state.phase {
    "busy" ->
      "The router is deciding on "
      <> int.to_string(state.offered)
      <> ", and "
      <> queued
      <> "."
    "idle" -> "The router is idle, and " <> queued <> "."
    other -> "The router reports " <> other <> ", and " <> queued <> "."
  }
}

/// What the router decided about the triggers it was given, newest first, as the
/// daemon records it: which trigger became which ticket, or was declined, with
/// its reason. A trigger is named by its source and actor, never by its text.
fn decisions(
  offer: Offer(message),
  found: Option(board.Board),
) -> Element(message) {
  case option.map(found, fn(held) { held.decisions }) {
    None | Some([]) ->
      html.p([attribute.class("home-empty")], [
        html.text("The router has decided nothing yet."),
      ])
    Some(rows) ->
      keyed.ul(
        [attribute.class("home-list")],
        list.map(rows, fn(each) { #(each.trigger, decision(offer, each)) }),
      )
  }
}

/// One decision: the sentence, then who sent the trigger and how long ago.
fn decision(offer: Offer(message), each: board.Decision) -> Element(message) {
  html.li([attribute.class("home-folder")], [
    html.span([attribute.class("home-folder-name")], [
      html.text(board.decision_words(each)),
    ]),
    html.span([attribute.class("home-folder-path")], [
      html.text(
        each.actor
        <> " via "
        <> each.source
        <> " · "
        <> board.age_words(each.at_ms, offer.now),
      ),
    ]),
  ])
}

/// The request box and its button. The box is keyed by how many requests the page
/// has sent, so a recorded request leaves an empty box.
fn composer(offer: Offer(message)) -> List(Element(message)) {
  let out = offer.page.composing == project_page.Sending

  [
    html.p([attribute.class("home-folder-path")], [html.text("REQUEST")]),
    keyed.div([attribute.class("relayed-reply")], [
      #(
        "request-" <> int.to_string(offer.page.sent),
        html.form(
          [
            attribute.class("place-composer"),
            event.on("submit", one_field("request", offer.request))
              |> event.prevent_default,
          ],
          [
            html.textarea(
              [
                attribute.name("request"),
                attribute.class("composer-name"),
                attribute.aria_label("Request"),
                attribute.placeholder("Ask the project for work"),
                attribute.attribute("rows", "3"),
                attribute.attribute(
                  "maxlength",
                  int.to_string(project_page.request_limit),
                ),
              ],
              "",
            ),
            html.div([attribute.class("cbar")], [
              html.button(
                [
                  attribute.type_("submit"),
                  attribute.class("place-send"),
                  attribute.disabled(out),
                ],
                [
                  html.text(case out {
                    True -> "Sending"
                    False -> "Send to the router"
                  }),
                ],
              ),
            ]),
          ],
        ),
      ),
    ]),
  ]
}

/// The tickets by stage, most urgent first, each as a button with its stage's
/// worker. When the board holds more tickets than its first page, a line says how
/// many it shows, because the rest are the quieter ones.
fn tickets(offer: Offer(message)) -> List(Element(message)) {
  case offer.loaded.board {
    None -> [
      html.p([attribute.class("home-empty")], [
        html.text("This project's board could not be read."),
      ]),
    ]
    Some(held) ->
      list.flatten([
        [html.p([attribute.class("home-folder-path")], [html.text("TICKETS")])],
        case held.tickets {
          [] -> [
            html.p([attribute.class("home-empty")], [
              html.text("No ticket yet."),
            ]),
          ]
          rows ->
            list.map(board.groups(board.ordered(rows)), fn(stage) {
              group(offer, stage)
            })
        },
        shown_of(held),
      ])
  }
}

/// "Showing N of M" when the board holds more than it shows.
fn shown_of(held: board.Board) -> List(Element(message)) {
  let shown = list.length(held.tickets)

  // A board that holds more than it shows says how many it shows.
  case held.total > shown {
    True -> [
      html.p([attribute.class("home-empty")], [
        html.text(
          "Showing "
          <> int.to_string(shown)
          <> " of "
          <> int.to_string(held.total)
          <> " tickets. The ones that need you come first.",
        ),
      ]),
    ]
    False -> []
  }
}

/// A stage heading and its tickets.
fn group(offer: Offer(message), stage: board.Group) -> Element(message) {
  html.div([attribute.class("home-project-stage")], [
    html.p([attribute.class("home-folder-path")], [
      html.text(
        string.uppercase(stage.word)
        <> " ("
        <> int.to_string(list.length(stage.tickets))
        <> ")",
      ),
    ]),
    keyed.ul(
      [attribute.class("home-list")],
      list.map(stage.tickets, fn(each) { #(each.id, ticket_row(offer, each)) }),
    ),
  ])
}

/// One ticket as a button: its title, its age and the state of its worker.
fn ticket_row(offer: Offer(message), each: board.Ticket) -> Element(message) {
  html.li([attribute.class("home-folder")], [
    html.button(
      [
        attribute.type_("button"),
        attribute.class("home-ticket"),
        event.on_click(offer.open_ticket(each.id)),
      ],
      [
        html.span([attribute.class("home-folder-name")], [
          html.text(board.title_words(each)),
        ]),
        html.span([attribute.class("home-folder-path")], [
          html.text(
            board.age_words(each.opened_ms, offer.now) <> " · " <> worker(each),
          ),
        ]),
      ],
    ),
  ])
}

/// What the ticket's worker is, in the daemon's words: its stage says whether it
/// works, waits or has gone, and a ticket with no session has no worker yet.
fn worker(each: board.Ticket) -> String {
  case each.session {
    Some(_) -> "worker " <> board.stage_word(each.stage)
    None -> "no worker yet"
  }
}

/// The settings in force, the form that changes them and the publishing buttons.
fn settings(offer: Offer(message)) -> List(Element(message)) {
  case offer.page.settings {
    project_page.Unread -> [
      html.p([attribute.class("home-folder-path")], [html.text("SETTINGS")]),
      html.p([attribute.class("home-empty")], [
        html.text("The settings have not been read."),
      ]),
    ]
    project_page.Held(held) ->
      list.flatten([
        [html.p([attribute.class("home-folder-path")], [html.text("SETTINGS")])],
        [
          html.ul(
            [attribute.class("home-list")],
            list.map(held.settings, fn(each) {
              html.li([attribute.class("home-folder home-detail")], [
                html.span([attribute.class("home-folder-name")], [
                  html.text(each.key <> ": " <> settings.value_text(each)),
                ]),
                html.span([attribute.class("home-folder-path")], [
                  html.text(settings.source_words(each.source)),
                ]),
              ])
            }),
          ),
        ],
        [settings_form(offer, held)],
        publishing(offer, held),
      ])
  }
}

/// The form: one box for each key, started as the value in force and keyed by the
/// revision, so a saved write refreshes the boxes.
fn settings_form(
  offer: Offer(message),
  held: settings.Settings,
) -> Element(message) {
  let value = fn(key) {
    case list.find(held.settings, fn(each) { each.key == key }) {
      Ok(found) -> string.join(found.value, " ")
      Error(Nil) -> ""
    }
  }
  let out = offer.page.composing == project_page.Sending

  keyed.div([], [
    #(
      "settings-" <> int.to_string(held.revision),
      html.form(
        [
          attribute.class("place-composer"),
          event.on("submit", four_fields(offer.save)) |> event.prevent_default,
        ],
        [
          box("check", "Check", value("check")),
          box("setup", "Setup", value("setup")),
          box("max_workers", "Most workers at once", value("max_workers")),
          box("protected_paths", "Protected paths", value("protected_paths")),
          html.div([attribute.class("cbar")], [
            html.button(
              [
                attribute.type_("submit"),
                attribute.class("place-send"),
                attribute.disabled(out),
              ],
              [html.text("Save settings")],
            ),
          ]),
        ],
      ),
    ),
  ])
}

/// One labelled box, started as the value in force.
fn box(name: String, label: String, value: String) -> Element(message) {
  html.div([], [
    html.p([attribute.class("home-folder-path")], [html.text(label)]),
    html.input([
      attribute.type_("text"),
      attribute.name(name),
      attribute.class("composer-typed"),
      attribute.aria_label(label),
      attribute.value(value),
      attribute.attribute("maxlength", "4096"),
      attribute.autocomplete("off"),
    ]),
  ])
}

/// The publishing buttons. Turning publishing on names the URL the daemon showed,
/// in the button's words, because the daemon refuses it otherwise; a project with
/// no remote draws a sentence and no button for it.
fn publishing(
  offer: Offer(message),
  held: settings.Settings,
) -> List(Element(message)) {
  let out = offer.page.composing == project_page.Sending
  let button = fn(words, how) {
    html.button(
      [
        attribute.type_("button"),
        attribute.class("home-new"),
        attribute.disabled(out),
        event.on_click(offer.publish(how)),
      ],
      [html.text(words)],
    )
  }

  [
    html.p([attribute.class("home-folder-path")], [html.text("PUBLISHING")]),
    case held.publish_url {
      Some(url) ->
        html.p([attribute.class("home-card-fact")], [
          html.text("Verified branches would be pushed to " <> url <> ". "),
          button("Turn publishing on", project_page.PublishOn),
          button("Turn publishing off", project_page.PublishOff),
        ])
      None ->
        html.p([attribute.class("home-empty")], [
          html.text(
            "This project has no remote, so there is nowhere to publish to.",
          ),
        ])
    },
  ]
}

/// A submit as the message that carries its one field. Any other field, a
/// repeated one or a missing one refuses the event.
fn one_field(
  name: String,
  make: fn(String) -> message,
) -> decode.Decoder(message) {
  use fields <- decode.subfield(
    ["detail", "formData"],
    decode.list(form_field()),
  )

  // The form has exactly this one field, so anything else is a forged event.
  case fields {
    [#(found, text)] if found == name -> decode.success(make(text))
    _ -> decode.failure(make(""), "request form")
  }
}

/// The settings form's submit: its four fields in order and nothing else.
fn four_fields(make: fn(Form) -> message) -> decode.Decoder(message) {
  use fields <- decode.subfield(
    ["detail", "formData"],
    decode.list(form_field()),
  )

  // The form has exactly these four fields, in this order.
  case fields {
    [
      #("check", check),
      #("setup", setup),
      #("max_workers", workers),
      #("protected_paths", paths),
    ] -> decode.success(make(project_page.Form(check, setup, workers, paths)))
    _ ->
      decode.failure(make(project_page.Form("", "", "", "")), "settings form")
  }
}

fn form_field() -> decode.Decoder(#(String, String)) {
  use name <- decode.field(0, decode.string)
  use value <- decode.field(1, decode.string)
  decode.success(#(name, value))
}
