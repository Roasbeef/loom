//// Authenticated operator transitions for one session's evolution catalogue.
////
//// Authority and principal identity arrive from the native connection binding,
//// never from JSON. A session operator can mutate only this session; global
//// workspace skills and exact model profiles require the daemon owner.
////
//// The read actions (`catalogue`, `evidence`, `inspect`, `status`) return
//// bounded pages, and `board` returns the whole panel in one bounded answer
//// (`board`, protocol-change/099). The mutating actions (`approve`, `revoke`,
//// `select`, `rollback`) each name a candidate. A selection of this session's own
//// extension is checked against its durable receipt and then runs through the
//// live owner's transition queue. An extension selection scoped to another
//// session is refused with `Authority: foreign session activation` and is not
//// committed. Any other selection commits directly, because it changes
//// discovery for new sessions and not a running one.

import client/evolution/board
import client/evolution/live
import client/evolution/page
import client/evolution/queue
import client/evolution/record
import client/evolution/store
import core/clock.{type Clock}
import core/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import storage/access
import tools/tool

/// The operator door the authenticated gateway fills with its binding.
pub type Seam {
  Seam(
    /// Native authority, identity and surface precede untrusted action
    /// arguments. The surface is recorded in the audit entry and decides
    /// nothing.
    command: fn(access.Authority, String, store.Via, String, json.JsonValue) ->
      Result(json.JsonValue, String),
  )
}

/// The authority an authenticated connection exercises on this door.
///
/// A page never attaches as `Owner` (051), so the owner's own page arrives as
/// an operator, and the store would refuse it the workspace and exact-model
/// rows the owner can see and approve from a terminal. The door therefore
/// derives authority from the principal's kind, as the gateway does for the
/// commands only the owner may send (073). Three limits keep it narrow:
///
/// - Only an operator is raised. An observer, which is a cap the owner chose
///   or a role the membership holds, keeps reading as a caller.
/// - Only the owner's principal is raised. A member stays an operator, so the
///   store still confines it to this session's own scope.
/// - The reviewed harness upgrade is never raised. It stays with an
///   attachment that is the owner by role, which is a terminal and not a page.
///
/// ## Examples
///
/// ```gleam
/// // for_principal(
/// //   access.Participant(access.Operator),
/// //   access.OwnerPrincipal,
/// //   "approve",
/// // ) == access.Owner
/// ```
pub fn for_principal(
  authority: access.Authority,
  kind: access.PrincipalKind,
  action: String,
) -> access.Authority {
  case authority, kind {
    access.Participant(access.Operator), access.OwnerPrincipal ->
      case action {
        "core_upgrade" | "core_downgrade" -> authority
        _other -> access.Owner
      }
    access.Participant(access.Operator), access.MemberPrincipal
    | access.Participant(access.Observer), _
    | access.Owner, _
    -> authority
  }
}

/// Creates the session-bound authenticated door.
///
/// ## Examples
///
/// ```gleam
/// // control.new(session_id, workspace, opener, owner, transitions, clock)
/// ```
///
pub fn new(
  session_id: String,
  workspace: String,
  open: fn(store.Authority) -> Result(store.Store, store.Refusal),
  owner: live.Live,
  transitions: queue.Queue,
  clock: Clock,
) -> Seam {
  Seam(command: fn(authority, principal, via, action, args) {
    use native <- result.try(authority_for(authority, session_id, workspace))
    use catalogue <- result.try(
      open(native)
      |> result.map(store.with_via(_, via))
      |> result.map_error(retained(owner)),
    )
    dispatch(
      Bound(catalogue:, owner:, transitions:, clock:, session_id:, principal:),
      action,
      args,
    )
  })
}

// The values every operator action needs, bound once per command: the
// catalogue opened for this caller's authority, the session's live owner and
// transition queue, and the authenticated principal. Actions take this and
// their own arguments, instead of repeating six parameters at each hop.
type Bound {
  Bound(
    catalogue: store.Store,
    owner: live.Live,
    transitions: queue.Queue,
    clock: Clock,
    session_id: String,
    principal: String,
  )
}

// Every catalogue refusal on this door first hands any cleanup authority it
// carries to the live owner, so a retry is not lost when the error is worded
// for the operator.
fn retained(owner: live.Live) -> fn(store.Refusal) -> String {
  fn(error) {
    live.retain(owner, error)
    store.describe(error)
  }
}

/// Wraps a door so that a committed mutation tells subscribers.
///
/// A mutation answers `Ok` only once its commit is durable, so the hint cannot
/// overtake the write it announces and a reader woken by it finds the new state.
/// A selection staged through the queue answers `queued` before it commits. The
/// queue announces that commit itself when the request ends, so a board is told
/// twice for one staged selection and draws the pending request first and its
/// outcome second. A refused mutation and every read announce nothing.
///
/// ## Examples
///
/// ```gleam
/// // control.announcing(seam, fn() { publish_evolution_changed() })
/// ```
pub fn announcing(seam: Seam, announce: fn() -> Nil) -> Seam {
  let command = seam.command
  Seam(command: fn(authority, principal, via, action, args) {
    let outcome = command(authority, principal, via, action, args)

    // Notify listeners when an evolution state mutation succeeds.
    case action, outcome {
      "approve", Ok(_)
      | "revoke", Ok(_)
      | "select", Ok(_)
      | "rollback", Ok(_)
      -> announce()
      _, _ -> Nil
    }

    outcome
  })
}

/// Maps client access authority into the corresponding evolution store authority scope.
fn authority_for(
  authority: access.Authority,
  session_id: String,
  workspace: String,
) -> Result(store.Authority, String) {
  case authority {
    access.Owner -> Ok(store.Owner)
    access.Participant(access.Operator) ->
      Ok(store.SessionOperator(session_id, workspace))
    access.Participant(access.Observer) ->
      Ok(store.Caller(session_id, workspace))
  }
}

/// Dispatches incoming evolution control actions to queries or mutations.
fn dispatch(
  bound: Bound,
  action: String,
  args: json.JsonValue,
) -> Result(json.JsonValue, String) {
  let Bound(catalogue:, owner:, transitions:, ..) = bound

  // Dispatch the requested control command action.
  case action {
    "catalogue" -> {
      use items <- result.try(
        store.catalogue(catalogue)
        |> result.map_error(retained(owner)),
      )
      let values =
        list.map(items, fn(candidate) {
          json.Object([
            #("candidate_id", json.String(record.id_string(candidate.id))),
            #("name", json.String(candidate.name)),
            #("description", json.String(candidate.description)),
          ])
        })
      page.items(values, args, 30_720) |> result.map(page.items_json)
    }

    "evidence" -> {
      use id <- result.try(evidence_arg(args))
      use evidence <- result.try(
        store.read_evidence(catalogue, id)
        |> result.map_error(retained(owner)),
      )
      page.envelope(
        record.evidence_string(id),
        record.encode_evidence(evidence),
        args,
      )
    }
    "status" -> status(catalogue, owner, transitions, args)
    "board" -> board(bound)
    "inspect" -> {
      use id <- result.try(candidate_arg(args))
      use candidate <- result.try(
        store.read_candidate(catalogue, id)
        |> result.map_error(retained(owner)),
      )
      page.envelope(
        record.id_string(id),
        record.encode_candidate(candidate),
        args,
      )
    }
    "approve" | "revoke" | "select" | "rollback" -> mutate(bound, action, args)
    _unknown -> Error("Unknown: unsupported evolution operator action")
  }
}

// The whole panel in one reply. The catalogue read is one lease, so the rows,
// selections and journal agree with each other. The live generation and the
/// Assembles the current evolution dashboard snapshot including catalog rows, active
/// published selections, and pending queue transitions.
fn board(bound: Bound) -> Result(json.JsonValue, String) {
  let Bound(catalogue:, owner:, transitions:, session_id:, ..) = bound
  use read <- result.try(
    store.read_board(catalogue)
    |> result.map_error(retained(owner)),
  )
  use waiting <- result.try(queue.pending(transitions))

  // A refused catalogue read already left its cleanup witness with `live`, so
  // it is drawn as nothing running and is not registered a second time.
  let published = case live.catalogue(owner) {
    Ok(Some(generation)) ->
      Some(board.Published(
        selection: generation.selection,
        inventory: result.unwrap(generation.inventory(), json.Null),
      ))
    Ok(None) | Error(_) -> None
  }

  Ok(
    board.value(board.Input(
      session_id:,
      identity: store.identity(catalogue),
      board: read,
      published:,
      waiting:,
    )),
  )
}

/// Executes state-mutating actions such as approval, revocation, selection, or rollback.
fn mutate(
  bound: Bound,
  action: String,
  args: json.JsonValue,
) -> Result(json.JsonValue, String) {
  let Bound(catalogue:, owner:, principal:, ..) = bound
  use id <- result.try(candidate_arg(args))
  use candidate <- result.try(
    store.read_candidate(catalogue, id)
    |> result.map_error(retained(owner)),
  )

  // Dispatch the mutation action on the verified candidate record.
  case action {
    "revoke" -> {
      use reason <- result.try(tool.required_string(args, "reason"))
      use Nil <- result.try(
        store.revoke(catalogue, id, candidate.scope, principal, reason)
        |> result.map_error(retained(owner)),
      )
      Ok(json.Object([#("revoked", json.String(record.id_string(id)))]))
    }
    "approve" -> {
      use evidence <- result.try(evidence_arg(args))
      use Nil <- result.try(
        store.approve(catalogue, id, evidence, candidate.scope, principal)
        |> result.map_error(retained(owner)),
      )
      Ok(json.Object([#("approved", json.String(record.id_string(id)))]))
    }
    "select" | "rollback" -> selecting(bound, candidate, args)
    _unknown -> Error("Unknown: unsupported mutation")
  }
}

/// Initiates candidate selection by validating evidence and checking generation concurrency.
fn selecting(
  bound: Bound,
  candidate: record.Candidate,
  args: json.JsonValue,
) -> Result(json.JsonValue, String) {
  let Bound(catalogue:, owner:, principal:, ..) = bound
  use evidence <- result.try(evidence_arg(args))
  use expected_generation <- result.try(
    tool.optional_int(args, "expected_generation")
    |> result.map(option.unwrap(_, 0)),
  )
  use reason <- result.try(tool.required_string(args, "reason"))
  use request_id <- result.try(tool.required_string(args, "request_id"))
  use receipt <- result.try(
    store.request_receipt(
      catalogue,
      candidate.id,
      evidence,
      candidate.scope,
      candidate.name,
      expected_generation,
      principal,
      reason,
      request_id,
    )
    |> result.map_error(retained(owner)),
  )

  // Durable acknowledgements precede the live queue, whose bounded memory can
  // have forgotten a request after restart or eviction. No retry restages it.
  case receipt {
    Some(selection) ->
      Ok(case candidate.kind, candidate.scope {
        record.Extension, record.Session(_) ->
          json.Object([
            #("state", json.String("committed")),
            #("request_id", json.String(request_id)),
            #("committed", selection_value(selection)),
          ])
        _, _ -> selection_value(selection)
      })
    None ->
      select_pending(
        bound,
        candidate,
        args,
        Request(evidence:, expected_generation:, reason:, request_id:),
      )
  }
}

// The operator's arguments for one selection, parsed once by `selecting`.
type Request {
  Request(
    evidence: record.EvidenceId,
    expected_generation: Int,
    reason: String,
    request_id: String,
  )
}

// A selection with no durable receipt yet. The commit closures are built from
// plain local values rather than from `bound`, so a queued transition keeps
// only what it reads and not the whole door.
/// Queues and commits a candidate selection, performing live reload transitions if needed.
fn select_pending(
  bound: Bound,
  candidate: record.Candidate,
  args: json.JsonValue,
  request: Request,
) -> Result(json.JsonValue, String) {
  // Extract caller credentials and verify current selection generation.
  let Bound(catalogue:, owner:, transitions:, clock:, session_id:, principal:) =
    bound
  let Request(evidence:, expected_generation:, reason:, request_id:) = request
  use expected <- result.try(
    store.selected(catalogue, candidate.scope, candidate.name)
    |> result.map_error(retained(owner)),
  )

  // Read current generation from selection or default to 0 for unselected candidates.
  let generation = case expected {
    None -> 0
    Some(selection) -> selection.generation
  }

  // Ensure the caller's expected generation matches the current stored generation.
  use Nil <- result.try(case generation == expected_generation {
    True -> Ok(Nil)
    False -> Error(store.describe(store.Stale))
  })

  // Build the commit closure and dispatch transition.
  let candidate_id = candidate.id
  let scope = candidate.scope
  let name = candidate.name
  let commit = fn() {
    store.select_request(
      catalogue,
      candidate_id,
      evidence,
      scope,
      name,
      expected,
      principal,
      reason,
      request_id,
    )
  }

  // Global selection changes discovery for new sessions. Only this session's
  // executable selection crosses its live native-retirement boundary here.
  case candidate.scope, candidate.kind {
    record.Session(id), record.Extension if id == session_id -> {
      use waiting <- result.try(
        tool.optional_int(args, "deadline_ms")
        |> result.map(option.unwrap(_, 60_000)),
      )

      // Validate the transition timeout deadline bounds.
      use Nil <- result.try(case waiting > 0 && waiting <= 120_000 {
        True -> Ok(Nil)
        False -> Error("Bounds: deadline_ms must be 1..120000")
      })

      // Calculate execution deadline bounds and construct commit closure.
      let #(now, _) = clock.read(clock)
      let expires_at = now + waiting
      let commit = fn() {
        store.select_request_admitted(
          catalogue,
          candidate_id,
          evidence,
          scope,
          name,
          expected,
          principal,
          reason,
          request_id,
          fn() {
            let #(at, _) = clock.read(clock)

            // Confirm that admission occurs before the transition deadline expires.
            case at < expires_at {
              True -> Ok(Nil)
              False -> Error(store.Busy)
            }
          },
        )
      }

      // Prepare selection record and queue transition with state machine.
      let next =
        record.Selection(
          candidate.id,
          evidence,
          candidate.scope,
          candidate.name,
          expected_generation + 1,
        )
      let signature =
        json.to_string(
          json.Object([
            #("candidate_id", json.String(record.id_string(candidate.id))),
            #("evidence_id", json.String(record.evidence_string(evidence))),
            #("expected_generation", json.Int(expected_generation)),
            #("principal", json.String(principal)),
            #("reason", json.String(reason)),
          ]),
        )
      queue.enqueue(
        transitions,
        live.Transition(request_id, expires_at, next, commit, fn() {
          store.request_receipt(
            catalogue,
            candidate_id,
            evidence,
            scope,
            name,
            expected_generation,
            principal,
            reason,
            request_id,
          )
        }),
        signature,
      )
      |> result.map(queue_value)
    }
    record.Session(_), record.Extension ->
      Error("Authority: foreign session activation")
    _, _ ->
      commit()
      |> result.map(selection_value)
      |> result.map_error(retained(owner))
  }
}

fn candidate_arg(args: json.JsonValue) -> Result(record.CandidateId, String) {
  use text <- result.try(tool.required_string(args, "candidate_id"))
  record.candidate_id(text)
}

fn evidence_arg(args: json.JsonValue) -> Result(record.EvidenceId, String) {
  use text <- result.try(tool.required_string(args, "evidence_id"))
  record.evidence_id(text)
}

/// Formats candidate selection identity and generation metadata into JSON.
fn selection_value(selection: record.Selection) -> json.JsonValue {
  json.Object([
    #("candidate_id", json.String(record.id_string(selection.candidate_id))),
    #("generation", json.Int(selection.generation)),
    #("name", json.String(selection.name)),
    #("evidence_id", json.String(record.evidence_string(selection.evidence_id))),
  ])
}

/// Queries the progress or outcome of a requested candidate transition.
fn status(
  catalogue: store.Store,
  owner: live.Live,
  transitions: queue.Queue,
  args: json.JsonValue,
) -> Result(json.JsonValue, String) {
  use request_id <- result.try(tool.optional_string(args, "request_id"))

  // Check status by specific request id or inspect current committed selection.
  case request_id {
    None -> status_committed(catalogue, owner, None, args)
    Some(id) -> {
      use queued <- result.try(queue.poll(transitions, id))

      // Check whether transition is still in-flight or has settled into a terminal state.
      case queued {
        Some(queue.Queued(_) as status) | Some(queue.Running(_) as status) ->
          Ok(queue_value(status))
        Some(queue.Completed(_)) | Some(queue.Failed(_)) | None ->
          status_terminal(catalogue, owner, id, queued)
      }
    }
  }
}

/// Resolves terminal status by cross-referencing durable receipts with queue status records.
fn status_terminal(
  catalogue: store.Store,
  owner: live.Live,
  id: String,
  queued: option.Option(queue.Status),
) -> Result(json.JsonValue, String) {
  use committed <- result.try(
    store.receipt(catalogue, id)
    |> result.map_error(retained(owner)),
  )

  // Correlate committed receipt with terminal queue status.
  case committed, queued {
    Some(selection), _ -> status_value(owner, Some(selection))
    None, Some(status) -> Ok(queue_value(status))
    None, None ->
      Ok(
        json.Object([
          #("state", json.String("unknown")),
          #("request_id", json.String(id)),
        ]),
      )
  }
}

/// Looks up committed selection status for a candidate within its resolved scope.
fn status_committed(
  catalogue: store.Store,
  owner: live.Live,
  request_id: option.Option(String),
  args: json.JsonValue,
) -> Result(json.JsonValue, String) {
  use selection <- result.try(
    case request_id {
      Some(id) -> store.receipt(catalogue, id)
      None -> {
        use id <- result.try(
          candidate_arg(args) |> result.map_error(store.Authority),
        )
        use candidate <- result.try(store.read_candidate(catalogue, id))
        store.selected(catalogue, candidate.scope, candidate.name)
      }
    }
    |> result.map_error(retained(owner)),
  )
  status_value(owner, selection)
}

/// Formats the active or historical selection status into a detailed JSON response.
fn status_value(
  owner: live.Live,
  selection: option.Option(record.Selection),
) -> Result(json.JsonValue, String) {
  let active = live.catalogue(owner)

  // Catalogue refusals already remain in Live's custody; rendering status
  // cannot register a second retry of that same native retirement.
  let published = result.unwrap(active, None)

  Ok(
    json.Object([
      #(
        "state",
        json.String(case active {
          Ok(_) -> "completed"
          Error(_) -> "committed"
        }),
      ),
      #("committed", case selection {
        None -> json.Null
        Some(one) -> selection_value(one)
      }),
      #("inventory", case published {
        None -> json.Null
        Some(one) -> result.unwrap(one.inventory(), json.Null)
      }),
      #("published", case published {
        None -> json.Null
        Some(one) -> selection_value(one.selection)
      }),
    ]),
  )
}

/// Formats queue status variants into JSON representation.
fn queue_value(status: queue.Status) -> json.JsonValue {
  case status {
    queue.Queued(id) ->
      json.Object([
        #("state", json.String("queued")),
        #("request_id", json.String(id)),
      ])
    queue.Running(id) ->
      json.Object([
        #("state", json.String("running")),
        #("request_id", json.String(id)),
      ])
    queue.Completed(selection) ->
      json.Object([
        #("state", json.String("completed")),
        #("committed", selection_value(selection)),
      ])
    queue.Failed(reason) ->
      json.Object([
        #("state", json.String("failed")),
        #("reason", json.String(reason)),
      ])
  }
}
