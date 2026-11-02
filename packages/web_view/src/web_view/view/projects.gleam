//// The home's Projects section and a ticket's page (protocol-change/106, the
//// addendum on the web view).
////
//// The section sits at the top of the owner's home, above whatever the centre
//// shows, and answers one question: what is waiting on me in my projects? A
//// project with nothing waiting is one line. A project with tickets that need a
//// person lists them grouped by the daemon's stage word, most urgent first, as
//// buttons, and ends with the one line that counts the rest. The order, the
//// words and the ages come from `session_view/project_board`, which the
//// terminal's board screen uses too.
////
//// A ticket's page is the centre while a ticket is open. It says why the ticket
//// was allowed, shows the worker's question with an answer box, lists the
//// messages the worker was given, and links to the worker's session when the
//// page holds that session's row. Nothing here is a control for a mode or for
//// publishing, which are not built.
////
//// ## What is drawn
////
//// Every ticket string is external text, made safe by
//// `session_view/project_board` when it decodes and drawn here as a text node
//// and nowhere else. No class, attribute, key or `href` is built from one. The
//// classes are fixed words, a row is keyed by the ticket's id (which the decoder
//// has checked is made of the characters the daemon's own ids use, so it holds
//// no tab, carriage return or newline), and the buttons send messages built from
//// the ids the server drew into the tree, never from anything the browser
//// supplies. The one value the browser supplies is the answer's text, from a
//// form with exactly one field.
////
//// The section and the page use the home's existing tinted boxes with a
//// hairline border. There is no left accent bar and no shadow.
////
//// ## Flow
////
//// `section` → `project` → `ticket_row`, and `ticket_page` → `answer_form`
////
//// 1. `section` draws the heading and a `project` for each project the page
////    holds.
//// 2. `project` draws one project's name and either its healthy line or its
////    stage groups of `ticket_row` buttons.
//// 3. `ticket_page` draws the open ticket, with `answer_form` when it has a
////    question.

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
import web_view/projects.{type Loaded}

/// The most bytes of an answer the page sends. The daemon takes more; this is
/// the size of a reply typed into a box.
pub const answer_limit = 8192

/// What the page offers for projects.
pub type Offer(message) {
  /// The page has no Projects section: it is not the owner's operating page, or
  /// the daemon holds no project. Nothing is drawn.
  Hidden

  /// The section is drawn.
  Shown(
    /// The projects as the last read gave them.
    projects: List(Loaded),
    /// The time of that read, in Unix milliseconds, which ages are counted from.
    now: Int,
    /// The message a ticket's button sends, given the project's id and the
    /// ticket's.
    open: fn(String, String) -> message,
  )
}

/// What the page last said about an answer, in words.
pub type Note {
  /// Something that went well, drawn quietly and fading.
  Told(
    /// The words.
    words: String,
  )

  /// Something that did not go through, drawn in the danger colour and kept.
  Refusal(
    /// The words.
    words: String,
  )
}

/// Whether an answer is being sent.
pub type Asking {
  /// The box can be used.
  Ready

  /// An answer is with the daemon, so the box is disabled.
  Sending
}

/// What the ticket page is given.
pub type Page(message) {
  Page(
    /// The ticket as the board holds it, or as the ticket read last gave it.
    ticket: board.Ticket,
    /// The ticket read, once it has answered.
    detail: Option(board.Detail),
    /// The time of the last list read, in Unix milliseconds.
    now: Int,
    /// Whether an answer is out.
    asking: Asking,
    /// What the page last said about an answer, or nothing.
    notice: Option(Note),
    /// How many answers have been recorded, which keys the answer box so a
    /// recorded answer leaves an empty box and a refused one keeps the text.
    answered: Int,
    /// The message the Back button sends.
    back: message,
    /// The message the answer form sends, given the question's sequence number
    /// the form was drawn with and the text.
    answer: fn(Int, String) -> message,
    /// The message that opens the worker's session, when the page holds the
    /// session's row, and none otherwise.
    worker: Option(message),
  )
}

/// What a memoized view keys on.
///
/// ## Examples
///
/// ```gleam
/// assert projects_view.keyed(projects_view.Hidden) == None
/// ```
pub fn keyed(offer: Offer(message)) -> Option(#(List(Loaded), Int)) {
  case offer {
    Hidden -> None
    Shown(projects:, now:, ..) -> Some(#(projects, now))
  }
}

/// The section, or nothing on a page that has none.
///
/// ## Examples
///
/// ```gleam
/// // projects_view.section(projects_view.Hidden)
/// ```
pub fn section(offer: Offer(message)) -> Element(message) {
  case offer {
    Hidden | Shown(projects: [], ..) -> element.none()
    Shown(projects:, now:, open:) ->
      html.section(
        [
          attribute.class("home-group"),
          attribute.class("home-projects"),
          attribute.aria_label("Projects"),
        ],
        [
          html.div([attribute.class("home-group-head")], [
            html.h3([attribute.class("home-workspace")], [html.text("Projects")]),
          ]),
          ..list.map(projects, project(_, now, open))
        ],
      )
  }
}

/// One project: its workspace as its name, and what is waiting in it.
fn project(
  loaded: Loaded,
  now: Int,
  open: fn(String, String) -> message,
) -> Element(message) {
  html.div([attribute.class("home-project")], [
    html.div([attribute.class("home-group-head")], [
      html.span([attribute.class("home-folder-name")], [
        html.text(loaded.workspace),
      ]),
    ]),
    case loaded.board {
      None ->
        html.p([attribute.class("home-empty")], [
          html.text("This project's board could not be read."),
        ])
      Some(held) -> waiting(loaded.id, held, now, open)
    },
  ])
}

/// What is waiting in a project. A project with nothing that needs a person is
/// its one line; otherwise the stage groups and then the line.
fn waiting(
  id: String,
  held: board.Board,
  now: Int,
  open: fn(String, String) -> message,
) -> Element(message) {
  let health =
    html.p([attribute.class("home-empty")], [
      html.text(board.health_words(held)),
    ])

  // A project with nothing that needs a person is its one line; otherwise the
  // line follows the stage groups and counts the rest. What `observe` rules
  // would have done comes last, because it needs nobody yet.
  let waiting = case board.needing(held) {
    [] -> [health]
    needing ->
      list.append(list.map(board.groups(needing), group(id, _, now, open)), [
        health,
      ])
  }
  html.div([], list.append(waiting, would(held.would)))
}

/// What `observe` rules recorded as work they would have done, newest first.
/// Every string is external text drawn as a text node, and the address of each
/// message is drawn as text too: no `href` is built from one.
fn would(rows: List(board.Would)) -> List(Element(message)) {
  case rows {
    [] -> []
    _ -> [
      html.div([attribute.class("home-project-stage")], [
        html.p([attribute.class("home-folder-path")], [
          html.text(
            "WOULD HAVE DONE (" <> int.to_string(list.length(rows)) <> ")",
          ),
        ]),
        html.ul(
          [attribute.class("home-list")],
          list.map(rows, fn(each) {
            html.li([attribute.class("home-folder")], [
              html.span([attribute.class("home-folder-name")], [
                html.text(board.would_words(each)),
              ]),
              case each.link {
                Some(link) ->
                  html.span([attribute.class("home-folder-path")], [
                    html.text(link),
                  ])
                None -> element.none()
              },
            ])
          }),
        ),
      ]),
    ]
  }
}

/// A stage heading and the tickets under it.
fn group(
  project: String,
  stage: board.Group,
  now: Int,
  open: fn(String, String) -> message,
) -> Element(message) {
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
      list.map(stage.tickets, fn(each) {
        #(each.id, ticket_row(project, each, now, open))
      }),
    ),
  ])
}

/// One ticket as a button: its title, and its age.
fn ticket_row(
  project: String,
  each: board.Ticket,
  now: Int,
  open: fn(String, String) -> message,
) -> Element(message) {
  html.li([attribute.class("home-folder")], [
    html.button(
      [
        attribute.type_("button"),
        attribute.class("home-ticket"),
        event.on_click(open(project, each.id)),
      ],
      [
        html.span([attribute.class("home-folder-name")], [
          html.text(board.title_words(each)),
        ]),
        html.span([attribute.class("home-folder-path")], [
          html.text(board.age_words(each.opened_ms, now)),
        ]),
      ],
    ),
  ])
}

/// The ticket's page.
///
/// ## Examples
///
/// ```gleam
/// // projects_view.ticket_page(page)
/// ```
pub fn ticket_page(page: Page(message)) -> Element(message) {
  let ticket = page.ticket

  html.section(
    [
      attribute.class("home-group"),
      attribute.class("home-ticket-page"),
      attribute.aria_label("Ticket"),
    ],
    list.flatten([
      [
        html.div([attribute.class("home-group-head")], [
          html.button(
            [
              attribute.type_("button"),
              attribute.class("home-new"),
              event.on_click(page.back),
            ],
            [html.text("Back")],
          ),
          html.h3([attribute.class("home-workspace")], [
            html.text(board.title_words(ticket)),
          ]),
        ]),
        html.p([attribute.class("home-folder-path")], [
          html.text(
            board.stage_word(ticket.stage)
            <> " · opened "
            <> board.age_words(ticket.opened_ms, page.now)
            <> " ago · "
            <> ticket.id,
          ),
        ]),
        html.p([attribute.class("home-card-fact")], [
          html.text(board.mandate_words(ticket.mandate)),
        ]),
      ],
      noticed(page.notice),
      question(page),
      worker(page),
      inputs(page.detail),
    ]),
  )
}

/// The last thing the page said about an answer.
fn noticed(notice: Option(Note)) -> List(Element(message)) {
  case notice {
    None -> []
    Some(Told(words)) -> [
      html.p([attribute.class("home-note")], [html.text(words)]),
    ]
    Some(Refusal(words)) -> [
      html.p([attribute.class("home-note"), attribute.class("refused")], [
        html.text(words),
      ]),
    ]
  }
}

/// The worker's question and the answer form, or a line that says there is no
/// open question.
fn question(page: Page(message)) -> List(Element(message)) {
  case page.ticket.question {
    None -> [
      html.p([attribute.class("home-empty")], [html.text("No open question.")]),
    ]
    Some(asked) -> [
      html.p([attribute.class("home-folder-path")], [
        html.text("QUESTION " <> int.to_string(asked.seq)),
      ]),
      html.p([attribute.class("home-card-fact")], [html.text(asked.text)]),
      case asked.options {
        [] -> element.none()
        found ->
          html.p([attribute.class("home-folder-path")], [
            html.text("Options: " <> string.join(found, " · ")),
          ])
      },
      answer_form(page, asked.seq),
    ]
  }
}

/// The answer form: one box and one button. The box is keyed by how many answers
/// have been recorded, so a recorded answer leaves an empty box and a refused or
/// unanswered one stays as the person typed it. The question's sequence number
/// is drawn into the handler, so the browser supplies the text and nothing else.
fn answer_form(page: Page(message), seq: Int) -> Element(message) {
  let out = page.asking == Sending

  keyed.div([attribute.class("relayed-reply")], [
    #(
      "answer-" <> int.to_string(page.answered),
      html.form(
        [
          attribute.class("place-composer"),
          event.on("submit", submitted(seq, page.answer))
            |> event.prevent_default,
        ],
        [
          html.textarea(
            [
              attribute.name("answer"),
              attribute.class("composer-name"),
              attribute.aria_label("Answer"),
              attribute.placeholder("Answer the worker"),
              attribute.attribute("rows", "3"),
              attribute.attribute("maxlength", int.to_string(answer_limit)),
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
                html.text(case page.asking {
                  Sending -> "Sending"
                  Ready -> "Send answer"
                }),
              ],
            ),
          ]),
        ],
      ),
    ),
  ])
}

/// The form's submit as the message that carries the one text field it has. Any
/// other field, a repeated one or a missing one refuses the event.
fn submitted(
  seq: Int,
  answer: fn(Int, String) -> message,
) -> decode.Decoder(message) {
  use fields <- decode.subfield(
    ["detail", "formData"],
    decode.list(form_field()),
  )

  // The form has exactly one field, so anything else is a forged event and the
  // runtime refuses it.
  case fields {
    [#("answer", text)] -> decode.success(answer(seq, text))
    _ -> decode.failure(answer(seq, ""), "answer form")
  }
}

fn form_field() -> decode.Decoder(#(String, String)) {
  use name <- decode.field(0, decode.string)
  use value <- decode.field(1, decode.string)
  decode.success(#(name, value))
}

/// The worker's session: a button when the page holds the session's row, and
/// words when it does not, so there is no button that could only be refused.
fn worker(page: Page(message)) -> List(Element(message)) {
  case page.ticket.session, page.worker {
    Some(_), Some(press) -> [
      html.p([attribute.class("home-card-fact")], [html.text("Worker session")]),
      html.button(
        [
          attribute.type_("button"),
          attribute.class("home-new"),
          event.on_click(press),
        ],
        [html.text("Open the worker's session")],
      ),
    ]
    Some(id), None -> [
      html.p([attribute.class("home-empty")], [
        html.text("The worker's session " <> id <> " is not in this list."),
      ]),
    ]
    None, _ -> [
      html.p([attribute.class("home-empty")], [
        html.text("No worker session is bound yet."),
      ]),
    ]
  }
}

/// The messages the worker was given, newest last. A message whose text the
/// ledger does not hold says so, because an empty line would read as an empty
/// message.
fn inputs(detail: Option(board.Detail)) -> List(Element(message)) {
  case detail {
    None -> []
    Some(held) ->
      case held.inputs {
        [] -> []
        found -> [
          html.p([attribute.class("home-folder-path")], [html.text("MESSAGES")]),
          keyed.ul(
            [attribute.class("home-list")],
            list.index_map(found, fn(each, index) {
              #(int.to_string(index), input(each))
            }),
          ),
        ]
      }
  }
}

/// One message: who sent it and where it stands, then its text.
fn input(each: board.Input) -> Element(message) {
  html.li([attribute.class("home-folder")], [
    html.p([attribute.class("home-folder-path")], [
      html.text(
        option.unwrap(each.actor, "someone")
        <> " via "
        <> option.unwrap(each.source, "a source")
        <> " · "
        <> board.delivery_words(each.delivery),
      ),
    ]),
    html.p([attribute.class("home-card-fact")], [
      html.text(case each.text {
        Some(text) -> text
        None -> "(the text is not in the ledger)"
      }),
    ]),
  ])
}
