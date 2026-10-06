//// Launch observation reads committed native history without publishing cap End.
////
//// The native phase is read before immutable terminal payloads, then the resource
//// journal independently checks the association again when retaining completion.
//// This reader never finalizes a build, reconnects a socket or grants activation.
//// Only the original inbound socket producer orders cap frames and End.

import executor/remote/admission
import executor/remote/journal
import executor/remote/launch_completion
import executor/remote/payload
import executor/remote/resource_journal
import executor/remote/wire
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// Observes settlement only after its exact terminal COMMIT.
///
/// ## Examples
///
/// `observe(resources, original)` returns pending while native intent is open.
pub fn observe(
  resources: resource_journal.Journal,
  original: resource_journal.Input,
) -> Result(Option(launch_completion.LaunchCompletion), resource_journal.Error) {
  use association <- result.try(resource_journal.inspect_native(
    resources,
    original,
  ))
  case association {
    resource_journal.Unassociated -> Ok(None)
    resource_journal.Associated(_ref, key, digest, _prepared) -> {
      let endpoint = resource_journal.native_endpoint(resources)
      use evidence <- result.try(
        journal.inspect(endpoint, key, digest)
        |> result.replace_error(resource_journal.Uncertain),
      )
      case admission.phase(evidence) {
        admission.Admitted | admission.LaunchIntent(_) -> Ok(None)
        admission.Terminal(saved, _, _)
        | admission.Refused(saved, _)
        | admission.Retired(saved)
        | admission.RetiredRefusal(saved) -> {
          // COMMIT dominates this read. Missing bytes after a committed phase
          // are corruption, rather than a reason to poll an unfinished process.
          use items <- result.try(
            journal.payloads(endpoint, key, digest)
            |> result.replace_error(resource_journal.Uncertain),
          )
          use bytes <- result.try(
            list.find_map(items, fn(item) {
              case item {
                payload.Terminal(bytes) -> Ok(bytes)
                payload.Output(..)
                | payload.Request(_)
                | payload.Authority(_)
                | payload.Cancellation(_) -> Error(Nil)
              }
            })
            |> result.replace_error(resource_journal.InvalidInput),
          )
          use actual <- result.try(
            wire.digest(bytes)
            |> result.replace_error(resource_journal.InvalidInput),
          )
          use Nil <- result.try(case actual == saved {
            True -> Ok(Nil)
            False -> Error(resource_journal.InvalidInput)
          })
          launch_completion.settled_native(
            resource_journal.enrolled(resources),
            original.key,
            key,
            digest,
            bytes,
          )
          |> result.map(Some)
          |> result.replace_error(resource_journal.InvalidInput)
        }
      }
    }
  }
}
