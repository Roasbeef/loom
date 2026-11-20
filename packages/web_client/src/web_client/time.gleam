//// `<loom-time at="1790030460000">`: an instant, drawn as the time of day in
//// the browser's own zone.
////
//// The admin page's refusal of a fourth grant in an hour says when the next is
//// free. The daemon knows the instant and the server cannot know where the
//// person is, so the server writes the instant as an attribute and this element
//// draws it as `13:02` in the zone the browser reports (`web_client/time_rule`),
//// which is what the owner's clock reads. The server also writes the instant's
//// UTC time as the element's light text and its `title`. The light text is
//// projected through the default slot until the element has drawn a time, and
//// whenever `at` does not parse, so a page never shows an empty gap; the title
//// lets a person compare the two.
////
//// A second attribute, `now`, makes the element a clock: whatever its `at`
//// says, it draws the browser's current time of day and redraws it every ten
//// seconds while it is on the page (`time_rule.current`). The rail's first line
//// uses it, because a session's page hears from the daemon only when something
//// happens, and an instant the server wrote when the page opened would read an
//// hour late by the time anyone looked. `at` stays as the first reading, so the
//// light text and the first draw agree with the server until the browser's own
//// clock takes over.
////
//// The attribute is an instant and not a duration, so a browser whose clock
//// disagrees with the daemon's still shows the daemon's instant correctly in
//// its zone. The element draws one text node in its own shadow root, from a
//// number the daemon wrote, never session text. It handles no key, takes no
//// focus and sends the server nothing.

import gleam/option.{type Option, None, Some}
import lustre
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import web_client/internal/ffi_dom
import web_client/time_rule

/// The element's tag.
pub const name = "loom-time"

/// What the element knows: the clock time it last drew, and the timer that
/// keeps it current while the server has asked it to be a clock.
pub type Model {
  Model(clock: Option(String), timer: Option(ffi_dom.Timer))
}

/// Everything the element can be told.
pub type Msg {
  /// The server wrote an instant.
  Instanted(milliseconds: Int)

  /// The server set `now`: the element is a clock.
  Following

  /// The element left the page.
  Disconnected

  /// The timer started.
  Started(timer: ffi_dom.Timer)

  /// Ten seconds passed, and this is the browser's clock.
  Ticked(now: Int)

  /// The browser answered with the clock time of the instant in its zone.
  Drawn(clock: String)
}

/// Registers the element with the browser.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = time.register()
/// ```
pub fn register() -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [
    component.on_attribute_change("at", instanted),
    component.on_attribute_change("now", following),
    component.on_disconnect(Disconnected),
  ])
  |> lustre.register(name)
}

// An `at` that is not a whole number is ignored, which leaves the element
// showing what it showed; the server only ever writes digits.
fn instanted(value: String) -> Result(Msg, Nil) {
  case time_rule.instant(value) {
    Ok(milliseconds) -> Ok(Instanted(milliseconds))
    Error(Nil) -> Error(Nil)
  }
}

// The attribute's presence is the request, whatever its value: the server
// writes `now=""`.
fn following(_value: String) -> Result(Msg, Nil) {
  Ok(Following)
}

fn init(_: Nil) -> #(Model, Effect(Msg)) {
  #(Model(clock: None, timer: None), effect.none())
}

/// Applies one message. The zone and the clock are read only inside effects, so
/// `update` is a function of its messages.
///
/// ## Examples
///
/// ```gleam
/// assert time.update(time.Model(None, None), time.Drawn("13:02")).0
///   == time.Model(Some("13:02"), None)
/// ```
pub fn update(model: Model, message: Msg) -> #(Model, Effect(Msg)) {
  case message {
    Instanted(milliseconds:) -> #(model, localise(milliseconds))
    Drawn(clock:) -> #(Model(..model, clock: Some(clock)), effect.none())

    // A clock reads the browser's time at once, and then every tick. A timer
    // left from an earlier `now` is stopped first, so the element never runs
    // two.
    Following -> #(model, effect.batch([stop(model.timer), start(), read()]))
    Started(timer:) -> #(Model(..model, timer: Some(timer)), effect.none())
    Disconnected -> #(Model(..model, timer: None), stop(model.timer))
    Ticked(now:) -> #(model, localise(time_rule.current(now)))
  }
}

fn read() -> Effect(Msg) {
  use dispatch <- effect.from
  dispatch(Ticked(ffi_dom.now()))
}

fn start() -> Effect(Msg) {
  use dispatch <- effect.from
  let timer =
    ffi_dom.set_interval(10_000, fn() { dispatch(Ticked(ffi_dom.now())) })
  dispatch(Started(timer))
}

/// Clears the interval when the element holds one, so a clock that is asked to
/// follow again, or that leaves the page, never leaves a timer running that
/// would draw into a dead element.
fn stop(timer: Option(ffi_dom.Timer)) -> Effect(Msg) {
  // A clock that was never started has nothing to clear.
  case timer {
    None -> effect.none()
    Some(timer) -> {
      use _ <- effect.from
      ffi_dom.clear_interval(timer)
    }
  }
}

/// Emits a local clock string adjusted for browser timezone offset.
fn localise(milliseconds: Int) -> Effect(Msg) {
  use dispatch <- effect.from
  dispatch(
    Drawn(time_rule.clock(
      milliseconds,
      ffi_dom.timezone_offset_minutes(milliseconds),
    )),
  )
}

fn view(model: Model) -> Element(Msg) {
  case model.clock {
    Some(clock) -> html.text(clock)
    None -> component.default_slot([], [])
  }
}
