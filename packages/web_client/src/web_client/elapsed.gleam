//// `<loom-elapsed since="1700000000000">`: how long ago `since` was,
//// counted in the browser once a second.
////
//// The server component draws each agent chip, and a chip's elapsed time is
//// the one figure on it that changes with nothing but the clock. Counting
//// it here means the server never renders the page again only to move a
//// second, which an idle page would otherwise pay four times a second and
//// an event-driven server would have no event for. The server sets `since`
//// once per operation, to the daemon's own record of when the operation
//// started (`agent_roster.started_at`), so the attribute does not change
//// while the operation runs.
////
//// The element renders only what its one attribute says: a number the
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
import web_client/internal/ffi_clock

/// The element's tag.
pub const name = "loom-elapsed"

/// What the element knows: when its operation started, the browser's clock
/// at the last tick, and its timer while it is on the page.
pub type Model {
  Model(since: Option(Int), now: Int, timer: Option(ffi_clock.Timer))
}

/// Everything the element can be told.
pub type Msg {
  /// The server set `since` to this Unix millisecond instant.
  SinceChanged(since: Int)

  /// The element was added to the page.
  Connected

  /// The element left the page.
  Disconnected

  /// The timer started.
  Started(timer: ffi_clock.Timer)

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
    component.on_attribute_change("since", since),
    component.on_connect(Connected),
    component.on_disconnect(Disconnected),
  ])
  |> lustre.register(name)
}

// A `since` that is not a whole number is ignored, which leaves the element
// showing what it showed; the server only ever writes digits.
fn since(value: String) -> Result(Msg, Nil) {
  value
  |> string.trim
  |> int.parse
  |> result.map(SinceChanged)
}

fn init(_: Nil) -> #(Model, Effect(Msg)) {
  #(Model(since: None, now: 0, timer: None), effect.none())
}

/// Applies one message. The clock is read only inside effects, so `update`
/// stays a function of its messages.
///
/// ## Examples
///
/// ```gleam
/// // elapsed.update(model, elapsed.Ticked(1_700_000_004_000))
/// ```
pub fn update(model: Model, message: Msg) -> #(Model, Effect(Msg)) {
  case message {
    SinceChanged(since:) -> #(Model(..model, since: Some(since)), read_clock())

    // Connecting starts one timer; a timer left from an earlier connection
    // is stopped first, so moving the element never runs two.
    Connected -> #(model, effect.batch([stop(model.timer), start()]))
    Started(timer:) -> #(Model(..model, timer: Some(timer)), read_clock())
    Disconnected -> #(Model(..model, timer: None), stop(model.timer))
    Ticked(now:) -> #(Model(..model, now:), effect.none())
  }
}

fn read_clock() -> Effect(Msg) {
  use dispatch <- effect.from
  dispatch(Ticked(ffi_clock.now()))
}

fn start() -> Effect(Msg) {
  use dispatch <- effect.from
  let timer = ffi_clock.every(1000, fn() { dispatch(Ticked(ffi_clock.now())) })
  dispatch(Started(timer))
}

fn stop(timer: Option(ffi_clock.Timer)) -> Effect(Msg) {
  case timer {
    None -> effect.none()
    Some(timer) -> {
      use _ <- effect.from
      ffi_clock.cancel(timer)
    }
  }
}

fn view(model: Model) -> Element(Msg) {
  case model.since {
    Some(since) if model.now > 0 ->
      html.text(duration(int.max(0, model.now - since) / 1000))
    Some(_) | None -> element.none()
  }
}

/// An elapsed duration the way the terminal's strip shows one
/// (`session_view/agent_roster.duration`): seconds under a minute, minutes
/// and padded seconds under an hour, then hours and padded minutes.
///
/// ## Examples
///
/// ```gleam
/// assert elapsed.duration(475) == "7m 55s"
/// ```
pub fn duration(seconds: Int) -> String {
  case seconds >= 3600, seconds >= 60 {
    True, _ ->
      int.to_string(seconds / 3600)
      <> "h "
      <> pad2({ seconds % 3600 } / 60)
      <> "m"
    False, True ->
      int.to_string(seconds / 60) <> "m " <> pad2(seconds % 60) <> "s"
    False, False -> int.to_string(int.max(0, seconds)) <> "s"
  }
}

fn pad2(value: Int) -> String {
  string.pad_start(int.to_string(value), to: 2, with: "0")
}
