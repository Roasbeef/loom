//// Whether this terminal can draw an image, decided once at launch.
////
//// A terminal cannot be identified from its environment: `TERM_PROGRAM`
//// survives `ssh`, and a multiplexer in between may not pass graphics
//// through. So the client asks the terminal, through etui's probe, and
//// believes only a positive answer. Everything else is `TextOnly`, and
//// `TextOnly` is a complete answer rather than a degraded one: the
//// placeholder row under a call (`render.image_rows`) already says what the
//// image is, and it is the only thing scrollback, a replay and `loom replay`
//// ever show.
////
//// ## Flow
////
//// `probe_terminal` → `detect` → `from_capabilities`
////
//// 1. `probe_terminal` is the one call the launcher makes. It hands the
////    real probe to `detect`.
//// 2. `detect` applies Loom's own rules first. A plain palette (no colour,
////    or a dumb terminal) means no images, and the probe is not sent.
////    Next etui's own check skips the probe inside Herdr, whose panes do not
////    pass graphics through, and under NO_COLOR. Only then does it run the
////    probe, a round trip of at most 200 milliseconds that must happen
////    before the alternate screen opens, because its replies are read in raw
////    mode and must not be drawn. The caller supplies the probe as a
////    function, so a test can answer for any terminal without a terminal.
//// 3. `from_capabilities` turns what the terminal said into one of the three
////    answers, with the cell size the box will be fitted with.
////
//// The answer is read once and kept in the model for the life of the
//// process. A terminal that gains graphics mid-session is not noticed, and
//// that is intended: the rows a transcript has already laid out would have
//// to be laid out again.

import etui/graphics
import etui/graphics/probe
import gleam/option
import tui/appearance

/// How long the probe waits for the terminal's primary device attributes
/// reply, which ends it. A local terminal answers in a few milliseconds, so
/// the whole of this is spent only on a terminal that does not answer.
pub const probe_timeout_ms = 200

/// What the terminal can draw, and so which protocol the box is made for.
pub type Support {
  /// No image is drawn, for the reason given.
  TextOnly(why: Why)

  /// kitty graphics through Unicode placeholders, which kitty and Ghostty
  /// implement. The image is transmitted once, and the cells of the box are
  /// ordinary text that scrolls and clips with the rows around them.
  KittyPlaceholders(cell: graphics.CellSize)

  /// iTerm2's OSC 1337 inline images. The image is not text, so it is drawn
  /// over the box after the frame that laid the box out.
  Iterm2Inline(cell: graphics.CellSize)
}

/// Why a terminal draws no image. It is for a test and a reader of the
/// model: the transcript shows the same placeholder row for every reason.
pub type Why {
  /// The model was built without a probe: a replay, a scripted run, or a
  /// test. Nothing was asked, so nothing is believed.
  NotProbed

  /// The palette is plain, so there is no colour to draw an image with.
  PlainPalette

  /// The terminal is a Herdr pane, which does not pass graphics through.
  InsideHerdr

  /// `NO_COLOR` is set to a non-empty value.
  ColourDisabled

  /// The terminal was asked and did not answer for a protocol Loom draws:
  /// the probe timed out, or the replies named neither kitty, Ghostty nor
  /// iTerm2. A multiplexer that drops the query lands here.
  NotAnswered
}

/// The cell size assumed when the terminal answers the graphics query but
/// not the size of a cell, in pixels. A box fitted with a wrong size shows
/// the whole image at a slightly wrong shape, which is better than none.
pub const guessed_cell = graphics.CellSize(width: 8, height: 16)

/// Chooses what to draw with, asking the terminal if it is worth asking.
///
/// `run` is the probe: `probe.run` in the launcher, a fake in a test. It is
/// called at most once, and not at all for a plain palette or an environment
/// `graphics.decide` skips.
///
/// ## Examples
///
/// ```gleam
/// assert image_support.detect(
///     appearance.Plain,
///     fn(_) { Error(Nil) },
///     fn(_) { panic as "a plain palette is not probed" },
///   )
///   == image_support.TextOnly(image_support.PlainPalette)
/// ```
pub fn detect(
  palette: appearance.Palette,
  getenv: fn(String) -> Result(String, Nil),
  run: fn(Int) -> graphics.Capabilities,
) -> Support {
  case palette {
    appearance.Plain -> TextOnly(PlainPalette)
    appearance.Dark | appearance.Light | appearance.Terminal ->
      case graphics.decide(getenv) {
        graphics.Skip(graphics.InsideHerdr) -> TextOnly(InsideHerdr)
        graphics.Skip(graphics.ColourDisabled) -> TextOnly(ColourDisabled)
        graphics.Probe -> from_capabilities(run(probe_timeout_ms))
      }
  }
}

/// Probes the terminal this process is attached to.
///
/// This is the one call the launcher makes, in the process that runs the
/// application loop and just before the loop starts: `probe.run` leaves the
/// terminal in raw mode for the backend that follows, because the Erlang
/// runtime enters raw mode once per session.
///
/// ## Examples
///
/// ```gleam
/// let support = image_support.probe_terminal(palette, host_bootstrap.getenv)
/// ```
pub fn probe_terminal(
  palette: appearance.Palette,
  getenv: fn(String) -> Result(String, Nil),
) -> Support {
  detect(palette, getenv, probe.run)
}

/// What the terminal's replies come to.
///
/// kitty wins when both protocols answer, as etui's `graphics.protocol`
/// decides, because its cells are text the frame differ moves and clips.
///
/// ## Examples
///
/// ```gleam
/// assert image_support.from_capabilities(graphics.none())
///   == image_support.TextOnly(image_support.NotAnswered)
/// ```
pub fn from_capabilities(caps: graphics.Capabilities) -> Support {
  let cell = option.unwrap(caps.cell_size, guessed_cell)
  case graphics.protocol(caps) {
    graphics.Kitty -> KittyPlaceholders(cell)
    graphics.Iterm2 -> Iterm2Inline(cell)
    graphics.TextOnly -> TextOnly(NotAnswered)
  }
}
