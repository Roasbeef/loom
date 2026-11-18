//// The home page's attention inbox: the owner's running sessions as a list of
//// threads grouped by what they need, with a reading pane for the thread the
//// owner selected.
////
//// It answers one question on landing, "what is waiting for me?", from what
//// the daemon's activity read already says (`web_view/sessions.Report`) and
//// from nothing else. `web_view/inbox_rule` decides the groups, the kinds, the
//// heads and the headline, and this module draws them. The list has a group
//// header with its count over the group's threads, each a button that shows
//// the thread in the reading pane. The quiet group is folded to one line of
//// names, since a session with nothing to say has nothing to open.
////
//// The reading pane names the thread (the kind's word, the session's name and
//// its workspace) and shows the main strand's last finished message and what
//// its other strands are doing. Both are model text, so each is drawn as a
//// text node under a label that says whose words they are: the message is "the
//// agent's last finished turn, untrusted text", which says in the label that
//// it is not current work and not a question the page has verified. A session
//// with an approval pending shows only the words "An approval is pending" and
//// a button to the session's own page. The approval's content and its deciding
//// control never appear on Home: the decision is made where the approval's
//// digest is shown, on the session's page.
////
//// The module draws inside the home's table region (`home.table_path`) and its
//// only handlers are clicks, so the socket admits it without a new rule: a
//// click beneath `table_path` is already a row's press. "Open session" and
//// "Decide on the session's page" send the same message a list row's press
//// sends (`Offer.open`), so there is one way to open a session from Home.
////
//// The classes are complete literals, so Tailwind finds them.
////
//// ## Flow
////
//// `view` → `threads_list` → `group` → `row` → `reading`
////
//// 1. `view` draws the headline, the list and the reading pane side by side.
//// 2. `threads_list` draws each group the rule found, and `quiet_line` folds the
////    quiet one.
//// 3. `row` draws one row, a button that selects its session.
//// 4. `reading` draws the selected thread: its eyebrow, the approval notice or
////    the failure line, the last message, the glances and the open button.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_view/inbox_rule.{type Group, type Kind, type Thread}
import web_view/sessions.{type Glance}
import web_view/view/heading

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
    /// What the headline over the list says (`inbox_rule.headline`).
    headline: String,
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
    /// What "All sessions" sends: show the page's full list.
    all_sessions: message,
  )
}

/// The inbox: the headline, the grouped list and the reading pane, with a way
/// to the full list.
///
/// ## Examples
///
/// ```gleam
/// // inbox.view(inbox.Offer(headline:, groups:, selected: None, opening: None, pick:, open:, all_sessions:))
/// ```
pub fn view(offer: Offer(message)) -> Element(message) {
  html.section([attribute.class("home-sessions inbox")], [
    html.h2([attribute.class("home-heading")], [html.text("Inbox")]),
    html.p([attribute.class("inbox-headline")], [html.text(offer.headline)]),
    html.div([attribute.class("inbox-body")], [
      threads_list(offer),
      reading_pane(offer),
    ]),
    html.button(
      [
        attribute.type_("button"),
        attribute.class("home-new"),
        event.on_click(offer.all_sessions),
      ],
      [html.text("All sessions ›")],
    ),
  ])
}

/// The grouped list: a section for each group that holds threads and has
/// something to open, and one folded line for the quiet ones.
fn threads_list(offer: Offer(message)) -> Element(message) {
  html.div(
    [attribute.class("inbox-list")],
    list.map(offer.groups, fn(entry) {
      case entry.0 {
        inbox_rule.Quiet -> quiet_line(entry.1)
        inbox_rule.NeedsYou | inbox_rule.Waiting | inbox_rule.Updates ->
          group(entry.0, entry.1, offer)
      }
    }),
  )
}

/// One group's header, with its count, over its threads.
fn group(
  which: Group,
  threads: List(Thread),
  offer: Offer(message),
) -> Element(message) {
  html.section([attribute.class("inbox-group")], [
    html.h3([attribute.class("inbox-group-head")], [
      html.text(inbox_rule.group_words(which)),
      html.span([attribute.class("inbox-count")], [
        html.text(int.to_string(list.length(threads))),
      ]),
    ]),
    html.ul(
      [attribute.class("inbox-threads")],
      list.map(threads, row(_, offer)),
    ),
  ])
}

/// The quiet sessions folded to a line of names. They have nothing to read, so
/// the line is text and not a row of buttons.
fn quiet_line(threads: List(Thread)) -> Element(message) {
  let names = list.map(threads, fn(each) { each.name })

  html.p([attribute.class("inbox-quiet")], [
    html.text("Quiet: " <> string.join(names, ", ")),
  ])
}

/// One thread's row: a button that shows the thread in the reading pane. Its
/// eyebrow is the kind's word and the session's name, and its head is the one
/// line the rule words from the report.
fn row(thread: Thread, offer: Offer(message)) -> Element(message) {
  let kind = inbox_rule.kind(thread.report)

  html.li([], [
    html.button(
      [
        attribute.type_("button"),
        attribute.class("inbox-thread"),
        attribute.class(kind_class(kind)),
        selection_class(thread.id, offer.selected),
        event.on_click(offer.pick(thread.id)),
      ],
      [
        html.span([attribute.class("inbox-eyebrow")], [
          html.text(inbox_rule.words(kind) <> " · " <> thread.name),
        ]),
        html.span([attribute.class("inbox-head")], [
          html.text(inbox_rule.head(thread.report)),
        ]),
      ],
    ),
  ])
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

/// The reading pane for one thread: its eyebrow, what its standing needs said,
/// its last message and strands, and the button that opens the session.
fn reading(
  thread: Thread,
  pick: Pick,
  offer: Offer(message),
) -> Element(message) {
  let kind = inbox_rule.kind(thread.report)

  html.article(
    [
      attribute.class("inbox-reading"),
      attribute.class(case pick {
        Default(_) -> "inbox-reading-default"
        Pressed(_) -> "inbox-reading-pressed"
      }),
    ],
    [
      html.p([attribute.class("inbox-eyebrow")], [
        html.text(eyebrow(thread, kind)),
      ]),
      standing(thread, kind, offer),
      said(thread),
      strands(thread.report.glances),
      open_button("Open session ›", thread.id, offer),
    ],
  )
}

/// The eyebrow: the kind's word, the session's name and, when the row has one,
/// its workspace as the host's text with the home directory shortened.
fn eyebrow(thread: Thread, kind: Kind) -> String {
  let base = inbox_rule.words(kind) <> " · " <> thread.name

  // A row with no workspace has no third part.
  case thread.workspace {
    "" -> base
    workspace -> base <> " · " <> heading.shorten_path(workspace)
  }
}

/// What the pane says about the thread's standing in the page's own words. An
/// approval is named and sent to the session's page and nothing of it is drawn
/// here; a failed run is named, since nothing waits on the owner but a fix.
fn standing(
  thread: Thread,
  kind: Kind,
  offer: Offer(message),
) -> Element(message) {
  case kind {
    inbox_rule.ApprovalPending ->
      html.div([attribute.class("inbox-standing")], [
        html.p([], [html.text("An approval is pending.")]),
        open_button("Decide on the session's page ›", thread.id, offer),
      ])
    inbox_rule.Failed ->
      html.p([attribute.class("inbox-standing")], [
        html.text("Its last run failed, and nothing is running."),
      ])
    inbox_rule.Idle | inbox_rule.Working | inbox_rule.Settled -> element.none()
  }
}

/// The main strand's last finished message under a label that says it is not
/// current work and not the page's words. It is a text node: the message is
/// model text.
fn said(thread: Thread) -> Element(message) {
  case thread.report.last_message {
    Some(text) ->
      case string.trim(text) {
        "" -> element.none()
        _ ->
          html.section([attribute.class("inbox-section")], [
            html.h4([attribute.class("inbox-label")], [
              html.text("The agent's last finished turn, untrusted text"),
            ]),
            html.p([attribute.class("inbox-message")], [html.text(text)]),
          ])
      }
    None -> element.none()
  }
}

/// What the session's strands say they are doing, one line each, as text nodes.
fn strands(glances: List(Glance)) -> Element(message) {
  case glances {
    [] -> element.none()
    [_, ..] ->
      html.section([attribute.class("inbox-section")], [
        html.h4([attribute.class("inbox-label")], [
          html.text("What its strands are doing"),
        ]),
        html.ul(
          [attribute.class("inbox-glances")],
          list.map(glances, fn(each) {
            html.li([], [html.text(glance_line(each))])
          }),
        ),
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

/// A button that sends the page's open message for the thread's session. It is
/// disabled while an open for the same session is out.
fn open_button(
  label: String,
  session: String,
  offer: Offer(message),
) -> Element(message) {
  let pending = offer.opening == Some(session)

  html.button(
    [
      attribute.type_("button"),
      attribute.class("inbox-open"),
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

/// The class that says which kind a row is, so the stylesheet tints its eyebrow.
fn kind_class(kind: Kind) -> String {
  case kind {
    inbox_rule.ApprovalPending -> "inbox-approval"
    inbox_rule.Failed -> "inbox-failed"
    inbox_rule.Idle -> "inbox-waiting"
    inbox_rule.Working -> "inbox-update"
    inbox_rule.Settled -> "inbox-settled"
  }
}

/// Marks the row whose thread the reading pane shows.
fn selection_class(
  session: String,
  selected: Option(Pick),
) -> attribute.Attribute(message) {
  case selected {
    Some(pick) if pick.session == session -> attribute.class("inbox-selected")
    Some(_) | None -> attribute.none()
  }
}
