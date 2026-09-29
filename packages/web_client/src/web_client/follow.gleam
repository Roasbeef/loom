//// `<loom-follow>`: the transcript's scroll container. It keeps the newest
//// row in view while the reader is at the bottom, leaves the transcript
//// alone once they scroll up, and offers a "Jump to latest" button while
//// they are away from the bottom.
////
//// The page's frame is pinned: the header and the agent strip stay at the
//// top and the dock at the bottom, and only the transcript scrolls
//// (`web_client.css`). This element is that scroller. The server component
//// draws the lane inside it, and a new row lands at the lane's end, below
//// what the reader sees. Nothing on the server can scroll the browser,
//// since a server component has no paint effects, and rendering a scroll
//// position from the server would cost a render per scroll. So the browser
//// decides, here, from what it can observe: each scroll of the transcript,
//// and each change in the size of its content.
////
//// The element starts `Following`. A scroll that ends within `slack`
//// pixels of the bottom is `Following`. A scroll that moves the transcript
//// up and ends further away is the reader leaving the tail, and is
//// `Reading`. A scroll that moves it down and ends short of the bottom
//// changes nothing: it is either the reader on their way back down, or the
//// element's own scroll to the bottom, reported after more rows landed
//// beneath it. Reading the gap alone would take that second case for the
//// reader scrolling up, and the transcript would stop following in the
//// middle of a burst of rows. When the content grows while the element is
//// `Following`, it scrolls to the bottom; while `Reading`, it does nothing.
//// Scrolling back to the bottom resumes following, as does the button.
////
//// The element also follows the transcript's own box. The dock grows when
//// an approval card appears, and the transcript shrinks by as much; the
//// element takes that as a resize and, while following, scrolls to the
//// bottom, so the newest row is not left behind the dock.
////
//// A fold the reader opens also grows the lane. Scrolling to the bottom
//// then would carry the transcript past the divider they just pressed, to
//// the end of the work it revealed. So `<loom-fold>` announces each toggle
//// with an event that bubbles to this element's slot, and the element
//// takes it as the reader's own move: it becomes `Reading`, the growth
//// that follows scrolls nothing, and the reader's next scroll to the
//// bottom resumes following.
////
//// The page holds only the newest rows, and the reader can load older ones
//// with the lane's "Load older" button, which the server draws above the
//// oldest row. The rows that arrive land above everything the reader was
//// looking at, and the stylesheet turns the browser's scroll anchoring off
//// for this element so that the place is kept in one way in every browser.
//// The element keeps it itself: when a click on that button reaches its
//// slot, which it tells from any other click by the button's fixed
//// `data-loom-older` marker, it becomes `Reading` and holds the lane's
//// first row and where that row is on screen. When the lane next changes
//// size with a new first row, the older rows have arrived, and it scrolls
//// the transcript by however far the held row moved, then lets go. A
//// scroll by the reader while it waits moves the held position with them.
////
//// The element takes no attribute. Its shadow root holds one default slot,
//// through which the server's lane is shown as the server rendered and
//// escaped it, and, while the reader is away from the bottom, one button
//// whose label is fixed here. It reads no text, handles no key, and
//// scrolls only itself. The approval cards and the composer are outside
//// it, in the dock, so neither its scrolling nor its size observation
//// touches them.

import gleam/dynamic/decode
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/order
import lustre
import lustre/attribute
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_client/fold
import web_client/internal/ffi_follow

/// The element's tag.
pub const name = "loom-follow"

/// How many pixels from the bottom of the transcript still count as at the
/// bottom. A reader who scrolls up by one notch of a wheel moves further
/// than this; a transcript whose last row is still being laid out does not.
pub const slack = 40

/// Where the reader is.
pub type Position {
  /// At the bottom of the transcript: a row that lands is scrolled into
  /// view.
  Following

  /// Scrolled up to read: a row that lands leaves the transcript where it
  /// is.
  Reading
}

/// What the element knows: where the reader is, how far the bottom of the
/// transcript was from the bottom of its view when last measured, its watch
/// on the transcript while it is on the page, and the row it holds in place
/// while older rows are loading above it.
pub type Model {
  Model(
    position: Position,
    gap: Int,
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

  /// The watch on the transcript's scrolling and size started.
  Watched(watching: ffi_follow.Watching)

  /// The transcript scrolled. Its view's bottom is `gap` pixels above its
  /// content's, and it moved by `moved` pixels, negative for a move up.
  Scrolled(gap: Int, moved: Int)

  /// The transcript or its content changed size: a row landed, a fold
  /// opened or closed, or the dock grew.
  Resized

  /// The gap between the view's bottom and the content's, measured after a
  /// change in size that scrolled nothing.
  Measured(gap: Int)

  /// A fold in the lane opened or closed at the reader's hand.
  Folded

  /// The reader pressed the lane's "Load older" button.
  Paged

  /// The reader pressed "Jump to latest".
  Jumped

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
  #(
    Model(position: Following, gap: 0, watching: None, anchor: None),
    effect.none(),
  )
}

/// The reader's position for a gap between the view's bottom and the
/// content's, in pixels.
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

/// The reader's position after a scroll that ended `gap` pixels from the
/// bottom and moved by `moved` pixels, negative for a move up. Ending
/// within `slack` of the bottom is following whichever way the scroll
/// went. Further away, only a move up is the reader leaving the tail; a
/// move down there is either the reader coming back or the element's own
/// scroll to the bottom that rows landing beneath it have since outgrown,
/// and neither changes where the reader is.
///
/// ## Examples
///
/// ```gleam
/// assert follow.after_scroll(follow.Following, 300, -80) == follow.Reading
/// assert follow.after_scroll(follow.Following, 300, 80) == follow.Following
/// assert follow.after_scroll(follow.Reading, 300, 80) == follow.Reading
/// assert follow.after_scroll(follow.Reading, 10, 80) == follow.Following
/// ```
pub fn after_scroll(current: Position, gap: Int, moved: Int) -> Position {
  case position(gap), int.compare(moved, 0) {
    Following, _ -> Following
    Reading, order.Lt -> Reading
    Reading, order.Eq | Reading, order.Gt -> current
  }
}

/// Applies one message. The transcript is read and scrolled only inside
/// effects, so `update` stays a function of its messages.
///
/// ## Examples
///
/// ```gleam
/// // follow.update(model, follow.Scrolled(0, 40))
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

    // A scroll the element made itself lands at the bottom and moves down,
    // so only the reader's own scroll up changes the position. A held row
    // is measured again, so the place kept for the reader is where they
    // have scrolled to, not where they pressed the button.
    Scrolled(gap:, moved:) -> #(
      Model(
        ..model,
        position: after_scroll(model.position, gap, moved),
        gap: gap,
      ),
      remeasure(model.anchor),
    )

    // While following, content that grew is scrolled to its end and
    // nothing needs holding. While reading, a held row that is no longer
    // the lane's first has had older rows land above it, and the
    // transcript is scrolled to put it back; either way the gap is
    // measured again, since growth below the reader is what shows the
    // button.
    Resized ->
      case model.position, model.anchor {
        Following, _ -> #(
          Model(..model, anchor: None),
          to_bottom(model.watching),
        )
        Reading, Some(anchor) -> #(model, keep(model.watching, anchor))
        Reading, None -> #(model, measure(model.watching))
      }
    Measured(gap:) -> #(Model(..model, gap: gap), effect.none())

    // The fold's event arrives in the turn of the fold's own update, a frame
    // before the render that resizes the lane, so that resize finds
    // `Reading`.
    Folded -> #(Model(..model, position: Reading), effect.none())

    // Pressing the button is the reader's own move, as opening a fold is,
    // so the rows that land do not carry the transcript to its end. The
    // click reaches the slot before the server has the press, and the rows
    // come back a round trip later, so the row is held before anything
    // moves.
    Paged -> #(Model(..model, position: Reading), hold(model.watching))
    Held(anchor:) -> #(Model(..model, anchor: Some(anchor)), effect.none())
    Released -> #(Model(..model, anchor: None), measure(model.watching))

    // The button is the way back to the tail without a scroll: it follows
    // again from here, and nothing stays held.
    Jumped -> #(
      Model(..model, position: Following, gap: 0, anchor: None),
      to_bottom(model.watching),
    )
  }
}

fn start() -> Effect(Msg) {
  use dispatch, root <- effect.after_paint
  let watching =
    ffi_follow.watch(
      root,
      fn(gap, moved) { dispatch(Scrolled(gap:, moved:)) },
      fn() { dispatch(Resized) },
    )
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

fn to_bottom(watching: Option(ffi_follow.Watching)) -> Effect(Msg) {
  case watching {
    None -> effect.none()
    Some(watching) -> {
      use _ <- effect.from
      ffi_follow.to_bottom(watching)
    }
  }
}

fn measure(watching: Option(ffi_follow.Watching)) -> Effect(Msg) {
  case watching {
    None -> effect.none()
    Some(watching) -> {
      use dispatch <- effect.from
      dispatch(Measured(ffi_follow.measure(watching)))
    }
  }
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

// Puts a held row back if older rows have landed above it, and measures
// the gap either way, so a reader who is held while more rows arrive below
// still sees the button.
fn keep(
  watching: Option(ffi_follow.Watching),
  anchor: ffi_follow.Anchor,
) -> Effect(Msg) {
  use dispatch <- effect.from
  case ffi_follow.keep(anchor) {
    ffi_follow.Waiting -> Nil
    ffi_follow.Restored -> dispatch(Released)
  }

  case watching {
    None -> Nil
    Some(watching) -> dispatch(Measured(ffi_follow.measure(watching)))
  }
}

// The slot is where an event from a slotted `<loom-fold>` passes on its
// way up, so the fold's toggle is heard here, and so is a click on the
// lane's "Load older" button. The click is told apart by the button's
// marker, whose value the server writes from a constant; any other click
// in the lane fails the decoder and dispatches nothing.
//
// The button after the slot is drawn only while the reader is reading and
// the bottom is further than `slack` away. Its wrapper has no height and
// sticks to the bottom of the scroller (`web_client.css`), so it floats over
// the last rows without changing the content's size, which is what the
// resize observation would otherwise report as growth.
fn view(model: Model) -> Element(Msg) {
  let slot =
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

  case model.position, position(model.gap) {
    Reading, Reading ->
      element.fragment([
        slot,
        html.div([attribute.class("jump-anchor")], [
          html.button(
            [
              attribute.type_("button"),
              attribute.class("jump-latest"),
              event.on_click(Jumped),
            ],
            [html.text("Jump to latest")],
          ),
        ]),
      ])
    Following, _ | Reading, Following -> slot
  }
}
