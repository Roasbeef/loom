//// Reading the terminal model for the images it shows, and queueing what the
//// terminal must be told.
////
//// `image_box` puts a box in the transcript rows, `image_shown` decides
//// which commands make the terminal agree with a frame, and this module is
//// the join between them and the model. After each step it reads the window
//// of transcript rows the frame is about to show, asks `image_box.found`
//// where the boxes are, finds each image again in the transcript's entries,
//// runs `image_shown.reconcile`, and queues the result as effects.
////
//// ## Flow
////
//// `settle` → `wants` → `queue`
////
//// 1. `settle` runs at the end of each step, after the frame is cached. It
////    does nothing on a terminal that draws no images, which is every
////    terminal until the launcher's probe says otherwise.
//// 2. `wants` reads the visible window and turns each box of the right kind
////    for the terminal into a screen position. `settle` hands those to
////    `image_shown.reconcile` with the transcript's images by id (`find`),
////    and a way to ask whether a box's cells survived into the frame
////    (`showing`), which is how an iTerm2 picture is kept off a surface
////    drawn over the transcript.
//// 3. `queue` stores the new shown state and queues the commands, a wake
////    when a picture is owed, and a notice for an image that failed.
////
//// ## Where the bytes come from
////
//// A transcript row holds an image's fingerprint, never its data
//// (`image_header.fingerprint`), so the data is found again here, in the
//// strand's entries, by hashing each entry's image to an id. That scan is
//// the cost of keeping rows small. It runs only when an image is first
//// fitted, uploaded or drawn: the shown state remembers the fit, so a tick
//// with the same images in view looks nothing up.

import etui/buffer
import etui/geometry.{type Position, type Rect}
import etui/graphics.{type Box}
import etui/graphics/kitty.{type ImageId}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import session_view/image_header.{type Picture}
import session_view/protocol
import session_view/shared_set
import session_view/transcript_image
import tui/effect
import tui/image_box
import tui/image_shown
import tui/image_support
import tui/layout
import tui/model.{type FrameCache, type Model, FrameCache, Model, View} as tui_model
import tui/render

/// Brings the terminal's images in line with the frame the step cached.
///
/// ## Examples
///
/// ```gleam
/// let model = image_plan.settle(model)
/// ```
pub fn settle(model: Model) -> Model {
  case model.view.image_support, model.shared.quit {
    image_support.TextOnly(..), _ -> model
    image_support.KittyPlaceholders(..), True
    | image_support.Iterm2Inline(..), True
    -> queue(model, image_shown.release(model.view.images))
    image_support.KittyPlaceholders(..) as support, False
    | image_support.Iterm2Inline(..) as support, False
    -> reconciled(model, support)
  }
}

// The terminal can draw, so the frame about to be shown is read for boxes.
// The closures take only the fields they read, so they do not hold the
// whole model while the shown state runs.
fn reconciled(model: Model, support: image_support.Support) -> Model {
  let screen = geometry.rect_new(0, 0, model.view.width, model.view.height)
  let area = render.transcript_area(model, screen)
  let records = model.shared.records
  let strand = model.shared.active_strand
  let cache = model.view.caches.frame_cache
  let facts =
    image_shown.Facts(
      support:,
      width: layout.transcript_width(model),
      height: model.view.height,
      wants: wants(support, model, area),
      picture: fn(id) { picture(records, strand, id) },
      bytes: fn(id) { bytes(records, strand, id) },
      showing: fn(at, box) { showing(cache, at, box) },
    )
  queue(model, image_shown.reconcile(model.view.images, facts))
}

// The boxes in the window that suit this terminal, at screen positions. A
// kitty terminal draws placeholder boxes and an iTerm2 terminal blank ones,
// so a box of the other kind is not its business.
fn wants(
  support: image_support.Support,
  model: Model,
  area: Rect,
) -> List(image_shown.Want) {
  render.transcript_window(model, area)
  |> image_box.found
  |> list.filter(fn(found) {
    case support, found.cells {
      image_support.KittyPlaceholders(..), image_box.Placeholders -> True
      image_support.Iterm2Inline(..), image_box.Blanks -> True
      image_support.KittyPlaceholders(..), image_box.Blanks
      | image_support.Iterm2Inline(..), image_box.Placeholders
      | image_support.TextOnly(..), _
      -> False
    }
  })
  |> list.map(fn(found) {
    image_shown.Want(
      id: found.id,
      at: geometry.Position(
        x: area.position.x + found.column,
        y: area.position.y + found.row,
      ),
      extent: found.extent,
    )
  })
}

// An image's header facts, found again from the transcript.
fn picture(
  records: List(protocol.EntryRecord),
  strand: String,
  id: ImageId,
) -> Result(Picture, image_shown.Failure) {
  use image <- result.try(find(records, strand, id))
  image_header.picture(image.mime_type, image.data)
  |> option.to_result(image_shown.Missing)
}

// An image's decoded bytes, found again from the transcript.
fn bytes(
  records: List(protocol.EntryRecord),
  strand: String,
  id: ImageId,
) -> Result(BitArray, image_shown.Failure) {
  use image <- result.try(find(records, strand, id))
  image_shown.decode(image.data)
}

// The active strand's image whose fingerprint hashes to `id`.
fn find(
  records: List(protocol.EntryRecord),
  strand: String,
  id: ImageId,
) -> Result(transcript_image.Image, image_shown.Failure) {
  records
  |> list.filter(fn(record) { record.strand == strand })
  |> list.find_map(fn(record) {
    transcript_image.of_entry(record.entry)
    |> list.find(fn(image) {
      image_box.id_of(image_header.fingerprint(image.data))
      == kitty.id_value(id)
    })
  })
  |> result.replace_error(image_shown.Missing)
}

// Whether every cell of a box on the cached frame is still one of the
// box's blank cells. A surface drawn over the transcript replaces them.
fn showing(
  cache: option.Option(FrameCache),
  at: Position,
  box: Box,
) -> image_shown.Showing {
  case cache {
    None -> image_shown.Overlaid
    Some(FrameCache(rendered: #(frame, _), ..)) -> {
      let cells =
        int.range(from: 0, to: box.rows, with: [], run: fn(rows, row) {
          int.range(
            from: 0,
            to: box.columns,
            with: rows,
            run: fn(cells, column) {
              [geometry.Position(x: at.x + column, y: at.y + row), ..cells]
            },
          )
        })
      case list.all(cells, blank_at(frame, _)) {
        True -> image_shown.Intact
        False -> image_shown.Overlaid
      }
    }
  }
}

fn blank_at(frame: buffer.Buffer, position: Position) -> Bool {
  case buffer.get_cell(frame, position).content {
    buffer.Content(symbol:, ..) -> symbol == image_box.blank
    buffer.Continuation -> False
  }
}

// Stores what the terminal now holds and queues what it must be told. The
// commands go first, the wake after them, so the loop is woken only once the
// commands are written.
fn queue(model: Model, outcome: image_shown.Outcome) -> Model {
  let model = Model(..model, view: View(..model.view, images: outcome.shown))
  let model = case outcome.commands {
    [] -> model
    commands -> tui_model.emit(model, effect.DrawImages(commands))
  }
  let model = case outcome.wake {
    image_shown.WakeSoon -> tui_model.emit(model, effect.WakeLoop)
    image_shown.NoWake -> model
  }
  case outcome.failures {
    [] -> model
    [#(_, failure), ..] ->
      Model(
        ..model,
        shared: shared_set.notice(
          model.shared,
          "could not draw an image: " <> explanation(failure),
        ),
      )
      |> tui_model.invalidate_frame
  }
}

fn explanation(failure: image_shown.Failure) -> String {
  case failure {
    image_shown.Missing -> "it is no longer in this transcript"
    image_shown.Undecodable -> "its data is not valid base64"
    image_shown.NotPng -> "its data is not a PNG file"
  }
}

/// Records that the backend has opened the alternate screen and reported its
/// size, which is what lets `settle` start sending images.
///
/// A resize also repaints every cell, so the iTerm2 pictures drawn are gone
/// and will be drawn again after the next frame.
///
/// ## Examples
///
/// ```gleam
/// let model = image_plan.resized(model)
/// ```
pub fn resized(model: Model) -> Model {
  Model(
    ..model,
    view: View(..model.view, images: image_shown.opened(model.view.images)),
  )
}
