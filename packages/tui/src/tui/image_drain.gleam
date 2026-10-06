//// The `o` key's half of opening an image: choosing it and reporting.
////
//// While the reader is above the tail, `o` hands the viewed strand's newest
//// image to the platform's opener. This module chooses the image from the
//// records the terminal already holds, starts the job that writes and opens
//// it (`job.OpenImage`, run by `tui/image_open`), and, when the job's reply
//// arrives, says in the notice what became of it. Everything here is a pure
//// step over the model; the file and the child process are the job's.
////
//// The newest image is the one chosen, not the one under the cursor: the
//// transcript's rows do not say which image a row belongs to without the
//// anchors, and the newest is the one a reader who just scrolled up to look
//// at a picture is almost always looking at.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/shared_set
import session_view/transcript_image
import tui/job
import tui/model.{type Model, Model} as tui_model
import tui/view_set
import weft

/// Starts opening the viewed strand's newest image, or says there is none.
///
/// A second `o` while one opens is answered by the first: the job slot
/// holds one key, and a reply for any other is dropped.
///
/// ## Examples
///
/// ```gleam
/// // image_drain.open_newest(model)
/// ```
pub fn open_newest(model: Model) -> Model {
  let newest =
    model.shared.records
    |> list.filter(fn(record) { record.strand == model.shared.active_strand })
    |> list.find_map(fn(record) {
      transcript_image.of_entry(record.entry) |> list.first
    })
  case newest, model.view.opening_image {
    _, Some(_) -> model
    Error(Nil), None -> notice(model, "no image on this strand to open")
    Ok(image), None -> {
      let #(model, key) =
        tui_model.start_job(
          model,
          job.OpenImage(mime_type: image.mime_type, data: image.data),
        )
      Model(
        ..model,
        view: view_set.opening_image(model.view, Some(job.awaiting(key))),
      )
      |> notice("opening the newest image outside the terminal")
    }
  }
}

/// Takes the open-image job's reply, if the runtime has admitted one, into
/// the notice, and frees the slot.
///
/// ## Examples
///
/// ```gleam
/// // image_drain.drain(model)
/// ```
pub fn drain(model: Model) -> Model {
  case model.view.opening_image {
    None -> model
    Some(awaiting) ->
      case job.take(awaiting) {
        #(_, Error(Nil)) -> model
        #(awaiting, Ok(reply)) -> {
          let held =
            Model(
              ..model,
              view: view_set.opening_image(model.view, Some(awaiting)),
            )
          let freed =
            Model(..model, view: view_set.opening_image(model.view, None))
          case reply {
            weft.NotYet -> held
            weft.PulledOutcome(weft.Completed(..)) ->
              notice(freed, "opened the image in the default viewer")
            weft.PulledOutcome(weft.Failed(error:, ..)) ->
              notice(freed, "could not open the image: " <> error)
            weft.PulledOutcome(weft.Crashed(reason:, ..))
            | weft.PulledOutcome(weft.DrainProofLost(reason:, ..)) ->
              notice(
                freed,
                "could not open the image: " <> string.inspect(reason),
              )
            weft.PulledOutcome(weft.Abandoned(..))
            | weft.PulledOutcome(weft.NeverStarted(..))
            | weft.PulledOutcome(weft.CancellationUnconfirmed(..))
            | weft.AllDelivered
            | weft.RunLost(_) ->
              notice(
                freed,
                "could not open the image: the opener did not answer",
              )
          }
        }
      }
  }
}

fn notice(model: Model, text: String) -> Model {
  Model(..model, shared: shared_set.notice(model.shared, text))
  |> tui_model.invalidate_frame
}
