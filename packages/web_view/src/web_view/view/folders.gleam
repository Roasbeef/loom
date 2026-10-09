//// The home's section for folders that hold no session: a control that opens a
//// session in a folder the owner types, and the folders the owner recently
//// started one in that the list above does not show (protocol-change/074).
////
//// A session's folder appears in the list while the owner holds a session in it.
//// When the last one is archived or deleted, the folder would otherwise be one
//// the owner has to type again, so the daemon remembers it and this section draws
//// it with a "New session" button and a "Forget this folder" button. The
//// section is drawn only where the page may create (`view/create`): the owner's
//// own operator page, and no other.
////
//// The section sits inside the sessions' region of the page (`home.table_path`),
//// which is where the owner's socket admits a submit, so its two forms need no
//// admission of their own. A folder's path is a person's text, so it is drawn as
//// a text node and never an attribute: not a `title`, not a class, and not the
//// key of its row. The row is keyed by the identity the daemon gave the entry
//// (`creations.Recent.id`), so a press that was in flight when the list changed
//// reaches the same entry or nothing, as a session's row does by its identity.
//// The refusal of a creation is drawn under the section's heading row, in the
//// fixed words of `creations.reason_words`, and never says the path.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import web_view/creations.{type Recent}
import web_view/view/create.{type Create}
import web_view/view/notice.{type Notice}

/// What the page offers for folders without a session.
pub type Folders(message) {
  /// The page may not create, or has not read its list yet. Nothing is drawn.
  Hidden

  /// The section is drawn. `recent` is the folders the daemon remembers that no
  /// session group already shows, newest first, and `forget` is the message a
  /// folder's button sends, given the entry's identity.
  Shown(recent: List(Recent), forget: fn(Int) -> message)
}

/// The folders a section draws, or `None` when it draws nothing, for a memoized
/// view's key: the section changes when its list does, and `forget` is a
/// constructor that is the same each time.
///
/// ## Examples
///
/// ```gleam
/// assert folders.listed(folders.Hidden) == None
/// ```
pub fn listed(folders: Folders(message)) -> Option(List(Recent)) {
  case folders {
    Hidden -> None
    Shown(recent:, ..) -> Some(recent)
  }
}

/// The section: its heading and the button that opens the form for a typed
/// folder (with the form, when it is open), then one row for each remembered
/// folder. `offer` is the page's offer to create (`view/create`), whose buttons
/// and forms the section reuses, and `notice` is the refusal of the last
/// creation made from this section, if one is.
///
/// ## Examples
///
/// ```gleam
/// // folders.view(folders.Hidden, create.Never, None)
/// ```
pub fn view(
  folders: Folders(message),
  offer: Create(message),
  notice: Option(Notice),
) -> Element(message) {
  case folders {
    Hidden -> element.none()
    Shown(recent:, forget:) ->
      html.section(
        [
          attribute.class("home-group"),
          attribute.class("home-folders"),
          attribute.aria_label("Other folders"),
        ],
        [
          html.div([attribute.class("home-group-head")], [
            html.h3([attribute.class("home-workspace")], [
              html.text("Other folders"),
            ]),
            create.elsewhere_button(offer),

            // The daemon's executors, when it has any, give the section a
            // second way to start a session where the owner has no folder: a
            // workspace registered on one of them (protocol-change/078).
            create.remote_button(offer),
          ]),

          // The refusal sits under the heading row and not in it: a sentence
          // as long as a refusal's squeezed the heading to two lines.
          case notice {
            Some(notice) -> notice.line(notice)
            None -> element.none()
          },
          create.elsewhere_form(offer),
          create.remote_form(offer),
          keyed.ul(
            [attribute.class("home-list")],
            list.map(recent, fn(entry) {
              #("f" <> int.to_string(entry.id), row(entry, offer, forget))
            }),
          ),
        ],
      )
  }
}

// One remembered folder: its directory name, the whole path as quiet text beside
// it, the two buttons, and the creation form beneath when this folder's is open.
fn row(
  entry: Recent,
  offer: Create(message),
  forget: fn(Int) -> message,
) -> Element(message) {
  html.li([attribute.class("home-folder")], [
    html.div([attribute.class("home-group-head")], [
      html.span([attribute.class("home-folder-name")], [
        html.text(creations.folder(entry.path)),
      ]),
      html.span([attribute.class("home-folder-path")], [html.text(entry.path)]),
      create.button(offer, entry.path),
      html.button(
        [
          attribute.type_("button"),
          attribute.class("home-forget"),
          event.on_click(forget(entry.id)),
        ],
        [html.text("Forget this folder")],
      ),
    ]),
    create.form(offer, entry.path),
  ])
}
