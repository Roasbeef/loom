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
//// The page holds only the newest rows, and the reader can load older ones
//// with the lane's "Load older" button, which the server draws above the
//// oldest row. The rows that arrive land above everything the reader was
//// looking at. A browser that anchors scrolling keeps the view where it
//// was, and one that does not moves every row down by the height of what
//// arrived. So the element keeps the place itself: when a click on that
//// button reaches its slot, which it tells from any other click by the
//// button's fixed `data-loom-older` marker, it becomes `Reading` and holds
//// the lane's first row and where that row is on screen. When the lane
//// next changes size with a new first row, the older rows have arrived, and
//// it scrolls the page by however far the held row moved, then lets go. A
//// scroll by the reader while it waits moves the held position with them.
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

/// What the element knows: where the reader is, its watch on the page
/// while it is on the page, and the row it holds in place while older rows
/// are loading above it.
pub type Model {
  Model(
    position: Position,
    watching: Option(ffi_follow.Watching),
    anchor: Option(ffi_follow.Anchor),
  )
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

  /// The reader pressed the lane's "Load older" button.
  Paged

  /// The lane's first row and where it is on screen, held while older rows
  /// load above it.
  Held(anchor: ffi_follow.Anchor)

  /// The older rows arrived and the held row is back where it was, or the
  /// row left the page: nothing is held any more.
  Released
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
  #(Model(position: Following, watching: None, anchor: None), effect.none())
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
    // following, so only the reader's own scroll changes the position. A
    // held row is measured again, so the place kept for the reader is where
    // they have scrolled to, not where they pressed the button.
    Scrolled(gap:) -> #(
      Model(..model, position: position(gap)),
      remeasure(model.anchor),
    )

    // While following, a lane that grew is scrolled to its end and nothing
    // needs holding. While reading, a held row that is no longer the lane's
    // first has had older rows land above it, and the page is scrolled to
    // put it back.
    Resized ->
      case model.position, model.anchor {
        Following, _ -> #(Model(..model, anchor: None), to_bottom())
        Reading, Some(anchor) -> #(model, keep(anchor))
        Reading, None -> #(model, effect.none())
      }

    // The fold's event arrives in the turn of the fold's own update, a frame
    // before the render that resizes the lane, so that resize finds
    // `Reading`.
    Folded -> #(Model(..model, position: Reading), effect.none())

    // Pressing the button is the reader's own move, as opening a fold is,
    // so the rows that land do not carry the page to its end. The click
    // reaches the slot before the server has the press, and the rows come
    // back a round trip later, so the row is held before anything moves.
    Paged -> #(Model(..model, position: Reading), hold(model.watching))
    Held(anchor:) -> #(Model(..model, anchor: Some(anchor)), effect.none())
    Released -> #(Model(..model, anchor: None), effect.none())
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

fn hold(watching: Option(ffi_follow.Watching)) -> Effect(Msg) {
  case watching {
    None -> effect.none()
    Some(watching) -> {
      use dispatch <- effect.from
      dispatch(Held(ffi_follow.hold(watching)))
    }
  }
}

fn remeasure(anchor: Option(ffi_follow.Anchor)) -> Effect(Msg) {
  case anchor {
    None -> effect.none()
    Some(anchor) -> {
      use dispatch <- effect.from
      dispatch(Held(ffi_follow.remeasure(anchor)))
    }
  }
}

fn keep(anchor: ffi_follow.Anchor) -> Effect(Msg) {
  use dispatch <- effect.from
  case ffi_follow.keep(anchor) {
    ffi_follow.Waiting -> Nil
    ffi_follow.Restored -> dispatch(Released)
  }
}

// The slot is where an event from a slotted `<loom-fold>` passes on its
// way up, so the fold's toggle is heard here, and so is a click on the
// lane's "Load older" button. The click is told apart by the button's
// marker, whose value the server writes from a constant; any other click
// in the lane fails the decoder and dispatches nothing.
fn view(_: Model) -> Element(Msg) {
  component.default_slot(
    [
      event.on(fold.toggled_event, decode.success(Folded)),
      event.on("click", {
        use _ <- decode.subfield(
          ["target", "dataset", "loomOlder"],
          decode.string,
        )
        decode.success(Paged)
      }),
    ],
    [],
  )
}
