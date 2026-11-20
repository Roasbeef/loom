//// The page's top bar on a session's page: the brand, the way back to the
//// inbox, the session's place as a breadcrumb, and who the page is for. It is
//// the first region both pages draw.
////
//// The bar is the final design's one row, 44px tall, the same on every page
//// (`docs/design-notes/attention-inbox/final/mockup.html`). It reads
//// `loom  ‹ Inbox  <workspace> / <b>name</b>  ● live`, then the pill that counts
//// what needs the owner and, at the right, a chip that says who the page is for.
//// The context and cost figures and the placement chips that used to sit on a
//// second row moved to the stream's strip (`view/stream_head`, `view/figures`),
//// which is where a reader looks for the facts of the session on screen.
////
//// It draws values the component hands it and decides nothing about the
//// session. Every value it draws comes from the daemon's catalogue or from the
//// component's own words, never from the session's transcript: the name is the
//// label the owner gave the session, the workspace is the directory the host
//// validated when the session was created, and the status is the component's.
//// Each is drawn as a text node, or as a `title` attribute that Lustre escapes
//// and the browser never runs. Transcript text must never reach this region,
//// and no attribute here may be built from it.
////
//// The location is two spans, the workspace's last folder name and then the
//// session's name, with the whole path in a `title`. The folder is left out when
//// it is only the name again.
////
//// A page opened from the home (protocol-change/065) draws one more control, a
//// "‹ Inbox" button, as the bar's second child, straight after the brand. The
//// bar always has that child, an empty node when the page has no way home, so
//// the page socket can name the button's path (`component.home_path`) and the
//// children after it keep their places whether or not it is drawn.
////
//// The session's name is wrapped, with the main strand's model beside it and the
//// `● live` mark after it, in one `span` that holds the bar's fourth child. The
//// `h1` stays alone in its own element, since `<loom-title>` reads the tab's
//// title from its text. The mark's dot takes its colour from a closed `Doing`,
//// and it is drawn only while the page is connected, so the status pill and the
//// mark never say two things at once.
////
//// The status is a pill whose colour and dot follow a `Tone` the component
//// chooses from the connection, so the words and the colour cannot disagree. The
//// stylesheet draws it only when the page is not connected.
////
//// The ended page's notice is the bar's fifth child after the status, so a page
//// with no session says why without moving any region after it. The hidden
//// `<loom-title>` comes next and sets the tab's title from the name drawn here
//// (`web_client/title`): the document the server serves can say only `Loom`,
//// because the session's name is not known to the shell. The pill that counts
//// what needs the owner and the chip that names the audience follow it.
////
//// The heading takes plain values rather than the component's `Label` and
//// `Status`, because `web_view/component` imports this module to lay the page
//// out, and a module the component imports cannot import the component back.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_view/view/stream_head.{type Tone as Doing}

/// How the status pill is coloured: the connection is up, is being made, or
/// has ended. The component maps its own status onto one, so the colour is
/// never derived from the status words.
pub type Tone {
  /// The page is connected: a green pill with a dot.
  Live

  /// The page is connecting: an amber pill.
  Pending

  /// The page has ended: a red pill.
  Closed
}

/// The page's top bar: the brand, the way back, the workspace and name that
/// locate the session, the connection's status and who the page is for.
///
/// The name is the catalogue's label, or the session's identity shortened to its
/// first eight characters when it has none; the whole identity is the heading's
/// `title`. The workspace is drawn as its last folder name and is omitted when it
/// equals the name's first word; the whole path, with the home directory written
/// as `~`, is in a `title`. Both are text nodes and attribute values that Lustre
/// escapes. The catalogue's fields are written by the owner and the host, never
/// by the session's agent, and a `title` is inert, so neither needs the stricter
/// handling transcript text gets.
///
/// `name` and `workspace` are the catalogue label's two fields, or `None` when
/// the host could not read the label; `status` is the connection's status as the
/// page words it. `model` is the catalogue's name for the model the main strand
/// runs on, drawn beside the name as plain text, or `None` while the capture
/// holds none; the model's upstream identifier is not drawn here. `doing` is
/// what the session is doing, for the `live` mark's dot, and `needing` how many
/// sessions wait on the person, which the pill beside the crumb counts. `role` is
/// the words of the chip at the right.
///
/// ## Examples
///
/// ```gleam
/// // heading.view("0192ab34cd", element.none(), Some("docs"), Some("/src/loom"), Some("glm-5-3"), "connected", heading.Live, element.none(), stream_head.Running, 2, "owner · operating")
/// ```
pub fn view(
  session_id session_id: String,
  home home: Element(message),
  name name: Option(String),
  workspace workspace: Option(String),
  model model: Option(String),
  status status: String,
  tone tone: Tone,
  notice notice: Element(message),
  doing doing: Doing,
  needing needing: Int,
  role role: String,
) -> Element(message) {
  html.header(
    [attribute.class("session-head"), attribute.attribute("slot", "bar")],
    [
      html.span([attribute.class("brand")], [html.text("loom")]),
      home,
      workspace_element(workspace, session_name(session_id, name)),
      html.span([attribute.class("session-title")], [
        html.h1([attribute.title(session_id)], [
          html.text(session_name(session_id, name)),
        ]),
        model_element(model),
        live_mark(tone, doing),
      ]),
      html.p(
        [
          attribute.class("status"),
          attribute.class("pill"),
          attribute.class(tone_class(tone)),
          attribute.role("status"),
        ],
        [html.text(status)],
      ),
      notice,
      tab_title(),
      need_pill(needing),
      html.span([attribute.class("role-chip")], [html.text(role)]),
    ],
  )
}

/// The `● live` mark after the session's name: a dot coloured for what the
/// session is doing and the word. It is drawn only while the page is connected;
/// a page that is connecting or has ended says so in the status pill instead.
fn live_mark(tone: Tone, doing: Doing) -> Element(message) {
  case tone {
    Live ->
      html.span([attribute.class("live-mark")], [
        html.span(
          [
            attribute.class("stream-dot"),
            attribute.class(case doing {
              stream_head.Running -> "stream-run"
              stream_head.Waiting -> "stream-wait"
              stream_head.Quiet -> "stream-quiet"
            }),
          ],
          [],
        ),
        html.text("live"),
      ])
    Pending | Closed -> element.none()
  }
}

/// The pill that says how many sessions wait on the person, or nothing when none
/// does. The number is an integer the page counted.
fn need_pill(needing: Int) -> Element(message) {
  case needing > 0 {
    True ->
      html.span([attribute.class("need-pill")], [
        html.text(int.to_string(needing) <> " need you"),
      ])
    False -> element.none()
  }
}

/// The main strand's model as quiet text beside the name, or nothing while it
/// is unknown. The name is the catalogue's, which the owner wrote, and it is a
/// text node; the element has no handler and no colour of its own.
fn model_element(model: Option(String)) -> Element(message) {
  case model {
    Some("") | None -> element.none()
    Some(model) ->
      html.span(
        [
          attribute.class("session-model"),
          attribute.title("Model the main strand runs on"),
        ],
        [html.text(model)],
      )
  }
}

// The element that writes the tab's title (`web_client/title`): hidden, empty
// and attribute-free, drawn after the notice so no child before it moves. It
// reads the name this bar draws as text and the frame's count; the server
// writes no name into it.
fn tab_title() -> Element(message) {
  element.element("loom-title", [attribute.attribute("hidden", "")], [])
}

/// The "Home" button of a page opened from the home: one handler, whose
/// message is the caller's and is fixed when the tree is drawn. A press asks
/// the daemon for a home ticket; the browser never names where it goes.
///
/// ## Examples
///
/// ```gleam
/// // heading.home_link(GoingHome)
/// ```
pub fn home_link(press: message) -> Element(message) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class("home-link"),
      attribute.title("Back to the inbox"),
      event.on_click(press),
    ],
    [html.text("‹ Inbox")],
  )
}

/// A session with no name, or none the host could read, is named by its
/// identity's first eight characters. The whole identity is in the
/// heading's `title`, so the shortening loses nothing a reader can need. The
/// breadcrumb names the session the same way.
///
/// ## Examples
///
/// ```gleam
/// assert heading.session_name("0192ab34cd", None) == "Session 0192ab34"
/// assert heading.session_name("0192ab34cd", Some("docs")) == "docs"
/// assert heading.session_name("0192ab34cd", Some("  ")) == "Session 0192ab34"
/// ```
pub fn session_name(session_id: String, name: Option(String)) -> String {
  // A name of only whitespace is no name, as `sessions.label` also judges.
  case option.map(name, string.trim) {
    Some("") | None -> "Session " <> string.slice(session_id, 0, 8)
    Some(_) -> option.unwrap(name, "")
  }
}

/// The class a tone gives the status pill, a complete literal so Tailwind
/// finds it.
///
/// ## Examples
///
/// ```gleam
/// assert heading.tone_class(heading.Live) == "online"
/// ```
pub fn tone_class(tone: Tone) -> String {
  case tone {
    Live -> "online"
    Pending -> "pending"
    Closed -> "ended"
  }
}

/// A workspace path for the bar: the owner's home directory is written
/// `~`, so `/Users/ada/src/loom` reads `~/src/loom`. Both the macOS and the
/// Linux home roots are recognised, and any other path is returned as given.
/// A trailing slash is dropped.
///
/// ## Examples
///
/// ```gleam
/// assert heading.shorten_path("/Users/ada/src/loom") == "~/src/loom"
/// assert heading.shorten_path("/home/ada") == "~"
/// assert heading.shorten_path("/srv/loom") == "/srv/loom"
/// ```
pub fn shorten_path(path: String) -> String {
  // Dispatch on shorten_path state.
  let path = case path != "/" && string.ends_with(path, "/") {
    True -> string.drop_end(path, 1)
    False -> path
  }

  // Dispatch on shorten_path state.
  case string.split(path, "/") {
    ["", "Users", _, ..rest] | ["", "home", _, ..rest] ->
      string.join(["~", ..rest], "/")
    _ -> path
  }
}

/// The workspace's shortened path, or nothing when it is unknown or is only
/// the session's name again. The bar keeps the same children either way, so
/// the status keeps its place in the tree. The whole path is also the title.
fn workspace_element(
  workspace: Option(String),
  name: String,
) -> Element(message) {
  case workspace {
    Some("") | None -> element.none()
    Some(workspace) ->
      case last_folder(workspace) == first_word(name) {
        True -> element.none()
        False ->
          html.span(
            [
              attribute.class("workspace"),
              attribute.title(shorten_path(workspace)),
            ],
            [html.text(last_folder(workspace))],
          )
      }
  }
}

/// The last folder of a path, which is the name the final design's crumb gives
/// the workspace and the stream's strip too. A path with no folder (the root) is
/// shown whole.
///
/// ## Examples
///
/// ```gleam
/// assert heading.last_folder("/src/loom/") == "loom"
/// assert heading.last_folder("/") == "/"
/// ```
pub fn last_folder(path: String) -> String {
  case
    list.last(list.filter(string.split(path, "/"), fn(part) { part != "" }))
  {
    Ok(folder) -> folder
    Error(Nil) -> path
  }
}

fn first_word(name: String) -> String {
  case string.split_once(name, " ") {
    Ok(#(word, _)) -> word
    Error(Nil) -> name
  }
}
