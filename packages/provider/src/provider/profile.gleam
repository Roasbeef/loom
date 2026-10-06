//// Immutable prose profiles selected by the native session host.
////
//// Profiles append text to the request's existing system and tool descriptions.
//// Names, schemas, replay metadata and the generated capability signatures stay
//// in the base request. The task template is a system instruction appended on
//// every attempt, so it applies to child and continued coding runs without
//// rewriting a durable user message. Approval belongs to the caller; this
//// module only validates the bounded shape and composes an exact target.

import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import provider/model

/// One bounded immutable profile. Construct it through `new`.
pub opaque type Profile {
  Profile(
    id: String,
    provider: String,
    model_id: String,
    api: String,
    system_suffix: String,
    task_prefix: String,
    descriptions: List(#(String, String)),
  )
}

/// Constructs prose additions for one exact provider, model and API.
/// All text together is at most 64 KiB and at most 128 tools are annotated.
///
/// ## Examples
///
/// ```gleam
/// // profile.new(id, "p", "m", "anthropic-messages", "Check results.", "", [])
/// ```
pub fn new(
  id: String,
  provider: String,
  model_id: String,
  api: String,
  system_suffix: String,
  task_prefix: String,
  descriptions: List(#(String, String)),
) -> Result(Profile, String) {
  let names = list.map(descriptions, fn(pair) { pair.0 })
  let total_bytes =
    bytes(system_suffix)
    + bytes(task_prefix)
    + list.fold(descriptions, 0, fn(total, pair) {
      total + bytes(pair.0) + bytes(pair.1)
    })
  case
    id != ""
    && bytes(id) <= 128
    && provider != ""
    && model_id != ""
    && bytes(provider) <= 256
    && bytes(model_id) <= 256
    && list.contains(
      [
        "anthropic-messages", "openai-completions", "openai-responses",
        "gemini-generate-content",
      ],
      api,
    )
    && total_bytes <= 65_536
    && list.length(descriptions) <= 128
    && list.length(list.unique(names)) == list.length(names)
    && list.all(names, fn(name) { name != "" && bytes(name) <= 256 })
  {
    True ->
      Ok(Profile(
        id:,
        provider:,
        model_id:,
        api:,
        system_suffix:,
        task_prefix:,
        descriptions:,
      ))
    False -> Error("invalid or oversized exact-model prose profile")
  }
}

/// Returns the profile's immutable identity and contents for durable pinning.
///
/// ## Examples
///
/// ```gleam
/// // profile.fields(approved)
/// ```
pub fn fields(
  profile: Profile,
) -> #(String, String, String, String, String, String, List(#(String, String))) {
  #(
    profile.id,
    profile.provider,
    profile.model_id,
    profile.api,
    profile.system_suffix,
    profile.task_prefix,
    profile.descriptions,
  )
}

/// Refuses duplicate targets and bounds the session map to 64 profiles.
///
/// ## Examples
///
/// ```gleam
/// assert profile.validate_map([]) == Ok([])
/// ```
pub fn validate_map(profiles: List(Profile)) -> Result(List(Profile), String) {
  let targets = list.map(profiles, fn(p) { #(p.provider, p.model_id, p.api) })
  case
    list.length(profiles) <= 64
    && list.length(list.unique(targets)) == list.length(targets)
  {
    True -> Ok(profiles)
    False -> Error("duplicate or oversized exact-model profile map")
  }
}

/// Derives one attempt from the unchanged base request, using an exact match.
/// The returned ID names the text that was composed, including an empty overlay.
///
/// ## Examples
///
/// ```gleam
/// // profile.apply(profiles, target, "anthropic-messages", base)
/// ```
pub fn apply(
  profiles: List(Profile),
  target: model.ResolvedModel,
  api: String,
  base: model.ProviderRequest,
) -> #(Option(String), model.ProviderRequest) {
  case
    list.find(profiles, fn(p) {
      p.provider == target.provider
      && p.model_id == target.model_id
      && p.api == api
    })
  {
    Error(Nil) -> #(None, base)
    Ok(profile) -> {
      let system =
        append_system(base.system, profile.system_suffix, profile.task_prefix)
      let tools =
        list.map(base.tools, fn(tool) {
          let suffix =
            list.key_find(profile.descriptions, tool.name) |> result.unwrap("")
          model.ToolSpec(
            ..tool,
            description: appended(tool.description, suffix),
          )
        })
      #(Some(profile.id), model.ProviderRequest(..base, system:, tools:))
    }
  }
}

fn append_system(
  base: Option(String),
  suffix: String,
  task: String,
) -> Option(String) {
  let extra = appended(suffix, task)
  case base, extra {
    None, "" -> None
    None, extra -> Some(extra)
    Some(text), extra -> Some(appended(text, extra))
  }
}

fn appended(base: String, addition: String) -> String {
  case base, addition {
    _, "" -> base
    "", _ -> addition
    _, _ -> base <> "\n\n" <> addition
  }
}

fn bytes(text: String) -> Int {
  bit_array.byte_size(bit_array.from_string(text))
}
