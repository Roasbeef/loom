//// The home's group for sessions on the owner's other orchestrators
//// (protocol-change/085).
////
//// A session is served by the orchestrator that created it, so the home lists
//// the ones its own daemon holds. This group follows "Other folders" and lists,
//// for each other orchestrator the daemon is configured with, the sessions that
//// orchestrator reports (`web_view/elsewhere`). A row is information, not a
//// door: this daemon cannot open another daemon's session for a browser, so the
//// row's button is "Where", which opens a detail under the row with the launch
//// that reaches the session on the machine that has it, in a `<loom-copy>` box,
//// and the same words the terminal prints. An orchestrator that did not answer
//// is one line, and one that has more rows than the page holds has a "Show more"
//// button that asks for the next page of that orchestrator alone.
////
//// Every handler is a click beneath the sessions' region of the page
//// (`home.table_path`), which the home's socket already admits, so the group
//// adds no event class, scope or route. A button names the orchestrator and the
//// session the server drew into the tree, never a value the browser supplies,
//// and the page honours a press only for a group and a row it holds.
////
//// ## What is drawn
////
//// Each orchestrator's key, address, and each row's name, workspace and
//// executor are other daemons' text, drawn as text nodes. No class, attribute
//// or key is built from any of them: the classes are fixed words, the rows are
//// keyed by position in the group, and the launch line travels in the
//// `<loom-copy>` element's `text` attribute, which the element checks against a
//// fixed shape before it offers a button (`web_client/copy_rule`). A state is
//// one of the fixed words of `web_view/elsewhere.word`. The detail and the
//// buttons use the page's existing tinted boxes with a hairline border, and no
//// left accent bar or shadow.
////
//// ## Flow
////
//// `view` → `group` → `row` → `detail`
////
//// 1. `view` is the memoized section: its heading and a `group` for each
////    orchestrator.
//// 2. `group` draws an orchestrator's name, then its rows or the one line that
////    says why it has none, and "Show more" when rows follow.
//// 3. `row` draws one session and its "Where" button, and `detail` the launch
////    box under the row whose button was pressed.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import web_view/elsewhere.{type Group, type Row, Answered, Further, Last, Silent}

/// Which row's detail is open: the orchestrator's key and the session.
pub type Detail {
  Detail(group: String, session: String)
}

/// What the page offers for the other orchestrators' sessions.
pub type Elsewhere(message) {
  /// The page has no such group: it is not the owner's operating page, or it has
  /// read nothing yet. Nothing is drawn.
  Hidden

  /// The group is drawn.
  Shown(
    /// The orchestrators and what each said.
    groups: List(Group),
    /// The row whose detail is open, if one is.
    open: Option(Detail),
    /// The orchestrator whose next page is out, if one is.
    asking: Option(String),
    /// The message a row's "Where" sends, given the orchestrator's key and the
    /// session.
    where: fn(String, String) -> message,
    /// The message the detail's "Close" sends.
    close: message,
    /// The message "Show more" sends, given the orchestrator's key.
    more: fn(String) -> message,
  )
}

/// What a memoized view keys on: the groups, the open detail and the group whose
/// page is out. The three message constructors are the same each time.
///
/// ## Examples
///
/// ```gleam
/// assert elsewhere.keyed(elsewhere.Hidden) == None
/// ```
pub fn keyed(
  offer: Elsewhere(message),
) -> Option(#(List(Group), Option(Detail), Option(String))) {
  case offer {
    Hidden -> None
    Shown(groups:, open:, asking:, ..) -> Some(#(groups, open, asking))
  }
}

/// The group, or nothing on a page that has no such group or has no other
/// orchestrator to list.
///
/// ## Examples
///
/// ```gleam
/// // elsewhere.view(elsewhere.Hidden)
/// ```
pub fn view(offer: Elsewhere(message)) -> Element(message) {
  case offer {
    Hidden | Shown(groups: [], ..) -> element.none()
    Shown(groups:, open:, asking:, where:, close:, more:) ->
      html.section(
        [
          attribute.class("home-group"),
          attribute.class("home-elsewhere"),
          attribute.aria_label("On other orchestrators"),
        ],
        [
          html.div([attribute.class("home-group-head")], [
            html.h3([attribute.class("home-workspace")], [
              html.text("On other orchestrators"),
            ]),
          ]),
          ..list.map(groups, group(_, open, asking, where, close, more))
        ],
      )
  }
}

// One orchestrator: its name and address as quiet text, then what it said.
fn group(
  each: Group,
  open: Option(Detail),
  asking: Option(String),
  where: fn(String, String) -> message,
  close: message,
  more: fn(String) -> message,
) -> Element(message) {
  html.div([attribute.class("home-elsewhere-group")], [
    html.div([attribute.class("home-group-head")], [
      html.span([attribute.class("home-folder-name")], [html.text(each.name)]),
      case each.address {
        Some(address) ->
          html.span([attribute.class("home-folder-path")], [
            html.text(address),
          ])
        None -> element.none()
      },
    ]),
    case each.hearing {
      Silent ->
        html.p([attribute.class("home-empty")], [
          html.text("No answer in time from this orchestrator."),
        ])
      Answered(rows: [], ..) ->
        html.p([attribute.class("home-empty")], [
          html.text("No sessions on this orchestrator."),
        ])
      Answered(rows:, more: shown_more) ->
        html.div([], [
          keyed.ul(
            [attribute.class("home-list")],
            list.index_map(rows, fn(each_row, index) {
              #(int.to_string(index), row(each, each_row, open, where, close))
            }),
          ),
          case shown_more {
            Further -> more_button(each.name, asking, more)
            Last -> element.none()
          },
        ])
    },
  ])
}

// One session and its button, and under them the detail when this is the row
// whose button was pressed.
fn row(
  each: Group,
  listed: Row,
  open: Option(Detail),
  where: fn(String, String) -> message,
  close: message,
) -> Element(message) {
  html.li([attribute.class("home-folder")], [
    html.div([attribute.class("home-group-head")], [
      html.span([attribute.class("home-folder-name")], [html.text(listed.name)]),
      html.span([attribute.class("home-folder-path")], [
        html.text(
          elsewhere.word(listed.status)
          <> " · "
          <> placed(listed.executor, listed.workspace),
        ),
      ]),
      html.button(
        [
          attribute.type_("button"),
          attribute.class("home-new"),
          event.on_click(where(each.name, listed.session_id)),
        ],
        [html.text("Where")],
      ),
    ]),
    case open {
      Some(Detail(group: key, session:))
        if key == each.name && session == listed.session_id
      -> detail(each, listed, close)
      Some(_) | None -> element.none()
    },
  ])
}

// The workspace, with the executor in front of it when the session is placed on
// one, as the terminal writes it.
fn placed(executor: Option(String), workspace: String) -> String {
  case executor {
    Some(name) -> name <> ":" <> workspace
    None -> workspace
  }
}

// The launch that reaches the session where it lives, in the box that copies
// exactly this shape and nothing else.
fn detail(each: Group, listed: Row, close: message) -> Element(message) {
  html.div([attribute.class("home-card")], [
    html.p([attribute.class("home-card-fact")], [
      html.text(
        "This session is on the orchestrator "
        <> each.name
        <> ". Run this on the machine that has its owner token:",
      ),
    ]),
    element.element(
      "loom-copy",
      [
        attribute.attribute("subject", "launch"),
        attribute.attribute("text", elsewhere.launch(each, listed)),
      ],
      [],
    ),
    html.button(
      [
        attribute.type_("button"),
        attribute.class("home-new"),
        event.on_click(close),
      ],
      [html.text("Close")],
    ),
  ])
}

// "Show more" for one orchestrator, disabled while its next page is out.
fn more_button(
  key: String,
  asking: Option(String),
  more: fn(String) -> message,
) -> Element(message) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class("home-new"),
      attribute.disabled(asking == Some(key)),
      event.on_click(more(key)),
    ],
    [html.text("Show more")],
  )
}
