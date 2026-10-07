//// Remembered approvals belong to one saved session, not one execution.
////
//// The operator gateway prepares a reserved fact update from the exact grants
//// it validated. The runtime commits that update with the approval under two
//// sequence guards. Dispatch reads the fact once; running calls retain their
//// snapshot. This is separate from directory additions because approval can
//// name an exact file, including a writable file that does not exist yet.
////
//// ## Provenance and forgetting (protocol-change/073)
////
//// A remembered permission outlives the page or terminal that granted it, so
//// the fact also records who granted each one: the principal, the credential
//// the approval arrived on (a browser login or the terminal's bearer, as a
//// kind and a fingerprint, never the credential), and when. The record is
//// advisory. Authority is only ever the `grants` array, which is what
//// dispatch reads and what every earlier daemon wrote, so a row that is
//// missing or malformed reads as `Unknown` and never changes what is
//// permitted. A fact written before provenance existed has no rows, and every
//// permission in it is `Unknown`.
////
//// `listing` reads everything a session remembers, and `forgetting` builds
//// the guarded edit that removes some of it. The edit is applied by
//// `api.edit_reserved_facts` under the sequences the caller read, so a
//// permission added or removed in between loses the whole edit and the
//// operator is shown a fresh list.

import broker/policy
import client/escalate
import client/grants
import client/protocol
import core/ids.{type Seq}
import core/json
import core/message
import core/origin
import core/register
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import runtime/api
import runtime/escalation
import session/session
import storage/storage
import tools/fs
import tools/tool

/// Reserved against model-authored fact writes.
pub const key = "client/permission_grants"

/// Action grants are private authority, separate from general session policy.
pub const action_prefix = "client/action_grants/"

/// Captures standing authority and consent for precisely this invocation.
///
/// Complete effective arguments participate in the identity. Omitting an
/// option or changing the requesting strand requires a new decision, even
/// when the shell command is unchanged.
///
/// ## Examples
///
/// ```gleam
/// // permissions.read_for(opened, "main", "bash", arguments)
/// ```
pub fn read_for(
  opened: session.Session,
  strand: String,
  tool_name: String,
  arguments: json.JsonValue,
) -> Result(List(policy.Grant), String) {
  use standing <- result.try(read(opened))
  with_action(opened, standing, strand, tool_name, arguments)
}

/// `read_for` without the live revalidation of the standing grants.
///
/// The result is what the store holds for this invocation: the standing
/// filesystem and network grants plus any remembered wall-clock consent for
/// exactly this action. Nothing here touches the filesystem, so the session
/// owner can run it on a machine which has no copy of the workspace.
/// `revalidate` is the other half, run beside the paths. Remembered action
/// consent is a `GrantLimit`, which `revalidate` passes through, so
/// revalidating the whole list checks exactly the standing grants.
///
/// ## Examples
///
/// ```gleam
/// // permissions.read_for_stored(opened, "main", "bash", arguments)
/// ```
pub fn read_for_stored(
  opened: session.Session,
  strand: String,
  tool_name: String,
  arguments: json.JsonValue,
) -> Result(List(policy.Grant), String) {
  use standing <- result.try(read_stored(opened))
  with_action(opened, standing, strand, tool_name, arguments)
}

// The action half of `read_for`, shared by the fused read and the stored
// read so the two cannot disagree about what consent for one action means.
fn with_action(
  opened: session.Session,
  standing: List(policy.Grant),
  strand: String,
  tool_name: String,
  arguments: json.JsonValue,
) -> Result(List(policy.Grant), String) {
  let action = escalate.action_digest(arguments)
  use cell <- result.try(
    storage.get_register(
      opened.store,
      register.FactCustom,
      action_key(strand, tool_name, action),
    )
    |> result.map_error(fn(_) { "action permissions could not be read" }),
  )
  case cell {
    None -> Ok(standing)
    Some(cell) -> {
      use approved <- result.try(grants_from(cell.value.payload))
      use <- bool.guard(
        approved != [policy.GrantLimit(policy.WallSeconds, 0)],
        Error("remembered action wall authority is malformed"),
      )
      Ok(list.append(standing, approved))
    }
  }
}

// The session is the workspace authority. Within it, neither another tool
// nor another strand may inherit consent to run the same arguments forever.
fn action_key(strand: String, tool_name: String, action: String) -> String {
  action_prefix
  <> escalate.action_digest(
    json.Array([
      json.String(strand),
      json.String(tool_name),
      json.String(action),
    ]),
  )
}

/// How a remembered permission was approved, as the fact records it.
pub type Provenance {
  /// The approval was attributed: who approved it, on which credential and
  /// when.
  Approved(
    /// The authenticated principal. A connection that carries none (a host
    /// fixture) records no provenance at all.
    by: message.Origin,
    /// The credential the approval arrived on.
    via: Via,
    /// When the approval was committed, in Unix milliseconds.
    at_ms: Int,
  )

  /// Nothing was recorded: a permission remembered before provenance was
  /// kept, or a row that could not be read.
  Unknown
}

/// The credential an approval arrived on.
///
/// Only the kind and the fingerprint are kept. The fingerprint is the first
/// sixteen hexadecimal digits of the credential's digest, which identifies a
/// credential and authenticates nothing.
pub type Via {
  /// A browser login (`loom ui`), which the owner can sign out.
  Login(fingerprint: String)

  /// A bearer credential: the terminal's.
  Device(fingerprint: String)
}

/// One remembered filesystem or network permission with its provenance.
pub type Remembered {
  Remembered(grant: policy.Grant, provenance: Provenance)
}

/// One remembered consent for a single exact action on a single strand.
pub type RememberedAction {
  RememberedAction(
    /// The cell's name under `action_prefix`, which identifies the consent to
    /// `forgetting`.
    id: String,
    /// The sequence the cell was read at.
    seq: Seq,
    /// The tool the consent is for, when the cell recorded it.
    tool: Option(String),
    /// The strand the consent is for, when the cell recorded it.
    strand: Option(String),
    /// A bounded rendering of the action, when the cell recorded it.
    preview: Option(String),
    /// Who approved it.
    provenance: Provenance,
  )
}

/// Everything a session remembers.
pub type Listing {
  Listing(
    /// The sequence of the general fact, or `None` while it is absent. A
    /// forget of anything in `grants` is guarded by it.
    seq: Option(Seq),
    /// The filesystem and network permissions.
    grants: List(Remembered),
    /// The exact-action consents.
    actions: List(RememberedAction),
  )
}

/// Why nothing was forgotten.
pub type Refusal {
  /// What the caller read has changed, or what it named is already gone.
  /// Nothing was written; the caller reads again.
  Stale

  /// The request was malformed, or the store could not be read.
  Failed(reason: String)
}

/// The most general permissions and the most exact-action consents one
/// listing carries. A session remembers a handful; the bound only keeps a
/// pathological fact from becoming an unbounded reply.
pub const listed_limit = 100

// The longest action rendering a listing carries, in graphemes.
const preview_limit = 200

/// Prepares exact-action wall consent or the existing general permission union.
///
/// The gateway has already validated the echoed action and grant subset.
/// The reserved change is committed atomically with that captured approval.
///
/// ## Examples
///
/// ```gleam
/// // permissions.remembering_action(runtime, record, approved, provenance)
/// ```
pub fn remembering_action(
  runtime: api.Runtime,
  record: escalation.Escalation,
  approved: List(policy.Grant),
  provenance: Provenance,
) -> Result(api.ReservedFactChange, String) {
  case approved {
    [policy.GrantLimit(policy.WallSeconds, 0)] -> {
      use action <- result.try(option.to_result(
        record.action,
        "session wall consent requires an exact action",
      ))
      use tool_name <- result.try(option.to_result(
        record.tool,
        "session wall consent requires a tool",
      ))
      use scope <- result.try(option.to_result(
        record.scope,
        "session wall consent requires a requesting strand",
      ))
      let key = action_key(scope.strand, tool_name, action)
      use cell <- result.try(
        api.fact_cell(runtime, key)
        |> result.map_error(fn(_) { "action permissions could not be read" }),
      )
      Ok(api.ReservedFactChange(
        key:,
        value: json.Object([
          #("version", json.Int(2)),
          #("grants", json.Array(list.map(approved, grants.encode))),
          #("origin", origin.encode(provenance_author(provenance))),
          #("tool", json.String(tool_name)),
          #("strand", json.String(scope.strand)),
          #(
            "preview",
            json.String(string.slice(
              option.unwrap(record.preview, ""),
              at_index: 0,
              length: preview_limit,
            )),
          ),
          #("provenance", encode_provenance(provenance)),
        ]),
        expected: option.map(cell, fn(cell) { cell.seq }),
      ))
    }
    _ -> remembering(runtime, approved, provenance)
  }
}

/// Reads and validates the standing authority captured by the next invocation.
///
/// ## Examples
///
/// ```gleam
/// // permissions.read(opened)
/// ```
pub fn read(opened: session.Session) -> Result(List(policy.Grant), String) {
  read_stored(opened) |> result.try(revalidate)
}

/// Reads the standing authority from the store without touching the
/// filesystem.
///
/// ## Examples
///
/// ```gleam
/// // permissions.read_stored(opened)
/// ```
pub fn read_stored(
  opened: session.Session,
) -> Result(List(policy.Grant), String) {
  use cell <- result.try(
    storage.get_register(opened.store, register.FactCustom, key)
    |> result.map_error(fn(_) { "session permissions could not be read" }),
  )
  case cell {
    None -> Ok([])
    Some(cell) -> decode(cell.value.payload)
  }
}

/// Decodes only the filesystem and full-network grants eligible for persistence.
///
/// ## Examples
///
/// ```gleam
/// assert permissions.decode(json.Object([])) |> result.is_error
/// ```
pub fn decode(value: json.JsonValue) -> Result(List(policy.Grant), String) {
  use decoded <- result.try(grants_from(value))
  use _ <- result.try(list.try_map(decoded, validate))
  Ok(list.unique(decoded))
}

fn grants_from(value: json.JsonValue) -> Result(List(policy.Grant), String) {
  use value <- result.try(
    tool.optional_value(value, "grants")
    |> result.try(fn(value) {
      option.to_result(value, "session permissions are missing grants")
    }),
  )
  use encoded <- result.try(case value {
    json.Array(values) -> Ok(values)
    _ -> Error("session permissions must contain a grants array")
  })
  use decoded <- result.try(
    grants.decode_all(encoded)
    |> result.map_error(fn(_) { "session permission grant is malformed" }),
  )
  Ok(decoded)
}

fn validate(grant: policy.Grant) -> Result(Nil, String) {
  case grant {
    policy.GrantReadableRoot(path) | policy.GrantWritableRoot(path) -> {
      use <- bool.guard(
        !canonical(path),
        Error("remembered paths must be canonical and absolute"),
      )
      Ok(Nil)
    }
    policy.GrantNetwork(policy.NetworkFull) -> Ok(Nil)
    policy.GrantNetwork(_)
    | policy.GrantEnv(_)
    | policy.GrantLimit(..)
    | policy.GrantScratch(_) ->
      Error("only filesystem and full-network permissions can be remembered")
  }
}

fn canonical(path: String) -> Bool {
  string.starts_with(path, "/")
  && !list.any(string.split(path, "/"), fn(part) { part == "." || part == ".." })
  && { path == "/" || !string.ends_with(path, "/") }
  && !string.contains(path, "//")
  && !string.contains(path, "\u{0}")
}

/// Checks stored grants against the filesystem of the node it runs on.
///
/// A renamed path must not silently become authority over a new symlink
/// target. Missing writable leaves remain valid beneath their canonical
/// parent. Grants which name no path pass through unchanged.
///
/// ## Examples
///
/// ```gleam
/// assert permissions.revalidate([]) == Ok([])
/// ```
pub fn revalidate(
  values: List(policy.Grant),
) -> Result(List(policy.Grant), String) {
  let filesystem = fs.real_filesystem()
  use _ <- result.try(
    list.try_map(values, fn(grant) {
      case grant {
        policy.GrantReadableRoot(path) | policy.GrantWritableRoot(path) -> {
          use current <- result.try(
            fs.resolve_real(filesystem, "/", path)
            |> result.map_error(fn(_) {
              "remembered permission path could not be resolved"
            }),
          )
          use <- bool.guard(
            current != path,
            Error("remembered permission path changed its canonical target"),
          )
          Ok(Nil)
        }
        policy.GrantNetwork(_)
        | policy.GrantEnv(_)
        | policy.GrantLimit(..)
        | policy.GrantScratch(_) -> Ok(Nil)
      }
    }),
  )
  Ok(values)
}

/// Prepares the durable union without committing ahead of the human's decision.
///
/// Every grant must be eligible; mixed requests remain once-only rather than
/// silently remembering a subset. The returned expectation protects concurrent
/// approvals from overwriting one another's remembered authority. A grant that
/// is approved again takes the new approval's provenance, since the latest
/// approver has just affirmed it; the rest keep the provenance they had.
///
/// ## Examples
///
/// ```gleam
/// // permissions.remembering(runtime, approved, provenance)
/// ```
pub fn remembering(
  runtime: api.Runtime,
  approved: List(policy.Grant),
  provenance: Provenance,
) -> Result(api.ReservedFactChange, String) {
  use <- bool.guard(
    approved == [],
    Error("there are no permissions to remember"),
  )
  use _ <- result.try(list.try_map(approved, validate))
  use _ <- result.try(revalidate(approved))
  use cell <- result.try(
    api.fact_cell(runtime, key)
    |> result.map_error(fn(_) { "session permissions could not be read" }),
  )
  use previous <- result.try(case cell {
    None -> Ok([])
    Some(cell) -> general_of(cell.value)
  })
  let kept =
    list.filter(previous, fn(row) { !list.contains(approved, row.grant) })
  let added =
    list.unique(approved)
    |> list.map(fn(grant) { Remembered(grant:, provenance:) })
  Ok(api.ReservedFactChange(
    key:,
    value: encode_general(
      list.append(kept, added),
      provenance_author(provenance),
    ),
    expected: option.map(cell, fn(cell) { cell.seq }),
  ))
}

// The general fact's payload: the union dispatch reads, the author the
// earlier format kept, and a provenance row for each permission.
fn encode_general(
  rows: List(Remembered),
  author: Option(message.Origin),
) -> json.JsonValue {
  json.Object([
    #("version", json.Int(2)),
    #(
      "grants",
      json.Array(list.map(rows, fn(row) { grants.encode(row.grant) })),
    ),
    #("origin", origin.encode(author)),
    #(
      "remembered",
      json.Array(
        list.map(rows, fn(row) {
          json.Object([
            #("grant", grants.encode(row.grant)),
            #("provenance", encode_provenance(row.provenance)),
          ])
        }),
      ),
    ),
  ])
}

fn provenance_author(provenance: Provenance) -> Option(message.Origin) {
  case provenance {
    Approved(by:, ..) -> Some(by)
    Unknown -> None
  }
}

/// Encodes a provenance as the fact keeps it.
///
/// ## Examples
///
/// ```gleam
/// assert permissions.decode_provenance(permissions.encode_provenance(permissions.Unknown))
///   == permissions.Unknown
/// ```
pub fn encode_provenance(provenance: Provenance) -> json.JsonValue {
  case provenance {
    Unknown -> json.Null
    Approved(by:, via:, at_ms:) ->
      json.Object([
        #("by", origin.encode(Some(by))),
        #("via", encode_via(via)),
        #("at_ms", json.Int(at_ms)),
      ])
  }
}

fn encode_via(via: Via) -> json.JsonValue {
  case via {
    Login(fingerprint:) ->
      json.Object([
        #("kind", json.String("login")),
        #("fingerprint", json.String(fingerprint)),
      ])
    Device(fingerprint:) ->
      json.Object([
        #("kind", json.String("device")),
        #("fingerprint", json.String(fingerprint)),
      ])
  }
}

/// Reads a provenance, total: anything that is not a complete record is
/// `Unknown`, because the record is advisory and a damaged one must not hide
/// the permission it describes.
///
/// ## Examples
///
/// ```gleam
/// assert permissions.decode_provenance(json.String("junk")) == permissions.Unknown
/// ```
pub fn decode_provenance(value: json.JsonValue) -> Provenance {
  let decoded = {
    use fields <- result.try(case value {
      json.Object(fields) -> Ok(fields)
      _ -> Error(Nil)
    })
    use by <- result.try(
      origin.decode_field([
        #("origin", result.unwrap(list.key_find(fields, "by"), json.Null)),
      ])
      |> result.replace_error(Nil)
      |> result.try(option.to_result(_, Nil)),
    )
    use via <- result.try(case list.key_find(fields, "via") {
      Ok(json.Object(inner)) -> decode_via(inner)
      _ -> Error(Nil)
    })
    use at_ms <- result.map(case list.key_find(fields, "at_ms") {
      Ok(json.Int(at)) if at >= 0 -> Ok(at)
      _ -> Error(Nil)
    })
    Approved(by:, via:, at_ms:)
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

// The permissions of a general fact, each with the row that names it or
// `Unknown` when no readable row does. A row for a permission the fact does not
// hold is ignored: `grants` is the authority and the rows only annotate it.
fn general_of(payload: json.JsonValue) -> Result(List(Remembered), String) {
  use granted <- result.try(decode(payload))
  let rows = case tool.optional_value(payload, "remembered") {
    Ok(Some(json.Array(rows))) -> rows
    Ok(Some(_)) | Ok(None) | Error(_) -> []
  }
  Ok(
    list.map(granted, fn(grant) {
      Remembered(grant:, provenance: provenance_for(grant, rows))
    }),
  )
}

fn provenance_for(
  grant: policy.Grant,
  rows: List(json.JsonValue),
) -> Provenance {
  list.find_map(rows, fn(row) {
    use fields <- result.try(case row {
      json.Object(fields) -> Ok(fields)
      _ -> Error(Nil)
    })
    use named <- result.try(list.key_find(fields, "grant"))
    use named <- result.try(grants.decode(named) |> result.replace_error(Nil))
    use <- bool.guard(named != grant, Error(Nil))
    list.key_find(fields, "provenance") |> result.map(decode_provenance)
  })
  |> result.unwrap(Unknown)
}

/// Reads everything the session remembers, with its provenance.
///
/// The general fact is decoded as `read` decodes it but is not checked against
/// the filesystem, so a permission whose path now resolves elsewhere (which
/// dispatch refuses) is still listed, and can be forgotten. A consent cell that
/// cannot be decoded is left out of the listing rather than hiding the rest:
/// dispatch does not honour it either.
///
/// ## Examples
///
/// ```gleam
/// // permissions.listing(runtime)
/// ```
pub fn listing(runtime: api.Runtime) -> Result(Listing, String) {
  use cell <- result.try(
    api.fact_cell(runtime, key)
    |> result.map_error(fn(_) { "session permissions could not be read" }),
  )
  use general <- result.try(case cell {
    None -> Ok([])
    Some(cell) -> general_of(cell.value)
  })
  use actions <- result.map(action_cells(runtime))
  Listing(
    seq: option.map(cell, fn(cell) { cell.seq }),
    grants: list.take(general, listed_limit),
    actions: list.take(actions, listed_limit),
  )
}

fn action_cells(
  runtime: api.Runtime,
) -> Result(List(RememberedAction), String) {
  use names <- result.try(action_names(runtime))
  use cells <- result.map(
    list.try_map(names, fn(name) {
      api.fact_cell(runtime, name)
      |> result.map(fn(cell) { #(name, cell) })
      |> result.map_error(fn(_) { "action permissions could not be read" })
    }),
  )
  list.filter_map(cells, fn(pair) {
    let #(name, cell) = pair
    use cell <- result.try(option.to_result(cell, Nil))
    use _ <- result.map(grants_from(cell.value) |> result.replace_error(Nil))
    RememberedAction(
      id: string.drop_start(name, string.length(action_prefix)),
      seq: cell.seq,
      tool: text_of(cell.value, "tool"),
      strand: text_of(cell.value, "strand"),
      preview: text_of(cell.value, "preview"),
      provenance: case tool.optional_value(cell.value, "provenance") {
        Ok(Some(value)) -> decode_provenance(value)
        Ok(None) | Error(_) -> Unknown
      },
    )
  })
}

fn action_names(runtime: api.Runtime) -> Result(List(String), String) {
  api.reserved_facts(runtime, prefix: action_prefix)
  |> result.map(list.map(_, fn(pair) { pair.0 }))
  |> result.map_error(fn(_) { "action permissions could not be read" })
}

fn text_of(payload: json.JsonValue, field: String) -> Option(String) {
  case tool.optional_value(payload, field) {
    Ok(Some(json.String(text))) -> Some(text)
    Ok(Some(_)) | Ok(None) | Error(_) -> None
  }
}

/// Builds the guarded edit that forgets `target`, as the operator saw the
/// listing at `expected`.
///
/// For `ForgetGrant` and `ForgetAll`, `expected` is the general fact's
/// sequence as the listing carried it; for `ForgetAction` it is that consent's
/// own. A cell that is no longer at the sequence the operator saw, or a target
/// that is no longer remembered, is `Stale`: the permission set the operator
/// looked at is not the one in force, so nothing is written and the operator
/// reads again. `ForgetAll` removes the general permissions and every consent
/// cell it finds, each guarded by the sequence it has when the forget is built,
/// so a consent that moves before the commit loses the transaction; one granted
/// after the listing is forgotten too.
///
/// The general fact is rewritten and never deleted, so its sequence keeps
/// guarding the next approval even when nothing is left in it.
///
/// ## Examples
///
/// ```gleam
/// // permissions.forgetting(runtime, protocol.ForgetAll, expected: Some(4))
/// ```
pub fn forgetting(
  runtime: api.Runtime,
  target: protocol.ForgetTarget,
  expected expected: Option(Seq),
) -> Result(List(api.ReservedFactEdit), Refusal) {
  case target {
    protocol.ForgetGrant(grant:) -> {
      use #(cell, rows) <- result.try(general_at(runtime, expected))
      use <- bool.guard(
        !list.any(rows, fn(row) { row.grant == grant }),
        Error(Stale),
      )
      Ok([
        general_edit(cell, list.filter(rows, fn(row) { row.grant != grant })),
      ])
    }
    protocol.ForgetAction(id:) -> forget_action(runtime, id, expected)
    protocol.ForgetAll -> {
      use #(cell, rows) <- result.try(general_at(runtime, expected))
      use names <- result.try(action_names(runtime) |> result.map_error(Failed))
      use removals <- result.map(
        list.try_map(names, fn(name) { removal(runtime, name) }),
      )
      let general = case rows {
        [] -> []
        [_, ..] -> [general_edit(cell, [])]
      }
      list.append(general, list.flatten(removals))
    }
  }
}

fn forget_action(
  runtime: api.Runtime,
  id: String,
  expected: Option(Seq),
) -> Result(List(api.ReservedFactEdit), Refusal) {
  use name <- result.try(action_name(id))
  use seen <- result.try(option.to_result(
    expected,
    Failed("a consent is forgotten at the sequence it was listed at"),
  ))
  use cell <- result.try(
    api.fact_cell(runtime, name)
    |> result.map_error(fn(_) { Failed("action permissions could not be read") }),
  )
  case cell {
    Some(cell) if cell.seq == seen ->
      Ok([api.ReservedFactRemove(key: name, expected: seen)])
    Some(_) | None -> Error(Stale)
  }
}

// The removal of one consent cell at the sequence it has now. A cell that has
// gone since the names were listed has nothing left to remove.
fn removal(
  runtime: api.Runtime,
  name: String,
) -> Result(List(api.ReservedFactEdit), Refusal) {
  use cell <- result.map(
    api.fact_cell(runtime, name)
    |> result.map_error(fn(_) { Failed("action permissions could not be read") }),
  )
  case cell {
    Some(cell) -> [api.ReservedFactRemove(key: name, expected: cell.seq)]
    None -> []
  }
}

// The consent cell's key for an id the operator named. The id is the cell's
// name under the prefix, which is lower-case hexadecimal; anything else cannot
// name one, and a wire value must not be able to name another reserved cell.
fn action_name(id: String) -> Result(String, Refusal) {
  let hex = "0123456789abcdef"
  let valid =
    id != ""
    && string.byte_size(id) <= 128
    && list.all(string.to_graphemes(id), fn(char) { string.contains(hex, char) })
  case valid {
    True -> Ok(action_prefix <> id)
    False -> Error(Failed("that is not a remembered action"))
  }
}

// The general fact as the operator saw it, or `Stale` when it has moved.
fn general_at(
  runtime: api.Runtime,
  expected: Option(Seq),
) -> Result(#(Option(api.FactCell), List(Remembered)), Refusal) {
  use cell <- result.try(
    api.fact_cell(runtime, key)
    |> result.map_error(fn(_) {
      Failed("session permissions could not be read")
    }),
  )
  use <- bool.guard(
    option.map(cell, fn(cell) { cell.seq }) != expected,
    Error(Stale),
  )
  case cell {
    None -> Ok(#(None, []))
    Some(found) ->
      general_of(found.value)
      |> result.map(fn(rows) { #(cell, rows) })
      |> result.map_error(Failed)
  }
}

// Rewrites the general fact to the permissions that remain, guarded by the
// sequence it was read at.
fn general_edit(
  cell: Option(api.FactCell),
  remaining: List(Remembered),
) -> api.ReservedFactEdit {
  api.ReservedFactSet(api.ReservedFactChange(
    key:,
    value: encode_general(remaining, None),
    expected: option.map(cell, fn(cell) { cell.seq }),
  ))
}

/// The listing as the wire carries it in a `permissions` snapshot.
///
/// Grants use the protocol's grant vocabulary, so a client echoes one back to
/// forget it. Nothing here is a credential: a fingerprint identifies a login
/// and authenticates nothing.
///
/// ## Examples
///
/// ```gleam
/// // permissions.board(listing)
/// ```
pub fn board(listing: Listing) -> json.JsonValue {
  json.Object([
    #("seq", case listing.seq {
      Some(seq) -> json.Int(seq)
      None -> json.Null
    }),
    #(
      "grants",
      json.Array(
        list.map(listing.grants, fn(row) {
          json.Object([
            #("grant", protocol.encode_grant(row.grant)),
            #("provenance", encode_provenance(row.provenance)),
          ])
        }),
      ),
    ),
    #(
      "actions",
      json.Array(
        list.map(listing.actions, fn(row) {
          json.Object([
            #("id", json.String(row.id)),
            #("seq", json.Int(row.seq)),
            #("tool", optional(row.tool)),
            #("strand", optional(row.strand)),
            #("preview", optional(row.preview)),
            #("provenance", encode_provenance(row.provenance)),
          ])
        }),
      ),
    ),
  ])
}

fn optional(value: Option(String)) -> json.JsonValue {
  case value {
    Some(text) -> json.String(text)
    None -> json.Null
  }
}
