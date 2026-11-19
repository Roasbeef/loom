//// The home page's attention inbox: a full-height split of a thread list and a
//// reading pane, each scrolling on its own, as the final design draws it
//// (`docs/design-notes/attention-inbox/final/mockup.html`).
////
//// It answers one question on landing, "what is waiting for me?", from what
//// the daemon's activity read already says (`web_view/sessions.Report`), the
//// attention feed, the review scan and the project boards. `web_view/inbox_rule`
//// decides the groups, the kinds and the heads, and this module draws them. The
//// list is a column of groups. Each group has a band across the column, its name
//// and count at the left and a gloss at the right, over its rows, and each row
//// is a button that shows the thread in the reading pane. The quiet group is
//// folded to one line of names, since a session with nothing to say has nothing
//// to open. A rail folder (`Offer.folder`) narrows the list to one group; it is
//// the page's own state and the daemon is told nothing.
////
//// The reading pane names the thread (a kind chip, then the session, its
//// workspace and its state in quiet words, then the head as a title) and shows
//// the main strand's last finished message and what its other strands are
//// doing. Both are model text, so each is drawn as a text node under a label
//// that says whose words they are: the message is "the agent's last finished
//// turn, untrusted text", which says in the label that it is not current work
//// and not a question the page has verified. A session with an approval pending
//// shows what the approval asks for, as a card, and a button to the session's
//// own page. The approval's deciding control never appears on Home: the
//// decision is made where the approval's digest is shown, on the session's
//// page.
////
//// The module draws inside the home's table region (`home.table_path`) and its
//// only handlers are clicks and the message form's submit, so the socket admits
//// it without a new rule: an event beneath `table_path` is already a row's
//// press. "Open session" and "Decide on the session's page" send the same
//// message a list row's press sends (`Offer.open`), so there is one way to open
//// a session from Home.
////
//// A thread ends in a message field when the page holds the capability to send
//// (`Offer.field`, protocol-change/118). The field is a box in the pane and the
//// buttons the thread's kind offers (`thread_send.choices`) are in the outbox
//// bar at the pane's foot, as submit buttons that name their delivery and
//// belong to the form through its `form` attribute: Send for an idle session,
//// Queue and Steer for a working one, and Send alone, with the words that say a
//// message does not decide the approval, for one that waits on an approval. The
//// handler carries the session's identity, drawn into it, and the browser
//// supplies the draft and the delivery and nothing else. The bar says in fixed
//// words what was sent and to whom.
////
//// The classes are complete literals, so Tailwind finds them. Rows, bands and
//// the pane's frame are `view/inbox_parts`.
////
//// ## Flow
////
//// `view` → `threads_list` → `band_group` / `quiet_group` → `row` → `reading`
////
//// 1. `view` draws the list and the reading pane side by side.
//// 2. `threads_list` draws each group the folder shows, in the final design's
////    order, and `quiet_group` folds the quiet one.
//// 3. `row` draws one row, a button that selects its session.
//// 4. `reading` draws the selected thread: its eyebrow, title, the approval
////    card or the failure line, the last message, the glances and the open
////    button.
//// 5. `compose` draws the thread's form and its outbox bar, and `submission`
////    reads the form's fields back into a draft and a delivery.

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
import session_view/operator.{type Delivery}
import web_view/composer
import web_view/inbox_rule.{type Folder, type Group, type Kind, type Thread}
import web_view/sessions.{type Glance}
import web_view/thread_send.{type Outbox}
import web_view/view/heading
import web_view/view/inbox_parts as parts

/// The thread the reading pane shows, and how it came to.
pub type Pick {
  /// The page chose it: the first thread of the first group, because the owner
  /// has pressed none. On a narrow screen the pane stays hidden until a press.
  Default(session: String)

  /// The owner pressed its row.
  Pressed(session: String)
}

/// What the inbox draws from, and the messages its buttons send.
pub type Offer(message) {
  Offer(
    /// The rail folder the list is narrowed to. `Everything` draws every group.
    folder: Folder,
    /// The threads in their groups, in the order they are drawn
    /// (`inbox_rule.grouped`).
    groups: List(#(Group, List(Thread))),
    /// The thread the reading pane shows, or nothing when there is none.
    selected: Option(Pick),
    /// The session whose open the daemon has not answered, if one is. It
    /// disables the open buttons, as it dims a list row, so a second press asks
    /// nothing.
    opening: Option(String),
    /// What a press on a thread sends, given its session: show it.
    pick: fn(String) -> message,
    /// What "Open session" and "Decide on the session's page" send, given the
    /// session: the message a list row's press sends.
    open: fn(String) -> message,
    /// What the pane's back control sends on a narrow screen: show the list.
    back: message,
    /// What "All sessions" sends: show the page's full list.
    all_sessions: message,
    /// What "New session" sends, on a page that may create one, and nothing on
    /// a page that may not. It is drawn only when no thread is left.
    new_session: Option(message),
    /// How many threads the person has pressed. It keys the reveal element, so
    /// each press brings the pane on screen again, and a press of the thread
    /// already shown does too.
    presses: Int,
    /// The message field of each thread, or nothing on a page that holds no
    /// capability to send: a member's home and an observer's draw no field.
    field: Option(Field(message)),
    /// The threads of asks, finds and stuck strands, or nothing on a page that
    /// reads no attention feed (`web_view/view/attention_thread`).
    attention: Option(Threads(message)),
    /// The review pane of the session whose thread is open in "To review", or
    /// nothing on a page that may not read a worktree
    /// (`web_view/view/review_thread`).
    review: Option(Reviewed(message)),
    /// The sessions listed under "To review" whose tree has not been read yet:
    /// their rows say they are being checked in place of a count of changes.
    checking: List(String),
    /// How long a session's thread has waited, in the page's words, by session.
    /// The activity read carries no raise time for an approval, so the page
    /// passes none today and a row draws no age; a later layer that reads one
    /// fills this and the row and the pane's eyebrow draw it as the final design
    /// does ("1h 22m", "waiting since 12:58").
    waited: List(#(String, String)),
  )
}

/// A review pane and the session it belongs to. The reading pane draws its body
/// for that session's thread and its outbox bar at the pane's foot, in place of
/// the one-box message field, since the review's own outbox carries what the
/// owner has to say.
pub type Reviewed(message) {
  Reviewed(
    session: String,
    /// The thread's title once the review is read, which replaces the head.
    title: Option(String),
    body: Element(message),
    bar: Element(message),
  )
}

/// The attention threads, drawn by `web_view/view/attention_thread`: the rows
/// that wait on the owner, the rows of finds and the pane of the open one.
pub type Threads(message) {
  Threads(
    /// One row for each ask and stuck strand, longest wait first. They sit at
    /// the head of "Needs you".
    needs: List(Element(message)),
    /// One row for each project ticket that waits on a person. They follow the
    /// asks in "Needs you", and are the "Projects" folder.
    tickets: List(Element(message)),
    /// One row for each open find, under their own heading.
    finds: List(Element(message)),
    /// The pane of the open item thread, which replaces the session's reading
    /// pane while one is open.
    pane: Option(Element(message)),
    /// The evidence of a session's pending approval, by session, drawn in that
    /// session's thread above the one control that leads to its page.
    evidence: List(#(String, Element(message))),
  )
}

/// What a thread's message field draws from, and the message its form sends.
pub type Field(message) {
  Field(
    /// What the outbox says: nothing sent, a send out, or the daemon's answer.
    outbox: Outbox,
    /// How many messages have been delivered, which keys the box: a delivered
    /// message leaves an empty box, and a refused or unanswered one stays as
    /// the person typed it.
    delivered: Int,
    /// What a submit sends, given the session whose thread the form belongs to,
    /// the draft and the delivery. The session is drawn into the handler, so
    /// the browser never names it.
    submit: fn(String, String, Delivery) -> message,
  )
}

/// The id of the message form. The outbox bar's buttons name it in their `form`
/// attribute, so they submit it from outside its element. Only one thread's form
/// is on the page at a time.
const form_id = "inbox-message-form"

/// How a button is drawn: the one action the thread leads to, or any other.
type Emphasis {
  /// The thread's main action, in the current colour.
  Primary

  /// An ordinary button.
  Plain
}

/// What a thread's parts are in the list's order, so a folder can show some and
/// hide the rest.
type Part {
  NeedsPart
  ProjectsPart
  ReviewPart
  WaitingPart
  FindsPart
  UpdatesPart
  QuietPart
}

/// The inbox: the grouped list and the reading pane, side by side, each
/// scrolling on its own.
///
/// ## Examples
///
/// ```gleam
/// // inbox.view(inbox.Offer(folder: inbox_rule.Everything, groups:, selected: None, opening: None, pick:, open:, back:, all_sessions:, new_session: None, presses: 0, field: None, attention: None, review: None, checking: [], waited: []))
/// ```
pub fn view(offer: Offer(message)) -> Element(message) {
  html.section([attribute.class("inbox")], [
    threads_list(offer),
    case offer.attention {
      Some(Threads(pane: Some(open), ..)) -> open
      Some(Threads(pane: None, ..)) | None -> reading_pane(offer)
    },
  ])
}

/// What the inbox says when every thread has gone while it is shown: the page
/// never switches the centre by itself, so it says that nothing waits and offers
/// the composer. An inbox with threads draws nothing here.
fn nothing_waits(offer: Offer(message)) -> Element(message) {
  // The attention rows are threads too: a page that draws an ask, a find or a
  // saved session's row never says that nothing waits.
  let rows = case offer.attention {
    Some(threads) ->
      list.length(threads.needs)
      + list.length(threads.tickets)
      + list.length(threads.finds)
    None -> 0
  }

  // Any thread, grouped or attention, means something waits, so no sentence.
  case rows > 0 || !list.all(offer.groups, fn(entry) { entry.1 == [] }) {
    True -> element.none()
    False ->
      html.p([attribute.class("inbox-empty")], [
        html.text("Nothing waits on you right now. "),
        case offer.new_session {
          Some(press) ->
            html.button(
              [
                attribute.type_("button"),
                attribute.class("link-button"),
                event.on_click(press),
              ],
              [html.text("New session")],
            )
          None -> element.none()
        },
      ])
  }
}

/// Whether the folder shows a part. "Needs you" includes the tickets that wait
/// on a person, which is why "Projects" is a narrower view of the same rows.
fn visible(folder: Folder, part: Part) -> Bool {
  case folder, part {
    inbox_rule.Everything, _ -> True
    inbox_rule.Needing, NeedsPart -> True
    inbox_rule.Reviewing, ReviewPart -> True
    inbox_rule.Finding, FindsPart -> True
    inbox_rule.Updating, UpdatesPart -> True
    inbox_rule.Projecting, ProjectsPart -> True
    _, _ -> False
  }
}

/// The grouped list: a band and its rows for each group that holds threads and
/// the folder shows, in the final design's order, then the folded quiet line and
/// the way to the full list.
fn threads_list(offer: Offer(message)) -> Element(message) {
  // A page with no feed has no attention threads, which is an empty set of them.
  let attention = case offer.attention {
    Some(threads) -> threads
    None -> Threads(needs: [], tickets: [], finds: [], pane: None, evidence: [])
  }

  let groups = offer.groups
  let sessions_in = fn(which) {
    case list.key_find(groups, which) {
      Ok(found) -> found
      Error(Nil) -> []
    }
  }
  let draw = fn(part, which, extra) {
    case visible(offer.folder, part) {
      True -> band_group(which, extra, sessions_in(which), offer)
      False -> element.none()
    }
  }

  html.div([attribute.class("inbox-list")], [
    nothing_waits(offer),
    case offer.folder {
      inbox_rule.Projecting -> projects_group(attention.tickets)
      _ ->
        draw(
          NeedsPart,
          inbox_rule.NeedsYou,
          list.append(attention.needs, attention.tickets),
        )
    },
    draw(ReviewPart, inbox_rule.ToReview, []),
    draw(WaitingPart, inbox_rule.Waiting, []),
    case visible(offer.folder, FindsPart) {
      True -> finds_group(attention.finds)
      False -> element.none()
    },
    draw(UpdatesPart, inbox_rule.Updates, []),
    case visible(offer.folder, QuietPart) {
      True -> quiet_group(sessions_in(inbox_rule.Quiet))
      False -> element.none()
    },
    all_sessions(offer),
  ])
}

/// The tickets alone, when the "Projects" folder is chosen.
fn projects_group(rows: List(Element(message))) -> Element(message) {
  case rows {
    [] -> element.none()
    [_, ..] ->
      parts.group(
        parts.band(
          "Projects",
          Some(list.length(rows)),
          "tickets waiting on a person",
          parts.Plain,
        ),
        rows,
      )
  }
}

/// The finds under their band, or nothing when there are none.
fn finds_group(rows: List(Element(message))) -> Element(message) {
  case rows {
    [] -> element.none()
    [_, ..] ->
      parts.group(
        parts.band(
          "Finds",
          Some(list.length(rows)),
          "noticed outside the task",
          parts.Plain,
        ),
        rows,
      )
  }
}

/// One group's band, with its count, over its rows: `extra` first, which are
/// rows another module drew for the group, then the sessions'. A group with
/// nothing in it draws nothing, except "Needs you" when only `extra` fills it.
fn band_group(
  which: Group,
  extra: List(Element(message)),
  threads: List(Thread),
  offer: Offer(message),
) -> Element(message) {
  let rows = list.append(extra, list.map(threads, row(_, which, offer)))

  // A group with no row has no band.
  case rows {
    [] -> element.none()
    [_, ..] ->
      parts.group(
        parts.band(
          inbox_rule.group_words(which),
          Some(list.length(rows)),
          inbox_rule.gloss(which),
          case which {
            inbox_rule.NeedsYou -> parts.Signal
            inbox_rule.ToReview
            | inbox_rule.Waiting
            | inbox_rule.Updates
            | inbox_rule.Quiet -> parts.Plain
          },
        ),
        rows,
      )
  }
}

/// The quiet sessions folded to a band and one line of names. They have nothing
/// to read, so the line is text and not a row of buttons.
fn quiet_group(threads: List(Thread)) -> Element(message) {
  case threads {
    [] -> element.none()
    [_, ..] ->
      html.section([attribute.class("inbox-group")], [
        parts.band(
          "Folded",
          None,
          inbox_rule.gloss(inbox_rule.Quiet),
          parts.Plain,
        ),
        parts.folded("Quiet", list.map(threads, inbox_rule.shown_name)),
      ])
  }
}

/// The way to the page's full list, at the foot of the list's column.
fn all_sessions(offer: Offer(message)) -> Element(message) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class("home-new inbox-all"),
      event.on_click(offer.all_sessions),
    ],
    [html.text("All sessions ›")],
  )
}

/// One thread's row: a button that shows the thread in the reading pane. Its
/// first line is the session's name, and its chip is the kind's word, then the
/// one line the rule words from the report.
fn row(
  thread: Thread,
  which: Group,
  offer: Offer(message),
) -> Element(message) {
  let kind = inbox_rule.kind(thread.report)

  parts.row(
    parts.Facts(
      dot: dot_of(kind),
      name: inbox_rule.shown_name(thread),
      age: case which, list.contains(offer.checking, thread.id) {
        inbox_rule.ToReview, True ->
          Some(parts.Age("Checking for changes…", parts.Ordinary))
        _, _ ->
          list.key_find(offer.waited, thread.id)
          |> option.from_result
          |> option.map(parts.Age(_, parts.Ordinary))
      },
      kind: row_word(kind, which),
      head: inbox_rule.thread_head(thread),
      selection: case offer.selected, item_open(offer) {
        Some(pick), False if pick.session == thread.id -> parts.Selected
        Some(_), _ | None, _ -> parts.Unselected
      },
    ),
    offer.pick(thread.id),
  )
}

/// Whether an attention item's or a ticket's pane is open, which takes the
/// reading pane, so no session's row is the one shown.
fn item_open(offer: Offer(message)) -> Bool {
  case offer.attention {
    Some(Threads(pane: Some(_), ..)) -> True
    Some(Threads(pane: None, ..)) | None -> False
  }
}

/// The dot a kind draws: the owner is waited on, a finished session is open to
/// read, a failure is marked, and a session that works or has nothing to say
/// waits on no one.
fn dot_of(kind: Kind) -> parts.Dot {
  case kind {
    inbox_rule.ApprovalPending -> parts.Waiting
    inbox_rule.Failed -> parts.Failing
    inbox_rule.Idle -> parts.Running
    inbox_rule.Working | inbox_rule.Settled -> parts.Resting
  }
}

/// The word a row's chip says: the kind's, except for a finished session whose
/// tree holds changes, which is a review.
fn row_word(kind: Kind, which: Group) -> String {
  case which {
    inbox_rule.ToReview -> "Review"
    inbox_rule.NeedsYou
    | inbox_rule.Waiting
    | inbox_rule.Updates
    | inbox_rule.Quiet -> inbox_rule.words(kind)
  }
}

/// The reading pane for the selected thread, or an empty node when the groups
/// hold no thread, so the region keeps its place. A thread chosen by default is
/// marked so the stylesheet can leave it out on a narrow screen, where the list
/// is the page until the owner presses a row.
fn reading_pane(offer: Offer(message)) -> Element(message) {
  case offer.selected {
    None -> element.none()
    Some(pick) ->
      case selected_thread(offer.groups, pick) {
        Some(found) -> reading(found, pick, offer)
        None -> element.none()
      }
  }
}

/// The reading pane for one thread: its eyebrow and title, what its standing
/// needs said, its last message and strands, the button that opens the session
/// and, at the foot, the outbox bar.
fn reading(
  thread: Thread,
  pick: Pick,
  offer: Offer(message),
) -> Element(message) {
  let kind = inbox_rule.kind(thread.report)
  let #(compose_body, bar) = compose(thread, kind, offer)
  let review = review_of(thread, offer)

  parts.pane(
    case pick {
      Default(_) -> parts.ByDefault
      Pressed(_) -> parts.ByPress
    },
    offer.back,
    list.flatten([
      [
        reveal(pick, offer.presses),
        parts.eyebrow(
          case review {
            Some(_) -> "Review"
            None -> inbox_rule.words(kind)
          },
          eyebrow(thread, kind),
          option.from_result(list.key_find(offer.waited, thread.id)),
        ),
        parts.title(case review {
          Some(Reviewed(title: Some(words), ..)) -> words
          Some(_) | None -> title(kind, thread)
        }),
      ],
      [standing(thread, kind, offer), said(thread, kind)],
      [strands(thread.report.glances), reviewed(thread, offer)],
      [acts(thread, kind, offer)],
      compose_body,
    ]),
    bar,
  )
}

/// The thread's review pane, when the page holds one for this session.
fn review_of(
  thread: Thread,
  offer: Offer(message),
) -> Option(Reviewed(message)) {
  case offer.review {
    Some(Reviewed(session:, ..) as held) if session == thread.id -> Some(held)
    Some(_) | None -> None
  }
}

/// The body of the thread's review pane, or nothing.
fn reviewed(thread: Thread, offer: Offer(message)) -> Element(message) {
  case review_of(thread, offer) {
    Some(Reviewed(body:, ..)) -> body
    None -> element.none()
  }
}

/// The element that scrolls the pane into view, drawn only for a thread the
/// person pressed. On a narrow screen the pane sits over the list, so a press
/// would change what is off screen. `<loom-reveal>` scrolls its nearest section
/// into view when it is inserted, so it is keyed by the press count to be
/// inserted again each time. A default thread draws nothing, since the page
/// did not ask to be looked at.
fn reveal(pick: Pick, presses: Int) -> Element(message) {
  case pick {
    Pressed(_) ->
      keyed.div([attribute.class("inbox-reveal")], [
        #(
          "reveal-" <> int.to_string(presses),
          element.element("loom-reveal", [], []),
        ),
      ])
    Default(_) -> element.none()
  }
}

/// The thread's message field and its outbox bar. The field is a form with one
/// box, in the pane, under the label "Message" and the thread's name. The bar is
/// at the pane's foot and holds the buttons the kind offers, which submit the
/// form from outside it. A page with no capability to send has neither, and a
/// reviewed thread has the review's own bar. The box is keyed by the thread and
/// by how many messages have been delivered, so a delivered message leaves an
/// empty box, and moving to another thread shows that thread's own empty one.
fn compose(
  thread: Thread,
  kind: Kind,
  offer: Offer(message),
) -> #(List(Element(message)), Element(message)) {
  case offer.field, offer.review {
    _, Some(Reviewed(session:, bar:, ..)) if session == thread.id -> #([], bar)
    None, _ -> #([], element.none())
    Some(field), _ -> #(
      [
        html.section([attribute.class("inbox-section inbox-msg")], [
          html.h2([attribute.class("inbox-label")], [
            html.text("Message " <> inbox_rule.shown_name(thread)),
          ]),
          keyed.div([attribute.class("inbox-send")], [
            #(
              "send-" <> thread.id <> "-" <> int.to_string(field.delivered),
              message_form(thread, kind, field),
            ),
          ]),
          delivery_hint(kind),
        ]),
      ],
      bar(thread, kind, field),
    )
  }
}

/// The form: one box and nothing else. Its submit buttons are in the outbox bar.
fn message_form(
  thread: Thread,
  _kind: Kind,
  field: Field(message),
) -> Element(message) {
  html.form(
    [
      attribute.id(form_id),
      attribute.class("inbox-form"),
      event.on("submit", submitted(thread.id, field.submit))
        |> event.prevent_default,
    ],
    [
      html.textarea(
        [
          attribute.name("draft"),
          attribute.class("inbox-ta"),
          attribute.aria_label("Message this session"),
          attribute.placeholder("Talk to it directly…"),
          attribute.attribute("rows", "3"),
          attribute.attribute("maxlength", int.to_string(composer.prompt_limit)),
        ],
        "",
      ),
    ],
  )
}

/// What Queue and Steer do, under the box of a working session's thread. No
/// other kind offers the choice.
fn delivery_hint(kind: Kind) -> Element(message) {
  case thread_send.choices(kind) {
    [thread_send.Queue, thread_send.Steer] ->
      html.p([attribute.class("inbox-hint")], [
        html.text(
          "Queue waits for this turn to end. Steer stops the current turn and runs first.",
        ),
      ])
    _ -> element.none()
  }
}

/// The outbox bar: what has been sent to whom in fixed words, or that nothing has
/// and what a message here does, and the buttons the kind offers at the right.
/// The buttons are disabled while a send is out, so a second press sends nothing.
fn bar(thread: Thread, kind: Kind, field: Field(message)) -> Element(message) {
  let said = thread_send.words(field.outbox, thread.id, thread.name)
  let choices = thread_send.choices(kind)

  parts.outbox_bar(
    case said {
      "" -> "Not sent."
      words -> words
    },
    case said {
      "" ->
        case thread_send.hold_note(kind) {
          Some(note) -> note
          None -> "Nothing is sent until you press a button."
        }
      _ -> ""
    },
    [],
    html.div(
      [attribute.class("inbox-outbox-buttons")],
      list.map(choices, send_button(_, field.outbox, list.length(choices))),
    ),
  )
}

/// One button of the bar: a submit button that names its delivery and belongs to
/// the message form. When the kind offers two, the second is the primary one.
fn send_button(
  choice: thread_send.Choice,
  outbox: Outbox,
  offered: Int,
) -> Element(message) {
  html.button(
    [
      attribute.type_("submit"),
      attribute.attribute("form", form_id),
      attribute.name("delivery"),
      attribute.value(case thread_send.delivery(choice) {
        operator.Prompt -> "prompt"
        operator.Steer -> "steer"
      }),
      attribute.class(case choice, offered {
        thread_send.Queue, 2 -> "inbox-btn"
        _, _ -> "inbox-primary"
      }),
      // A send that is out, for any thread, disables every button: there is one
      // outbox, and a second press would be refused by the page anyway.
      attribute.disabled(case outbox {
        thread_send.Sending(..) -> True
        thread_send.Unsent | thread_send.Settled(..) -> False
      }),
    ],
    [html.text(thread_send.label(choice))],
  )
}

/// The form's submit as the message that carries its draft and delivery. A
/// field the form does not have, a repeated one or an unknown delivery refuses
/// the event, so a forged submit cannot send what no button offers.
fn submitted(
  session: String,
  submit: fn(String, String, Delivery) -> message,
) -> decode.Decoder(message) {
  use fields <- decode.subfield(
    ["detail", "formData"],
    decode.list(form_field()),
  )

  // Decode the form's fields into a draft and a delivery, or refuse.
  case submission(fields) {
    Ok(#(draft, delivery)) -> decode.success(submit(session, draft, delivery))
    Error(Nil) ->
      decode.failure(submit(session, "", operator.Prompt), "inbox message form")
  }
}

/// The draft and the delivery a submitted form's fields stand for, or a refusal.
///
/// The form has two fields and no others: exactly one `draft`, and at most one
/// `delivery`, which is `prompt` or `steer`. A form submitted by Enter in the
/// box names no delivery, and is a prompt.
///
/// ## Examples
///
/// ```gleam
/// assert inbox.submission([#("draft", "hi"), #("delivery", "steer")])
///   == Ok(#("hi", operator.Steer))
/// ```
pub fn submission(
  fields: List(#(String, String)),
) -> Result(#(String, Delivery), Nil) {
  let drafts = list.filter(fields, fn(field) { field.0 == "draft" })
  let deliveries = list.filter(fields, fn(field) { field.0 == "delivery" })
  let others =
    list.filter(fields, fn(field) {
      field.0 != "draft" && field.0 != "delivery"
    })

  // The form's own shape and no other.
  case drafts, deliveries, others {
    [#(_, text)], [], [] -> Ok(#(text, operator.Prompt))
    [#(_, text)], [#(_, "prompt")], [] -> Ok(#(text, operator.Prompt))
    [#(_, text)], [#(_, "steer")], [] -> Ok(#(text, operator.Steer))
    _, _, _ -> Error(Nil)
  }
}

/// One field of a submitted form: its name and its value.
fn form_field() -> decode.Decoder(#(String, String)) {
  use name <- decode.field(0, decode.string)
  use value <- decode.field(1, decode.string)
  decode.success(#(name, value))
}

/// The eyebrow's quiet words: the session's name, its workspace as the host's
/// text with the home directory shortened when the row has one, and what the
/// session is doing in the page's own word.
fn eyebrow(thread: Thread, kind: Kind) -> String {
  let base = inbox_rule.shown_name(thread)

  // A row with no workspace has no third part.
  let placed = case thread.workspace {
    "" -> base
    workspace -> base <> " · " <> heading.shorten_path(workspace)
  }

  placed <> " · " <> state_words(kind)
}

/// What a kind says about the session's state, in the eyebrow.
fn state_words(kind: Kind) -> String {
  case kind {
    inbox_rule.ApprovalPending -> "waiting on an approval"
    inbox_rule.Failed -> "its last run failed"
    inbox_rule.Idle -> "idle, finished"
    inbox_rule.Working -> "working"
    inbox_rule.Settled -> "quiet"
  }
}

/// The thread's title. An approval's is the page's own sentence, since the
/// approval's content is drawn as evidence below it; any other is the head the
/// rule words from the report.
fn title(kind: Kind, thread: Thread) -> String {
  case kind {
    inbox_rule.ApprovalPending -> "An approval is pending."
    inbox_rule.Failed
    | inbox_rule.Idle
    | inbox_rule.Working
    | inbox_rule.Settled -> inbox_rule.thread_head(thread)
  }
}

/// What the pane says about the thread's standing in the page's own words. An
/// approval is named, its evidence drawn and the session's page offered, and
/// nothing decides it here; a failed run is named, since nothing waits on the
/// owner but a fix.
fn standing(
  thread: Thread,
  kind: Kind,
  offer: Offer(message),
) -> Element(message) {
  case kind {
    inbox_rule.ApprovalPending ->
      html.div([attribute.class("inbox-standing")], [
        evidence_of(thread.id, offer),
        parts.section("Decide", [
          html.div([attribute.class("inbox-acts")], [
            open_button(
              "Decide on the session's page ›",
              thread.id,
              offer,
              Primary,
            ),
          ]),
        ]),
      ])
    inbox_rule.Failed ->
      html.p([attribute.class("inbox-meta")], [
        html.text("Its last run failed, and nothing is running."),
      ])
    inbox_rule.Idle | inbox_rule.Working | inbox_rule.Settled -> element.none()
  }
}

/// The evidence the page read for this session's approval, or nothing when it
/// has read none (a page that reads no feed).
fn evidence_of(session: String, offer: Offer(message)) -> Element(message) {
  case offer.attention {
    Some(threads) ->
      case list.key_find(threads.evidence, session) {
        Ok(drawn) -> drawn
        Error(Nil) -> element.none()
      }
    None -> element.none()
  }
}

/// The main strand's last finished message under a label that says it is not
/// current work and not the page's words. It is a text node: the message is
/// model text. An approval's thread leaves it out, as the approval is what the
/// thread is about.
fn said(thread: Thread, kind: Kind) -> Element(message) {
  case kind, thread.report.last_message {
    inbox_rule.ApprovalPending, _ -> element.none()
    _, Some(text) ->
      case string.trim(text) {
        "" -> element.none()
        _ ->
          html.div([attribute.class("inbox-said")], [
            parts.quote("The agent's last finished turn, untrusted text", text),
          ])
      }
    _, None -> element.none()
  }
}

/// What the session's strands say they are doing, one line each, as text nodes.
fn strands(glances: List(Glance)) -> Element(message) {
  case glances {
    [] -> element.none()
    [_, ..] ->
      parts.section("What its strands are doing", [
        parts.card([
          html.ul(
            [attribute.class("inbox-glances")],
            list.map(glances, fn(each) {
              html.li([], [html.text(glance_line(each))])
            }),
          ),
        ]),
      ])
  }
}

/// A glance as one line: the title the strand chose, or the strand's name when
/// it chose none, then the summary.
fn glance_line(glance: Glance) -> String {
  case glance.title {
    "" -> glance.strand <> ": " <> glance.summary
    title -> title <> ": " <> glance.summary
  }
}

/// The row of buttons under the thread's facts: the one that opens its session.
/// An approval's thread has the same press under "Decide", so it draws none here.
fn acts(thread: Thread, kind: Kind, offer: Offer(message)) -> Element(message) {
  case kind {
    inbox_rule.ApprovalPending -> element.none()
    inbox_rule.Failed
    | inbox_rule.Idle
    | inbox_rule.Working
    | inbox_rule.Settled ->
      html.div([attribute.class("inbox-acts")], [
        open_button("Open session ›", thread.id, offer, Plain),
      ])
  }
}

/// A button that sends the page's open message for the thread's session. It is
/// disabled while an open for the same session is out.
fn open_button(
  label: String,
  session: String,
  offer: Offer(message),
  emphasis: Emphasis,
) -> Element(message) {
  let pending = offer.opening == Some(session)

  html.button(
    [
      attribute.type_("button"),
      attribute.class("inbox-open"),
      case emphasis {
        Primary -> attribute.class("inbox-open-primary")
        Plain -> attribute.none()
      },
      attribute.disabled(pending),
      event.on_click(offer.open(session)),
    ],
    [
      html.text(case pending {
        True -> "Opening…"
        False -> label
      }),
    ],
  )
}

/// The thread a pick names, wherever the groups hold it.
fn selected_thread(
  groups: List(#(Group, List(Thread))),
  pick: Pick,
) -> Option(Thread) {
  groups
  |> list.flat_map(fn(entry) { entry.1 })
  |> list.find(fn(each) { each.id == pick.session })
  |> option.from_result
}
