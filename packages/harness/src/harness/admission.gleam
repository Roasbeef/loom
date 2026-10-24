//// The pre-request admission, and the image readers it and dispatch share.
////
//// Admission is answered from the query's own configuration rather than from
//// a closure frozen at boot. Three durable values ride on it: the intended
//// output limit and the context window that overflow classification is stable
//// against, and the `request_api` a deferred handle is validated against
//// (ORCH-L4). All three are properties of the identity *this attempt* will
//// reach, which a boot-time answer cannot know for a strand that switched
//// models since.
////
//// The fourth question is the vision rule (issue #358). An image-bearing
//// request from a strand whose model cannot read images is admitted against
//// the *vision head's* facts, the identity this attempt will actually reach,
//// and refused in band when no usable vision route resolves. The image
//// classification reads the strand's durable projection, the same place the
//// threshold and overflow hooks decide from, so a decision taken before a
//// crash is taken again after it. A store that will not answer classifies as
//// imageless: a read that fails must not strand the conversation.
////
//// Moved from `client/wiring` (issue #1030) with its decisions unchanged.
////
//// ## Flow
////
//// `admit` answers a query; it consults `model_facts.of_identity` first and
//// only a text-only identity pays for `image_bearing_projected`, then
//// `admit_through_vision` admits against the head `identity_of` names.
//// `image_bearing` is the classification dispatch uses on the request's own
//// context, and `active_run_images` counts the images the current run must
//// keep through image budgeting.

import core/entry
import core/ids.{type OpId}
import core/message.{type AgentMessage}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import harness/model_facts.{
  type Fallback, type Lookup, Known, ReadsImages, TextOnly,
}
import harness/session_read
import harness/vision
import machine/operation
import machine/planner.{type RequestAdmission, Admitted}
import machine/strand.{type ModelIdentity, ModelIdentity}
import provider/gateway.{type Gateway}
import provider/image_budget
import provider/model.{type ResolvedModel}
import runtime/effects
import runtime/hooks
import session/session.{type Session}
import storage/storage

/// Admits one generation query against the model facts of the identity it
/// will reach.
///
/// An image-capable model keeps its route for every transcript, so that fact
/// is consulted first and only text-only admission pays for image projection.
///
/// ## Examples
///
/// ```gleam
/// // admission.admit(session, gateway, lookup, fallback, query)
/// // -> planner.Admitted(..)
/// ```
///
pub fn admit(
  opened: Session,
  provider_gateway: Gateway,
  lookup: Lookup,
  fallback: Fallback,
  query: effects.AdmissionQuery,
) -> RequestAdmission {
  let identity = query.configuration.model
  let facts = model_facts.of_identity(lookup, fallback, identity)

  // Route image-bearing requests for text-only models through vision.
  case
    facts.reading == TextOnly
    && image_bearing_projected(opened, query.operation)
  {
    False ->
      Admitted(
        stream_options: query.stream_options,
        intended_output_limit: facts.max_output_tokens,
        context_window: facts.context_window,
        api: facts.api,
      )
    True -> admit_through_vision(provider_gateway, lookup, fallback, query)
  }
}

/// Admits an image-bearing request through the resolved vision provider chain.
fn admit_through_vision(
  provider_gateway: Gateway,
  lookup: Lookup,
  fallback: Fallback,
  query: effects.AdmissionQuery,
) -> RequestAdmission {
  let identity = query.configuration.model

  // Resolve the vision chain model or fail with a no-route refusal.
  case gateway.resolve(provider_gateway, model.Vision) {
    Error(_missing) -> vision.no_route_refusal(identity)
    Ok(head) ->
      case lookup(identity_of(head)) {
        Ok(Known(reading: TextOnly, ..)) -> vision.blind_route_refusal(head)
        Ok(Known(reading: ReadsImages, ..)) | Error(Nil) -> {
          let head_facts =
            model_facts.of_identity(lookup, fallback, identity_of(head))
          Admitted(
            stream_options: query.stream_options,
            intended_output_limit: head_facts.max_output_tokens,
            context_window: head_facts.context_window,
            api: head_facts.api,
          )
        }
      }
  }
}

// The identity a resolved model dispatches to, back on the seam's own terms:
// the lookup is keyed by the durable identity shape.
fn identity_of(resolved: ResolvedModel) -> ModelIdentity {
  ModelIdentity(provider: resolved.provider, model_id: resolved.model_id)
}

/// Checks if the projected context for an operation's strand carries images.
fn image_bearing_projected(opened: Session, operation: OpId) -> Bool {
  case session_read.strand_of(opened, operation) {
    Error(Nil) -> False
    Ok(strand) ->
      image_bearing(opened, operation, hooks.project(opened, strand).messages)
  }
}

/// Whether the dispatcher sends this generation to the `vision` chain when its
/// identity reads only text.
///
/// The admitted prompt batch is immutable for the operation. It can contain an
/// image followed by a text instruction when held inputs are released
/// together. Keep that entire image-bearing run on vision, including tool and
/// run-end continuations. Later prompts keep vision while their projected
/// context retains images; compaction can discard them and return to text.
/// Context classification also covers image steers and legacy callers.
///
/// ## Examples
///
/// ```gleam
/// // admission.image_bearing(session, operation, context)
/// ```
///
pub fn image_bearing(
  opened: Session,
  operation: OpId,
  context: List(AgentMessage),
) -> Bool {
  vision.image_bearing(context)
  || admitted_image_bearing(opened, operation) |> result.unwrap(False)
}

/// Checks whether prompt entries admitted for the operation carry images.
fn admitted_image_bearing(
  session: Session,
  operation: OpId,
) -> Result(Bool, Nil) {
  use cell <- result.try(
    session.op_meta(session, operation) |> result.replace_error(Nil),
  )
  use cell <- result.try(option.to_result(cell, Nil))
  let meta = cell.value

  // Extract the latest prompt entry from the run intent.
  use last_prompt <- result.try(case meta.intent {
    operation.RunIntent(prompt_entries:) -> list.last(prompt_entries)
    operation.CompactionIntent(..) | operation.NavigationIntent(..) ->
      Error(Nil)
  })

  let scan = storage.branch_scan(last_prompt)

  // Bound the branch scan to the operation's source leaf when present.
  let scan = case meta.source_leaf {
    None -> scan
    Some(leaf) -> storage.branch_stop_at_id(scan, leaf)
  }

  use entries <- result.try(
    storage.scan_branch(session.store, scan) |> result.replace_error(Nil),
  )

  Ok(
    list.any(entries, fn(item) {
      case item {
        entry.MessageEntry(id:, message:, ..) ->
          Some(id) != meta.source_leaf && vision.image_bearing([message])
        entry.CompactionEntry(..)
        | entry.BranchSummaryEntry(..)
        | entry.CustomEntry(..) -> False
      }
    }),
  )
}

/// How many original user and tool-result images the operation's run holds
/// after its source leaf.
///
/// A held batch and its tool continuations belong to one admitted run, even
/// when its newest attributed prompt contains no images. Protect every image
/// since the immutable source leaf. Compaction preserves parent links, so the
/// walk goes through it and counts original messages once, never the copied
/// retained tail. Retained tails are contiguous suffixes: if compaction
/// removed current-run images, it also removed all older history. The
/// gateway's cap to the actual projected count then protects exactly the
/// surviving current-run images.
///
/// ## Examples
///
/// ```gleam
/// // admission.active_run_images(session, operation) == Ok(0)
/// ```
///
pub fn active_run_images(opened: Session, operation: OpId) -> Result(Int, Nil) {
  use cell <- result.try(
    session.op_meta(opened, operation) |> result.replace_error(Nil),
  )
  use cell <- result.try(option.to_result(cell, Nil))
  let meta = cell.value
  use leaf_cell <- result.try(
    session.strand_leaf(opened, meta.strand) |> result.replace_error(Nil),
  )
  use leaf_cell <- result.try(option.to_result(leaf_cell, Nil))
  use leaf <- result.try(option.to_result(leaf_cell.value, Nil))

  let scan = storage.branch_scan(leaf)

  // Stop scanning at the source leaf to bound active run entries.
  let scan = case meta.source_leaf {
    None -> scan
    Some(source) -> storage.branch_stop_at_id(scan, source)
  }

  use entries <- result.try(
    storage.scan_branch(opened.store, scan) |> result.replace_error(Nil),
  )

  entries
  |> list.filter_map(fn(item) {
    case item {
      entry.MessageEntry(id:, message:, ..) if Some(id) != meta.source_leaf ->
        Ok(message)
      entry.MessageEntry(..)
      | entry.CompactionEntry(..)
      | entry.BranchSummaryEntry(..)
      | entry.CustomEntry(..) -> Error(Nil)
    }
  })
  |> image_budget.count
  |> Ok
}
