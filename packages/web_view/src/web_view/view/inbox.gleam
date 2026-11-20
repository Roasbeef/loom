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
import gleam/set.{type Set}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import session_view/operator.{type Delivery}
import web_view/composer
import web_view/inbox_rule.{type Folder, type Group, type Kind, type Thread}
import web_view/session_brief.{type Brief}
import web_view/sessions.{type Glance}
import web_view/thread_send.{type Outbox}
import web_view/view/brief_view
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
    /// The keys of the threads the person has opened since the page loaded, for
    /// the filled and hollow dot of a row. A session's thread is keyed by its
    /// identity, an attention item's by `attention_rule.opened_key` and a
    /// ticket's by `ticket_rule.opened_key`.
    opened: Set(String),
    /// What the page knows of when a session's thread began, by session: the
    /// age its row says, the time its eyebrow dates and what it says the session
    /// is doing. A session whose data holds no time has no entry and draws none.
    dated: List(#(String, Dated)),
    /// The brief of a session, as its thread may draw it, or nothing when none
    /// was read (`web_view/brief_rule.shown`).
    briefs: fn(String) -> Option(Brief),
    /// A session's name in the page's own words, which a peer message names its
    /// sender by.
    name_of: fn(String) -> String,
    /// The press that opens the open ask of a session, when it has one.
    ask_of: fn(String) -> Option(message),
  )
}

/// What the page knows of when a session's thread began. Every part is optional
/// because each comes from a different record, and a part that is not known is
/// not drawn: the page never invents a time.
pub type Dated {
  Dated(
    /// The age the row's first line says, with whether it is a long wait.
    age: Option(parts.Age),
    /// The time the eyebrow dates: `waiting since 12:58`, `finished 12:31`.
    moment: Option(parts.Moment),
    /// What the eyebrow says the session is doing in place of the kind's word:
    /// `working, 14 min into a turn`.
    state: Option(String),
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
    /// One row for each project ticket whose work waits to be read, `person/review`
    /// and `person/check`. They follow the finished sessions in "To review", and
    /// are in the "Projects" folder too.
    reviews: List(Element(message)),
    /// One row for each open find, under their own heading.
    finds: List(Element(message)),
    /// The pane of the open item thread, which replaces the session's reading
    /// pane while one is open.
    pane: Option(Element(message)),
    /// The composed title of a session's pending approval, by session, which the
    /// pane draws in place of the page's own sentence when the evidence has one
    /// (`attention_thread.approval_title`).
    titles: List(#(String, List(Element(message)))),
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
    None ->
      Threads(
        needs: [],
        tickets: [],
        reviews: [],
        finds: [],
        pane: None,
        titles: [],
        evidence: [],
      )
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
      inbox_rule.Projecting ->
        projects_group(list.append(attention.tickets, attention.reviews))
      _ ->
        draw(
          NeedsPart,
          inbox_rule.NeedsYou,
          list.append(attention.needs, attention.tickets),
        )
    },
    draw(ReviewPart, inbox_rule.ToReview, attention.reviews),
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
      reading: case parts.reading(offer.opened, thread.id), offer.selected {
        parts.Read, _ -> parts.Read
        parts.Unread, Some(pick) if pick.session == thread.id -> parts.Read
        parts.Unread, Some(_) | parts.Unread, None -> parts.Unread
      },
      name: inbox_rule.shown_name(thread),
      age: case which, list.contains(offer.checking, thread.id) {
        inbox_rule.ToReview, True ->
          Some(parts.Age("Checking for changes…", parts.Ordinary))
        _, _ ->
          case list.key_find(offer.dated, thread.id) {
            Ok(Dated(age:, ..)) -> age
            Error(Nil) -> None
          }
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
  let dated = list.key_find(offer.dated, thread.id) |> option.from_result
  let brief = offer.briefs(thread.id)

  parts.pane_with(
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
          eyebrow(thread, kind, dated),
          option.then(dated, fn(each) { each.moment }),
        ),
        case review, composed_title(thread, kind, offer) {
          Some(Reviewed(title: Some(words), ..)), _ -> parts.title(words)
          _, Some(nodes) -> parts.title_nodes(nodes)
          _, None -> parts.title(title(kind, thread))
        },
      ],
      [
        standing(thread, kind, brief, offer),
        case review {
          Some(_) -> element.none()
          None -> said(thread, kind, brief)
        },
      ],
      [
        activity(thread, kind, brief),
        case review {
          Some(_) -> element.none()
          None -> coordinator(kind, brief)
        },
        reviewed(thread, offer),
      ],
      [acts(thread, kind, offer)],
    ]),
    compose_body,
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

/// The composed title of an approval's thread, when the evidence the page read
/// gives one. Any other kind has none.
fn composed_title(
  thread: Thread,
  kind: Kind,
  offer: Offer(message),
) -> Option(List(Element(message))) {
  case kind, offer.attention {
    inbox_rule.ApprovalPending, Some(threads) ->
      list.key_find(threads.titles, thread.id) |> option.from_result
    _, _ -> None
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
        ]),
      ],
      bar(thread, kind, field),
    )
  }
}

/// The form: one box and, for a working session, the choice of how to deliver the
/// message. Its one submit button is in the outbox bar. A radio is part of the
/// form, so the draft and the delivery travel in one submit and nothing is
/// sent until Send: the choice is staged by the radio's own state and the page
/// holds none.
fn message_form(
  thread: Thread,
  kind: Kind,
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
          attribute.placeholder(placeholder(kind)),
          attribute.attribute("rows", "3"),
          attribute.attribute("maxlength", int.to_string(composer.prompt_limit)),
        ],
        "",
      ),
      delivery_choice(kind),
    ],
  )
}

/// What the box says before anything is typed. The words say what a message does
/// for this kind, and the approval's say that it starts a turn now, which is what
/// the gateway does (`thread_send.hold_note`), not that it waits behind the
/// approval.
fn placeholder(kind: Kind) -> String {
  case kind {
    inbox_rule.ApprovalPending ->
      "It is waiting on the approval; a message here starts a new turn now…"
    inbox_rule.Working
    | inbox_rule.Idle
    | inbox_rule.Failed
    | inbox_rule.Settled -> "Talk to it directly…"
  }
}

/// "Deliver as Queue or Steer", for a working session, as two radios styled as
/// toggles with a check on the staged one. Queue is chosen to begin with. Another
/// kind offers no choice, so it draws nothing.
fn delivery_choice(kind: Kind) -> Element(message) {
  case thread_send.choices(kind) {
    [thread_send.Queue, thread_send.Steer] ->
      html.div([attribute.class("inbox-how")], [
        html.span([attribute.class("inbox-hint")], [html.text("Deliver as")]),
        delivery_radio("prompt", "Queue", [attribute.checked(True)]),
        delivery_radio("steer", "Steer", []),
        html.span([attribute.class("inbox-hint")], [
          html.text(
            "Queue waits for this turn to end. Steer stops the current turn and runs first.",
          ),
        ]),
      ])
    _ -> element.none()
  }
}

/// One delivery's radio: the input carries the wire word the form reads back, and
/// the label around it is what the person presses and sees.
fn delivery_radio(
  word: String,
  label: String,
  extra: List(attribute.Attribute(message)),
) -> Element(message) {
  html.label([attribute.class("inbox-deliver")], [
    html.input([
      attribute.type_("radio"),
      attribute.name("delivery"),
      attribute.value(word),
      ..extra
    ]),
    html.span([], [html.text(label)]),
  ])
}

/// The outbox bar: what has been sent to whom in fixed words, or that nothing has
/// and what a message here does, and the one Send button at the right. A working
/// session's bar also holds a chip for each delivery, which the stylesheet shows
/// for the radio that is checked once the box holds a draft, and Send looks
/// disabled while it is empty. The button is disabled while a send is out, so a
/// second press sends nothing.
fn bar(thread: Thread, kind: Kind, field: Field(message)) -> Element(message) {
  let said = thread_send.words(field.outbox, thread.id, thread.name)
  let choices = thread_send.choices(kind)

  parts.outbox_bar_with(
    case said {
      "" -> "Not sent."
      words -> words
    },
    case said {
      "" ->
        case thread_send.hold_note(kind), choices {
          Some(note), _ -> note
          None, [thread_send.Queue, thread_send.Steer] ->
            "Write a message, choose how to deliver it, and press Send."
          None, _ -> "Nothing is sent until you press Send."
        }
      _ -> ""
    },
    case choices {
      [thread_send.Queue, thread_send.Steer] -> [
        html.span(
          [attribute.class("inbox-staged inbox-staged-msg inbox-staged-queue")],
          [html.text("Message, as a queued prompt")],
        ),
        html.span(
          [attribute.class("inbox-staged inbox-staged-msg inbox-staged-steer")],
          [html.text("Message, as a steer")],
        ),
      ]
      _ -> []
    },
    html.div([attribute.class("inbox-outbox-buttons")], [
      send_button(field.outbox),
    ]),
  )
}

/// The one button of the bar: a submit button that belongs to the message form
/// through its `form` attribute. It names no delivery: a working session's radio
/// carries it, and any other kind sends a prompt.
fn send_button(outbox: Outbox) -> Element(message) {
  html.button(
    [
      attribute.type_("submit"),
      attribute.attribute("form", form_id),
      attribute.class("inbox-primary"),
      attribute.disabled(case outbox {
        thread_send.Sending(..) -> True
        thread_send.Unsent | thread_send.Settled(..) -> False
      }),
    ],
    [html.text("Send")],
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
/// session is doing in the page's own word, or in the words the data gives when
/// it dates the turn (`working, 14 min into a turn`).
fn eyebrow(thread: Thread, kind: Kind, dated: Option(Dated)) -> String {
  let base = inbox_rule.shown_name(thread)

  // A row with no workspace has no third part.
  let placed = case thread.workspace {
    "" -> base
    workspace -> base <> " · " <> heading.shorten_path(workspace)
  }

  // What the data says the session is doing replaces the kind's own word.
  case option.then(dated, fn(each) { each.state }) {
    Some(words) -> placed <> " · " <> words
    None -> placed <> " · " <> state_words(kind)
  }
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
  brief: Option(Brief),
  offer: Offer(message),
) -> Element(message) {
  case kind {
    inbox_rule.ApprovalPending ->
      html.div([attribute.class("inbox-standing")], [
        evidence_of(thread.id, offer),
        case brief {
          Some(read) -> brief_view.peers(read.peers, offer.name_of)
          None -> element.none()
        },
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

/// What the agent last said. A working session whose brief was read shows the
/// brief's latest message, which may belong to the turn still running, with the
/// time it was written. Any other thread shows the main strand's last finished
/// message under a label that says it is not current work and not the page's
/// words. Both are text nodes: the message is model text. An approval's thread
/// leaves it out, as the approval is what the thread is about, and a review's
/// thread draws it itself, between its counts and its verdict.
fn said(thread: Thread, kind: Kind, brief: Option(Brief)) -> Element(message) {
  case kind, brief, thread.report.last_message {
    inbox_rule.ApprovalPending, _, _ -> element.none()
    inbox_rule.Working, Some(read), _ -> brief_view.latest(read)
    _, _, Some(text) ->
      case string.trim(text) {
        "" -> element.none()
        _ ->
          html.div([attribute.class("inbox-said")], [
            brief_view.finished(text, thread.report.last_message_at),
          ])
      }
    _, _, None -> element.none()
  }
}

/// What the session is doing: its last few steps when the brief has them, and
/// otherwise what its strands say they are doing, one line each, as text nodes.
fn activity(
  thread: Thread,
  kind: Kind,
  brief: Option(Brief),
) -> Element(message) {
  case kind, brief {
    inbox_rule.ApprovalPending, _ -> element.none()
    _, Some(read) if read.steps != [] -> brief_view.steps(read)
    _, _ -> strands(thread.report.glances)
  }
}

/// The coordinator's card, for a thread that is not an approval and whose
/// brief has a goal or strands to list.
fn coordinator(kind: Kind, brief: Option(Brief)) -> Element(message) {
  case kind, brief {
    inbox_rule.ApprovalPending, _ | _, None -> element.none()
    _, Some(read) -> brief_view.coordinator(read)
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
    inbox_rule.Working ->
      html.div([attribute.class("inbox-acts")], [
        open_button("Watch it live ›", thread.id, offer, Plain),
        ask_button(thread.id, offer),
      ])
    inbox_rule.Failed | inbox_rule.Idle | inbox_rule.Settled ->
      html.div([attribute.class("inbox-acts")], [
        open_button("Open session ›", thread.id, offer, Plain),
        ask_button(thread.id, offer),
      ])
  }
}

/// The button that opens the session's own open ask in the inbox, when it has
/// one. The ask is another thread of the same list, and its press is the row's.
fn ask_button(session: String, offer: Offer(message)) -> Element(message) {
  case offer.ask_of(session) {
    Some(press) ->
      html.button(
        [
          attribute.type_("button"),
          attribute.class("inbox-open"),
          event.on_click(press),
        ],
        [html.text("Its open ask ›")],
      )
    None -> element.none()
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
