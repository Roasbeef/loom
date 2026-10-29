//// The centre of the page of a session that runs on another orchestrator
//// (protocol-change/094, the placement revamp's slice S2b, and section 4.4 of
//// [`docs/design-notes/placement-revamp.md`](../../../../../docs/design-notes/placement-revamp.md)).
////
//// The home draws this where it draws the composer or the list. The header says
//// the session's name, where it lives (the placement strip, with the orchestrator
//// as the agent), what it is doing, and that this page relays replies and
//// approvals. Below it come the requests the session is waiting on, the newest
//// page of its transcript, and the reply form. Stop and Archive are the two
//// session controls the page may offer: a relayed session cannot be deleted,
//// shared, moved or renamed from here.
////
//// ## What it draws, and what the page decides
////
//// The view draws a state and decides nothing. `web_view/relayed_session` holds
//// the state and the rules: which presses may reach the daemon, what a reply may
//// be, which request a decision may name. Every button carries a message the
//// server built from the row it holds, so a browser's event names only the path
//// it fired at (`docs/lustre.md`, "Only events you attach can arrive"). The one
//// browser-supplied value is the reply's text, which the form's decoder accepts
//// as exactly one field and the state bounds.
////
//// ## Text from another machine
////
//// The session's name, its folder, every line of its transcript and every word of
//// a request were written on the box, and a model wrote some of them. All of it
//// is a text node. The transcript is not Markdown and carries no image, tool
//// result body or link: the box's page of words (`remote_transcript.said`) is
//// drawn as it is, between the framing lines every host draws around another
//// machine's working (`strand_framing`). The only strings that become classes
//// are fixed words chosen by `case`. A request's identity is also the key of its
//// card in the list: a key is only compared with the other keys of that list,
//// never becomes a path, a class or an attribute, and the port's decoder bounds
//// its length.
////
//// ## When the box stops answering
////
//// The last good read stays on the page, and one line above it says that the box
//// is not reachable and how old the page is. Buttons stay where they were: a
//// press that cannot reach the box is refused with the reason, in the notice.
////
//// ## Flow
////
//// `view` → `head` → `needs` → `transcript` → `reply`
////
//// 1. `view` lays the centre out for what the page holds: nothing read yet, a
////    session the box does not list, or a session.
//// 2. `head` draws the name, the placement and the two controls.
//// 3. `needs` draws a card for each pending request, `transcript` the newest
////    page of the conversation, and `reply` the form.
//// 4. `reply_fields` is the one rule of the form's decoder.
////
//// ## Examples
////
//// ```gleam
//// // relayed_session.view(state, presses)
//// ```

import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import session_view/remote_transcript
import session_view/strand_framing
import web_view/relayed.{type Need, type Row}
import web_view/relayed_session.{type State}
import web_view/view/placement

/// The messages a page's buttons send, as constructors the view applies to the
/// values it draws. They are the caller's, fixed when the tree is drawn.
pub type Presses(message) {
  Presses(
    /// The reply form was submitted with this text.
    replied: fn(String) -> message,
    /// Stop was pressed.
    stopped: message,
    /// Archive was pressed.
    archive_asked: message,
    /// The archive question was confirmed.
    archive_confirmed: message,
    /// The archive question was cancelled.
    archive_cancelled: message,
    /// A request's button was pressed, with the request's identity and the
    /// revision the card showed, and what was chosen.
    decided: fn(String, Int, relayed.Choice) -> message,
  )
}

/// The reply form's one field, which a submit must carry exactly once. A frame
/// with another field, a repeat or none at all is not a reply.
///
/// ## Examples
///
/// ```gleam
/// assert relayed_session.reply_fields([#("message", "hello")]) == Ok("hello")
/// assert relayed_session.reply_fields([]) == Error(Nil)
/// ```
pub fn reply_fields(listed: List(#(String, String))) -> Result(String, Nil) {
  case listed {
    [#("message", text)] -> Ok(text)
    _ -> Error(Nil)
  }
}

/// The page's centre for what the page holds.
///
/// ## Examples
///
/// ```gleam
/// // relayed_session.view(state, presses)
/// ```
pub fn view(state: State, presses: Presses(message)) -> Element(message) {
  html.div([attribute.class("relayed-pane")], case state.presence, state.row {
    relayed_session.Listed, Some(row) -> [
      head(state, row, presses),
      reach(state),
      notice(state),
      needs(state, row, presses),
      transcript(state),
      reply(state, presses),
    ]
    relayed_session.Unread, _ | relayed_session.Listed, None ->
      case state.reach {
        relayed_session.Answering -> [waiting(state)]
        relayed_session.Silent(..) -> [reach(state)]
      }
    relayed_session.Unlisted, _ -> [absent(state), reach(state)]
  })
}

// The page before the first read answers.
fn waiting(state: State) -> Element(message) {
  html.p([attribute.class("page-note")], [
    html.text("Reading the session from " <> state.orchestrator <> "…"),
  ])
}

/// The box answered, and its list does not hold the session.
fn absent(state: State) -> Element(message) {
  html.p([attribute.class("page-note")], [
    html.text(
      state.orchestrator
      <> " does not list this session for this daemon. It may have been archived or deleted there, or this daemon did not start it.",
    ),
  ])
}

/// The line that says the box is not answering, and how old the page is. An empty
/// node otherwise, so the centre keeps its children.
fn reach(state: State) -> Element(message) {
  case state.reach {
    relayed_session.Answering -> element.none()
    relayed_session.Silent(why:, ..) ->
      html.p([attribute.class("relayed-stale")], [
        html.text(
          case state.seen_ms {
            Some(_) -> "Could not refresh from "
            None -> "Could not read from "
          }
          <> state.orchestrator
          <> ": "
          <> why,
        ),
        html.text(case state.seen_ms {
          Some(seen) ->
            ". This is what it said "
            <> relayed.age_words(state.clock_ms - seen)
            <> "."
          None -> "."
        }),
      ])
  }
}

/// The name, where the session lives, what it is doing, and the controls.
fn head(state: State, row: Row, presses: Presses(message)) -> Element(message) {
  html.header([attribute.class("relayed-head")], [
    html.h1([], [html.text(heading(row))]),
    placement.view(state.orchestrator, Some(row.code)),
    html.p([attribute.class("relayed-where")], [
      html.span([attribute.class(state_class(row.activity))], [
        html.text(relayed.activity_words(row.activity)),
      ]),
      html.text(
        " · This session lives on "
        <> state.orchestrator
        <> ". This page relays replies and approvals.",
      ),
    ]),
    controls(state, row, presses),
  ])
}

// A session the person has not named yet has the words the box gave it, which
// may be empty.
fn heading(row: Row) -> String {
  case string.trim(row.name) {
    "" -> "Session"
    name -> name
  }
}

/// State class helper.
fn state_class(activity: relayed.Activity) -> String {
  case activity {
    relayed.NeedsYou -> "relayed-state relayed-needs"
    relayed.Working -> "relayed-state relayed-working"
    relayed.Idle -> "relayed-state relayed-idle"
  }
}

/// Stop while a strand runs or waits, and Archive always. Archive asks once more.
fn controls(
  state: State,
  row: Row,
  presses: Presses(message),
) -> Element(message) {
  let busy = state.acting == relayed_session.Busy

  // Dispatch on controls state.
  let stop = case row.activity {
    relayed.Working | relayed.NeedsYou -> [
      html.button(
        [
          attribute.type_("button"),
          attribute.class("relayed-stop"),
          attribute.disabled(busy),
          event.on_click(presses.stopped),
        ],
        [html.text("Stop")],
      ),
    ]
    relayed.Idle -> []
  }

  html.div([attribute.class("relayed-controls")], case state.acting {
    relayed_session.Confirming -> [
      html.span([attribute.class("relayed-question")], [
        html.text(
          "Archive this session? It leaves this list. Delete it on its own machine's page to remove it.",
        ),
      ]),
      html.button(
        [
          attribute.type_("button"),
          attribute.class("relayed-archive"),
          event.on_click(presses.archive_confirmed),
        ],
        [html.text("Archive")],
      ),
      html.button(
        [
          attribute.type_("button"),
          attribute.class("relayed-cancel"),
          event.on_click(presses.archive_cancelled),
        ],
        [html.text("Cancel")],
      ),
    ]
    relayed_session.Calm | relayed_session.Busy ->
      list.append(stop, [
        html.button(
          [
            attribute.type_("button"),
            attribute.class("relayed-archive"),
            attribute.disabled(busy),
            event.on_click(presses.archive_asked),
          ],
          [html.text("Archive")],
        ),
      ])
  })
}

/// What the last press said, quiet for a success and in the danger colour for a
/// refusal. An empty node when there is none.
fn notice(state: State) -> Element(message) {
  case state.notice {
    Some(relayed_session.Said(words:)) ->
      html.p([attribute.class("relayed-notice")], [html.text(words)])
    Some(relayed_session.Failed(words:)) ->
      html.p([attribute.class("relayed-notice relayed-failed")], [
        html.text(words),
      ])
    None -> element.none()
  }
}

/// The requests the session waits on, as the cards a local approval draws. A
/// request is keyed by its identity and revision, so a card the person is reading
/// keeps its place when another arrives, and a revised question is a new card.
fn needs(
  state: State,
  row: Row,
  presses: Presses(message),
) -> Element(message) {
  case row.needs {
    [] -> element.none()
    listed ->
      html.section(
        [
          attribute.class("approvals"),
          attribute.aria_label("Approvals waiting"),
          attribute.data("loom-approvals", ""),
        ],
        [
          keyed.div(
            [attribute.class("approval-list")],
            list.map(listed, fn(need) {
              #(
                need.escalation <> "@" <> int.to_string(need.seq),
                card(state, need, presses),
              )
            }),
          ),
          more_needs(row),
        ],
      )
  }
}

/// More needs helper.
fn more_needs(row: Row) -> Element(message) {
  case row.more_needs {
    0 -> element.none()
    count ->
      html.p([attribute.class("relayed-more")], [
        html.text(
          int.to_string(count)
          <> " more requests are waiting on the orchestrator's own page.",
        ),
      ])
  }
}

/// One request: who asked and what for, the question, the exact action, the
/// access approving would add, and the buttons the box's ceiling lets the page
/// offer. Deny comes first so it is the first control a tab reaches.
fn card(
  state: State,
  need: Need,
  presses: Presses(message),
) -> Element(message) {
  // Dispatch on card state.
  let asked = case need.tool {
    "" -> "this request"
    tool -> tool
  }

  let body = [
    html.p([attribute.class("approval-head")], [
      html.b([attribute.class("approval-strand")], [html.text(need.strand)]),
      html.text(" on " <> state.orchestrator <> " asks about " <> asked),
    ]),
    html.p([attribute.class("approval-question")], [html.text(need.question)]),
    html.pre([attribute.class("approval-action")], [html.text(need.action)]),
    html.ul(
      [attribute.class("approval-authority")],
      list.map(need.authority, fn(line) { html.li([], [html.text(line)]) }),
    ),
    outside(need),
  ]

  html.article(
    [attribute.class("approval-card")],
    list.append(body, [actions(state, need, asked, presses)]),
  )
}

/// Outside helper.
fn outside(need: Need) -> Element(message) {
  case need.outside {
    [] -> element.none()
    lines ->
      html.ul(
        [attribute.class("approval-outside")],
        list.map(lines, fn(line) { html.li([], [html.text(line)]) }),
      )
  }
}

/// The buttons of a card the page may decide, with the arming delay every
/// approval row has, or the line that says the request is decided elsewhere.
fn actions(
  state: State,
  need: Need,
  asked: String,
  presses: Presses(message),
) -> Element(message) {
  // Dispatch on actions state.
  case need.ability {
    relayed.ViewOnly ->
      html.p([attribute.class("approval-question")], [
        html.text(
          "This request is decided on "
          <> state.orchestrator
          <> "'s own page: its approval ceiling does not let this page decide it.",
        ),
      ])
    relayed.Decidable -> {
      let waiting = state.deciding != None
      let choose = fn(class, label, choice) {
        html.button(
          [
            attribute.type_("button"),
            attribute.class(class),
            attribute.disabled(waiting),
            event.on_click(presses.decided(need.escalation, need.seq, choice)),
          ],
          [html.text(label)],
        )
      }
      let once =
        choose("approval-allow", "Allow " <> asked <> " once", relayed.Allow)

      // Dispatch on actions state.
      let remembered = case need.remember {
        relayed.Rememberable -> [
          choose(
            "approval-allow",
            "Allow " <> asked <> " for this session",
            relayed.AllowForSession,
          ),
        ]
        relayed.OnceOnly -> []
      }

      html.div(
        [attribute.class("approval-actions"), attribute.class("arming")],
        list.flatten([
          [choose("approval-deny", "Deny " <> asked, relayed.Deny), once],
          remembered,
          [html.span([attribute.class("arm-note")], [html.text("Arming…")])],
        ]),
      )
    }
  }
}

/// The newest page of the transcript between the framing every host draws around
/// another machine's working, with a line for older entries the page does not
/// hold and one for entries left out because they were too large to send.
fn transcript(state: State) -> Element(message) {
  case state.history {
    None -> element.none()
    Some(relayed.Unreadable(why:)) ->
      html.p([attribute.class("page-note")], [
        html.text("The transcript could not be read: " <> why),
      ])
    Some(relayed.Shown(page:)) ->
      html.section([attribute.class("relayed-transcript")], [
        html.p([attribute.class("peek-frame")], [
          html.text(strand_framing.transcript_head(
            page.child,
            state.orchestrator,
          )),
        ]),
        html.div([attribute.class("peek-body")], page_body(page)),
        html.p([attribute.class("peek-frame")], [
          html.text(strand_framing.transcript_foot),
        ]),
      ])
  }
}

/// Page body helper.
fn page_body(page: remote_transcript.Page) -> List(Element(message)) {
  // Dispatch on page_body state.
  let older = case page.next {
    Some(_) -> [
      html.p([attribute.class("pane-empty")], [
        html.text("Older entries are not shown."),
      ]),
    ]
    None -> []
  }

  // Dispatch on page_body state.
  let omitted = case page.omitted {
    0 -> []
    count -> [
      html.p([attribute.class("pane-empty")], [
        html.text(
          int.to_string(count) <> " entries too large to show were left out.",
        ),
      ]),
    ]
  }

  // Dispatch on page_body state.
  let entries = case remote_transcript.said(page) {
    [] -> [
      html.p([attribute.class("pane-empty")], [html.text("No entries yet.")]),
    ]
    said -> list.map(said, entry)
  }

  list.flatten([older, entries, omitted])
}

/// Entry helper.
fn entry(said: remote_transcript.Said) -> Element(message) {
  html.div([attribute.class("peek-entry")], [
    html.span([attribute.class("peek-speaker")], [
      html.text(remote_transcript.speaker_word(said.speaker)),
    ]),
    html.p([attribute.class("peek-text")], [html.text(said.text)]),
  ])
}

/// The reply form: one box and one button. The box is uncontrolled and keyed by
/// how many replies have landed, so a reply that landed leaves with an empty box
/// and a refused or unanswered one stays as the person typed it.
fn reply(state: State, presses: Presses(message)) -> Element(message) {
  let out = state.sending == relayed_session.Out
  let slot = "reply-" <> int.to_string(state.sent)

  keyed.div([attribute.class("relayed-reply")], [
    #(
      slot,
      html.form(
        [
          attribute.class("place-composer"),
          event.on("submit", submitted(presses.replied))
            |> event.prevent_default,
        ],
        [
          html.textarea(
            [
              attribute.name("message"),
              attribute.class("composer-name"),
              attribute.aria_label("Reply"),
              attribute.placeholder("Reply to the session"),
              attribute.attribute("rows", "3"),
              attribute.attribute(
                "maxlength",
                int.to_string(relayed_session.reply_limit),
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
                html.text(case state.sending {
                  relayed_session.Out -> "Sending"
                  relayed_session.Ready -> "Send"
                }),
              ],
            ),
          ]),
        ],
      ),
    ),
  ])
}

/// Submitted helper.
fn submitted(replied: fn(String) -> message) -> decode.Decoder(message) {
  use listed <- decode.subfield(
    ["detail", "formData"],
    decode.list(form_field()),
  )

  // Dispatch on submitted state.
  case reply_fields(listed) {
    Ok(text) -> decode.success(replied(text))
    Error(Nil) -> decode.failure(replied(""), "reply form")
  }
}

fn form_field() -> decode.Decoder(#(String, String)) {
  use name <- decode.field(0, decode.string)
  use value <- decode.field(1, decode.string)
  decode.success(#(name, value))
}
