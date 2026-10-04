//// What the terminal has been told about images, and what to tell it next.
////
//// Drawing an image is two jobs. The frame carries the box (`image_box`):
//// text the frame differ already moves and clips. The terminal carries the
//// picture, and has to be told, by escape sequences written between frames,
//// which pictures exist and where. This module is the second job as a pure
//// function: it holds what the terminal was last told and, given what the
//// next frame shows, answers with the commands that make the terminal agree.
//// Nothing here writes to a terminal or reads a model, so every ordering rule
//// below is a plain test.
////
//// ## Flow
////
//// `opened` → `reconcile` → `kitty` or `iterm2` → `sequence`
////
//// 1. `reconcile` does nothing until `opened` has been called, which the
////    client calls on the first resize event. That event comes from the
////    backend only after it has entered the alternate screen, and kitty and
////    Ghostty keep each screen's images apart, so an image sent earlier
////    would be sent to the screen that is left behind.
//// 2. `kitty` keeps the set of images the terminal holds. An image that
////    enters view is uploaded (transmitted and given its virtual
////    placement), one whose box changed size is placed again, and one that
////    left view is deleted. The cells are text in the frame, so the order
////    of these commands against the frame does not matter.
//// 3. `iterm2` keeps the set of images drawn. The picture is not text, and
////    anything the frame writes over a drawn cell erases it, so a picture
////    may only be drawn after the frame that laid its box out. A box seen
////    for the first time is therefore only owed; it is drawn by the next
////    reconcile, which runs after that frame, and the caller wakes the loop
////    so the next one is not a second away. A box that moved or left view
////    is erased at once. A resize repaints every cell, so `opened` forgets
////    everything drawn without erasing it.
//// 4. `sequence` turns the commands into the bytes etui's `kitty` and
////    `iterm2` modules define.
////
//// ## Budget
////
//// `image_box.verdict` refuses an image over `image_box.max_bytes`, and an
//// image is held by the terminal only while its box is in view, which holds
//// a few boxes at most, so the bytes sent to the terminal are bounded by
//// the viewport rather than by the transcript. An image that cannot be
//// loaded or decoded is recorded in `failed` and is never tried again, so a
//// bad image costs one failure and no per-frame retry.

import etui/geometry.{type Position}
import etui/graphics.{type Box}
import etui/graphics/iterm2
import etui/graphics/kitty.{type ImageId}
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string
import session_view/image_header.{type Picture}
import tui/image_box
import tui/image_support.{type Support}

/// Whether the backend has opened the alternate screen.
pub type Screen {
  /// No resize has arrived, so the alternate screen may not be open. No
  /// image command is decided in this state.
  BeforeScreen

  /// The backend has entered the alternate screen and reported its size.
  OnScreen
}

/// A kitty image the terminal holds: its id and the box it was last placed
/// with.
pub type Uploaded {
  Uploaded(id: ImageId, box: Box)
}

/// An iTerm2 picture's place on the screen: the cell of its top-left corner
/// and the cells it covers.
pub type Spot {
  Spot(id: ImageId, at: Position, box: Box)
}

/// What the terminal was last told. It is `Shown`, not a plan: the next frame
/// is compared with it.
pub type Shown {
  Shown(
    /// Whether commands may be decided yet.
    screen: Screen,
    /// kitty: the images the terminal holds.
    uploaded: List(Uploaded),
    /// iTerm2: the pictures drawn and believed to be on screen.
    drawn: List(Spot),
    /// iTerm2: boxes seen once, to be drawn by the next reconcile if they
    /// are still where they were.
    owed: List(Spot),
    /// Images that could not be loaded or decoded, never retried.
    failed: List(ImageId),
    /// What each image fits to at the pane size it was last fitted for, so
    /// a tick does not look an image up again.
    fits: Dict(ImageId, Fit),
  )
}

/// An image's box at one pane size, or the fact that it has none. The box
/// depends on the pane's height as well as its width, because a short pane
/// gives a picture fewer rows.
pub type Fit {
  Fitted(width: Int, height: Int, box: Box)
  Unfitted(width: Int, height: Int)
}

/// A shown state before the alternate screen: nothing sent, nothing owed.
///
/// ## Examples
///
/// ```gleam
/// assert image_shown.new().screen == image_shown.BeforeScreen
/// ```
pub fn new() -> Shown {
  Shown(
    screen: BeforeScreen,
    uploaded: [],
    drawn: [],
    owed: [],
    failed: [],
    fits: dict.new(),
  )
}

/// Records that the backend has opened the alternate screen, and, because a
/// resize repaints every cell and so erases every drawn picture, forgets the
/// iTerm2 pictures drawn and owed. kitty images survive a resize: their
/// cells are text and the terminal still holds the data.
///
/// ## Examples
///
/// ```gleam
/// assert image_shown.opened(image_shown.new()).screen == image_shown.OnScreen
/// ```
pub fn opened(shown: Shown) -> Shown {
  Shown(..shown, screen: OnScreen, drawn: [], owed: [])
}

/// One command for the terminal.
pub type Command {
  /// Transmit the PNG under the id and give it its virtual placement.
  Upload(id: ImageId, png: BitArray, box: Box)

  /// Place an image the terminal already holds again, at a new box size.
  Place(id: ImageId, box: Box)

  /// Delete an image and its placements.
  Remove(id: ImageId)

  /// Draw a picture over a box, after the frame.
  Draw(at: Position, bytes: BitArray, box: Box)

  /// Blank the cells a picture was drawn over.
  Erase(at: Position, box: Box)
}

/// Why an image could not be drawn.
pub type Failure {
  /// The transcript no longer holds the image: its entry was compacted away
  /// or belongs to another strand.
  Missing

  /// The image's data is not valid base64.
  Undecodable

  /// The terminal draws PNG through kitty's protocol and these bytes are not
  /// one.
  NotPng
}

/// Where a box is on the frame about to be drawn, and how much of it.
pub type Want {
  Want(id: ImageId, at: Position, extent: image_box.Extent)
}

/// Whether a box's cells survived into the frame. Another surface drawn over
/// the transcript replaces them, and a picture drawn over that surface would
/// be drawn over text.
pub type Showing {
  Intact
  Overlaid
}

/// What a reconcile reads of the world: the terminal, the pane, the boxes
/// on the next frame, and the transcript's images.
pub type Facts {
  Facts(
    support: Support,
    /// The pane's width in cells, which the box is fitted to.
    width: Int,
    /// The transcript's height in rows, which bounds the box's rows.
    height: Int,
    wants: List(Want),
    /// The image's header facts, from the transcript.
    picture: fn(ImageId) -> Result(Picture, Failure),
    /// The image's decoded bytes, from the transcript.
    bytes: fn(ImageId) -> Result(BitArray, Failure),
    /// Whether a box's cells are intact on the next frame.
    showing: fn(Position, Box) -> Showing,
  )
}

/// Whether the loop should be woken to run another reconcile soon.
pub type Wake {
  /// A picture is owed: it can only be drawn after the frame, and the frame
  /// is drawn when this step returns.
  WakeSoon
  NoWake
}

/// The result of one reconcile.
pub type Outcome {
  Outcome(
    shown: Shown,
    /// What to write to the terminal, in order, before the next frame.
    commands: List(Command),
    /// Images that failed this time, in the order they were met.
    failures: List(#(ImageId, Failure)),
    wake: Wake,
  )
}

/// Deletes every image the terminal holds, for a client that is quitting.
///
/// kitty keeps an image until it is deleted or the screen it was sent to is
/// left, and a terminal that keeps its alternate screen's store after the
/// client exits would carry the pictures into the next program. The caller
/// writes the commands while the alternate screen is still open.
///
/// ## Examples
///
/// ```gleam
/// assert image_shown.release(image_shown.new()).commands == []
/// ```
pub fn release(shown: Shown) -> Outcome {
  Outcome(
    shown: Shown(..shown, uploaded: []),
    commands: list.map(shown.uploaded, fn(held) { Remove(held.id) }),
    failures: [],
    wake: NoWake,
  )
}

/// Brings the terminal in line with the next frame.
///
/// ## Examples
///
/// ```gleam
/// let outcome = image_shown.reconcile(image_shown.new(), facts)
/// assert outcome.commands == []
/// ```
pub fn reconcile(shown: Shown, facts: Facts) -> Outcome {
  case shown.screen, facts.support {
    BeforeScreen, _ -> quiet(shown)
    OnScreen, image_support.TextOnly(..) -> quiet(shown)
    OnScreen, image_support.KittyPlaceholders(..) -> kitty(shown, facts)
    OnScreen, image_support.Iterm2Inline(..) -> iterm2(shown, facts)
  }
}

fn quiet(shown: Shown) -> Outcome {
  Outcome(shown:, commands: [], failures: [], wake: NoWake)
}

/// A box on the next frame with the cells its image fits to at this width.
pub type Placed {
  Placed(want: Want, box: Box)
}

// What `fitted` carries along the wants: the shown state with its cache
// brought up to date, and the boxes that have a fit.
type Fitting {
  Fitting(shown: Shown, placed: List(Placed))
}

// The wants that have a fit at this width, in the order they were met. An
// image that cannot be fitted is remembered, so a tick does not look it up
// again.
fn fitted(shown: Shown, facts: Facts) -> Fitting {
  let done =
    list.fold(facts.wants, Fitting(shown:, placed: []), fn(fitting, want) {
      fit(fitting, want, facts)
    })
  Fitting(..done, placed: list.reverse(done.placed))
}

fn fit(fitting: Fitting, want: Want, facts: Facts) -> Fitting {
  case dict.get(fitting.shown.fits, want.id) {
    Ok(Fitted(width:, height:, box:))
      if width == facts.width && height == facts.height
    -> Fitting(..fitting, placed: [Placed(want:, box:), ..fitting.placed])
    Ok(Unfitted(width:, height:))
      if width == facts.width && height == facts.height
    -> fitting
    Ok(_) | Error(Nil) -> look_up(fitting, want, facts)
  }
}

// The first time an image is wanted at a pane size: its picture is read from
// the transcript and its box fitted, and the answer is remembered either way.
//
// A picture that cannot be found is not reported. A box the projection built
// carries the fingerprint of an image it read from the transcript, so a miss
// means the marked cells are not a box at all, such as a pasted line that
// happens to look like one, and a notice about an image would be about
// nothing.
fn look_up(fitting: Fitting, want: Want, facts: Facts) -> Fitting {
  let unfitted = Unfitted(facts.width, facts.height)
  case facts.picture(want.id) {
    Error(_) ->
      Fitting(..fitting, shown: remember(fitting.shown, want.id, unfitted))
    Ok(picture) ->
      case
        image_box.verdict(facts.support, picture, facts.width, facts.height)
      {
        image_box.Draw(drawing) ->
          Fitting(
            shown: remember(
              fitting.shown,
              want.id,
              Fitted(facts.width, facts.height, drawing.box),
            ),
            placed: [Placed(want:, box: drawing.box), ..fitting.placed],
          )
        image_box.Keep | image_box.Refuse(..) ->
          Fitting(..fitting, shown: remember(fitting.shown, want.id, unfitted))
      }
  }
}

fn remember(shown: Shown, id: ImageId, fit: Fit) -> Shown {
  Shown(..shown, fits: dict.insert(shown.fits, id, fit))
}

// ----------------------------------------------------------------- kitty

// The images in view are uploaded, re-placed or kept, and the images that
// left view are deleted first, so the terminal's memory falls before it
// grows.
fn kitty(shown: Shown, facts: Facts) -> Outcome {
  let fitting = fitted(shown, facts)
  let placed = unique(fitting.placed)
  let #(kept, removed) =
    list.partition(fitting.shown.uploaded, fn(held) {
      list.any(placed, fn(entry) { entry.want.id == held.id })
    })
  let start =
    Outcome(
      shown: Shown(..fitting.shown, uploaded: kept),
      commands: list.map(removed, fn(held) { Remove(held.id) }),
      failures: [],
      wake: NoWake,
    )
  list.fold(placed, start, fn(outcome, entry) {
    upload(outcome, entry.want.id, entry.box, facts)
  })
}

// One image in view against what the terminal holds.
fn upload(outcome: Outcome, id: ImageId, box: Box, facts: Facts) -> Outcome {
  let shown = outcome.shown
  case
    list.contains(shown.failed, id),
    list.find(shown.uploaded, fn(held) { held.id == id })
  {
    True, _ -> outcome
    False, Ok(held) if held.box == box -> outcome
    False, Ok(_) ->
      Outcome(
        ..outcome,
        shown: Shown(
          ..shown,
          uploaded: replace_upload(shown.uploaded, Uploaded(id, box)),
        ),
        commands: list.append(outcome.commands, [Place(id, box)]),
      )
    False, Error(Nil) ->
      case facts.bytes(id) |> result.try(png) {
        Ok(bytes) ->
          Outcome(
            ..outcome,
            shown: Shown(..shown, uploaded: [
              Uploaded(id, box),
              ..shown.uploaded
            ]),
            commands: list.append(outcome.commands, [Upload(id, bytes, box)]),
          )
        Error(failure) -> failed(outcome, id, failure)
      }
  }
}

fn replace_upload(held: List(Uploaded), next: Uploaded) -> List(Uploaded) {
  list.map(held, fn(entry) {
    case entry.id == next.id {
      True -> next
      False -> entry
    }
  })
}

// kitty's transmission carries the file as a PNG, so bytes that do not open
// with a PNG signature are refused before they are sent.
fn png(bytes: BitArray) -> Result(BitArray, Failure) {
  case bytes {
    <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, _:bits>> -> Ok(bytes)
    _ -> Error(NotPng)
  }
}

fn failed(outcome: Outcome, id: ImageId, failure: Failure) -> Outcome {
  Outcome(
    ..outcome,
    shown: Shown(..outcome.shown, failed: [id, ..outcome.shown.failed]),
    failures: list.append(outcome.failures, [#(id, failure)]),
  )
}

// A box is wanted once however many rows of the transcript show it.
fn unique(placed: List(Placed)) -> List(Placed) {
  list.fold(placed, [], fn(seen: List(Placed), entry: Placed) {
    case list.any(seen, fn(held) { held.want.id == entry.want.id }) {
      True -> seen
      False -> [entry, ..seen]
    }
  })
  |> list.reverse
}

// ---------------------------------------------------------------- iTerm2

// The pictures drawn that are no longer where the frame has them are erased
// now. The pictures the frame has that are not drawn are drawn if they were
// owed by the last reconcile, which means a frame has been drawn since, and
// are otherwise owed.
fn iterm2(shown: Shown, facts: Facts) -> Outcome {
  let fitting = fitted(shown, facts)
  let shown = fitting.shown
  let spots =
    fitting.placed
    |> list.filter(fn(entry) { whole(entry.want) })
    |> list.map(fn(entry) {
      Spot(id: entry.want.id, at: entry.want.at, box: entry.box)
    })
    |> list.filter(fn(spot) { facts.showing(spot.at, spot.box) == Intact })
    |> list.filter(fn(spot) { !list.contains(shown.failed, spot.id) })
  let #(kept, erasures) =
    list.partition(shown.drawn, fn(spot) { list.contains(spots, spot) })
  let fresh = list.filter(spots, fn(spot) { !list.contains(kept, spot) })
  let #(due, owed) =
    list.partition(fresh, fn(spot) { list.contains(shown.owed, spot) })
  let start =
    Outcome(
      shown: Shown(..shown, drawn: kept, owed:),
      commands: list.map(erasures, fn(spot) { Erase(spot.at, spot.box) }),
      failures: [],
      wake: case owed {
        [] -> NoWake
        [_, ..] -> WakeSoon
      },
    )
  list.fold(due, start, fn(outcome, spot) { draw(outcome, spot, facts) })
}

fn whole(want: Want) -> Bool {
  case want.extent {
    image_box.Whole -> True
    image_box.Clipped -> False
  }
}

fn draw(outcome: Outcome, spot: Spot, facts: Facts) -> Outcome {
  case facts.bytes(spot.id) {
    Ok(bytes) ->
      Outcome(
        ..outcome,
        shown: Shown(..outcome.shown, drawn: [spot, ..outcome.shown.drawn]),
        commands: list.append(outcome.commands, [
          Draw(spot.at, bytes, spot.box),
        ]),
      )
    Error(failure) -> failed(outcome, spot.id, failure)
  }
}

// ---------------------------------------------------------------- bytes

/// The bytes the terminal reads for a list of commands, in order.
///
/// ## Examples
///
/// ```gleam
/// assert image_shown.sequence([]) == ""
/// ```
pub fn sequence(commands: List(Command)) -> String {
  commands |> list.map(command_bytes) |> string.concat
}

fn command_bytes(command: Command) -> String {
  case command {
    Upload(id:, png:, box:) -> kitty.transmit(id, png) <> kitty.place(id, box)
    Place(id:, box:) -> kitty.place(id, box)
    Remove(id:) -> kitty.delete(id)
    Draw(at:, bytes:, box:) -> iterm2.draw_at(at, bytes, box)
    Erase(at:, box:) -> iterm2.erase(at, box)
  }
}

/// The decoded bytes of an image held as base64 text.
///
/// ## Examples
///
/// ```gleam
/// assert image_shown.decode("aGk=") == Ok(<<"hi":utf8>>)
/// ```
pub fn decode(data: String) -> Result(BitArray, Failure) {
  bit_array.base64_decode(data) |> result.replace_error(Undecodable)
}
