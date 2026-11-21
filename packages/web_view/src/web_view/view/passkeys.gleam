//// The account panel's passkeys region (protocol-change/127): the owner's
//// passkeys, one row each, a "Remove" that asks for a second press, and on a
//// fresh home "Add a passkey".
////
//// A row says the label the owner typed, when the passkey was added and when it
//// last signed a browser in, in words. Its one control is "Remove". The first
//// press does not remove: it turns the row's control into "Confirm" and "Cancel",
//// and only "Confirm" asks the daemon. Each button's message names the row's
//// fingerprint as the server drew it into the tree, so the browser's event names
//// only the path it fired at.
////
//// "Add a passkey" is a link to the registration page, not an event: creating a
//// credential needs a script, so it is a document of its own
//// (`web_view/page.passkey_page`). The link is drawn only when the daemon handed
//// the page an address for it, which it does for the owner's fresh operating
//// home alone, and the daemon refuses the registration from any other page.
////
//// The region is the last child of the account panel (`view/signins`), so every
//// handler is beneath `home.signins_path` and the home's socket already admits a
//// click there. Nothing here comes from a session. The labels and the words are
//// text nodes, the link's address is the daemon's, and the classes are complete
//// literals, so Tailwind finds them.

import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_view/passkeys.{type Passkey}
import web_view/sessions

/// What the region offers.
pub type Offer(message) {
  /// The page was handed no passkey capability, a member's or a read-only
  /// page's, so no region is drawn.
  Hidden

  /// The region is drawn. `rows` are the passkeys, `now` the instant the words
  /// are counted from in Unix milliseconds, and `add` the address of the
  /// registration page when this page may offer it. `ask`, `confirm` and
  /// `cancel` are the messages of "Remove", "Confirm" and "Cancel", given a
  /// row's fingerprint where a row is named, `asked` the fingerprint whose second
  /// press is pending, and `notice` the words of the last press.
  Shown(
    rows: List(Passkey),
    now: Int,
    add: Option(String),
    ask: fn(String) -> message,
    confirm: fn(String) -> message,
    cancel: message,
    asked: Option(String),
    notice: Option(String),
  )
}

/// The region, or nothing for a page without the capability.
///
/// ## Examples
///
/// ```gleam
/// // passkeys_view.view(passkeys_view.Hidden) == element.none()
/// ```
pub fn view(offer: Offer(message)) -> Element(message) {
  case offer {
    Hidden -> element.none()
    Shown(rows:, now:, add:, ask:, confirm:, cancel:, asked:, notice:) ->
      html.div([attribute.class("home-passkeys")], [
        html.h2([attribute.class("home-heading")], [html.text("Passkeys")]),
        html.p([attribute.class("home-signins-lead")], [html.text(lead())]),
        case rows {
          [] ->
            html.p([attribute.class("home-empty")], [
              html.text(empty_words(add)),
            ])
          [_, ..] ->
            html.ul(
              [attribute.class("home-signin-list")],
              list.map(rows, row(_, now, ask, confirm, cancel, asked)),
            )
        },
        html.div([attribute.class("home-signin-actions")], [add_link(add)]),
        status(notice),
      ])
  }
}

/// What the region says it is for.
fn lead() -> String {
  "Sign in to this daemon from a phone or another computer without a shell, "
  <> "with a passkey. A passkey opens your home and cannot open the admin page "
  <> "or add another passkey."
}

/// What the region says when there is no passkey, and where to add one.
fn empty_words(add: Option(String)) -> String {
  case add {
    Some(_) -> "No passkey is added yet."
    None ->
      "No passkey is added yet. Add one from a page opened with `loom ui`."
  }
}

/// "Add a passkey", a link, when the page may offer it.
fn add_link(add: Option(String)) -> Element(message) {
  case add {
    Some(address) ->
      html.a(
        [
          attribute.class("home-signin-device"),
          attribute.href(address),
          attribute.title("Add a passkey for this daemon"),
        ],
        [html.text("Add a passkey")],
      )
    None -> element.none()
  }
}

/// One passkey: its label, the words of its history, and its controls. The text
/// is first and the buttons last, so the row reads left to right.
fn row(
  passkey: Passkey,
  now: Int,
  ask: fn(String) -> message,
  confirm: fn(String) -> message,
  cancel: message,
  asked: Option(String),
) -> Element(message) {
  html.li([attribute.class("home-signin other")], [
    html.span([attribute.class("home-signin-text")], [
      html.span([attribute.class("home-signin-name")], [
        html.text(passkey.label),
      ]),
      html.span([attribute.class("home-signin-sub")], [
        html.text(history(passkey, now)),
      ]),
    ]),
    case asked == Some(passkey.fingerprint) {
      True ->
        element.fragment([
          button("Confirm", "Remove this passkey", confirm(passkey.fingerprint)),
          button("Cancel", "Keep this passkey", cancel),
        ])
      False -> button("Remove", "Remove this passkey", ask(passkey.fingerprint))
    },
  ])
}

/// The words under a label: when the passkey was added and when it last signed a
/// browser in.
///
/// ## Examples
///
/// ```gleam
/// // passkeys_view.history(row, now) == "added 2h ago · not used yet"
/// ```
pub fn history(passkey: Passkey, now: Int) -> String {
  let added = "added " <> sessions.ago(now, passkey.created_at_ms)

  // A passkey that has never signed anything in says so.
  case passkey.last_used_ms {
    Some(at) -> added <> " · last used " <> sessions.ago(now, at)
    None -> added <> " · not used yet"
  }
}

/// One of a row's buttons. The message is the daemon-drawn one for this row.
fn button(words: String, title: String, message: message) -> Element(message) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class("home-signin-out"),
      attribute.title(title),
      event.on_click(message),
    ],
    [html.text(words)],
  )
}

/// The line under the controls: the last press's fixed words, or the empty line
/// that keeps the region's children where they are.
fn status(notice: Option(String)) -> Element(message) {
  case notice {
    Some(words) ->
      html.p([attribute.class("home-signin-status"), attribute.role("status")], [
        html.text(words),
      ])
    None -> html.p([attribute.class("home-signin-status")], [])
  }
}
