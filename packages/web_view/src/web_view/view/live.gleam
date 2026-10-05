//// The live region: the rows of a response the provider is still writing,
//// drawn at the end of the lane until the daemon commits the answer.
////
//// A capture draws only records the daemon has committed. Between a request
//// going out and its answer committing, the session is silent on the page
//// for as long as the model takes, which is the longest wait a reader has.
//// This region fills it with the two things the terminal draws for that
//// interval: a reasoning row that says the model is reasoning and for how
//// long, `Reasoning · 7s`, with the summarizer's headline beneath it when one
//// has been pushed (protocol 050), and the answer as it grows. A turn that has
//// opened and streamed nothing yet draws `Thinking · 0:03` in the reasoning
//// row's place, so a model that sends no reasoning text still shows progress. The lane gives
//// the region a timeline dot of its own and pulses it while the region exists.
//// After them come the inputs the daemon holds for the strand, as the
//// terminal draws them: a steer waiting for the generation's next boundary
//// and the prompts queued behind the turn, each a quiet row of the person's
//// own words with the engine's words for how it will run beneath, so a
//// message that was taken but not yet run is on the page from the capture
//// that first lists it until the one that no longer does.
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
    /// How much has arrived, in the engine's words: `12 lines`. The row keeps
    /// it as its title and does not say it.
    progress: String,
    /// How long the generation had run, in milliseconds, when the row was
    /// built, on the daemon host's clock; `None` before the clock started.
    /// The browser counts on from it.
    elapsed_ms: Option(Int),
    /// The summarizer's headline for the block so far, when one has been
    /// pushed.
    headline: Option(String),
  )

  /// A turn that has opened and has streamed nothing yet: the request is out
  /// and the model has said nothing, which is every wait a model that streams
  /// no reasoning text makes. It is drawn as `Thinking · 0:03` so the lane is
  /// not silent, and a streamed row replaces it.
  Opened(
    /// How long the generation had run, as in `Thinking`. `None` until the
    /// generation clock starts, and then the row says `Thinking` alone; no
    /// other clock stands in for it.
    elapsed_ms: Option(Int),
  )

  /// The answer so far, as the transcript's line for an assistant answer.
  Answer(line: Line)

  /// An input the daemon holds for the strand (`snapshot_view.PendingInput`):
  /// a steer not yet folded in, or a prompt queued behind the turn.
  Held(
    /// The daemon's excerpt of the person's own words.
    text: String,
    /// How it will run, in the engine's words (`transcript_lines.held_words`).
    words: String,
  )
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

    // The person's words and, beneath them, how the daemon will run them.
    // Both are text nodes: the words are the daemon's excerpt of a message
    // a person typed, and the mark is the engine's fixed phrase.
    Held(text:, words:) ->
      html.div([attribute.class("held")], [
        html.p([attribute.class("held-text")], [html.text(text)]),
        html.p([attribute.class("held-mark")], [html.text(words)]),
      ])

    // The turn is open and nothing has streamed. The same row the reasoning
    // text will fill, headed `Thinking`, so that the hand-over changes a word
    // and not the row's place. The lane's own dot pulses beside it.
    Opened(elapsed_ms:) ->
      html.div([attribute.class("thinking")], [
        html.p([attribute.class("who"), attribute.class("thinking-head")], [
          html.text("Thinking"),
          ..elapsed(elapsed_ms)
        ]),
      ])

    // The row says what the model is doing and for how long, `Reasoning ·
    // 7s`, with the summarizer's headline beneath it once one is pushed. The
    // count of lines that have arrived is a detail of the engine's, so it is
    // the row's title and not its words.
    Thinking(progress:, elapsed_ms:, headline:) ->
      html.div([attribute.class("thinking"), attribute.title(progress)], [
        html.p([attribute.class("who"), attribute.class("thinking-head")], [
          html.text("Reasoning"),
          ..elapsed(elapsed_ms)
        ]),
        ..case headline {
          Some(headline) -> [
            html.p([attribute.class("thinking-headline")], [
              html.text(headline),
            ]),
          ]
          None -> []
        }
      ])
  }
}

// The clock after the row's word. The browser counts it from the reading
// (`<loom-elapsed offset>`, in milliseconds), so a reading is drawn only once
// the generation clock has started.
fn elapsed(elapsed_ms: Option(Int)) -> List(Element(message)) {
  case elapsed_ms {
    None -> []
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
    ]
  }
}
