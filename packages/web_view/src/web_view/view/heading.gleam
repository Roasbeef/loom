//// The page's top bar: the brand, the session's location (the workspace
//// and the name), the connection's status, and the two figures the engine
//// estimates for the session. It is the first region both pages draw.
////
//// The bar is the heading the page always had, moved to a full-width row
//// above the three columns (docs/design-notes/web-design.md, section 2.1).
//// It draws values the component hands it and decides nothing about the
//// session. Every value it draws comes from the daemon's catalogue or from
//// the component's own words, never from the session's transcript: the name
//// is the label the owner gave the session, the workspace is the directory
//// the host validated when the session was created, the status is the
//// component's, and the context and cost figures are the shared record's own
//// estimates as `session_view` words them. Each is drawn as a text node, or
//// as a `title` attribute that Lustre escapes and the browser never runs.
//// Transcript text must never reach this region, and no attribute here may
//// be built from it.
////
//// The location is two spans, the workspace's path and then the session's
//// name, so a link can replace the first when the app has a home page to
//// return to. The path is shown in full with the owner's home directory
//// written as `~`, and is left out when it is only the name again.
////
//// A page opened from the home (protocol-change/065) draws one more control, a
//// "Home" button, as the bar's second child, straight after the brand. The
//// bar always has that child, an empty node when the page has no way home, so
//// the page socket can name the button's path (`component.home_path`) and
//// the children after it keep their places whether or not it is drawn.
////
//// The session's name is wrapped, with the main strand's model beside it, in
//// one `span` that holds the bar's fourth child, so the model sits next to the
//// name without moving any child after it (the page socket names the figures'
//// path, `component.context_refresh_path`). The model is the catalogue's name
//// for it, quiet text with no colour of its own, and the wrapper is drawn
//// whether or not a model is known. The `h1` stays alone in its own element,
//// since `<loom-title>` reads the tab's title from its text.
////
//// The status is a pill whose colour and dot follow a `Tone` the component
//// chooses from the connection, so the words and the colour cannot disagree.
////
//// The ended page's notice is the bar's last child but one, so a page with no
//// session says why without moving any region after it. The stylesheet
//// wraps it onto a row of its own beneath the figures. The last child is the
//// hidden `<loom-title>`, which sets the tab's title from the name drawn here
//// (`web_client/title`): the document the server serves can say only `Loom`,
//// because the session's name is not known to the shell.
////
//// The heading takes plain values rather than the component's `Label` and
//// `Status`, because `web_view/component` imports this module to lay the
//// page out, and a module the component imports cannot import the
//// component back.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

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

/// The page's top bar: the brand, the workspace and name that locate the
/// session, the connection's status, and the context and cost figures.
///
/// The name is the catalogue's label, or the session's identity shortened
/// to its first eight characters when it has none; the whole identity is
/// the heading's `title`. The workspace is drawn as its whole path with the
/// home directory written as `~` (`shorten_path`), and is omitted when it
/// equals the name's first word; the whole path is in a `title`. Both are text nodes and attribute
/// values that Lustre escapes. The catalogue's fields are written by the
/// owner and the host, never by the session's agent, and a `title` is
/// inert, so neither needs the stricter handling transcript text gets.
///
/// `name` and `workspace` are the catalogue label's two fields, or `None`
/// when the host could not read the label; `status` is the connection's
/// status as the page words it. `context` and `cost` are the two estimates
/// the terminal's footer shows (`ctx ~41%` and `est $0.04`), already worded.
/// The context figure is the summary of a native `<details>`, and `breakdown`
/// is the body it opens (`view/context_breakdown`), drawn by the component
/// from the shared record; the heading places it and reads none of it.
/// `model` is the catalogue's name for the model the main strand runs on, drawn
/// beside the name as plain text, or `None` while the capture holds none; the
/// model's upstream identifier is not drawn here. The cost is the session's
/// running total across strands, and the bar's
/// label says so. A figure with no value is not drawn: an empty `context`
/// draws no `ctx`, and a `cost` that ends in the dash (`est —`, a model with
/// no price) draws no `est`, since two dashes beside each other read as
/// missing data rather than as "not known".
///
/// ## Examples
///
/// ```gleam
/// // heading.view("0192ab34cd", element.none(), Some("docs"), Some("/src/loom"), Some("glm-5-3"), "connected", heading.Live, "ctx ~41%", element.none(), "est $0.04", element.none())
/// ```
pub fn view(
  session_id session_id: String,
  home home: Element(message),
  name name: Option(String),
  workspace workspace: Option(String),
  model model: Option(String),
  status status: String,
  tone tone: Tone,
  context context: String,
  breakdown breakdown: Element(message),
  cost cost: String,
  notice notice: Element(message),
) -> Element(message) {
  html.header(
    [attribute.class("session-head"), attribute.attribute("slot", "bar")],
    [
      html.span([attribute.class("brand")], [html.text("Loom")]),
      home,
      workspace_element(workspace, session_name(session_id, name)),
      html.span([attribute.class("session-title")], [
        html.h1([attribute.title(session_id)], [
          html.text(session_name(session_id, name)),
        ]),
        model_element(model),
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
      html.span(
        [attribute.class("figures")],
        list.flatten([
          case context {
            "" -> []
            _ -> [
              html.details(
                [
                  attribute.class("figure"),
                  attribute.class("ctx"),
                  attribute.attribute("data-dismiss", "keep"),
                ],
                [
                  html.summary(
                    [
                      attribute.title(case string.ends_with(context, " —") {
                        True -> "No turn yet on the strand shown"
                        False ->
                          "Estimated context use of the strand shown. Open for the breakdown."
                      }),
                    ],
                    figure_words(context),
                  ),
                  breakdown,
                ],
              ),

              // Closes the panel on an outside press or Escape. A sibling and
              // not a wrapper, so the panel's buttons keep their tree paths.
              element.element("loom-dismiss", [], []),
            ]
          },

          // A session whose model has no price has no estimate to give, and
          // two dashes read as missing data. The Session tab, which has a row
          // labelled for the estimate, keeps its dash.
          case cost == "" || string.ends_with(cost, " —") {
            True -> []
            False -> [
              html.span(
                [
                  attribute.class("figure"),
                  attribute.title(
                    "Estimated cost of the session, across strands",
                  ),
                ],
                figure_words(cost),
              ),
            ]
          },
        ]),
      ),
      notice,
      tab_title(),
    ],
  )
}

// The main strand's model as quiet text beside the name, or nothing while it
// is unknown. The name is the catalogue's, which the owner wrote, and it is a
// text node; the element has no handler and no colour of its own.
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
// and attribute-free, the bar's last child so no child before it moves. It
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
      attribute.title("Back to the list of your sessions"),
      event.on_click(press),
    ],
    [html.text("Home")],
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
/// ```
pub fn session_name(session_id: String, name: Option(String)) -> String {
  case name {
    Some("") | None -> "Session " <> string.slice(session_id, 0, 8)
    Some(name) -> name
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
  let path = case path != "/" && string.ends_with(path, "/") {
    True -> string.drop_end(path, 1)
    False -> path
  }

  case string.split(path, "/") {
    ["", "Users", _, ..rest] | ["", "home", _, ..rest] ->
      string.join(["~", ..rest], "/")
    _ -> path
  }
}

// The workspace's shortened path, or nothing when it is unknown or is only
// the session's name again. The bar keeps the same children either way, so
// the status keeps its place in the tree. The whole path is also the title.
fn workspace_element(
  workspace: Option(String),
  name: String,
) -> Element(message) {
  case workspace {
    Some("") | None -> element.none()
    Some(workspace) ->
      case shorten_path(workspace) == first_word(name) {
        True -> element.none()
        False ->
          html.span([attribute.class("workspace"), attribute.title(workspace)], [
            html.text(shorten_path(workspace)),
          ])
      }
  }
}

fn first_word(name: String) -> String {
  case string.split_once(name, " ") {
    Ok(#(word, _)) -> word
    Error(Nil) -> name
  }
}

// The emphasised number of a figure. It is a classed span and not a `<b>`:
// the page's tests treat a bare bold tag anywhere in the page as markup that
// escaped from transcript text.
fn number_element(number: String) -> Element(message) {
  html.span([attribute.class("num")], [html.text(number)])
}

// A figure's label and its number: `ctx ~41%` is the word `ctx` and the
// emphasised `~41%`. The number is the last token and the label is everything
// before it, because the cost words carry qualifiers ahead of the marker
// (`API ref partial est $1.00`, `mixed rates est $2.10`) and only the amount
// is emphasis. A figure with no space is all emphasis.
fn figure_words(words: String) -> List(Element(message)) {
  case list.reverse(string.split(words, " ")) {
    [number, last_label, ..earlier] -> [
      html.text(string.join(list.reverse([last_label, ..earlier]), " ") <> " "),
      number_element(number),
    ]

    [_] | [] -> [number_element(words)]
  }
}
