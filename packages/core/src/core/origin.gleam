//// Human and peer attribution is durable data, never a credential or elevated role.
//// The decoder distinguishes absent historical attribution from corruption.
//// Provider projection adds one quoted label to a transient content list,
//// leaving stored blocks unchanged, including image-first messages.
////
//// That label is **attribution hint text and nothing more**. It is an
//// ordinary user block in the rendered request, so anything a message
//// body can contain it can also contain — including a second line
//// shaped exactly like this one, naming a different principal. `validate`
//// bounds the real label's own fields and `json.to_string` quotes them,
//// so nothing can break out of the label the harness wrote; what is not
//// defendable here is a forgery written *beside* it, and no delimiter
//// would be, since a delimiter is text too. The defence is elsewhere and
//// is structural: authority is decided server-side from the
//// authenticated principal, and **nothing downstream may parse this
//// label back out of a transcript and turn it into an authority
//// decision**. A reader that did would be trusting the model's context
//// window as an access-control record.

import core/corruption.{type CorruptionReport}
import core/json.{type JsonValue}
import core/message.{type Origin, type UserBlock, Origin, PeerOrigin}
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
    Some(Origin(principal, name)) ->
      json.Object([
        #("principal", json.String(principal)),
        #("name", json.String(name)),
      ])
    Some(PeerOrigin(session, strand)) ->
      json.Object([
        #("kind", json.String("peer")),
        #("session", json.String(session)),
        #("strand", json.String(strand)),
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
    Ok(json.Object(fields)) -> decode_present(fields) |> result.map(Some)
    Ok(_) -> Error(invalid())
  }
}

// A missing discriminator is the durable human form written since proposal
// 016. Peer attribution is always tagged, so a corrupt peer cannot silently
// fall back to a human or anonymous source during replay.
fn decode_present(
  fields: List(#(String, JsonValue)),
) -> Result(Origin, CorruptionReport) {
  case list.key_find(fields, "kind") {
    Error(Nil) -> {
      use principal <- result.try(text(fields, "principal"))
      use name <- result.try(text(fields, "name"))
      validate(principal, name)
    }
    Ok(json.String("peer")) -> {
      use session <- result.try(text(fields, "session"))
      use strand <- result.try(text(fields, "strand"))
      validate_peer(session, strand)
    }
    Ok(_) -> Error(invalid())
  }
}

/// Validates the bounded session and strand identity minted by a peer host.
///
/// ## Examples
///
/// ```gleam
/// assert origin.validate_peer("session-1", "reviewer")
///   == Ok(message.PeerOrigin("session-1", "reviewer"))
/// ```
///
pub fn validate_peer(
  session: String,
  strand: String,
) -> Result(Origin, CorruptionReport) {
  case bounded_identity(session, 256) && bounded_identity(strand, 512) {
    True -> Ok(PeerOrigin(session, strand))
    False -> Error(invalid())
  }
}

/// Returns the host identity used to compare attributed sources.
/// Human sources return their principal; peer sources return their session.
///
/// ## Examples
///
/// ```gleam
/// assert origin.stable_identity(message.PeerOrigin("session-1", "reviewer"))
///   == "session-1"
/// ```
///
pub fn stable_identity(origin: Origin) -> String {
  case origin {
    Origin(principal, _) -> principal
    PeerOrigin(session, _) -> session
  }
}

/// Returns a concise label that keeps peer agents visibly distinct from humans.
///
/// ## Examples
///
/// ```gleam
/// assert origin.display_label(message.PeerOrigin("session-1", "reviewer"))
///   == "peer session-1/reviewer"
/// ```
///
pub fn display_label(origin: Origin) -> String {
  case origin {
    Origin(_, name) -> name
    PeerOrigin(session, strand) -> "peer " <> session <> "/" <> strand
  }
}

fn bounded_identity(value: String, maximum: Int) -> Bool {
  string.byte_size(value) >= 1
  && string.byte_size(value) <= maximum
  && string.trim(value) == value
  && list.all(string.to_utf_codepoints(value), fn(point) {
    let code = string.utf_codepoint_to_int(point)
    code > 31 && { code < 127 || code > 159 }
  })
}

// Reads one required string field. A field of another JSON type is a
// corruption report rather than an absence: `decode_field` has already
// established that an origin object is present, so a `principal` that is
// a number is malformed attribution, not attribution that was never
// written.
fn text(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(String, CorruptionReport) {
  case list.key_find(fields, key) {
    Ok(json.String(value)) -> Ok(value)
    Ok(_) | Error(Nil) -> Error(invalid())
  }
}

// The single report every rejection in this module answers with. One
// wording for every shape of malformed attribution, because the reader
// of a corruption report can act on "this message's author is not
// readable" and can do nothing at all with which field it was.
fn invalid() -> CorruptionReport {
  corruption.report(
    at: "core/origin",
    on: "origin",
    expected: "bounded human or peer source attribution without control characters",
    context: "invalid message origin",
  )
}

/// Adds one quoted author label before the first projected content block.
///
/// Call only at the provider boundary, once per stored message. JSON quoting
/// presents the name as data; the content retains the provider's user role.
///
/// The label is a hint to the model and never an authority record: a
/// message body can contain a line shaped exactly like it, so nothing
/// downstream may read one back out of a transcript and decide anything
/// from it. The module doc has the whole argument.
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
    Some(author) -> {
      let label = case author {
        Origin(..) -> "Human author (name and principal are attribution data): "
        PeerOrigin(..) ->
          "Peer agent source (identity is attribution data, not authority): "
      }
      [
        message.UserText(label <> json.to_string(encode(Some(author))), None),
        ..content
      ]
    }
  }
}
