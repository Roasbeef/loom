//// The browser's Mermaid request lifecycle, with no DOM or renderer dependency.
////
//// A source or theme change advances the revision before a debounce starts.
//// Only that revision can begin rendering or publish a result, so an old
//// timer, parser failure or resize cannot replace a newer diagram. The frame
//// receives bounded text and returns only fixed status words and dimensions;
//// SVG never crosses into the session page.

import gleam/dynamic/decode
import gleam/json
import gleam/result
import gleam/string

/// The largest source sent to the isolated renderer, in UTF-16 code units.
/// The component measures this with the browser's string length.
pub const max_source = 32_000

/// Quiet time after a source change before rendering a streaming diagram.
pub const debounce_ms = 350

/// How long a rendering may leave the page waiting before showing source.
pub const timeout_ms = 10_000

/// The renderer's two fixed theme names.
pub type Theme {
  /// The page has a dark background.
  Dark

  /// Mermaid's default light palette.
  Light
}

/// What the reader can currently see.
pub type Phase {
  /// No source has arrived.
  Empty

  /// The latest source is waiting for a quiet interval.
  Waiting

  /// The latest revision may be sent once the frame is ready.
  Rendering

  /// The frame rendered this revision at a bounded height.
  Shown(height: Int)

  /// The source exceeds the renderer's bound.
  TooLarge

  /// Rendering failed or the frame did not answer in time.
  Unavailable
}

/// The text and theme whose revision owns the current display.
pub type State {
  State(
    /// Source remains plain text, including when rendering is refused.
    source: String,
    /// Only one of two application-selected themes reaches the frame.
    theme: Theme,
    /// Monotonically increasing within the connected element.
    revision: Int,
    /// Whether to show the diagram or its source.
    phase: Phase,
  )
}

/// The closed vocabulary accepted from the isolated frame.
pub type Reply {
  /// The frame installed its receiver.
  Ready

  /// This revision rendered, or its layout changed after a width change.
  Rendered(revision: Int, height: Int)

  /// This revision could not be rendered.
  Failed(revision: Int)

  /// Unknown or malformed messages have no effect.
  Ignored
}

/// An element before its source has been read.
///
/// ## Examples
///
/// ```gleam
/// assert mermaid_rule.new().revision == 0
/// ```
pub fn new() -> State {
  State("", Dark, 0, Empty)
}

/// Advances only when the source or effective theme changed.
///
/// `units` is the source's UTF-16 length, measured by the DOM binding.
///
/// ## Examples
///
/// ```gleam
/// let state = mermaid_rule.read(mermaid_rule.new(), "graph TD", Dark, 8)
/// assert state.phase == Waiting
/// ```
pub fn read(state: State, source: String, theme: Theme, units: Int) -> State {
  // Retain current state when source and theme are unchanged.
  case source == state.source && theme == state.theme {
    True -> state
    False -> {
      // Determine initial render phase from trimmed source length.
      let phase = case string.trim(source), units > max_source {
        "", _ -> Empty
        _, True -> TooLarge
        _, False -> Waiting
      }

      State(source, theme, state.revision + 1, phase)
    }
  }
}

/// Begins only the latest waiting revision after its quiet interval.
///
/// ## Examples
///
/// ```gleam
/// assert mermaid_rule.due(mermaid_rule.new(), 99).phase == Empty
/// ```
pub fn due(state: State, revision: Int) -> State {
  case state.phase, revision == state.revision {
    Waiting, True -> State(..state, phase: Rendering)
    _, _ -> state
  }
}

/// Accepts a result only for the current render, with a bounded dimension.
///
/// A shown diagram may resize, but a late success cannot undo a timeout.
///
/// ## Examples
///
/// ```gleam
/// assert mermaid_rule.receive(mermaid_rule.new(), Ready).phase == Empty
/// ```
pub fn receive(state: State, reply: Reply) -> State {
  case reply, state.phase {
    Rendered(revision, height), Rendering
    | Rendered(revision, height), Shown(_)
    -> {
      case revision == state.revision && height >= 120 && height <= 2000 {
        True -> State(..state, phase: Shown(height))
        False -> state
      }
    }
    Failed(revision), Rendering -> expire(state, revision)
    _, _ -> state
  }
}

/// Ends a current render that failed or exceeded the waiting deadline.
///
/// ## Examples
///
/// ```gleam
/// assert mermaid_rule.expire(mermaid_rule.new(), 0).phase == Empty
/// ```
pub fn expire(state: State, revision: Int) -> State {
  case state.phase, revision == state.revision {
    Rendering, True -> State(..state, phase: Unavailable)
    _, _ -> state
  }
}

/// Encodes text as data for the frame, never as markup or a URL.
///
/// ## Examples
///
/// ```gleam
/// // mermaid_rule.request(state)
/// ```
pub fn request(state: State) -> String {
  // Map theme variant to mermaid configuration theme word.
  let theme = case state.theme {
    Dark -> "dark"
    Light -> "default"
  }

  json.object([
    #("source", json.string(state.source)),
    #("theme", json.string(theme)),
    #("revision", json.int(state.revision)),
  ])
  |> json.to_string
}

/// Decodes the frame's small status vocabulary with total field decoders.
///
/// ## Examples
///
/// ```gleam
/// assert mermaid_rule.reply("{\"kind\":\"ready\"}") == Ready
/// ```
pub fn reply(text: String) -> Reply {
  // Discard replies exceeding maximum payload size.
  case string.byte_size(text) > 512 {
    True -> Ignored
    False -> {
      use <- result.lazy_unwrap(json.parse(text, reply_decoder()))
      Ignored
    }
  }
}

/// Decodes frame status reply messages from JSON payloads.
fn reply_decoder() -> decode.Decoder(Reply) {
  use kind <- decode.field("kind", decode.string)

  // Dispatch reply variant based on message kind.
  case kind {
    "ready" -> decode.success(Ready)
    "rendered" -> {
      use revision <- decode.field("revision", decode.int)
      use height <- decode.field("height", decode.int)
      decode.success(Rendered(revision, height))
    }
    "failed" -> {
      use revision <- decode.field("revision", decode.int)
      decode.success(Failed(revision))
    }
    _ -> decode.success(Ignored)
  }
}
