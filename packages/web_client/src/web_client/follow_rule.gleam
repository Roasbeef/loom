//// The follower's decisions as functions of plain values: where the reader is
//// after a scroll, who moved it, how a gap and a move are measured, and what a
//// held row asks for once older rows have landed above it.
////
//// `web_client/follow` is the element: it reads the page, sends these
//// functions what it read, and does what they say. This module imports neither
//// Lustre nor the DOM binding, so its tests run without a page and without
//// the browser's runtime (`docs/lustre.md`), and the rule that only a scroll
//// the reader made leaves the tail has one home.

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/order

/// How many pixels from the bottom of the transcript still count as at the
/// bottom. A reader who scrolls up by one notch of a wheel moves further
/// than this; a transcript whose last row is still being laid out does not.
pub const slack = 40

/// Where the reader is.
pub type Position {
  /// At the bottom of the transcript: a row that lands is scrolled into
  /// view.
  Following

  /// Scrolled up to read: a row that lands leaves the transcript where it
  /// is.
  Reading
}

/// The reader's position for a gap between the view's bottom and the
/// content's, in pixels.
///
/// ## Examples
///
/// ```gleam
/// assert follow_rule.position(0) == follow_rule.Following
/// assert follow_rule.position(600) == follow_rule.Reading
/// ```
pub fn position(gap: Int) -> Position {
  case gap <= slack {
    True -> Following
    False -> Reading
  }
}

/// How long, in milliseconds, a touch of the reader's wheel, finger, pointer
/// or keyboard keeps the scrolls that follow it the reader's.
pub const touch_window = 500

/// How far from the bottom the reader must be before the "Jump to latest"
/// button is worth drawing. The button floats over the bottom of the view, and
/// a reader who is only a row above the bottom would have it cover the row they
/// are about to read, to offer a jump of one row. The distance is the lane's
/// 16 pixels of bottom padding, one row of text with its spacing (about 40
/// pixels) and the button with its inset (about 40 pixels). The padding is not
/// made larger instead: it would change the transcript's size when the button
/// appears, which the follower reads as the layout moving.
pub const jump_gap = 96

/// Whether the "Jump to latest" button is drawn.
pub type Jump {
  /// The reader is away from the bottom by enough that the button covers no
  /// row they are near.
  Offered

  /// The reader is following, or is within `jump_gap` of the bottom.
  Withheld
}

/// The button's state for a reader's position and gap. A reader whose
/// position is `Reading` but whose gap is within `jump_gap` is still reading,
/// and a row that lands leaves the transcript where it is; only the button is
/// withheld.
///
/// ## Examples
///
/// ```gleam
/// assert follow_rule.jump(follow_rule.Reading, 600) == follow_rule.Offered
/// assert follow_rule.jump(follow_rule.Reading, 60) == follow_rule.Withheld
/// assert follow_rule.jump(follow_rule.Following, 600) == follow_rule.Withheld
/// ```
pub fn jump(position: Position, gap: Int) -> Jump {
  case position, gap > jump_gap {
    Reading, True -> Offered
    Reading, False | Following, _ -> Withheld
  }
}

/// What moved the transcript, as far as a scroll event can tell.
pub type Origin {
  /// The reader's wheel, finger, pointer or a key touched the transcript within
  /// `touch_window`, so the scroll is theirs.
  Input

  /// Nothing touched it, but the transcript is the same size as at the last
  /// scroll, so nothing under the scroll position moved: a key pressed
  /// outside the transcript, find-in-page or a scrollbar drag, which raise no
  /// event this element listens to, is the likely cause.
  Steady

  /// Nothing touched it and it changed size since the last scroll: the
  /// browser moved the scroll position to fit the new layout, as it does when
  /// the content shrinks or the box grows, and the rows that landed after
  /// that are what make the position read as far from the bottom. The reader
  /// did not scroll.
  Layout
}

/// What moved a scroll heard at time `at`, given when the reader last touched
/// the transcript and its size at the last scroll and now.
///
/// ## Examples
///
/// ```gleam
/// let same = follow_rule.Extent(1000.0, 500.0)
/// let taller = follow_rule.Extent(1400.0, 500.0)
/// assert follow_rule.origin(Some(900), 1000, same, taller) == follow_rule.Input
/// assert follow_rule.origin(None, 1000, same, same) == follow_rule.Steady
/// assert follow_rule.origin(None, 1000, same, taller) == follow_rule.Layout
/// assert follow_rule.origin(Some(100), 1000, same, taller) == follow_rule.Layout
/// ```
pub fn origin(
  touched: Option(Int),
  at: Int,
  before: Extent,
  now: Extent,
) -> Origin {
  let touching = case touched {
    Some(when) -> at - when <= touch_window
    None -> False
  }
  case touching, before == now {
    True, _ -> Input
    False, True -> Steady
    False, False -> Layout
  }
}

/// The reader's position after a scroll that ended `gap` pixels from the
/// bottom, moved by `moved` pixels (negative for a move up) and had the
/// given origin. Ending within `slack` of the bottom is following whichever
/// way the scroll went and whoever made it. Further away, only the reader's
/// own move up is leaving the tail. A move up that the layout made is not: it
/// is the browser fitting the scroll position to a box that grew or content
/// that shrank, and the element scrolls to the bottom when it hears the size
/// change. A move down there is either the reader coming back or the
/// element's own scroll to the bottom that rows landing beneath it have
/// since outgrown, and neither changes where the reader is.
///
/// ## Examples
///
/// ```gleam
/// assert follow_rule.after_scroll(follow_rule.Following, 300, -80, follow_rule.Input)
///   == follow_rule.Reading
/// assert follow_rule.after_scroll(follow_rule.Following, 300, -80, follow_rule.Layout)
///   == follow_rule.Following
/// assert follow_rule.after_scroll(follow_rule.Following, 300, 80, follow_rule.Input)
///   == follow_rule.Following
/// assert follow_rule.after_scroll(follow_rule.Reading, 300, 80, follow_rule.Input)
///   == follow_rule.Reading
/// assert follow_rule.after_scroll(follow_rule.Reading, 10, 80, follow_rule.Layout)
///   == follow_rule.Following
/// ```
pub fn after_scroll(
  current: Position,
  gap: Int,
  moved: Int,
  origin: Origin,
) -> Position {
  case position(gap), int.compare(moved, 0), origin {
    Following, _, _ -> Following
    Reading, order.Lt, Input | Reading, order.Lt, Steady -> Reading
    Reading, _, _ -> current
  }
}

/// The distance, in whole pixels, from the bottom of a scroller's view to the
/// bottom of its content, given the content's height, how far it is scrolled
/// and the view's height. It is never negative: a browser can overscroll by a
/// fraction of a pixel.
///
/// ## Examples
///
/// ```gleam
/// assert follow_rule.gap(1000.0, 400.0, 500.0) == 100
/// assert follow_rule.gap(1000.0, 500.4, 500.0) == 0
/// assert follow_rule.gap(1000.0, 501.0, 500.0) == 0
/// ```
pub fn gap(content: Float, scrolled: Float, view: Float) -> Int {
  int.max(0, float.round(content -. scrolled -. view))
}

/// How far a scroll moved, in whole pixels, negative for a move up, from where
/// the transcript was last heard to be to where it is.
///
/// ## Examples
///
/// ```gleam
/// assert follow_rule.moved(120.0, 100.0) == 20
/// assert follow_rule.moved(80.0, 100.0) == -20
/// ```
pub fn moved(now: Float, before: Float) -> Int {
  float.round(now -. before)
}

/// Where the held row stands on the page, as read when rows may have landed.
pub type Standing {
  /// The row left the page, so there is nothing left to keep.
  Detached

  /// The row is still the lane's first: the older rows have not arrived.
  Leading

  /// Another row is now the lane's first, so older rows landed above the
  /// held one, which is now `top` pixels from the top of the viewport.
  Displaced(top: Float)
}

/// Whether a held row has been put back where it was.
pub type Keeping {
  /// The older rows have not arrived: keep holding the row.
  Waiting

  /// The older rows arrived, or the row left the page. Nothing is held any
  /// more, and the transcript is to be scrolled by `by` pixels first, which
  /// is zero when the row did not move.
  Restored(by: Float)
}

/// What to do about a held row, given where it stands now and where its top
/// edge was when it was held. A displaced row is put back by scrolling the
/// transcript by however far the row moved.
///
/// ## Examples
///
/// ```gleam
/// assert follow_rule.keeping(follow_rule.Leading, 80.0) == follow_rule.Waiting
/// assert follow_rule.keeping(follow_rule.Detached, 80.0) == follow_rule.Restored(0.0)
/// assert follow_rule.keeping(follow_rule.Displaced(380.0), 80.0)
///   == follow_rule.Restored(300.0)
/// ```
pub fn keeping(standing: Standing, held: Float) -> Keeping {
  case standing {
    Detached -> Restored(by: 0.0)
    Leading -> Waiting
    Displaced(top:) -> Restored(by: top -. held)
  }
}

/// The size of the transcript at a moment: the height of everything in it
/// and the height of the box that shows it, in pixels. Either changing is the
/// layout moving, which is not the reader.
pub type Extent {
  Extent(content: Float, view: Float)
}

/// What the follower knows about the reader, apart from the page: where they
/// are, how far the bottom of the transcript was from the bottom of its view
/// when last measured, how far the transcript was scrolled and how big it was
/// when a scroll was last heard, and when the reader last touched it.
pub type Reader {
  Reader(
    position: Position,
    gap: Int,
    top: Float,
    extent: Extent,
    touched: Option(Int),
  )
}

/// A reader who has not moved: following, with nothing measured.
///
/// ## Examples
///
/// ```gleam
/// assert follow_rule.start().position == follow_rule.Following
/// ```
pub fn start() -> Reader {
  Reader(
    position: Following,
    gap: 0,
    top: 0.0,
    extent: Extent(content: 0.0, view: 0.0),
    touched: None,
  )
}

/// The reader once the watch has started and read the transcript.
pub fn watched(reader: Reader, top: Float, extent: Extent) -> Reader {
  Reader(..reader, top:, extent:)
}

/// The reader once the wheel, a finger, a pointer or a key touched the
/// transcript at time `at`, in milliseconds.
pub fn touched(reader: Reader, at: Int) -> Reader {
  Reader(..reader, touched: Some(at))
}

/// The reader after a scroll heard at time `at`, to `top` pixels, with the
/// transcript `extent` big. Who moved it decides whether it leaves the tail
/// (`origin`, `after_scroll`); a scroll that is the reader's renews their
/// touch, so a slow scrollbar drag stays theirs.
///
/// ## Examples
///
/// ```gleam
/// // follow_rule.scrolled(reader, 1000.0, follow_rule.Extent(2000.0, 500.0), 9000)
/// ```
pub fn scrolled(reader: Reader, top: Float, extent: Extent, at: Int) -> Reader {
  let gap = gap(extent.content, top, extent.view)
  let origin = origin(reader.touched, at, reader.extent, extent)
  Reader(
    position: after_scroll(reader.position, gap, moved(top, reader.top), origin),
    gap: gap,
    top: top,
    extent: extent,
    touched: case origin {
      Input -> Some(at)
      Steady | Layout -> reader.touched
    },
  )
}

/// The reader after a gap was measured with nothing scrolled.
pub fn measured(reader: Reader, gap: Int) -> Reader {
  Reader(..reader, gap:)
}

/// The reader after a fold they opened: reading, so the lane growing does not
/// carry the transcript past the fold.
pub fn folded(reader: Reader) -> Reader {
  Reader(..reader, position: Reading)
}

/// The reader after they pressed "Load older": reading, so the rows that
/// land do not carry the transcript to its end.
pub fn paged(reader: Reader) -> Reader {
  Reader(..reader, position: Reading)
}

/// The reader after they pressed "Jump to latest": following from the
/// bottom.
pub fn jumped(reader: Reader) -> Reader {
  Reader(..reader, position: Following, gap: 0)
}

/// The attribute the server draws the strand's numeric key in.
pub const key_attribute = "data-strand-key"

/// Where the reader stood in a strand's transcript when they left it.
pub type Saved {
  /// They were at the bottom, so the strand is followed again when they
  /// return, however many rows landed meanwhile.
  AtBottom

  /// They had scrolled up to read, `top` pixels down.
  Offset(top: Float)
}

/// What the follower remembers of the strands the reader left, by the
/// strand's numeric key (`data-strand-key`, a number the page assigned the
/// strand, so the key carries none of its text). It lives as long as the element.
pub type Memory =
  Dict(Int, Saved)

/// What a strand's arrival asks of the transcript.
pub type Arrival {
  /// Follow the tail: the strand was never left, or was left at the bottom.
  Tail

  /// Put the transcript back `top` pixels down, and leave it there while the
  /// reader reads.
  Resume(top: Float)
}

/// Nothing remembered.
///
/// ## Examples
///
/// ```gleam
/// assert follow_rule.forgotten() == dict.new()
/// ```
pub fn forgotten() -> Memory {
  dict.new()
}

/// The memory once the reader leaves the strand `key`: where they stood, from
/// the last scroll the element heard, which is the position before the new
/// strand's rows replaced the old ones, since a scroll event is reported
/// after the change that caused it.
///
/// ## Examples
///
/// ```gleam
/// // follow_rule.leaving(follow_rule.forgotten(), 7, reader)
/// ```
pub fn leaving(memory: Memory, key: Int, reader: Reader) -> Memory {
  let saved = case reader.position {
    Following -> AtBottom
    Reading -> Offset(top: reader.top)
  }
  dict.insert(memory, key, saved)
}

/// What the transcript is asked to do when the strand `key` is shown.
///
/// ## Examples
///
/// ```gleam
/// assert follow_rule.arriving(follow_rule.forgotten(), 7) == follow_rule.Tail
/// ```
pub fn arriving(memory: Memory, key: Int) -> Arrival {
  case dict.get(memory, key) {
    Ok(Offset(top:)) -> Resume(top:)
    Ok(AtBottom) | Error(Nil) -> Tail
  }
}

/// The reader once an arrival is applied: reading for a resumed offset, so
/// the rows that land do not carry the transcript away from it, and
/// following the tail otherwise.
///
/// ## Examples
///
/// ```gleam
/// assert follow_rule.arrived(follow_rule.start(), follow_rule.Tail).position
///   == follow_rule.Following
/// ```
pub fn arrived(reader: Reader, arrival: Arrival) -> Reader {
  case arrival {
    Tail -> Reader(..reader, position: Following, gap: 0)
    Resume(top:) -> Reader(..reader, position: Reading, top:)
  }
}

/// What a change of the strand key asks of the element.
pub type Keying {
  /// The key is the one already shown, so nothing changes. The attribute may
  /// be written again with the same value.
  Unchanged

  /// Another strand is shown: the memory holds the departing strand's place,
  /// the reader is set for the arrival, and the transcript is asked to follow
  /// the tail or resume an offset.
  Changed(key: Int, memory: Memory, reader: Reader, arrival: Arrival)
}

/// The decision for a strand key `new` arriving while `shown` is on screen.
/// The departing strand is saved before the arriving one is looked up, so a
/// strand that is left and returned to in a row finds the place it was just
/// left at.
///
/// ## Examples
///
/// ```gleam
/// assert follow_rule.keyed(Some(7), follow_rule.forgotten(), follow_rule.start(), 7)
///   == follow_rule.Unchanged
/// ```
pub fn keyed(
  shown: Option(Int),
  memory: Memory,
  reader: Reader,
  new: Int,
) -> Keying {
  case shown == Some(new) {
    True -> Unchanged
    False -> {
      let kept = case shown {
        Some(left) -> leaving(memory, left, reader)
        None -> memory
      }
      let arrival = arriving(kept, new)
      Changed(
        key: new,
        memory: kept,
        reader: arrived(reader, arrival),
        arrival:,
      )
    }
  }
}
