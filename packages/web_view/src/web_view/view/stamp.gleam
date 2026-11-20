//// A time of day on the page, drawn in the browser's zone.
////
//// The records give an instant (Unix milliseconds) and the server cannot know
//// where the reader is, so a time on the live page is a `<loom-time at>`
//// (`web_client/time`): the browser words the instant in its own zone as
//// `13:40`. The element's light text is the instant's UTC time, which shows
//// until the browser has drawn the local one and whenever the script is not
//// running, so no row is ever drawn with an empty gutter. The `title` carries
//// the same UTC time, so a reader can compare the two.
////
//// Both the transcript's gutter (`view/lane`) and the rail's card headers
//// (`view/lifted`) draw a time, and they draw it here, so the same instant
//// reads the same in both. The instant is a number the daemon wrote and the
//// words are digits, so nothing reaches an attribute from session text.
////
//// ## Flow
////
//// `time` draws the element, `utc` words the fallback it carries, and `pad`
//// gives each part of that fallback its two digits.

import gleam/int
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

/// The instant as a `<loom-time>` of the given class, with the UTC time of day
/// as its light text and its title.
///
/// ## Examples
///
/// ```gleam
/// // stamp.time(1_790_030_460_000, "tl-time")
/// ```
pub fn time(at: Int, class: String) -> Element(message) {
  let words = utc(at)

  element.element(
    "loom-time",
    [
      attribute.class(class),
      attribute.attribute("at", int.to_string(at)),
      attribute.title(words <> " UTC"),
    ],
    [html.text(words)],
  )
}

/// The instant as a `<loom-time>` with no class: what a sentence's time and a
/// quote's source use. The words and attributes are `time`'s.
///
/// ## Examples
///
/// ```gleam
/// // stamp.plain(1_790_030_460_000)
/// ```
pub fn plain(at: Int) -> Element(message) {
  let words = utc(at)

  element.element(
    "loom-time",
    [
      attribute.attribute("at", int.to_string(at)),
      attribute.title(words <> " UTC"),
    ],
    [html.text(words)],
  )
}

/// An instant as the UTC time of day, `14:20`. An instant before the epoch is
/// the epoch, so a bad value reads `00:00` and never a sign in the digits.
///
/// ## Examples
///
/// ```gleam
/// assert stamp.utc(1_790_030_460_000) == "22:41"
/// assert stamp.utc(-5) == "00:00"
/// ```
pub fn utc(at: Int) -> String {
  let minutes = int.max(at, 0) / 60_000
  let hours = minutes / 60 % 24

  pad(hours) <> ":" <> pad(minutes % 60)
}

/// A number of at most two digits, with a leading zero.
fn pad(value: Int) -> String {
  case value < 10 {
    True -> "0" <> int.to_string(value)
    False -> int.to_string(value)
  }
}
