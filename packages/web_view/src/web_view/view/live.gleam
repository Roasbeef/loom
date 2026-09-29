//// The live region: the rows of a response the provider is still writing,
//// drawn at the end of the lane until the daemon commits the answer.
////
//// A capture draws only records the daemon has committed. Between a request
//// going out and its answer committing, the session is silent on the page
//// for as long as the model takes, which is the longest wait a reader has.
//// This region fills it with the two things the terminal draws for that
//// interval: a reasoning row that says how much has arrived and how long the
//// generation has run, with the summarizer's headline beneath it when one
//// has been pushed (protocol 050), and the answer as it grows.
////
//// The rows are `component.live`'s, taken from the shared record's streams,
//// and this module only draws them. It decides nothing about the session.
////
//// Three properties keep the region cheap and quiet:
////
//// - **Only this region changes.** A fragment changes the streams and
////   nothing a capture projects, so the committed rows above are not
////   rebuilt and their memos hold (`view/lane`). Lustre's diff of the
////   region is the tail of the answer and the reasoning row's counter.
//// - **The clock is the browser's.** The elapsed time is a `<loom-elapsed>`
////   (`packages/web_client`), the element the agent strip's chips use, so
////   the server does not render again to move a second.
//// - **It is not announced.** The lane is a polite live region, and an
////   answer that changed on every batch would be read out as it grew. The
////   region opts out with `aria-live="off"`; the committed row that replaces
////   it, a single addition to the lane, is announced once.
////
//// Every string here is session text drawn as a text node: the progress
//// words are the engine's, the headline was written by a summarizer and the
//// answer goes through `draw`, which is the lane's own drawing of an
//// assistant line, Markdown parsed into text nodes.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import session_view/transcript_line.{type Line}

/// One row of the live region.
pub type Row {
  /// A reasoning block still streaming. Its text is never drawn: the
  /// opening words of a block that is still growing are rewritten under the
  /// reader as fragments land, and a counter that climbs is easier to ignore
  /// than that.
  Thinking(
    /// How much has arrived, in the engine's words: `12 lines`.
    progress: String,
    /// How long the generation had run, in milliseconds, when the row was
    /// built, on the daemon host's clock; `None` before the clock started.
    /// The browser counts on from it.
    elapsed_ms: Option(Int),
    /// The summarizer's headline for the block so far, when one has been
    /// pushed.
    headline: Option(String),
  )

  /// The answer so far, as the transcript's line for an assistant answer.
  Answer(line: Line)
}

/// The region's rows in the order the provider sent them, in one block.
/// `draw` draws an answer's line, so the lane's Markdown drawing is used
/// rather than a second one.
///
/// ## Examples
///
/// ```gleam
/// // live.view([live.Thinking("2 lines", Some(4500), None)], draw)
/// ```
pub fn view(
  rows: List(Row),
  draw: fn(Line) -> Element(message),
) -> Element(message) {
  html.div(
    [
      attribute.class("block"),
      attribute.class("live"),
      attribute.attribute("aria-live", "off"),
      attribute.attribute("aria-busy", "true"),
    ],
    list.map(rows, row(_, draw)),
  )
}

fn row(row: Row, draw: fn(Line) -> Element(message)) -> Element(message) {
  case row {
    Answer(line:) -> draw(line)

    // Without a headline the row is the digest the terminal shows,
    // `12 lines · 1m 04s so far`. With one it is the header of the
    // summarized row, the same count and clock, and the headline beneath it.
    Thinking(progress:, elapsed_ms:, headline: None) ->
      html.pre([attribute.class("line"), attribute.class("reasoning-digest")], [
        html.text(progress),
        ..elapsed(elapsed_ms, [html.text(" so far")])
      ])
    Thinking(progress:, elapsed_ms:, headline: Some(headline)) ->
      html.pre(
        [attribute.class("line"), attribute.class("summarized-reasoning")],
        [
          html.text(progress),
          ..elapsed(elapsed_ms, [html.text("\n" <> headline)])
        ],
      )
  }
}

// The clock after a row's count, then `rest`. The browser counts it from the
// reading (`<loom-elapsed offset>`, in milliseconds), so a reading is drawn
// only once the generation clock has started.
fn elapsed(
  elapsed_ms: Option(Int),
  rest: List(Element(message)),
) -> List(Element(message)) {
  case elapsed_ms {
    None -> rest
    Some(ms) -> [
      html.text(" · "),
      element.element(
        "loom-elapsed",
        [
          attribute.class("elapsed"),
          attribute.attribute("offset", int.to_string(ms)),
        ],
        [],
      ),
      ..rest
    ]
  }
}
