//// Authenticated operator transitions for one session's evolution catalogue.
////
//// Authority and principal identity arrive from the native connection binding,
//// never from JSON. A session operator can mutate only this session; global
//// workspace skills and exact model profiles require the daemon owner.

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
    /// Native authority and identity precede untrusted action arguments.
    command: fn(access.Authority, String, String, json.JsonValue) ->
      Result(json.JsonValue, String),
  )
}

/// Creates the session-bound authenticated door.
///
/// ## Examples
///
/// ```gleam
/// // control.new(session_id, workspace, opener, owner, clock)
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
  Seam(command: fn(authority, principal, action, args) {
    use native <- result.try(authority_for(authority, session_id, workspace))
    use catalogue <- result.try(
      open(native)
      |> result.map_error(fn(error) {
        live.retain(owner, error)
        store.describe(error)
      }),
    )
    dispatch(
      catalogue,
      owner,
      transitions,
      clock,
      session_id,
      principal,
      action,
      args,
    )
  })
}

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

fn dispatch(
  catalogue: store.Store,
  owner: live.Live,
  transitions: queue.Queue,
  clock: Clock,
  session_id: String,
  principal: String,
  action: String,
  args: json.JsonValue,
) -> Result(json.JsonValue, String) {
  case action {
    "catalogue" -> {
      use items <- result.try(
        store.catalogue(catalogue)
        |> result.map_error(fn(error) {
          live.retain(owner, error)
          store.describe(error)
        }),
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
        |> result.map_error(fn(error) {
          live.retain(owner, error)
          store.describe(error)
        }),
      )
      page.envelope(
        record.evidence_string(id),
        record.encode_evidence(evidence),
        args,
      )
    }
    "status" -> status(catalogue, owner, transitions, args)
    "inspect" -> {
      use id <- result.try(candidate_arg(args))
      use candidate <- result.try(
        store.read_candidate(catalogue, id)
        |> result.map_error(fn(error) {
          live.retain(owner, error)
          store.describe(error)
        }),
      )
      page.envelope(
        record.id_string(id),
        record.encode_candidate(candidate),
        args,
      )
    }
    "approve" | "revoke" | "select" | "rollback" ->
      mutate(
        catalogue,
        owner,
        transitions,
        clock,
        session_id,
        principal,
        action,
        args,
      )
    _unknown -> Error("Unknown: unsupported evolution operator action")
  }
}

fn mutate(
  catalogue: store.Store,
  owner: live.Live,
  transitions: queue.Queue,
  clock: Clock,
  session_id: String,
  principal: String,
  action: String,
  args: json.JsonValue,
) -> Result(json.JsonValue, String) {
  use id <- result.try(candidate_arg(args))
  use candidate <- result.try(
    store.read_candidate(catalogue, id)
    |> result.map_error(fn(error) {
      live.retain(owner, error)
      store.describe(error)
    }),
  )
  case action {
    "revoke" -> {
      use reason <- result.try(tool.required_string(args, "reason"))
      use Nil <- result.try(
        store.revoke(catalogue, id, candidate.scope, principal, reason)
        |> result.map_error(fn(error) {
          live.retain(owner, error)
          store.describe(error)
        }),
      )
      Ok(json.Object([#("revoked", json.String(record.id_string(id)))]))
    }
    "approve" -> {
      use evidence <- result.try(evidence_arg(args))
      use Nil <- result.try(
        store.approve(catalogue, id, evidence, candidate.scope, principal)
        |> result.map_error(fn(error) {
          live.retain(owner, error)
          store.describe(error)
        }),
      )
      Ok(json.Object([#("approved", json.String(record.id_string(id)))]))
    }
    "select" | "rollback" ->
      selecting(
        catalogue,
        owner,
        transitions,
        clock,
        session_id,
        principal,
        candidate,
        args,
      )
    _unknown -> Error("Unknown: unsupported mutation")
  }
}

fn selecting(
  catalogue: store.Store,
  owner: live.Live,
  transitions: queue.Queue,
  clock: Clock,
  session_id: String,
  principal: String,
  candidate: record.Candidate,
  args: json.JsonValue,
) -> Result(json.JsonValue, String) {
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
    |> result.map_error(fn(error) {
      live.retain(owner, error)
      store.describe(error)
    }),
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
        catalogue,
        owner,
        transitions,
        clock,
        session_id,
        principal,
        candidate,
        args,
        evidence,
        expected_generation,
        reason,
        request_id,
      )
  }
}

fn select_pending(
  catalogue: store.Store,
  owner: live.Live,
  transitions: queue.Queue,
  clock: Clock,
  session_id: String,
  principal: String,
  candidate: record.Candidate,
  args: json.JsonValue,
  evidence: record.EvidenceId,
  expected_generation: Int,
  reason: String,
  request_id: String,
) -> Result(json.JsonValue, String) {
  use expected <- result.try(
    store.selected(catalogue, candidate.scope, candidate.name)
    |> result.map_error(fn(error) {
      live.retain(owner, error)
      store.describe(error)
    }),
  )
  let generation = case expected {
    None -> 0
    Some(selection) -> selection.generation
  }
  use Nil <- result.try(case generation == expected_generation {
    True -> Ok(Nil)
    False -> Error(store.describe(store.Stale))
  })
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
      use Nil <- result.try(case waiting > 0 && waiting <= 120_000 {
        True -> Ok(Nil)
        False -> Error("Bounds: deadline_ms must be 1..120000")
      })
      let #(now, _) = clock.read(clock)
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
        live.Transition(request_id, now + waiting, next, commit),
        signature,
      )
      |> result.map(queue_value)
    }
    record.Session(_), record.Extension ->
      Error("Authority: foreign session activation")
    _, _ ->
      commit()
      |> result.map(selection_value)
      |> result.map_error(fn(error) {
        live.retain(owner, error)
        store.describe(error)
      })
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

fn selection_value(selection: record.Selection) -> json.JsonValue {
  json.Object([
    #("candidate_id", json.String(record.id_string(selection.candidate_id))),
    #("generation", json.Int(selection.generation)),
    #("name", json.String(selection.name)),
    #("evidence_id", json.String(record.evidence_string(selection.evidence_id))),
  ])
}

fn status(
  catalogue: store.Store,
  owner: live.Live,
  transitions: queue.Queue,
  args: json.JsonValue,
) -> Result(json.JsonValue, String) {
  use request_id <- result.try(tool.optional_string(args, "request_id"))
  case request_id {
    None -> status_committed(catalogue, owner, None, args)
    Some(id) -> {
      use queued <- result.try(queue.poll(transitions, id))
      case queued {
        Some(queue.Queued(_) as status) | Some(queue.Running(_) as status) ->
          Ok(queue_value(status))
        Some(queue.Completed(_)) | Some(queue.Failed(_)) | None ->
          status_terminal(catalogue, owner, id, queued)
      }
    }
  }
}

// An in-flight request returns its actor receipt before borrowing SQLite.
// A terminal failure still checks the durable receipt first: a commit whose
// acknowledgement was lost must remain observable after later selections.
fn status_terminal(
  catalogue: store.Store,
  owner: live.Live,
  id: String,
  queued: option.Option(queue.Status),
) -> Result(json.JsonValue, String) {
  use committed <- result.try(
    store.receipt(catalogue, id)
    |> result.map_error(fn(error) {
      live.retain(owner, error)
      store.describe(error)
    }),
  )
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
    |> result.map_error(fn(error) {
      live.retain(owner, error)
      store.describe(error)
    }),
  )
  status_value(owner, selection)
}

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
