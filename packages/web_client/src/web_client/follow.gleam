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
//// `Reading`, provided the reader made it. A scroll that moves it down and
//// ends short of the bottom changes nothing: it is either the reader on
//// their way back down, or the element's own scroll to the bottom, reported
//// after more rows landed beneath it. Reading the gap alone would take that
//// second case for the reader scrolling up, and the transcript would stop
//// following in the middle of a burst of rows. When the content grows while
//// the element is `Following`, it scrolls to the bottom; while `Reading`,
//// it does nothing. Scrolling back to the bottom resumes following, as does
//// the button.
////
//// Who made a scroll matters because the browser makes some. When the
//// content shrinks or the box grows it moves the scroll position up to fit,
//// and the event for that is heard after the rows that landed since, so it
//// reads as a move up that ends far from the bottom. The element tells the
//// two apart (`follow_rule.origin`) by what it heard first: a wheel, a finger, a pointer
//// press or a key pressed inside the transcript, within `follow_rule.touch_window`,
//// makes a scroll the reader's. Without one, a transcript that is the size
//// it was at the last scroll was moved by something that changes no size,
//// and is the reader's too. A transcript that changed size, with no touch,
//// was moved by the layout, and does not leave the tail: the size change
//// brings `Resized`, which scrolls to the bottom.
////
//// The key is noted and nothing more: the listener reads neither the key nor
//// its modifiers, cancels nothing and sends nothing, and only the composer
//// acts on keys. It hears only keys pressed with focus inside the
//// transcript.
////
//// The cost of the rule is that a scroll with none of those events before it
//// is the reader's only while the transcript holds still. While content is
//// growing, find-in-page, a key pressed with focus outside the transcript
//// and, in Firefox, a scrollbar drag (it raises no `pointerdown` there) see
//// a changed extent, so they read as `Layout` and cannot leave the tail
//// until the growth stops. Wheel, trackpad, touch and keys pressed in the
//// transcript are first-class.
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
//// A message the reader sends from the composer is the one event after which
//// the transcript always returns to the tail. The composer is in the dock,
//// outside this element, so it dispatches `follow_rule.sent_event` on press,
//// bubbling and composed, and the element hears it on the document and
//// follows again, whatever the reader had scrolled up to read.
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
//// The page shows one strand at a time in this one transcript, and the reader
//// leaves a strand where they were reading it. The server draws the strand's
//// numeric key as `data-strand-key` on the element (a number the page assigned the
//// strand, so no model or peer text reaches an attribute). When the key changes
//// the element keeps the departing strand's place in memory under its key, for
//// the life of the element: the offset if the reader had scrolled up, or "at
//// the bottom". It then puts the arriving strand where it was left, or follows
//// the tail if it was left at the bottom or never seen. Nothing is stored
//// outside the element.
////
//// The element takes one attribute, `data-strand-key`, read as a whole
//// number; anything else is ignored. Its shadow root holds one default slot,
//// through which the server's lane is shown as the server rendered and
//// escaped it, and, while the reader is away from the bottom, one button
//// whose label is fixed here. It reads no text, handles no key, and
//// scrolls only itself. The approval cards and the composer are outside
//// it, in the dock, so neither its scrolling nor its size observation
//// touches them.

import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import lustre
import lustre/attribute
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_client/fold
import web_client/follow_rule.{
  type Extent, type Memory, type Reader, Detached, Displaced, Extent, Following,
  Leading, Reading, Restored, Waiting,
}
import web_client/internal/ffi_dom

/// The element's tag.
pub const name = "loom-follow"

/// A running watch on the transcript: the element that scrolls, and what is
/// listening to it, which `stop` ends together.
pub type Watching {
  Watching(
    /// The `<loom-follow>` element itself, which the stylesheet makes the
    /// scroll container.
    host: ffi_dom.Element,
    /// The passive `scroll` listener on `host`.
    scroll: ffi_dom.Listener,
    /// The passive listeners for the reader's own input, by event name.
    inputs: List(#(String, ffi_dom.Listener)),
    /// The observer of the size of `host` and of each of its children.
    sizes: ffi_dom.Observer,
    /// The observer of `host`'s children coming and going, which keeps
    /// `sizes` observing the current ones.
    children: ffi_dom.Observer,
    /// The listener on the document for the composer's send
    /// (`follow_rule.sent_event`), which is outside this element.
    sent: ffi_dom.Listener,
  )
}

/// The lane's first row, held while older rows load above it, and where its
/// top edge was in the viewport when it was last measured. Only the row's box
/// is read; nothing here reads its content.
pub type Anchor {
  Anchor(
    /// The scroller the row is in, which is scrolled to put the row back.
    host: ffi_dom.Element,
    /// The element the server draws the rows in, whose first child the row
    /// was when it was held.
    lane: ffi_dom.Element,
    /// The held row.
    row: ffi_dom.Element,
    /// The row's top edge in the viewport, in pixels, when last measured.
    top: Float,
  )
}

/// What the element knows: where the reader is, how far the bottom of the
/// transcript was from the bottom of its view when last measured, how far
/// the transcript was scrolled and how big it was when a scroll was last
/// heard, when the reader last touched it, its watch on the transcript while
/// it is on the page, and the row it holds in place while older rows are
/// loading above it.
pub type Model {
  Model(
    reader: Reader,
    watching: Option(Watching),
    anchor: Option(Anchor),
    key: Option(Int),
    memory: Memory,
  )
}

/// Everything the element can be told.
pub type Msg {
  /// The element was added to the page.
  Connected

  /// The element left the page.
  Disconnected

  /// The watch on the transcript's scrolling and size started, and the
  /// transcript was scrolled `top` pixels and `extent` big when it did.
  Watched(watching: Watching, top: Float, extent: Extent)

  /// The reader's wheel, finger, pointer or a key touched the transcript, at
  /// this time in milliseconds.
  Touched(at: Int)

  /// The transcript scrolled to `top` pixels while it was `extent` big, at
  /// this time in milliseconds.
  Scrolled(top: Float, extent: Extent, at: Int)

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

  /// The reader sent a message from the composer.
  Sent

  /// The lane's first row and where it is on screen, held while older rows
  /// load above it, or nothing when the page has no lane or the lane has no
  /// row.
  Held(anchor: Option(Anchor))

  /// The older rows arrived and the held row is back where it was, or the
  /// row left the page: nothing is held any more.
  Released

  /// The server drew the transcript of the strand with this numeric key.
  Keyed(key: Int)
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
    component.on_attribute_change(follow_rule.key_attribute, keyed),
  ])
  |> lustre.register(name)
}

// The strand key decoded totally: a whole number is a message, and anything
// else is none.
fn keyed(value: String) -> Result(Msg, Nil) {
  int.parse(value) |> result.map(Keyed)
}

fn init(_: Nil) -> #(Model, Effect(Msg)) {
  #(
    Model(
      reader: follow_rule.start(),
      watching: None,
      anchor: None,
      key: None,
      memory: follow_rule.forgotten(),
    ),
    effect.none(),
  )
}

/// Applies one message. The transcript is read and scrolled only inside
/// effects, so `update` stays a function of its messages.
///
/// ## Examples
///
/// ```gleam
/// // follow.update(model, follow.Scrolled(40.0, 0))
/// ```
pub fn update(model: Model, message: Msg) -> #(Model, Effect(Msg)) {
  case message {
    // Connecting starts one watch. Disconnecting stopped the one before, so
    // moving the element never runs two. The watch needs the element's
    // shadow root, which an effect is handed only once the element has
    // rendered.
    Connected -> #(model, effect.batch([stop(model.watching), start()]))
    Watched(watching:, top:, extent:) -> #(
      Model(
        ..model,
        reader: follow_rule.watched(model.reader, top, extent),
        watching: Some(watching),
      ),
      effect.none(),
    )
    Touched(at:) -> #(
      Model(..model, reader: follow_rule.touched(model.reader, at)),
      effect.none(),
    )
    Disconnected -> #(Model(..model, watching: None), stop(model.watching))

    // A scroll the element made itself lands at the bottom and moves down,
    // so only the reader's own scroll up changes the position. A scroll the
    // layout made, when the box grew or the content shrank, can move up too;
    // it has no touch before it and a size the last scroll did not see, so
    // it does not leave the tail, and the size change that caused it brings
    // `Resized`, which scrolls back down. A held row is measured again, so
    // the place kept for the reader is where they have scrolled to, not
    // where they pressed the button.
    Scrolled(top:, extent:, at:) -> #(
      Model(
        ..model,
        reader: follow_rule.scrolled(model.reader, top, extent, at),
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
      case model.reader.position, model.anchor {
        Following, _ -> #(
          Model(..model, anchor: None),
          to_bottom(model.watching),
        )
        Reading, Some(anchor) -> #(model, keep(model.watching, anchor))
        Reading, None -> #(model, measure(model.watching))
      }
    Measured(gap:) -> #(
      Model(..model, reader: follow_rule.measured(model.reader, gap)),
      effect.none(),
    )

    // The fold's event arrives in the turn of the fold's own update, a frame
    // before the render that resizes the lane, so that resize finds
    // `Reading`.
    Folded -> #(
      Model(..model, reader: follow_rule.folded(model.reader)),
      effect.none(),
    )

    // Pressing the button is the reader's own move, as opening a fold is,
    // so the rows that land do not carry the transcript to its end. The
    // click reaches the slot before the server has the press, and the rows
    // come back a round trip later, so the row is held before anything
    // moves.
    Paged -> #(
      Model(..model, reader: follow_rule.paged(model.reader)),
      hold(model.watching),
    )
    Held(anchor:) -> #(Model(..model, anchor:), effect.none())
    Released -> #(Model(..model, anchor: None), measure(model.watching))

    // The server drew another strand's transcript. Where the reader stood in
    // the strand they left is kept under its key, taken from the last scroll
    // heard, which is the position before the change; the strand shown now
    // gets the place it was left at, or the tail when it was left at the
    // bottom or never seen. A held row belongs to the old rows and is let go.
    Keyed(key:) ->
      case follow_rule.keyed(model.key, model.memory, model.reader, key) {
        follow_rule.Unchanged -> #(model, effect.none())
        follow_rule.Changed(key:, memory:, reader:, arrival:) -> #(
          Model(..model, reader:, anchor: None, key: Some(key), memory:),
          arrive(model.watching, arrival),
        )
      }

    // The button is the way back to the tail without a scroll: it follows
    // again from here, and nothing stays held.
    Jumped -> #(
      Model(..model, reader: follow_rule.jumped(model.reader), anchor: None),
      to_bottom(model.watching),
    )

    // A send is the same request made from the composer. The reader's own
    // message lands below the fold of a lane they had scrolled up in, and
    // the answer after it, so the transcript follows the tail again from the
    // press, and the rows that land scroll it down as they do any follower.
    Sent -> #(
      Model(..model, reader: follow_rule.jumped(model.reader), anchor: None),
      to_bottom(model.watching),
    )
  }
}

// How big the scroller and its content are now.
fn extent_of(host: ffi_dom.Element) -> Extent {
  Extent(
    content: ffi_dom.scroll_height(host),
    view: ffi_dom.client_height(host),
  )
}

// The gap now, read from the scroller.
fn gap_of(host: ffi_dom.Element) -> Int {
  let extent = extent_of(host)
  follow_rule.gap(extent.content, ffi_dom.scroll_top(host), extent.view)
}

// The events that are the reader's hand on the transcript: the wheel, a
// finger, a pointer press, which includes a press on the scrollbar, and a key
// pressed inside it. Each is heard passively and only noted: the handler
// reads nothing from the event, so it can neither act on a key nor cancel
// one. The browser never waits on this element to scroll.
const reader_input = [
  "wheel",
  "touchstart",
  "touchmove",
  "pointerdown",
  "keydown",
]

// Starts watching. The scroller is the `<loom-follow>` element itself, whose
// shadow root the effect is handed: the stylesheet gives it a fixed share of
// the viewport and lets its content scroll inside it, so the header, the
// agent strip and the dock never move with the transcript.
//
// Every scroll reports where it ended and how big the transcript was. Every
// touch of the reader's reports when. Every change in the size of the
// scroller or of its content reports growth. The content is the scroller's
// children (the line above the oldest row and the lane), not the scroller:
// its own box has a fixed height, so it does not change when a row lands. The
// children are observed as they are added, since the scroller can be
// connected before the server's rows are in it.
fn start() -> Effect(Msg) {
  use dispatch, root <- effect.after_paint
  let host = ffi_dom.host(ffi_dom.as_element(root))
  let scroll =
    ffi_dom.add_passive_listener(host, "scroll", fn() {
      dispatch(Scrolled(
        top: ffi_dom.scroll_top(host),
        extent: extent_of(host),
        at: ffi_dom.now(),
      ))
    })
  let inputs =
    list.map(reader_input, fn(event) {
      let listener =
        ffi_dom.add_passive_listener(host, event, fn() {
          dispatch(Touched(at: ffi_dom.now()))
        })
      #(event, listener)
    })
  let sent =
    ffi_dom.add_listener(ffi_dom.get_document(), follow_rule.sent_event, fn(_) {
      dispatch(Sent)
    })
  let sizes = ffi_dom.resize_observer(fn() { dispatch(Resized) })
  ffi_dom.observe(sizes, host)
  observe_children(sizes, host)
  let children =
    ffi_dom.mutation_observer(fn() { observe_children(sizes, host) })
  ffi_dom.observe_child_list(children, host)

  dispatch(Watched(
    Watching(host:, scroll:, inputs:, sizes:, children:, sent:),
    top: ffi_dom.scroll_top(host),
    extent: extent_of(host),
  ))
}

fn observe_children(sizes: ffi_dom.Observer, host: ffi_dom.Element) -> Nil {
  list.each(ffi_dom.children(host), ffi_dom.observe(sizes, _))
}

fn stop(watching: Option(Watching)) -> Effect(Msg) {
  case watching {
    None -> effect.none()
    Some(watching) -> {
      use _ <- effect.from
      ffi_dom.remove_listener(watching.host, "scroll", watching.scroll)
      list.each(watching.inputs, fn(input) {
        ffi_dom.remove_listener(watching.host, input.0, input.1)
      })
      ffi_dom.remove_listener(
        ffi_dom.get_document(),
        follow_rule.sent_event,
        watching.sent,
      )
      ffi_dom.disconnect(watching.sizes)
      ffi_dom.disconnect(watching.children)
    }
  }
}

// Scrolls the transcript to its bottom at once. It is never animated: a
// smooth scroll reports its intermediate positions, and each would be a move
// for `<loom-follow>` to read as the reader leaving the tail.
fn to_bottom(watching: Option(Watching)) -> Effect(Msg) {
  case watching {
    None -> effect.none()
    Some(Watching(host:, ..)) -> {
      use _ <- effect.from
      ffi_dom.set_scroll_top(host, ffi_dom.scroll_height(host))
    }
  }
}

// Applies an arrival once the new rows are painted: to the bottom, or back to
// the offset the reader left the strand at. The browser clamps an offset
// past the end of the content.
fn arrive(
  watching: Option(Watching),
  arrival: follow_rule.Arrival,
) -> Effect(Msg) {
  case watching {
    None -> effect.none()
    Some(Watching(host:, ..)) -> {
      use dispatch, _ <- effect.after_paint
      case arrival {
        follow_rule.Tail ->
          ffi_dom.set_scroll_top(host, ffi_dom.scroll_height(host))
        follow_rule.Resume(top:) -> ffi_dom.set_scroll_top(host, top)
      }

      // The browser clamps an offset past the end of the content, and a
      // clamp that leaves the offset where it was raises no scroll event, so
      // the position and the gap are read again for the button's state.
      dispatch(Scrolled(
        top: ffi_dom.scroll_top(host),
        extent: extent_of(host),
        at: ffi_dom.now(),
      ))
    }
  }
}

fn measure(watching: Option(Watching)) -> Effect(Msg) {
  case watching {
    None -> effect.none()
    Some(Watching(host:, ..)) -> {
      use dispatch <- effect.from
      dispatch(Measured(gap_of(host)))
    }
  }
}

// Holds the first row of the lane inside the watched scroller, and the
// viewport position of its top edge. The lane is the element's `.lane`
// child; nothing here reads a row's content.
fn hold(watching: Option(Watching)) -> Effect(Msg) {
  case watching {
    None -> effect.none()
    Some(Watching(host:, ..)) -> {
      use dispatch <- effect.from
      let anchor = {
        use lane <- result.try(ffi_dom.query_selector(host, ".lane"))
        use row <- result.map(ffi_dom.first_element_child(lane))
        Anchor(host:, lane:, row:, top: ffi_dom.bounding_top(row))
      }
      dispatch(Held(option.from_result(anchor)))
    }
  }
}

// The same row, measured again after the reader scrolled.
fn remeasure(anchor: Option(Anchor)) -> Effect(Msg) {
  case anchor {
    None -> effect.none()
    Some(anchor) -> {
      use dispatch <- effect.from
      let top = ffi_dom.bounding_top(anchor.row)
      dispatch(Held(Some(Anchor(..anchor, top:))))
    }
  }
}

// Whether the held row is still the lane's first child.
fn leads(anchor: Anchor) -> Bool {
  ffi_dom.first_element_child(anchor.lane)
  |> result.map(ffi_dom.same(_, anchor.row))
  |> result.unwrap(or: False)
}

// Where the held row stands on the page now.
fn standing(anchor: Anchor) -> follow_rule.Standing {
  case ffi_dom.is_connected(anchor.row), leads(anchor) {
    False, _ -> Detached
    True, True -> Leading
    True, False -> Displaced(top: ffi_dom.bounding_top(anchor.row))
  }
}

// Puts a held row back if older rows have landed above it, and measures
// the gap either way, so a reader who is held while more rows arrive below
// still sees the button. The stylesheet turns the browser's own scroll
// anchoring off for the scroller, so this is the one place the reader's
// place is kept.
fn keep(watching: Option(Watching), anchor: Anchor) -> Effect(Msg) {
  use dispatch <- effect.from
  case follow_rule.keeping(standing(anchor), anchor.top) {
    Waiting -> Nil
    Restored(by:) -> {
      case by == 0.0 {
        True -> Nil
        False -> ffi_dom.scroll_by(anchor.host, by)
      }
      dispatch(Released)
    }
  }

  case watching {
    None -> Nil
    Some(Watching(host:, ..)) -> dispatch(Measured(gap_of(host)))
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

  case follow_rule.jump(model.reader.position, model.reader.gap) {
    follow_rule.Offered ->
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
    follow_rule.Withheld -> slot
  }
}
