//// Model-facing evolution doors are origin-bound native capabilities.
//// Authors may propose, test and inspect exact source; only authenticated
//// operator controls hold catalogue approval and selection capabilities.

import client/evolution/candidate
import client/evolution/page
import client/evolution/record
import client/evolution/store
import client/extension/archive
import client/extension/manifest
import codemode/vet/package
import core/json as value
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tools/evolution as surface
import tools/tool

/// Connects stable model tools to native capture and evaluator capabilities.
///
/// A lookup receives the current Ctx so its authority is never reused from the
/// authoring session. Cleanup handling retains an unconfirmed retirement witness
/// in the native session owner before rendering the refusal for the model.
///
/// ## Examples
///
/// `door(lookup, origin, evaluate, invoke, failed)` registers all model doors.
pub fn door(
  lookup: fn(tool.Ctx) -> Result(store.Store, store.Refusal),
  origin: fn(tool.Ctx) -> record.Origin,
  evaluate: fn(tool.Ctx, store.Store, record.CandidateId, value.JsonValue) ->
    Result(record.Evidence, store.Refusal),
  invoke: fn(tool.Ctx, value.JsonValue) -> tool.ToolOutcome,
  failed: fn(store.Refusal) -> tool.ToolOutcome,
) -> surface.Door {
  door_over_model(
    lookup,
    origin,
    fn(_) { Error(store.Authority("current resolved model is unavailable")) },
    evaluate,
    invoke,
    failed,
  )
}

/// Enables exact-model authoring through a native provider-resolution callback.
///
/// Proposal JSON supplies text and source paths, while this callback alone
/// selects the admitted model. Approval and global selection remain owner-only.
///
/// ## Examples
///
/// `door_over_model(lookup,origin,current_model,evaluate,invoke,failed)` serves prompts.
pub fn door_over_model(
  lookup: fn(tool.Ctx) -> Result(store.Store, store.Refusal),
  origin: fn(tool.Ctx) -> record.Origin,
  current_model: fn(tool.Ctx) -> Result(record.ModelScope, store.Refusal),
  evaluate: fn(tool.Ctx, store.Store, record.CandidateId, value.JsonValue) ->
    Result(record.Evidence, store.Refusal),
  invoke: fn(tool.Ctx, value.JsonValue) -> tool.ToolOutcome,
  failed: fn(store.Refusal) -> tool.ToolOutcome,
) -> surface.Door {
  door_over_capture_model(
    lookup,
    origin,
    current_model,
    fn(_, _) {
      Error(store.Unavailable("jailed source capture is unavailable"))
    },
    evaluate,
    invoke,
    failed,
  )
}

/// Connects an owned jailed snapshotter before any candidate is retained.
///
/// The native owner bounds concurrent allocations and retains failed retirement
/// witnesses before returning a tool refusal. Evaluator arguments remain intact.
///
/// ## Examples
///
/// `door_over_capture_model(lookup,origin,current_model,snapshot,evaluate,invoke,failed)`
/// binds the production capture and test planes.
pub fn door_over_capture_model(
  lookup: fn(tool.Ctx) -> Result(store.Store, store.Refusal),
  origin: fn(tool.Ctx) -> record.Origin,
  current_model: fn(tool.Ctx) -> Result(record.ModelScope, store.Refusal),
  snapshot: fn(tool.Ctx, String) -> Result(archive.Tree, store.Refusal),
  evaluate: fn(tool.Ctx, store.Store, record.CandidateId, value.JsonValue) ->
    Result(record.Evidence, store.Refusal),
  invoke: fn(tool.Ctx, value.JsonValue) -> tool.ToolOutcome,
  failed: fn(store.Refusal) -> tool.ToolOutcome,
) -> surface.Door {
  surface.Door(
    propose: fn(ctx, args) {
      outcome(
        propose(lookup, origin, current_model, snapshot, ctx, args),
        failed,
      )
    },
    test_candidate: fn(ctx, args) {
      outcome(test_candidate(lookup, evaluate, ctx, args), failed)
    },
    inspect: fn(ctx, args) { outcome(inspect(lookup, ctx, args), failed) },
    catalogue: fn(ctx, args) { outcome(catalogue(lookup, ctx, args), failed) },
    invoke:,
  )
}

fn propose(
  lookup: fn(tool.Ctx) -> Result(store.Store, store.Refusal),
  origin: fn(tool.Ctx) -> record.Origin,
  current_model: fn(tool.Ctx) -> Result(record.ModelScope, store.Refusal),
  snapshot: fn(tool.Ctx, String) -> Result(archive.Tree, store.Refusal),
  ctx: tool.Ctx,
  args: value.JsonValue,
) -> Result(value.JsonValue, store.Refusal) {
  use store <- result.try(lookup(ctx))
  use directory <- result.try(
    tool.required_string(args, "directory") |> result.map_error(store.Authority),
  )
  use name <- result.try(
    tool.required_string(args, "name") |> result.map_error(store.Authority),
  )
  use kind <- result.try(
    tool.required_string(args, "kind") |> result.map_error(store.Authority),
  )
  use kind <- result.try(case kind {
    "extension" -> Ok(record.Extension)
    "program" -> Ok(record.Program)
    "prompt" -> Ok(record.Prompt)
    _ -> Error(store.Authority("CoreChangeRequired: unknown artifact boundary"))
  })
  use test_entry <- result.try(
    tool.optional_string(args, "test_entry")
    |> result.map_error(store.Authority),
  )
  use description <- result.try(
    tool.optional_string(args, "description")
    |> result.map_error(store.Authority),
  )
  use schema <- result.try(
    tool.optional_string(args, "input_schema")
    |> result.map_error(store.Authority),
  )
  let provenance = origin(ctx)
  use #(store, scope) <- result.try(case kind {
    record.Prompt -> {
      use target <- result.try(current_model(ctx))
      use admitted <- result.try(store.model_author(store, target))
      Ok(#(admitted, record.ExactModel(target)))
    }
    record.Extension -> Ok(#(store, record.Session(provenance.session_id)))
    record.Program -> Ok(#(store, record.Workspace(provenance.workspace)))
  })
  let proposal =
    candidate.Proposal(
      directory:,
      name:,
      kind:,
      scope:,
      test_entry:,
      description: option_text(description),
      input_schema: case kind, schema {
        record.Program, None -> "{}"
        _, schema -> option_text(schema)
      },
    )
  use candidate <- result.try(candidate.capture_with(
    store,
    proposal,
    provenance,
    ctx,
    snapshot,
  ))
  Ok(proposal_json(candidate))
}

fn test_candidate(
  lookup: fn(tool.Ctx) -> Result(store.Store, store.Refusal),
  evaluate: fn(tool.Ctx, store.Store, record.CandidateId, value.JsonValue) ->
    Result(record.Evidence, store.Refusal),
  ctx: tool.Ctx,
  args: value.JsonValue,
) -> Result(value.JsonValue, store.Refusal) {
  use catalogue <- result.try(lookup(ctx))
  use id <- result.try(request_id(args))
  use evidence <- result.try(evaluate(ctx, catalogue, id, args))
  page.envelope(
    record.evidence_string(evidence.id),
    value.to_string(evidence_json(evidence)),
    args,
  )
  |> result.map_error(store.Bounds)
}

fn inspect(
  lookup: fn(tool.Ctx) -> Result(store.Store, store.Refusal),
  ctx: tool.Ctx,
  args: value.JsonValue,
) -> Result(value.JsonValue, store.Refusal) {
  use catalogue <- result.try(lookup(ctx))
  use evidence_id <- result.try(
    tool.optional_string(args, "evidence_id")
    |> result.map_error(store.Authority),
  )
  case evidence_id {
    Some(id) -> {
      use id <- result.try(
        record.evidence_id(id) |> result.map_error(store.Authority),
      )
      use evidence <- result.try(store.read_evidence(catalogue, id))
      page.envelope(
        record.evidence_string(id),
        value.to_string(evidence_json(evidence)),
        args,
      )
      |> result.map_error(store.Bounds)
    }
    None -> {
      use id <- result.try(request_id(args))
      use candidate <- result.try(store.read_candidate(catalogue, id))
      page.envelope(
        record.id_string(candidate.id),
        value.to_string(candidate_json(candidate)),
        args,
      )
      |> result.map_error(store.Bounds)
    }
  }
}

fn catalogue(
  lookup: fn(tool.Ctx) -> Result(store.Store, store.Refusal),
  ctx: tool.Ctx,
  args: value.JsonValue,
) -> Result(value.JsonValue, store.Refusal) {
  use catalogue <- result.try(lookup(ctx))
  use values <- result.try(catalogue_values(catalogue))
  catalogue_page(values, args)
}

/// Verified candidate metadata and currently authorized callable contracts.
pub type CatalogueValues {
  CatalogueValues(
    /// Immutable visible candidate identities and applicability.
    candidates: List(value.JsonValue),
    /// Complete callable schemas with exact identity and generation.
    active: List(value.JsonValue),
  )
}

/// Reads visible records once for native discovery composition.
///
/// ## Examples
///
/// `catalogue_values(store)` allows a host to add its active tool contracts.
pub fn catalogue_values(
  catalogue: store.Store,
) -> Result(CatalogueValues, store.Refusal) {
  use candidates <- result.try(store.catalogue(catalogue))
  use entries <- result.try(
    list.try_map(candidates, fn(candidate) {
      use selected <- result.try(case candidate.scope {
        record.ExactModel(_) -> Ok(None)
        record.Session(_) | record.Workspace(_) ->
          store.selected(catalogue, candidate.scope, candidate.name)
      })
      Ok(case selected {
        Some(selection) ->
          value.Object([
            #("candidate", catalogue_json(candidate)),
            #(
              "selected_id",
              value.String(record.id_string(selection.candidate_id)),
            ),
            #("generation", value.Int(selection.generation)),
          ])
        None ->
          value.Object([
            #("candidate", catalogue_json(candidate)),
            #("selected_id", value.Null),
          ])
      })
    }),
  )
  use active <- result.try(
    list.try_map(candidates, fn(candidate) {
      active_entries(catalogue, candidate)
    }),
  )
  Ok(CatalogueValues(entries, list.flatten(active)))
}

/// Pages both native discovery streams within one bounded result envelope.
///
/// ## Examples
///
/// `catalogue_page(values,args)` retains separate continuation offsets.
pub fn catalogue_page(
  values: CatalogueValues,
  args: value.JsonValue,
) -> Result(value.JsonValue, store.Refusal) {
  use active <- result.try(
    page.items(values.active, args, 23_552)
    |> result.map_error(store.Bounds),
  )
  use candidate_offset <- result.try(
    tool.optional_int(args, "candidate_offset")
    |> result.map_error(store.Bounds),
  )
  use count <- result.try(
    tool.optional_int(args, "count")
    |> result.map_error(store.Bounds),
  )
  let candidate_args =
    value.Object([
      #("offset", case candidate_offset {
        Some(offset) -> value.Int(offset)
        None -> value.Int(0)
      }),
      #("count", case count {
        Some(count) -> value.Int(count)
        None -> value.Int(8)
      }),
    ])
  use entries <- result.try(
    page.items(values.candidates, candidate_args, 7168)
    |> result.map_error(store.Bounds),
  )
  Ok(
    value.Object([
      #("candidates", value.Array(entries.values)),
      #("active", value.Array(active.values)),
      #("offset", value.Int(active.offset)),
      #("next_offset", page.offset_json(active.next_offset)),
      #("candidate_offset", value.Int(entries.offset)),
      #("next_candidate_offset", page.offset_json(entries.next_offset)),
    ]),
  )
}

fn active_entries(
  catalogue: store.Store,
  candidate: record.Candidate,
) -> Result(List(value.JsonValue), store.Refusal) {
  use selected <- result.try(case candidate.scope {
    record.ExactModel(_) -> Ok(None)
    record.Session(_) | record.Workspace(_) ->
      store.selected(catalogue, candidate.scope, candidate.name)
  })
  case selected {
    None -> Ok([])
    Some(selection) ->
      case selection.candidate_id == candidate.id {
        False -> Ok([])
        True -> advertised(catalogue, candidate, selection)
      }
  }
}

fn advertised(
  catalogue: store.Store,
  candidate: record.Candidate,
  selection: record.Selection,
) -> Result(List(value.JsonValue), store.Refusal) {
  case store.authorized(catalogue, selection) {
    Ok(_) -> callable_entries(candidate, selection.generation)
    Error(store.NotApproved) | Error(store.Stale) | Error(store.Changed) ->
      Ok([])
    Error(refusal) -> Error(refusal)
  }
}

fn callable_entries(
  candidate: record.Candidate,
  generation: Int,
) -> Result(List(value.JsonValue), store.Refusal) {
  case candidate.kind {
    record.Prompt -> Ok([])
    record.Program -> {
      use schema <- result.try(
        value.parse(candidate.input_schema)
        |> result.replace_error(store.Corrupt(
          "skill input schema is invalid JSON",
        )),
      )
      Ok([
        callable_json(
          candidate,
          generation,
          candidate.name,
          candidate.description,
          schema,
        ),
      ])
    }
    record.Extension -> {
      use text <- result.try(
        list.key_find(candidate.files, "extension.toml")
        |> result.replace_error(store.Corrupt("selected manifest is absent")),
      )
      use decoded <- result.try(
        manifest.decode(
          text,
          manifest.Surroundings(
            files: candidate.files,
            modules: package.module_names_of(candidate.files),
          ),
        )
        |> result.map_error(store.Corrupt),
      )
      list.try_map(decoded.tools, fn(declared) {
        use text <- result.try(
          list.key_find(candidate.files, declared.parameters)
          |> result.replace_error(store.Corrupt("selected schema is absent")),
        )
        use schema <- result.try(
          value.parse(text)
          |> result.replace_error(store.Corrupt(
            "selected schema is invalid JSON",
          )),
        )
        let descriptor =
          callable_json(
            candidate,
            generation,
            declared.name,
            declared.description,
            schema,
          )
        case string.byte_size(value.to_string(descriptor)) <= 23_549 {
          True -> Ok(descriptor)
          False ->
            Error(store.Bounds(
              "complete callable descriptor exceeds discovery budget",
            ))
        }
      })
    }
  }
}

fn callable_json(
  candidate: record.Candidate,
  generation: Int,
  name: String,
  description: String,
  schema: value.JsonValue,
) -> value.JsonValue {
  value.Object([
    #("candidate_id", value.String(record.id_string(candidate.id))),
    #("generation", value.Int(generation)),
    #("name", value.String(name)),
    #("description", value.String(description)),
    #("schema", schema),
  ])
}

fn catalogue_json(candidate: record.Candidate) -> value.JsonValue {
  value.Object([
    #("candidate_id", value.String(record.id_string(candidate.id))),
    #("name", value.String(candidate.name)),
    #(
      "kind",
      value.String(case candidate.kind {
        record.Extension -> "extension"
        record.Program -> "program"
        record.Prompt -> "prompt"
      }),
    ),
    #("scope", value.String(record.scope_key(candidate.scope))),
  ])
}

fn evidence_json(evidence: record.Evidence) -> value.JsonValue {
  value.Object([
    #("candidate_id", value.String(record.id_string(evidence.candidate_id))),
    #("evidence_id", value.String(record.evidence_string(evidence.id))),
    #("evidence", value.String(record.encode_evidence(evidence))),
  ])
}

fn proposal_json(candidate: record.Candidate) -> value.JsonValue {
  value.Object([
    #("candidate_id", value.String(record.id_string(candidate.id))),
    #("name", value.String(candidate.name)),
    #(
      "kind",
      value.String(case candidate.kind {
        record.Extension -> "extension"
        record.Program -> "program"
        record.Prompt -> "prompt"
      }),
    ),
    #("scope", value.String(record.scope_key(candidate.scope))),
    #(
      "identity",
      value.Object([
        #("build", value.String(candidate.identity.build)),
        #("seam", value.String(candidate.identity.seam)),
        #("evaluator", value.String(candidate.identity.evaluator)),
      ]),
    ),
    #(
      "origin",
      value.Object([
        #("session_id", value.String(candidate.origin.session_id)),
        #("strand", value.String(candidate.origin.strand)),
        #("workspace", value.String(candidate.origin.workspace)),
      ]),
    ),
  ])
}

fn candidate_json(candidate: record.Candidate) -> value.JsonValue {
  value.Object([
    #("candidate_id", value.String(record.id_string(candidate.id))),
    #("name", value.String(candidate.name)),
    #("envelope", value.String(record.encode_candidate(candidate))),
  ])
}

fn request_id(
  args: value.JsonValue,
) -> Result(record.CandidateId, store.Refusal) {
  use text <- result.try(
    tool.required_string(args, "candidate_id")
    |> result.map_error(store.Authority),
  )
  record.candidate_id(text) |> result.map_error(store.Corrupt)
}

fn option_text(text: Option(String)) -> String {
  case text {
    None -> ""
    Some(text) -> text
  }
}

fn outcome(
  result: Result(value.JsonValue, store.Refusal),
  failed: fn(store.Refusal) -> tool.ToolOutcome,
) -> tool.ToolOutcome {
  case result {
    Ok(value) -> tool.with_details(tool.success(value.to_string(value)), value)
    Error(refusal) -> failed(refusal)
  }
}
