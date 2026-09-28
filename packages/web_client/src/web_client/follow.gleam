//// `<loom-follow>`: keeps the newest row of the lane in view while the
//// reader is at the bottom of the page, and leaves the page alone once they
//// scroll up.
////
//// The server component draws the lane inside this element, and a new row
//// lands at the lane's end, below the viewport. Nothing on the server can
//// scroll the browser, since a server component has no paint effects, and
//// rendering a scroll position from the server would cost a render per
//// scroll. So the browser decides, here, from two things it can observe:
//// how far the viewport is from the bottom of the page when the page
//// scrolls, and when the lane changes size.
////
//// The element starts `Following`. Each scroll of the page sets its
//// position from the gap between the viewport's bottom and the page's: a
//// gap within `slack` pixels is `Following`, and anything more means the
//// reader scrolled up to read and is `Reading`. When the lane grows while
//// the element is `Following`, it scrolls the page to its bottom; while
//// `Reading`, it does nothing. Scrolling back to the bottom is a scroll
//// like any other, so it resumes following with no control to press.
////
//// A fold the reader opens also grows the lane. Scrolling to the bottom
//// then would carry the page past the divider they just pressed, to the
//// end of the work it revealed. So `<loom-fold>` announces each toggle
//// with an event that bubbles to this element's slot, and the element
//// takes it as the reader's own move: it becomes `Reading`, the growth
//// that follows scrolls nothing, and the reader's next scroll to the
//// bottom resumes following.
////
//// The element takes no attribute and renders nothing of its own: its
//// shadow root holds one default slot, through which the server's lane is
//// shown as the server rendered and escaped it. It reads no text, handles
//// no key, takes no focus, and scrolls only the page. The approval cards
//// and the composer are outside it, in the dock, so neither its scrolling
//// nor its size observation touches them.

import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}
import lustre
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/event
import web_client/fold
import web_client/internal/ffi_follow

/// The element's tag.
pub const name = "loom-follow"

/// How many pixels from the bottom of the page still count as at the
/// bottom. A reader who scrolls up by one notch of a wheel moves further
/// than this; a page whose last row is still being laid out does not.
pub const slack = 40

/// Where the reader is.
pub type Position {
  /// At the bottom of the page: a row that lands is scrolled into view.
  Following

  /// Scrolled up to read: a row that lands leaves the page where it is.
  Reading
}

/// What the element knows: where the reader is, and its watch on the page
/// while it is on the page.
pub type Model {
  Model(position: Position, watching: Option(ffi_follow.Watching))
}

/// Everything the element can be told.
pub type Msg {
  /// The element was added to the page.
  Connected

  /// The element left the page.
  Disconnected

  /// The watch on the page's scrolling and the lane's size started.
  Watched(watching: ffi_follow.Watching)

  /// The page scrolled, and the viewport's bottom is this many pixels above
  /// the page's.
  Scrolled(gap: Int)

  /// The lane changed size: a row landed, or a fold opened or closed.
  Resized

  /// A fold in the lane opened or closed at the reader's hand.
  Folded
}

/// Registers the element with the browser.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = follow.register()
/// ```
pub fn register() -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [
    component.on_connect(Connected),
    component.on_disconnect(Disconnected),
  ])
  |> lustre.register(name)
}

fn init(_: Nil) -> #(Model, Effect(Msg)) {
  #(Model(position: Following, watching: None), effect.none())
}

/// The reader's position for a gap between the viewport's bottom and the
/// page's, in pixels.
///
/// ## Examples
///
/// ```gleam
/// assert follow.position(0) == follow.Following
/// assert follow.position(600) == follow.Reading
/// ```
pub fn position(gap: Int) -> Position {
  case gap <= slack {
    True -> Following
    False -> Reading
  }
}

/// Applies one message. The page is read and scrolled only inside effects,
/// so `update` stays a function of its messages.
///
/// ## Examples
///
/// ```gleam
/// // follow.update(model, follow.Scrolled(0))
/// ```
pub fn update(model: Model, message: Msg) -> #(Model, Effect(Msg)) {
  case message {
    // Connecting starts one watch. Disconnecting stopped the one before, so
    // moving the element never runs two. The watch needs the element's
    // shadow root, which an effect is handed only once the element has
    // rendered.
    Connected -> #(model, start())
    Watched(watching:) -> #(
      Model(..model, watching: Some(watching)),
      effect.none(),
    )
    Disconnected -> #(Model(..model, watching: None), stop(model.watching))

    // A scroll the element made itself lands at the bottom and reads as
    // following, so only the reader's own scroll changes the position.
    Scrolled(gap:) -> #(Model(..model, position: position(gap)), effect.none())

    Resized ->
      case model.position {
        Following -> #(model, to_bottom())
        Reading -> #(model, effect.none())
      }

    // The fold's event arrives in the turn of the fold's own update, a frame
    // before the render that resizes the lane, so that resize finds
    // `Reading`.
    Folded -> #(Model(..model, position: Reading), effect.none())
  }
}

fn start() -> Effect(Msg) {
  use dispatch, root <- effect.after_paint
  let watching =
    ffi_follow.watch(root, fn(gap) { dispatch(Scrolled(gap)) }, fn() {
      dispatch(Resized)
    })
  dispatch(Watched(watching))
}

fn stop(watching: Option(ffi_follow.Watching)) -> Effect(Msg) {
  case watching {
    None -> effect.none()
    Some(watching) -> {
      use _ <- effect.from
      ffi_follow.unwatch(watching)
    }
  }
}

fn to_bottom() -> Effect(Msg) {
  use _ <- effect.from
  ffi_follow.to_bottom()
}

// The slot is where an event from a slotted `<loom-fold>` passes on its
// way up, so the fold's toggle is heard here.
fn view(_: Model) -> Element(Msg) {
  component.default_slot(
    [event.on(fold.toggled_event, decode.success(Folded))],
    [],
  )
}
