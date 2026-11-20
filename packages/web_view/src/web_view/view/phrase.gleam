//// Draws a sentence that holds instants (`web_view/thread_words.Phrase`) and a
//// lone instant, as the browser's own time of day.
////
//// The server holds an instant in Unix milliseconds and cannot know the zone of
//// the person reading, so it writes the instant as the `at` attribute of a
//// `<loom-time>` and the browser draws the clock time (`web_client/time`). The
//// element's light text and its title are the instant's UTC time, which show
//// until the browser has drawn the local one and for a browser that has not
//// registered the element, so a page never shows an empty gap. The words around
//// an instant are a text node each. No attribute carries a word.
////
//// ## Flow
////
//// `view` → `part` → `clock`
////
//// 1. `view` draws each part of a phrase in order.
//// 2. `part` draws words as a text node and an instant with `clock`.
//// 3. `clock` draws one instant, which the eyebrow and the quotes' sources use
////    on their own.

import gleam/int
import gleam/list
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import web_view/thread_words.{type Part, type Phrase}

/// A phrase as nodes, in order.
///
/// ## Examples
///
/// ```gleam
/// // phrase.view([thread_words.Words("Failed at "), thread_words.Clock(0)])
/// ```
pub fn view(phrase: Phrase) -> List(Element(message)) {
  list.map(phrase, part)
}

/// One part: words as text, an instant as a clock.
fn part(each: Part) -> Element(message) {
  case each {
    thread_words.Words(words) -> html.text(words)
    thread_words.Clock(at) -> clock(at)
  }
}

/// An instant as a `<loom-time>`: the time of day in the browser's zone, with
/// the instant's UTC time as its light text and title.
///
/// ## Examples
///
/// ```gleam
/// // phrase.clock(1_790_030_460_000)
/// ```
pub fn clock(at: Int) -> Element(message) {
  let utc = utc_clock(at)

  element.element(
    "loom-time",
    [
      attribute.attribute("at", int.to_string(at)),
      attribute.title(utc <> " UTC"),
    ],
    [html.text(utc)],
  )
}

/// The UTC time of day of an instant as `HH:MM`.
fn utc_clock(at: Int) -> String {
  let minutes = int.max(at, 0) / 60_000

  two({ minutes / 60 } % 24) <> ":" <> two(minutes % 60)
}

/// A number as two digits.
fn two(value: Int) -> String {
  string.pad_start(int.to_string(value), 2, "0")
}
