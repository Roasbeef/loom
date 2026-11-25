//// A project's page: what the owner holds of one project besides its tickets
//// (protocol-change/106, the addendum on the project page).
////
//// The page shows the project's router and what it decided lately, the project's
//// tickets by stage, a composer that posts a request to the router, and the
//// project's own settings with a form that changes them. The board it draws from
//// is the page's own (`Model.boards`), so this module holds only what the page
//// adds: the settings last read, whether a request is out, and what the page last
//// said. It is pure. The home owns the effects, and `view/project_page` draws the
//// state.
////
//// ## Settings
////
//// The form has four fields, `check`, `setup`, `max_workers` and
//// `protected_paths`, and the daemon's own rules judge every value, so a refusal
//// is the file's words. `changes` turns what the owner typed into the changes the
//// daemon takes, and sends only a key whose text differs from the value in force:
//// an unchanged form writes nothing, and a blank box gives a key the project holds
//// back to `loom.toml`. Publishing is not a field. It is a pair of buttons because
//// turning it on must name the URL the daemon showed, and `publishing` builds that
//// write.
////
//// ## Flow
////
//// `open` → `settings_heard` → `changes` → `settings_settled`, and `posting` →
//// `post_settled`
////
//// 1. `open` starts a page for a project, before its settings have been read.
//// 2. `settings_heard` takes a read of the settings, which decode totally.
//// 3. `changes` and `publishing` turn the form into a write, and
////    `settings_settled` takes the daemon's word on it.
//// 4. `posting` takes the composer's text and `post_settled` the daemon's word.
////
//// ## Examples
////
//// ```gleam
//// let page = project_page.open("p1")
//// assert page.settings == project_page.Unread
//// ```

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/project_settings_view.{type Settings, FromProject}
import web_view/projects

/// The most bytes of a request the page sends. The daemon takes more; this is
/// the size of a request typed into a box.
pub const request_limit = 8192

/// One project's page.
pub type Page {
  Page(
    /// The project's id, a value of a board the page holds.
    project: String,
    /// What the page knows of the settings.
    settings: Reading,
    /// Whether a request is with the daemon.
    composing: Composing,
    /// How many requests the page has sent. It keys the composer's box, so a
    /// recorded request leaves an empty box and a refused one keeps its text,
    /// and it makes the request id of the next.
    sent: Int,
    /// What the page last said, or nothing.
    notice: Option(Note),
  )
}

/// Where the read of the settings stands.
pub type Reading {
  /// The read has not answered, or did not decode. The page says so and keeps the
  /// rest of the page usable.
  Unread

  /// The settings as the daemon last sent them.
  Held(
    /// The settings, with the revision a write must echo.
    settings: Settings,
  )
}

/// Whether a request is out.
pub type Composing {
  /// The composer can be used.
  Ready

  /// A request or a settings write is with the daemon, so the page asks nothing
  /// more of it.
  Sending
}

/// What the page last said, in words.
pub type Note {
  /// Something that went well.
  Told(
    /// The words.
    words: String,
  )

  /// Something that did not go through, kept until the next act.
  Refusal(
    /// The words.
    words: String,
  )
}

/// A page for a project, with nothing read yet.
///
/// ## Examples
///
/// ```gleam
/// assert project_page.open("p1").sent == 0
/// ```
pub fn open(project: String) -> Page {
  Page(project:, settings: Unread, composing: Ready, sent: 0, notice: None)
}

/// A read of the settings. A body that does not decode keeps what the page held,
/// and says nothing, because the next read of the board tries again.
///
/// ## Examples
///
/// ```gleam
/// let page = project_page.open("p1")
/// assert project_page.settings_heard(page, projects.SettingsUnread) == page
/// ```
pub fn settings_heard(page: Page, read: projects.SettingsRead) -> Page {
  case read {
    projects.SettingsHeard(body:) ->
      case project_settings_view.decode_settings(body) {
        Ok(settings) -> Page(..page, settings: Held(settings))
        Error(_) -> page
      }
    projects.SettingsUnread -> page
  }
}

/// What the form's boxes held when it was sent.
pub type Form {
  Form(
    /// The check command.
    check: String,
    /// The setup command.
    setup: String,
    /// The most workers at once, as typed.
    max_workers: String,
    /// The protected path patterns, separated by spaces.
    protected_paths: String,
  )
}

/// The changes a form asks for: a key whose text differs from the value in force,
/// with its words, or none to give a key the project holds back to `loom.toml`
/// when the box was left blank. A form that changes nothing asks for nothing.
///
/// ## Examples
///
/// ```gleam
/// // project_page.changes(settings, project_page.Form("make check", "", "4", ""))
/// ```
pub fn changes(
  settings: Settings,
  form: Form,
) -> List(#(String, Option(List(String)))) {
  list.filter_map(
    [
      #("check", form.check, One),
      #("setup", form.setup, One),
      #("max_workers", form.max_workers, One),
      #("protected_paths", form.protected_paths, Many),
    ],
    fn(each) { change(settings, each.0, each.1, each.2) },
  )
}

/// How many words a key's value holds.
type Shape {
  /// One word: a command or a number, taken whole.
  One

  /// Any number, separated by spaces.
  Many
}

/// One key's change, or nothing when the text is the value in force.
fn change(
  settings: Settings,
  key: String,
  typed: String,
  shape: Shape,
) -> Result(#(String, Option(List(String))), Nil) {
  let held = list.find(settings.settings, fn(each) { each.key == key })

  // The typed text decides whether the key changes, is released or is left alone.
  let current = case held {
    Ok(found) -> string.join(found.value, " ")
    Error(Nil) -> ""
  }

  // The typed text decides whether the key changes, is released or is left alone.
  let source_held = case held {
    Ok(found) -> found.source == FromProject
    Error(Nil) -> False
  }

  let text = string.trim(typed)

  // A blank box releases a key the project holds and leaves any other alone.
  case text == string.trim(current), text {
    True, _ -> Error(Nil)
    False, "" ->
      case source_held {
        True -> Ok(#(key, None))
        False -> Error(Nil)
      }
    False, _ -> Ok(#(key, Some(words(text, shape))))
  }
}

/// The words of a value: the whole text for a command or a number, and each
/// pattern for a list of them.
fn words(text: String, shape: Shape) -> List(String) {
  case shape {
    Many -> string.split(text, " ") |> list.filter(fn(word) { word != "" })
    One -> [text]
  }
}

/// How publishing is to change.
pub type Publishing {
  /// Send verified branches to the project's remote. It names the URL the daemon
  /// showed, which the daemon requires before it turns this on.
  PublishOn

  /// Send nothing outward.
  PublishOff
}

/// The write that sets publishing, and the URL it names: the one the settings
/// showed when turning it on, or nothing when the project has no remote, which
/// the daemon refuses in words.
///
/// ## Examples
///
/// ```gleam
/// // project_page.publishing(settings, project_page.PublishOff)
/// ```
pub fn publishing(
  settings: Settings,
  how: Publishing,
) -> #(List(#(String, Option(List(String)))), Option(String)) {
  case how {
    PublishOn -> #([#("publish", Some(["pull_request"]))], settings.publish_url)
    PublishOff -> #([#("publish", Some(["off"]))], None)
  }
}

/// The daemon's word on a settings write. A stored write replaces the settings
/// the page holds, a stale one is read again by the home, and a refusal is said
/// in the daemon's words.
///
/// ## Examples
///
/// ```gleam
/// // project_page.settings_settled(page, projects.SettingsDeclined("bad_request", "no"))
/// ```
pub fn settings_settled(page: Page, write: projects.SettingsWrite) -> Page {
  case write {
    projects.SettingsStored(body:) ->
      case project_settings_view.decode_settings(body) {
        Ok(settings) ->
          Page(
            ..page,
            settings: Held(settings),
            composing: Ready,
            notice: Some(Told("Settings saved.")),
          )
        Error(_) ->
          Page(
            ..page,
            composing: Ready,
            notice: Some(Told("Settings saved. They are read again.")),
          )
      }
    projects.SettingsDeclined(code: _, words:) ->
      Page(..page, composing: Ready, notice: Some(Refusal(words)))
  }
}

/// The composer's text. An empty request asks nothing, a request past the box's
/// limit is refused in words, and a page already sending asks nothing. The
/// result is the page that waits for the daemon and the request id to send, or
/// the page unchanged.
///
/// ## Examples
///
/// ```gleam
/// assert project_page.posting(project_page.open("p1"), "  ") == Error(project_page.open("p1"))
/// ```
pub fn posting(page: Page, text: String) -> Result(#(Page, String), Page) {
  case page.composing, string.trim(text) {
    Sending, _ -> Error(page)
    Ready, "" -> Error(page)
    Ready, trimmed ->
      case string.byte_size(trimmed) > request_limit {
        True ->
          Error(
            Page(
              ..page,
              notice: Some(Refusal(
                "That request is longer than the page sends.",
              )),
            ),
          )
        False -> Ok(#(Page(..page, composing: Sending, notice: None), trimmed))
      }
  }
}

/// The daemon's word on a post. A recorded request leaves an empty box, because
/// the page counts it, and a refusal keeps the text.
///
/// ## Examples
///
/// ```gleam
/// // project_page.post_settled(page, projects.Posted("tr-1"))
/// ```
pub fn post_settled(page: Page, posted: projects.Posted) -> Page {
  case posted {
    projects.Posted(_) | projects.Reposted(_) ->
      Page(
        ..page,
        composing: Ready,
        sent: page.sent + 1,
        notice: Some(Told("Request sent to the router.")),
      )
    projects.NotPosted(code:) ->
      Page(..page, composing: Ready, notice: Some(Refusal(post_refusal(code))))
  }
}

/// A refusal of a post, in words. The daemon's code is the only thing that
/// selects them.
fn post_refusal(code: String) -> String {
  case code {
    "not_found" -> "That project is gone."
    "forbidden" -> "Only the owner can post a request."
    _ -> "The daemon did not take that request."
  }
}

/// The request id of the next post: the project, and how many the page has sent.
/// A repeat of one id is `Reposted` and changes nothing, so the daemon dedupes a
/// press that arrives twice.
///
/// ## Examples
///
/// ```gleam
/// assert project_page.request_id(project_page.open("p1")) == "web-p1-0"
/// ```
pub fn request_id(page: Page) -> String {
  "web-" <> page.project <> "-" <> int.to_string(page.sent)
}
