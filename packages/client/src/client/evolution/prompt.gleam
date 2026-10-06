//// Prompt candidates use the catalogue's immutable source identity and approvals.
////
//// A candidate's `prompt.json` declares additions to one exact model's system
//// prompt, task instruction and tool descriptions. The ordinary generated
//// system prompt and callable schemas remain the base. Selection is read only
//// at new-session boot; `system_prompt` pins this bounded map beside its existing
//// prompt pin. A resume decodes those same bytes and never rereads selection.

import client/evolution/record
import client/evolution/store
import client/mcp
import core/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import provider/model
import provider/profile.{type Profile}

/// Decodes immutable candidate bytes, assigning the catalogue identity.
/// Unknown fields, malformed prose or a scope mismatch refuse adoption.
///
/// ## Examples
///
/// ```gleam
/// // prompt.candidate_profile(candidate)
/// ```
pub fn candidate_profile(
  candidate: record.Candidate,
) -> Result(Profile, String) {
  use target <- result.try(case candidate.kind, candidate.scope {
    record.Prompt, record.ExactModel(target) -> Ok(target)
    _, _ -> Error("a prompt profile requires an exact model scope")
  })
  use source <- result.try(
    list.key_find(candidate.files, "prompt.json")
    |> result.map_error(fn(_) { "prompt.json is absent" }),
  )
  use value <- result.try(
    json.parse(source) |> result.map_error(fn(_) { "prompt.json is malformed" }),
  )
  use parsed <- result.try(decode_profile(
    value,
    record.id_string(candidate.id),
    7,
  ))
  let #(_, provider, model_id, api, _, _, _) = profile.fields(parsed)
  case
    provider == target.provider && model_id == target.model && api == target.api
  {
    True -> Ok(parsed)
    False -> Error("prompt.json does not match its approved exact model scope")
  }
}

/// Reads only currently selected prompt candidates through native store authority.
/// Duplicate exact targets refuse rather than make selection depend on scan order.
///
/// ## Examples
///
/// ```gleam
/// // prompt.selected(catalogue)
/// ```
pub fn selected(catalogue: store.Store) -> Result(List(Profile), String) {
  use candidates <- result.try(
    store.catalogue(catalogue)
    |> result.map_error(fn(_) { "the prompt catalogue is unreadable" }),
  )
  use profiles <- result.try(
    list.try_fold(candidates, [], fn(profiles, candidate) {
      selected_candidate(catalogue, candidate, profiles)
    }),
  )
  profile.validate_map(list.reverse(profiles))
}

fn selected_candidate(
  catalogue: store.Store,
  candidate: record.Candidate,
  profiles: List(Profile),
) -> Result(List(Profile), String) {
  case candidate.kind {
    record.Extension | record.Program -> Ok(profiles)
    record.Prompt -> {
      use selected <- result.try(
        store.selected(catalogue, candidate.scope, candidate.name)
        |> result.map_error(fn(_) { "the prompt selection is unreadable" }),
      )
      case selected {
        None -> Ok(profiles)
        Some(selection) if selection.candidate_id != candidate.id -> Ok(profiles)
        Some(selection) -> {
          use candidate <- result.try(
            store.authorized(catalogue, selection)
            |> result.map_error(fn(_) {
              "selected prompt approval is no longer current"
            }),
          )
          use parsed <- result.try(candidate_profile(candidate))
          Ok([parsed, ..profiles])
        }
      }
    }
  }
}

/// Encodes a session's exact immutable map, including selected candidate IDs.
///
/// ## Examples
///
/// ```gleam
/// assert prompt.encode_map([]) == json.Array([])
/// ```
pub fn encode_map(profiles: List(Profile)) -> json.JsonValue {
  json.Array(list.map(profiles, encode_profile))
}

fn encode_profile(profile: Profile) -> json.JsonValue {
  let #(id, provider, model_id, api, system, task, descriptions) =
    profile.fields(profile)
  json.Object([
    #("version", json.Int(1)),
    #("id", json.String(id)),
    #("provider", json.String(provider)),
    #("model", json.String(model_id)),
    #("api", json.String(api)),
    #("system", json.String(system)),
    #("task", json.String(task)),
    #(
      "descriptions",
      json.Object(
        list.map(descriptions, fn(pair) { #(pair.0, json.String(pair.1)) }),
      ),
    ),
  ])
}

/// Totally decodes a persisted map and refuses oversized or duplicate targets.
///
/// ## Examples
///
/// ```gleam
/// assert prompt.decode_map(json.Array([])) == Ok([])
/// ```
pub fn decode_map(value: json.JsonValue) -> Result(List(Profile), String) {
  case value {
    json.Array(items) -> {
      use Nil <- result.try(case list.length(items) <= 64 {
        True -> Ok(Nil)
        False -> Error("oversized pinned profile map")
      })
      use profiles <- result.try(
        list.try_map(items, fn(item) {
          use id <- result.try(text_field(item, "id"))
          use _validated <- result.try(record.candidate_id(id))
          decode_profile(item, id, 8)
        }),
      )
      profile.validate_map(profiles)
    }
    _ -> Error("invalid or oversized pinned profile map")
  }
}

fn decode_profile(
  value: json.JsonValue,
  id: String,
  count: Int,
) -> Result(Profile, String) {
  use fields <- result.try(case value {
    json.Object(fields) ->
      case list.length(fields) == count {
        True -> Ok(fields)
        False -> Error("a profile must have exactly its declared fields")
      }
    _ -> Error("a profile must have exactly its declared fields")
  })
  use Nil <- result.try(case list.key_find(fields, "version") {
    Ok(json.Int(1)) -> Ok(Nil)
    _ -> Error("unknown prompt profile format")
  })
  use provider <- result.try(text_field(value, "provider"))
  use model_id <- result.try(text_field(value, "model"))
  use api <- result.try(text_field(value, "api"))
  use system <- result.try(text_field(value, "system"))
  use task <- result.try(text_field(value, "task"))
  use descriptions <- result.try(case list.key_find(fields, "descriptions") {
    Ok(json.Object(fields)) ->
      list.try_map(fields, fn(pair) {
        case pair.1 {
          json.String(text) -> Ok(#(pair.0, text))
          _ -> Error("tool description additions must be prose strings")
        }
      })
    _ -> Error("descriptions must be an object of tool prose")
  })
  profile.new(id, provider, model_id, api, system, task, descriptions)
}

fn text_field(value: json.JsonValue, key: String) -> Result(String, String) {
  case value {
    json.Object(fields) -> {
      use item <- result.try(
        list.key_find(fields, key)
        |> result.map_error(fn(_) { "missing profile field " <> key }),
      )
      case item {
        json.String(text) -> Ok(text)
        _ -> Error("profile field " <> key <> " must be text")
      }
    }
    _ -> Error("profile must be an object")
  }
}

/// Fingerprints the composed prompt and full tool surface before each attempt.
/// Text and schemas stay local; only this SHA256 crosses the observation seam.
///
/// ## Examples
///
/// ```gleam
/// // prompt.fingerprint(option.Some("base"), tools)
/// ```
pub fn fingerprint(
  system: Option(String),
  tools: List(model.ToolSpec),
) -> String {
  json.Object([
    #("system", case system {
      None -> json.Null
      Some(text) -> json.String(text)
    }),
    #(
      "tools",
      json.Array(
        list.map(tools, fn(tool) {
          json.Object([
            #("name", json.String(tool.name)),
            #("description", json.String(tool.description)),
            #("schema", tool.input_schema),
          ])
        }),
      ),
    ),
  ])
  |> json.to_string
  |> mcp.sha256_hex
}
