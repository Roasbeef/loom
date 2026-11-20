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

import gleam/list
import lustre/element.{type Element}
import lustre/element/html
import web_view/thread_words.{type Part, type Phrase}
import web_view/view/stamp

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
  stamp.plain(at)
}
