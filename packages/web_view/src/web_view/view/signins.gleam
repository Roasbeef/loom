//// The home page's sign-ins region: the browsers signed in as the page's
//// principal, one row each, with the controls that end them and, on a page a
//// `loom ui` exchange opened, one that signs in another device
//// (protocol-change/065, the eighth pull request).
////
//// A row says which browser it is ("This browser" for the login this page
//// belongs to), when it was signed in, when it last came back and when it ends,
//// in words, and carries one button, "Sign out", whose message names the row's
//// fingerprint as the server drew it into the tree, so the browser's event names
//// only the path it fired at. Below the rows are "Sign out everywhere" and, on a
//// fresh home, "Sign in another device". The link that button makes is shown
//// once, in a `<loom-copy subject="device">` box that copies it only when it has
//// the shape the daemon writes (`web_client/copy_rule`), with a "Done" button
//// that hides it. The page that was opened by a remembered login also draws the
//// bookmark as text, so the person can keep it.
////
//// The region is the centre column's third child, after the sessions, so its
//// handlers are all beneath `home.signins_path`, and the home's socket admits a
//// click there for every home. Nothing here comes from a session. The
//// fingerprints, the bookmark and the link are the daemon's own, the words are
//// fixed, and every one is a text node or an attribute value on a client element
//// that checks its shape, and never a class, a key, a URL or a handler's message.
//// The classes are complete literals, so Tailwind finds them.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_view/sessions
import web_view/signins.{type Signin}

/// What the region offers for a device link.
pub type Device(message) {
  /// No control is drawn: the page was opened by the bookmark, or the daemon
  /// handed it no capability. The daemon refuses a forged request too.
  Never

  /// A "Sign in another device" button, and, when `shown` holds a link, the box
  /// that shows it once with `done` as its button's message. `press` is the
  /// button's message, `asking` says a request is out so the button holds no
  /// handler, and `refused` is the last refusal in the reason's fixed words.
  Offered(
    press: message,
    done: message,
    shown: Option(String),
    asking: Asking,
    refused: Option(String),
  )
}

/// Whether a device link's request is with the daemon.
pub type Asking {
  /// No request is out.
  Idle

  /// A request is out, so the button is disabled.
  Waiting
}

/// The region: a heading, the rows or the line that says there are none, the
/// controls, and the bookmark. `now` is the instant in Unix milliseconds the
/// words are counted from, and `this` is the fingerprint of the login this page
/// belongs to, if it does. `sign_out` is the message a row's button sends, given
/// that row's fingerprint, and `everywhere` is the message of "Sign out
/// everywhere". `bookmark` is the address the person keeps, when the page was
/// opened by a remembered login. `notice` is the words of the last press.
///
/// ## Examples
///
/// ```gleam
/// // signins.view(rows, now, None, None, SigningOut, SigningOutAll, Never, None)
/// ```
pub fn view(
  rows: List(Signin),
  now: Int,
  this: Option(String),
  bookmark: Option(String),
  sign_out: fn(String) -> message,
  everywhere: message,
  device: Device(message),
  notice: Option(String),
) -> Element(message) {
  use <- element.memo([
    element.ref(rows),
    element.ref(now),
    element.ref(this),
    element.ref(bookmark),
    element.ref(device),
    element.ref(notice),
  ])
  html.section([attribute.class("home-signins")], [
    html.h2([attribute.class("home-heading")], [html.text("Sign-ins")]),
    html.p([attribute.class("home-signins-lead")], [
      html.text(
        "Browsers signed in as you. A sign-in lasts 30 days from when it was made and is not extended by use.",
      ),
    ]),
    bookmark_line(bookmark),
    case rows {
      [] ->
        html.p([attribute.class("home-empty")], [
          html.text(
            "No browser is signed in. Run `loom ui` to sign this one in.",
          ),
        ])
      [_, ..] ->
        html.ul(
          [attribute.class("home-signin-list")],
          list.map(rows, row(_, now, this, sign_out)),
        )
    },
    controls(rows, everywhere, device),
    status(device, notice),
  ])
}

// The address the person keeps, as text: the whole of what a visit needs, since
// the browser holds the rest.
fn bookmark_line(bookmark: Option(String)) -> Element(message) {
  case bookmark {
    None -> element.none()
    Some(address) ->
      html.p([attribute.class("home-bookmark")], [
        html.text("Bookmark this address to come back without "),
        html.code([], [html.text("loom")]),
        html.text(": "),
        html.code([attribute.class("home-bookmark-text")], [html.text(address)]),
      ])
  }
}

// One browser: whose it is, the words of its history, and the button that ends
// it. The text is first and the button last, so the row reads left to right.
fn row(
  signin: Signin,
  now: Int,
  this: Option(String),
  sign_out: fn(String) -> message,
) -> Element(message) {
  let here = this == Some(signin.fingerprint)
  let name = case here {
    True -> "This browser"
    False -> "Another browser"
  }
  html.li(
    [
      attribute.class("home-signin"),
      attribute.class(case here {
        True -> "this"
        False -> "other"
      }),
    ],
    [
      html.span([attribute.class("home-signin-text")], [
        html.span([attribute.class("home-signin-name")], [html.text(name)]),
        html.span([attribute.class("home-signin-sub")], [
          html.text(history(signin, now)),
        ]),
      ]),
      html.button(
        [
          attribute.type_("button"),
          attribute.class("home-signin-out"),
          attribute.title("Sign this browser out"),
          event.on_click(sign_out(signin.fingerprint)),
        ],
        [html.text("Sign out")],
      ),
    ],
  )
}

// The words under a name: when it was signed in, when it last came back, when it
// ends and, for a login a device link made, the fingerprint of the one it came
// from, in the daemon's own digits. Each is a quiet phrase joined by a middle
// dot.
fn history(signin: Signin, now: Int) -> String {
  let signed = "signed in " <> sessions.ago(now, signin.issued_at_ms)
  let used = case signin.last_resumed_ms {
    Some(at) -> ["last used " <> sessions.ago(now, at)]
    None -> ["not used since"]
  }
  let ends = case signin.expires_at_ms {
    Some(at) -> ["ends in " <> signins.ends_in(now, at)]
    None -> []
  }
  let from = case signin.issued_by {
    Some(parent) -> ["from " <> parent]
    None -> []
  }
  join([[signed], used, ends, from])
}

fn join(parts: List(List(String))) -> String {
  string.join(list.flatten(parts), " · ")
}

// "Sign out everywhere", when there is a sign-in to end, and the device control
// of a fresh home. They share one row of actions.
fn controls(
  rows: List(Signin),
  everywhere: message,
  device: Device(message),
) -> Element(message) {
  html.div([attribute.class("home-signin-actions")], [
    case rows {
      [] -> element.none()
      [_, ..] ->
        html.button(
          [
            attribute.type_("button"),
            attribute.class("home-signin-all"),
            attribute.title("Sign every browser out, this one included"),
            event.on_click(everywhere),
          ],
          [html.text("Sign out everywhere")],
        )
    },
    case device {
      Never -> element.none()
      Offered(press:, asking:, ..) -> device_button(press, asking)
    },
  ])
}

fn device_button(press: message, asking: Asking) -> Element(message) {
  let common = [
    attribute.type_("button"),
    attribute.class("home-signin-device"),
    attribute.title("Make a link that signs in another device"),
  ]
  case asking {
    Waiting ->
      html.button([attribute.disabled(True), ..common], [
        html.text("Sign in another device"),
      ])
    Idle ->
      html.button([event.on_click(press), ..common], [
        html.text("Sign in another device"),
      ])
  }
}

// The line under the controls: the device link in its box while one is shown,
// the last refusal or press in fixed words, or the empty line, so the region's
// children keep their places.
fn status(device: Device(message), notice: Option(String)) -> Element(message) {
  case device {
    Offered(shown: Some(address), done:, ..) ->
      html.div([attribute.class("home-device-link")], [
        html.p([attribute.class("home-device-lead")], [
          html.text(
            "Open this link on the other device within 10 minutes. It signs that device in for the time this sign-in has left, and it works once.",
          ),
        ]),
        element.element(
          "loom-copy",
          [
            attribute.attribute("subject", "device"),
            attribute.attribute("text", address),
          ],
          [
            html.code([attribute.class("home-device-text")], [
              html.text(address),
            ]),
          ],
        ),
        html.button(
          [
            attribute.type_("button"),
            attribute.class("home-device-done"),
            event.on_click(done),
          ],
          [html.text("Done")],
        ),
      ])
    Offered(refused: Some(words), ..) -> line(words)
    Offered(..) | Never ->
      case notice {
        Some(words) -> line(words)
        None -> html.p([attribute.class("home-signin-status")], [])
      }
  }
}

fn line(words: String) -> Element(message) {
  html.p([attribute.class("home-signin-status"), attribute.role("status")], [
    html.text(words),
  ])
}
