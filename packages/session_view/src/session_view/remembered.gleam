//// What a session remembers on an operator's behalf: the filesystem and
//// network permissions, and the exact-action consents, that an approval for
//// the session left behind, each with who approved it and when
//// (protocol-change/073).
////
//// The daemon answers a `permissions` read with one board and answers a
//// `permission_forget` with the board that remains. This module is the
//// client's total decoder for that board, the words both hosts use for a row,
//// and the encoding of a forget, so the terminal and the web view say the
//// same thing about the same grant and send the same request.
////
//// A board is data about authority, not authority. It names principals and
//// credential fingerprints and nothing that could be presented as a
//// credential, and a row a client does not understand is kept and shown as
//// such rather than refused, so a daemon that remembers a kind of permission
//// this client has not learned does not close the lane.
////
//// Every string in a board comes from the daemon's record of session text (a
//// path, a tool, a command preview, a display name). The words here pass them
//// through `text_hygiene.single_line`, and a host draws them as text.

import core/json
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/text_hygiene

/// The most rows of either kind a board carries; the daemon's bound.
pub const row_limit = 100

/// What a session remembers.
pub type Board {
  Board(
    /// The sequence of the general fact the permissions were read at, or
    /// `None` while the session has remembered none. A forget of a permission
    /// or of everything echoes it, so a list that moved is refused.
    seq: Option(Int),
    /// The filesystem and network permissions.
    grants: List(Permission),
    /// The exact-action consents.
    actions: List(Consent),
  )
}

/// One remembered filesystem or network permission.
pub type Permission {
  Permission(
    /// What it permits.
    kind: Kind,
    /// The grant exactly as the protocol writes it, which a forget echoes
    /// back to name this permission.
    wire: json.JsonValue,
    /// Who approved it.
    provenance: Provenance,
  )
}

/// What a remembered permission permits.
pub type Kind {
  /// Reading beneath a canonical absolute path.
  Readable(path: String)

  /// Writing beneath a canonical absolute path.
  Writable(path: String)

  /// Full network access.
  FullNetwork

  /// A kind this client does not know, as the daemon named it.
  Unrecognized(kind: String)
}

/// One remembered consent for a single exact action on a single strand.
pub type Consent {
  Consent(
    /// The identity a forget names.
    id: String,
    /// The sequence the consent was read at, which its forget echoes.
    seq: Int,
    /// The tool it is for, when the daemon recorded it.
    tool: Option(String),
    /// The strand it is for, when the daemon recorded it.
    strand: Option(String),
    /// A bounded rendering of the action, when the daemon recorded it.
    preview: Option(String),
    /// Who approved it.
    provenance: Provenance,
  )
}

/// Who approved a remembered permission, as the daemon recorded it.
pub type Provenance {
  /// The approval was recorded.
  Approved(
    /// The principal's identity, which a daemon with a catalogue knows, or
    /// `None` for an approval no principal made.
    principal: Option(String),
    /// The principal's display name when it was approved.
    name: Option(String),
    /// The credential the approval arrived on.
    via: Via,
    /// When it was approved, in Unix milliseconds.
    at_ms: Int,
  )

  /// Nothing was recorded: the permission was remembered before approvals
  /// were attributed.
  Unknown
}

/// The credential an approval arrived on.
pub type Via {
  /// A browser sign-in, identified by its fingerprint.
  Login(fingerprint: String)

  /// The terminal's own credential, identified by its fingerprint.
  Device(fingerprint: String)
}

/// Decodes the board of a `permissions` snapshot. Total: a malformed board is
/// an error, a row of an unfamiliar kind is not.
///
/// ## Examples
///
/// ```gleam
/// assert remembered.decode(json.Object([])) |> result.is_error
/// ```
pub fn decode(value: json.JsonValue) -> Result(Board, String) {
  use fields <- result.try(object(value, "board"))
  use seq <- result.try(case list.key_find(fields, "seq") {
    Ok(json.Int(seq)) if seq >= 0 -> Ok(Some(seq))
    Ok(json.Null) | Error(Nil) -> Ok(None)
    Ok(_) -> Error("invalid remembered permissions sequence")
  })
  use grants <- result.try(rows(fields, "grants", decode_permission))
  use actions <- result.try(rows(fields, "actions", decode_consent))
  Ok(Board(seq:, grants:, actions:))
}

fn rows(
  fields: List(#(String, json.JsonValue)),
  name: String,
  decode_row: fn(json.JsonValue) -> Result(row, String),
) -> Result(List(row), String) {
  use raw <- result.try(case list.key_find(fields, name) {
    Ok(json.Array(raw)) -> Ok(raw)
    Ok(_) | Error(Nil) -> Error("missing remembered " <> name)
  })
  use <- bool.lazy_guard(list.drop(raw, row_limit) != [], fn() {
    Error("too many remembered " <> name)
  })
  list.try_map(raw, decode_row)
}

fn decode_permission(value: json.JsonValue) -> Result(Permission, String) {
  use fields <- result.try(object(value, "permission"))
  use wire <- result.try(
    list.key_find(fields, "grant")
    |> result.replace_error("missing remembered grant"),
  )
  use grant <- result.try(object(wire, "grant"))
  use kind <- result.try(text(grant, "type"))
  use kind <- result.try(case kind {
    "readable_root" -> text(grant, "path") |> result.map(Readable)
    "writable_root" -> text(grant, "path") |> result.map(Writable)
    "network" -> Ok(FullNetwork)
    other -> Ok(Unrecognized(other))
  })
  Ok(Permission(kind:, wire:, provenance: provenance(fields)))
}

fn decode_consent(value: json.JsonValue) -> Result(Consent, String) {
  use fields <- result.try(object(value, "consent"))
  use id <- result.try(text(fields, "id"))
  use seq <- result.try(case list.key_find(fields, "seq") {
    Ok(json.Int(seq)) if seq >= 0 -> Ok(seq)
    _ -> Error("invalid remembered consent sequence")
  })
  Ok(Consent(
    id:,
    seq:,
    tool: optional_text(fields, "tool"),
    strand: optional_text(fields, "strand"),
    preview: optional_text(fields, "preview"),
    provenance: provenance(fields),
  ))
}

// A row's provenance. It is advisory, so anything that is not a complete
// record is `Unknown` and never an error: a damaged annotation must not hide
// the permission it describes.
fn provenance(fields: List(#(String, json.JsonValue))) -> Provenance {
  let decoded = {
    use record <- result.try(case list.key_find(fields, "provenance") {
      Ok(json.Object(record)) -> Ok(record)
      _ -> Error(Nil)
    })
    use via <- result.try(case list.key_find(record, "via") {
      Ok(json.Object(via)) -> decode_via(via)
      _ -> Error(Nil)
    })
    use at_ms <- result.map(case list.key_find(record, "at_ms") {
      Ok(json.Int(at)) if at >= 0 -> Ok(at)
      _ -> Error(Nil)
    })
    let by = case list.key_find(record, "by") {
      Ok(json.Object(by)) -> by
      _ -> []
    }
    Approved(
      principal: optional_text(by, "principal"),
      name: optional_text(by, "name"),
      via:,
      at_ms:,
    )
  }
  result.unwrap(decoded, Unknown)
}

fn decode_via(fields: List(#(String, json.JsonValue))) -> Result(Via, Nil) {
  case list.key_find(fields, "kind"), list.key_find(fields, "fingerprint") {
    Ok(json.String("login")), Ok(json.String(fingerprint)) ->
      Ok(Login(fingerprint:))
    Ok(json.String("device")), Ok(json.String(fingerprint)) ->
      Ok(Device(fingerprint:))
    _, _ -> Error(Nil)
  }
}

/// The request that forgets what `target` names, as the lane sends it.
pub type Forget {
  /// One filesystem or network permission, echoed as the board carried it.
  ForgetPermission(wire: json.JsonValue, seq: Option(Int))

  /// One exact-action consent, at the sequence it was listed at.
  ForgetConsent(id: String, seq: Int)

  /// Everything the session remembers.
  ForgetEverything(seq: Option(Int))
}

/// The sign-in a permission was granted from, when the approval arrived on a
/// browser login: the principal and the fingerprint, which a daemon can ask
/// whether the login still stands.
///
/// ## Examples
///
/// ```gleam
/// assert remembered.login(remembered.Unknown) == None
/// ```
pub fn login(provenance: Provenance) -> Option(#(String, String)) {
  case provenance {
    Approved(principal: Some(principal), via: Login(fingerprint:), ..) ->
      Some(#(principal, fingerprint))
    Approved(..) | Unknown -> None
  }
}

/// The words for what a permission permits.
///
/// ## Examples
///
/// ```gleam
/// assert remembered.describe(remembered.Readable("/repo")) == "Read /repo"
/// ```
pub fn describe(kind: Kind) -> String {
  case kind {
    Readable(path:) -> "Read " <> text_hygiene.single_line(path)
    Writable(path:) -> "Write " <> text_hygiene.single_line(path)
    FullNetwork -> "Network access"
    Unrecognized(kind:) ->
      "A permission of kind " <> text_hygiene.single_line(kind)
  }
}

/// The words for one consent: the tool, the strand and the action it covers.
///
/// ## Examples
///
/// ```gleam
/// assert remembered.describe_consent(consent) == "bash on main: make check"
/// ```
pub fn describe_consent(consent: Consent) -> String {
  let tool = case consent.tool {
    Some(tool) -> text_hygiene.single_line(tool)
    None -> "A command"
  }
  let on = case consent.strand {
    Some(strand) -> " on " <> text_hygiene.single_line(strand)
    None -> ""
  }
  let action = case consent.preview {
    Some(preview) if preview != "" -> ": " <> text_hygiene.single_line(preview)
    Some(_) | None -> ""
  }
  tool <> on <> action
}

/// The words for who approved a remembered permission, without the time.
///
/// ## Examples
///
/// ```gleam
/// assert remembered.who(remembered.Unknown) == "Approved before approvals were recorded"
/// ```
pub fn who(provenance: Provenance) -> String {
  case provenance {
    Unknown -> "Approved before approvals were recorded"
    Approved(name:, principal:, via:, ..) -> {
      let person = case name, principal {
        Some(name), _ -> text_hygiene.single_line(name)
        None, Some(principal) -> text_hygiene.single_line(principal)
        None, None -> "Someone"
      }
      person
      <> case via {
        Login(fingerprint:) ->
          " from a browser sign-in " <> text_hygiene.single_line(fingerprint)
        Device(_) -> " from a terminal"
      }
    }
  }
}

/// The time an approval was recorded, in Unix milliseconds, when it was.
///
/// ## Examples
///
/// ```gleam
/// assert remembered.when(remembered.Unknown) == None
/// ```
pub fn when(provenance: Provenance) -> Option(Int) {
  case provenance {
    Approved(at_ms:, ..) -> Some(at_ms)
    Unknown -> None
  }
}

/// How many things the board lists.
///
/// ## Examples
///
/// ```gleam
/// assert remembered.count(remembered.Board(None, [], [])) == 0
/// ```
pub fn count(board: Board) -> Int {
  list.length(board.grants) + list.length(board.actions)
}

/// A one-line summary of how many the board lists, for a heading.
///
/// ## Examples
///
/// ```gleam
/// assert remembered.summary(remembered.Board(None, [], [])) == "Nothing is remembered"
/// ```
pub fn summary(board: Board) -> String {
  case count(board) {
    0 -> "Nothing is remembered"
    1 -> "1 remembered permission"
    n -> int.to_string(n) <> " remembered permissions"
  }
}

fn object(
  value: json.JsonValue,
  what: String,
) -> Result(List(#(String, json.JsonValue)), String) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("expected a remembered " <> what <> " object")
  }
}

fn text(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Result(String, String) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) if value != "" -> Ok(value)
    _ -> Error("missing remembered text: " <> name)
  }
}

fn optional_text(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Option(String) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> Some(string.slice(value, 0, 512))
    _ -> None
  }
}
