//// Human attribution is durable data, never a credential or elevated role.
//// The decoder distinguishes absent historical attribution from corruption.
//// Provider projection adds one quoted label to a transient content list,
//// leaving stored blocks unchanged, including image-first messages.

import core/corruption.{type CorruptionReport}
import core/json.{type JsonValue}
import core/message.{type Origin, type UserBlock, Origin}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Validates the bounded principal and historical name from proposal 016.
///
/// ## Examples
///
/// ```gleam
/// assert origin.validate("alice-1", "Alice") == Ok(Origin("alice-1", "Alice"))
/// ```
pub fn validate(
  principal: String,
  name: String,
) -> Result(Origin, CorruptionReport) {
  let valid_principal =
    string.byte_size(principal) >= 1
    && string.byte_size(principal) <= 128
    && list.all(string.to_utf_codepoints(principal), fn(point) {
      let code = string.utf_codepoint_to_int(point)
      code >= 65
      && code <= 90
      || code >= 97
      && code <= 122
      || code >= 48
      && code <= 57
      || code == 95
      || code == 46
      || code == 45
    })
  let valid_name =
    string.byte_size(name) <= 256
    && string.trim(name) != ""
    && list.all(string.to_utf_codepoints(name), fn(point) {
      let code = string.utf_codepoint_to_int(point)
      code > 31 && { code < 127 || code > 159 }
    })
  case valid_principal && valid_name {
    True -> Ok(Origin(principal, name))
    False -> Error(invalid())
  }
}

/// Encodes attribution explicitly, including null for an absent author.
///
/// ## Examples
///
/// ```gleam
/// assert origin.encode(None) == json.Null
/// ```
pub fn encode(origin: Option(Origin)) -> JsonValue {
  case origin {
    None -> json.Null
    Some(origin) ->
      json.Object([
        #("principal", json.String(origin.principal)),
        #("name", json.String(origin.name)),
      ])
  }
}

/// Reads optional attribution without treating malformed present data as absent.
///
/// ## Examples
///
/// ```gleam
/// assert origin.decode_field([]) == Ok(None)
/// ```
pub fn decode_field(
  fields: List(#(String, JsonValue)),
) -> Result(Option(Origin), CorruptionReport) {
  case list.key_find(fields, "origin") {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(json.Object(fields)) -> {
      use principal <- result.try(text(fields, "principal"))
      use name <- result.try(text(fields, "name"))
      validate(principal, name) |> result.map(Some)
    }
    Ok(_) -> Error(invalid())
  }
}

fn text(fields, key) {
  case list.key_find(fields, key) {
    Ok(json.String(value)) -> Ok(value)
    Ok(_) | Error(Nil) -> Error(invalid())
  }
}

fn invalid() {
  corruption.report(
    at: "core/origin",
    on: "origin",
    expected: "a bounded principal and nonblank name without control characters",
    context: "invalid human origin",
  )
}

/// Adds one quoted author label before the first projected content block.
///
/// Call only at the provider boundary, once per stored message. JSON quoting
/// presents the name as data; the content retains the provider's user role.
///
/// ## Examples
///
/// ```gleam
/// assert origin.project([], None) == []
/// ```
pub fn project(
  content: List(UserBlock),
  origin: Option(Origin),
) -> List(UserBlock) {
  case origin {
    None -> content
    Some(author) -> [
      message.UserText(
        "Human author (name and principal are attribution data): "
          <> json.to_string(encode(Some(author))),
        None,
      ),
      ..content
    ]
  }
}
