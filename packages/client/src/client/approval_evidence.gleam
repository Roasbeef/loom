//// What a session's pending approvals are, worded as evidence a person can read
//// on Home before opening the session's own page (protocol-change/120, the
//// addendum "Approval evidence").
////
//// An approval is decided on the session's page, from the card that page draws,
//// and nowhere else. This module is the read half only: it lists the session's
//// pending escalation records with the revision of each, and for each the tool,
//// a bounded rendering of the action, what held it and which grants it wants.
//// It never decides, consumes or claims a record.
////
//// An item carries `raised_at`, the time the record's question was put to a
//// person (protocol-change/124), and none for a record written before that
//// field existed. The record's scope names the operation that held the claim,
//// and an operation can run for hours before it raises, so no age is ever
//// worded from the scope (120 rejects the same idea for the feed).
////
//// An item also says what a person weighs the grant against, all read when the
//// read is made and never stored (protocol-change/120, the addendum on
//// approval words): the network the call would have and the session's sandbox
//// and network policy today. Each word is the one dispatch would apply: the
//// assembled base policy with the session's remembered grants folded in. When
//// either is not known the word is left out, and no word ever claims `off` on a
//// guess, because evidence that understates what a call gets is the dangerous
//// direction. The call and command inside a `code_mode` program are not read
//// from the program's source, which a model wrote and which can show a command
//// the program never runs, and the escalation records no such call.
////
//// ## Flow
////
//// `read` → `item` → `wanted_line`
////
//// 1. `read` lists the escalation records and keeps the pending ones in id
////    order, a few of them, with the total as a count.
//// 2. `item` words one record at the revision of its cell, with the network
////    word and the policy.
//// 3. `wanted_line` turns one wanted grant, in the escalation vocabulary, into a
////    kind and a short detail.
////
//// ## Bounds
////
//// Every text is cut on a grapheme boundary (`core/glance.clip`), at most
//// `max_wanted` grants are listed for a record, and the number of records is
//// `max_items`, so a reply stays far under one frame whatever the session
//// holds. The tool, preview and denial reason were written by the harness and
//// the model, so the page draws them as text nodes and nowhere else.

import broker/policy
import client/grants
import core/glance
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import runtime/api
import runtime/escalation.{type Escalation}

/// The most pending records one read lists.
pub const max_items = 4

/// The most wanted grants one record lists.
pub const max_wanted = 6

/// The longest tool name, in bytes.
pub const tool_bytes = 64

/// The longest action preview, in bytes. The record bounds its own preview, so
/// this is a ceiling on what the reply repeats.
pub const preview_bytes = 400

/// The longest denial reason, in bytes.
pub const reason_bytes = 300

/// The longest detail of one wanted grant, in bytes.
pub const detail_bytes = 160

/// The sandbox and network a session runs its tools under today, in the words
/// a page draws. The session's host works them out from its base policy
/// (`today_of`) and lends them to the read, so a record is never stored with
/// words that a later setting would make false.
pub type Today {
  Today(
    /// `workspace-write` when the jail may write under a root, `read-only`
    /// when it may write nowhere.
    sandbox: String,
    /// `off`, `loopback`, `proxy` or `on` (unrestricted).
    network: String,
  )
}

/// The words for a base policy.
///
/// ## Examples
///
/// ```gleam
/// // approval_evidence.today_of(workspace_policy.base_policy("/work"))
/// //   == Today("workspace-write", "on")
/// ```
pub fn today_of(base: policy.SandboxPolicy) -> Today {
  Today(
    sandbox: case base.writable_roots {
      [] -> "read-only"
      [_, ..] -> "workspace-write"
    },
    network: case base.network {
      policy.NetworkOff -> "off"
      policy.NetworkLoopback -> "loopback"
      policy.NetworkProxy(..) -> "proxy"
      policy.NetworkFull -> "on"
    },
  )
}

/// The session's pending approvals as one reply object:
/// `{"approvals": {"count", "items": [...]}}`. A record that cannot be read at
/// its cell is left out of the items and still counted.
///
/// `today` is the assembled base policy in words, or nothing for a host that has
/// none to lend. The session's remembered grants are read here, at the moment of
/// the read, and folded in: a remembered full network makes the item `on`. A
/// host with no policy, and a store whose remembered grants cannot be read, leave
/// out the words that need them.
///
/// ## Examples
///
/// ```gleam
/// // approval_evidence.read(runtime, Some(approval_evidence.Today("workspace-write", "off")))
/// ```
pub fn read(
  runtime: api.Runtime,
  today: Option(Today),
) -> Result(JsonValue, String) {
  use records <- result.map(
    api.escalations(runtime) |> result.map_error(string.inspect),
  )
  let remembered = remembered_network(runtime)

  // Only a record that still awaits a decision is evidence for a person.
  let pending =
    records
    |> list.filter(fn(record) { record.status == escalation.Pending })
    |> list.sort(fn(left, right) { string.compare(left.id, right.id) })
  let items =
    pending
    |> list.take(max_items)
    |> list.filter_map(fn(record) { item(runtime, record, today, remembered) })

  json.Object([
    #(
      "approvals",
      json.Object([
        #("count", json.Int(list.length(pending))),
        #("items", json.Array(items)),
      ]),
    ),
  ])
}

/// One pending record worded at the revision of its cell, or nothing when the
/// cell cannot be read again, which happens only when it was decided between
/// the listing and this read.
fn item(
  runtime: api.Runtime,
  record: Escalation,
  today: Option(Today),
  remembered: Remembered,
) -> Result(JsonValue, Nil) {
  use cell <- result.map(
    api.escalation_cell(runtime, record.id) |> result.replace_error(Nil),
  )
  let record = cell.record

  json.Object(
    list.flatten([
      [
        #("id", json.String(glance.clip(record.id, 64))),
        #("revision", json.Int(cell.seq)),
        #("tool", json.String(glance.clip(tool_of(record), tool_bytes))),
        #("preview", case record.preview {
          Some(text) -> json.String(glance.clip(text, preview_bytes))
          None -> json.Null
        }),
        #("source", json.String(source_of(record.denial))),
        #(
          "reason",
          json.String(glance.clip(reason_of(record.denial), reason_bytes)),
        ),
        #("wanted", json.Array(wanted_of(record.denial))),
        #("asked", json.Int(record.asked)),
      ],
      optional("raised_at", option.map(record.raised_at, json.Int)),
      optional(
        "network",
        option.map(network_word(today, remembered, record.denial), json.String),
      ),
      optional(
        "policy",
        option.map(policy_words(today, remembered), policy_json),
      ),
    ]),
  )
}

/// A member that is present only when it has a value.
fn optional(
  name: String,
  value: Option(JsonValue),
) -> List(#(String, JsonValue)) {
  case value {
    Some(value) -> [#(name, value)]
    None -> []
  }
}

/// The session's policy as `{"sandbox", "network"}`.
fn policy_json(today: Today) -> JsonValue {
  json.Object([
    #("sandbox", json.String(today.sandbox)),
    #("network", json.String(today.network)),
  ])
}

/// What the session remembers about the network, read from the store at the
/// moment of the read.
type Remembered {
  /// A full network grant is remembered, so tools reach the network whatever the
  /// base policy says.
  NetworkRemembered

  /// The remembered grants were read and hold no full network.
  NothingRemembered

  /// The remembered grants could not be read, so nothing is known.
  Unknown
}

/// The cell the session's remembered grants are stored in. It is
/// `permissions.key`, spelled here because `client/permissions` reaches this
/// module through `client/escalate`, and a test pins the two together.
pub const remembered_key = "client/permission_grants"

/// The session's remembered grants, as far as the network is concerned. A cell
/// that is absent holds nothing, and one that does not decode is not known.
fn remembered_network(runtime: api.Runtime) -> Remembered {
  case api.fact(runtime, remembered_key) {
    Ok(None) -> NothingRemembered
    Ok(Some(json.Object(fields))) ->
      case list.key_find(fields, "grants") {
        Ok(json.Array(encoded)) ->
          case grants.decode_all(encoded) {
            Ok(held) ->
              case
                list.contains(held, policy.GrantNetwork(policy.NetworkFull))
              {
                True -> NetworkRemembered
                False -> NothingRemembered
              }
            Error(_) -> Unknown
          }
        Ok(_) | Error(Nil) -> Unknown
      }
    Ok(Some(_)) | Error(_) -> Unknown
  }
}

/// The session's policy today: the assembled base with the remembered grants
/// folded in. Nothing when the host lent no base or the remembered grants are
/// not known, so a word is never a guess.
fn policy_words(today: Option(Today), remembered: Remembered) -> Option(Today) {
  case today, remembered {
    Some(base), NetworkRemembered -> Some(Today(..base, network: "on"))
    Some(base), NothingRemembered -> Some(base)
    Some(_), Unknown | None, _ -> None
  }
}

/// The network the call would have if it were approved. `on` when the denial
/// wants a network grant that is not `off`, when a full network is remembered, or
/// when the policy today lets tools out. `off` only when the policy today is
/// off and nothing remembered or wanted adds a network. Nothing in every other
/// case, loopback included, since a word that cannot be exact is left out.
fn network_word(
  today: Option(Today),
  remembered: Remembered,
  denial: JsonValue,
) -> Option(String) {
  let wants_network = list.any(wanted_list(denial), wants_network_on)

  // Anything that adds a network makes the call `on`, and `off` needs the whole
  // of the policy to be known.
  case wants_network, remembered, policy_words(today, remembered) {
    True, _, _ | False, NetworkRemembered, _ -> Some("on")
    False, _, Some(Today(network: "off", ..)) -> Some("off")
    False, _, Some(Today(network: "proxy", ..))
    | False, _, Some(Today(network: "on", ..))
    -> Some("on")
    False, _, Some(Today(network: _, ..)) | False, _, None -> None
  }
}

/// Whether a wanted grant is a network grant for a mode other than `off`.
fn wants_network_on(grant: JsonValue) -> Bool {
  field_text(grant, "grant") == "network"
  && network_mode(grant) != "off"
  && network_mode(grant) != ""
}

/// names no action has none, which the page words as unknown.
fn tool_of(record: Escalation) -> String {
  option.unwrap(record.tool, "")
}

/// The denial's source word, `policy` or `execution`, or empty when the stored
/// denial has none.
fn source_of(denial: JsonValue) -> String {
  field_text(denial, "source")
}

/// The denial's reason, or empty when the stored denial has none.
fn reason_of(denial: JsonValue) -> String {
  field_text(denial, "reason")
}

/// A text member of a stored object, or empty.
fn field_text(value: JsonValue, name: String) -> String {
  case value {
    json.Object(fields) ->
      case list.key_find(fields, name) {
        Ok(json.String(text)) -> text
        Ok(_) | Error(Nil) -> ""
      }
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> ""
  }
}

/// The wanted grants of a denial as `{kind, detail}` objects, in order and at
/// most `max_wanted`.
fn wanted_of(denial: JsonValue) -> List(JsonValue) {
  wanted_list(denial) |> list.take(max_wanted) |> list.map(wanted_line)
}

/// The raw wanted grants of a denial. A denial with no wanted list wants
/// nothing the page can list.
fn wanted_list(denial: JsonValue) -> List(JsonValue) {
  case denial {
    json.Object(fields) ->
      case list.key_find(fields, "wanted") {
        Ok(json.Array(items)) -> items
        Ok(_) | Error(Nil) -> []
      }
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> []
  }
}

/// One wanted grant as a kind and a short detail: the path of a root, the mode
/// of a network, the name of an environment variable, a limit's field and
/// value, a scratch's word. A grant of a shape this module does not know is
/// `other`, with nothing to say about it.
///
/// ## Examples
///
/// ```gleam
/// // approval_evidence.wanted_line(json.Object([#("grant", json.String("env")), #("name", json.String("HOME"))]))
/// ```
pub fn wanted_line(grant: JsonValue) -> JsonValue {
  let kind = field_text(grant, "grant")

  // Each kind of grant keeps the member that says what it is about.
  let detail = case kind {
    "writable_root" | "readable_root" -> field_text(grant, "path")
    "env" -> field_text(grant, "name")
    "scratch" -> field_text(grant, "scratch")
    "limit" -> field_text(grant, "field") <> " " <> field_number(grant, "value")
    "network" -> network_mode(grant)
    _ -> ""
  }

  json.Object([
    #("kind", json.String(glance.clip(kind, 32))),
    #("detail", json.String(glance.clip(detail, detail_bytes))),
  ])
}

/// The mode of a network grant: `off`, `loopback`, `full` or `proxy`.
fn network_mode(grant: JsonValue) -> String {
  case grant {
    json.Object(fields) ->
      case list.key_find(fields, "network") {
        Ok(network) -> field_text(network, "mode")
        Error(Nil) -> ""
      }
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> ""
  }
}

/// An integer member of a stored object as text, or empty.
fn field_number(value: JsonValue, name: String) -> String {
  case value {
    json.Object(fields) ->
      case list.key_find(fields, name) {
        Ok(json.Int(number)) -> json.to_string(json.Int(number))
        Ok(_) | Error(Nil) -> ""
      }
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> ""
  }
}
