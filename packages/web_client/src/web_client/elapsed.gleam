//// `<loom-elapsed offset="4500">`: an operation that had run `offset`
//// milliseconds when the attribute arrived, counted on from there in the
//// browser once a second.
////
//// The server component draws each agent chip, and a chip's elapsed time is
//// the one figure on it that changes with nothing but the clock. Counting
//// it here means the server never renders the page again only to move a
//// second, which an idle page would otherwise pay four times a second and
//// an event-driven server would have no event for.
////
//// The attribute is a duration, not an instant. The server measured it on
//// the daemon host's clock (`agent_roster.running_ms`), and the element
//// anchors it to the browser's clock the moment it arrives, so the count is
//// `offset + (now - anchor)` with each subtraction on one clock. A browser
//// whose clock disagrees with the daemon's by a minute still counts right,
//// which subtracting a daemon instant from `Date.now()` would not. Each
//// rebuilt strip brings a fresh reading, and a changed attribute
//// re-anchors.
////
//// A second attribute, `remaining`, reverses the count: it is the milliseconds
//// a page has left, anchored on arrival in the same way, and the element draws
//// `duration.remaining` of what is left, down to `0s`. The admin page's pill
//// uses it for the fifteen minutes the page lives. Whichever attribute arrived
//// last sets the direction.
////
//// A third attribute, `since`, is the Unix time in milliseconds at which
//// something started, for a thing whose start the records give and whose age
//// the server has no clock to measure: a tool call still running. The element
//// reads the browser's clock once, takes the difference as an elapsed reading
//// (`duration.since_offset`) and counts on from it as `offset` does. This trusts the
//// browser's clock to agree with the daemon's, so a browser whose clock is
//// wrong shows a wrong age; it never shows a negative one.
////
//// The element renders only what its attributes say: a number the
//// daemon wrote, never session text. It draws a text node in its own shadow
//// root, handles no key and takes no focus.

import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import web_client/duration
import web_client/internal/ffi_dom

/// The element's tag.
pub const name = "loom-elapsed"

/// What the element knows: the server's reading and the browser's clock
/// when it arrived, the browser's clock at the last tick, and its timer
/// while it is on the page.
pub type Model {
  Model(reading: Option(Reading), now: Int, timer: Option(ffi_dom.Timer))
}

/// Which way a reading counts.
pub type Direction {
  /// The reading is how long something has run, and grows.
  Up

  /// The reading is how long something has left, and shrinks.
  Down
}

/// One reading from the server, anchored to the browser's clock.
pub type Reading {
  Reading(
    /// How long the operation had run, or has left, in milliseconds, by the
    /// server.
    offset: Int,
    /// The browser's clock when the reading arrived.
    anchor: Int,
    /// Whether `offset` is elapsed time or time left.
    direction: Direction,
  )
}

/// Everything the element can be told.
pub type Msg {
  /// The server set `offset` to this many milliseconds.
  OffsetChanged(offset: Int)

  /// The server set `remaining` to this many milliseconds.
  RemainingChanged(remaining: Int)

  /// The server set `since` to this Unix time in milliseconds.
  SinceChanged(since: Int)

  /// The reading arrived, anchored to the browser's clock.
  Anchored(reading: Reading)

  /// The element was added to the page.
  Connected

  /// The element left the page.
  Disconnected

  /// The timer started.
  Started(timer: ffi_dom.Timer)

  /// A second passed, and this is the browser's clock.
  Ticked(now: Int)
}

/// Registers the element with the browser.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = elapsed.register()
/// ```
pub fn register() -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [
    component.on_attribute_change("offset", offset),
    component.on_attribute_change("remaining", remaining),
    component.on_attribute_change("since", since),
    component.on_connect(Connected),
    component.on_disconnect(Disconnected),
  ])
  |> lustre.register(name)
}

// An `offset` that is not a whole number is ignored, which leaves the
// element showing what it showed; the server only ever writes digits.
fn offset(value: String) -> Result(Msg, Nil) {
  value
  |> string.trim
  |> int.parse
  |> result.map(OffsetChanged)
}

// A `remaining` that is not a whole number is ignored, as `offset` is.
fn remaining(value: String) -> Result(Msg, Nil) {
  value
  |> string.trim
  |> int.parse
  |> result.map(RemainingChanged)
}

// A `since` that is not a whole number is ignored, as `offset` is.
fn since(value: String) -> Result(Msg, Nil) {
  value
  |> string.trim
  |> int.parse
  |> result.map(SinceChanged)
}

fn init(_: Nil) -> #(Model, Effect(Msg)) {
  #(Model(reading: None, now: 0, timer: None), effect.none())
}

/// Applies one message. The clock is read only inside effects, so `update`
/// stays a function of its messages.
///
/// ## Examples
///
/// ```gleam
/// // elapsed.update(model, elapsed.OffsetChanged(4500))
/// ```
pub fn update(model: Model, message: Msg) -> #(Model, Effect(Msg)) {
  case message {
    // The reading is anchored inside an effect, where the clock is read,
    // and the anchor doubles as the clock's latest reading.
    OffsetChanged(offset:) -> #(model, anchor(offset, Up))
    RemainingChanged(remaining:) -> #(model, anchor(remaining, Down))
    SinceChanged(since:) -> #(model, anchor_since(since))
    Anchored(reading:) -> #(
      Model(..model, reading: Some(reading), now: reading.anchor),
      effect.none(),
    )

    // Connecting starts one timer; a timer left from an earlier connection
    // is stopped first, so moving the element never runs two.
    Connected -> #(model, effect.batch([stop(model.timer), start()]))
    Started(timer:) -> #(Model(..model, timer: Some(timer)), read_clock())
    Disconnected -> #(Model(..model, timer: None), stop(model.timer))
    Ticked(now:) -> #(Model(..model, now:), effect.none())
  }
}

fn anchor(offset: Int, direction: Direction) -> Effect(Msg) {
  use dispatch <- effect.from
  dispatch(Anchored(Reading(offset:, anchor: ffi_dom.now(), direction:)))
}

fn anchor_since(since: Int) -> Effect(Msg) {
  use dispatch <- effect.from
  let now = ffi_dom.now()
  dispatch(
    Anchored(Reading(
      offset: duration.since_offset(now:, since:),
      anchor: now,
      direction: Up,
    )),
  )
}

fn read_clock() -> Effect(Msg) {
  use dispatch <- effect.from
  dispatch(Ticked(ffi_dom.now()))
}

fn start() -> Effect(Msg) {
  use dispatch <- effect.from
  let timer =
    ffi_dom.set_interval(1000, fn() { dispatch(Ticked(ffi_dom.now())) })
  dispatch(Started(timer))
}

fn stop(timer: Option(ffi_dom.Timer)) -> Effect(Msg) {
  case timer {
    None -> effect.none()
    Some(timer) -> {
      use _ <- effect.from
      ffi_dom.clear_interval(timer)
    }
  }
}

fn view(model: Model) -> Element(Msg) {
  case model.reading {
    Some(reading) -> {
      let passed = model.now - reading.anchor
      case reading.direction {
        Up ->
          html.text(duration.format(int.max(0, reading.offset + passed) / 1000))
        Down ->
          html.text(duration.remaining(
            int.max(0, reading.offset - passed) / 1000,
          ))
      }
    }
    None -> element.none()
  }
}
