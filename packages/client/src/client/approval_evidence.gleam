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
//// approval words): the network the call would have, the session's sandbox
//// and network policy today, and for a `code_mode` program the capability call
//// and command that the program's source names.
////
//// ## Flow
////
//// `read` → `item` → `wanted_line`
////
//// 1. `read` lists the escalation records and keeps the pending ones in id
////    order, a few of them, with the total as a count.
//// 2. `item` words one record at the revision of its cell, with the network
////    word, the policy and, for a program, what `code_call` reads from it.
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

/// The longest command a `code_mode` item names, in bytes.
pub const command_bytes = 400

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
/// `today` is the session's policy in words, or nothing for a host that has
/// none to lend, in which case an item carries neither the policy nor a network
/// word it cannot know.
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

  // Only a record that still awaits a decision is evidence for a person.
  let pending =
    records
    |> list.filter(fn(record) { record.status == escalation.Pending })
    |> list.sort(fn(left, right) { string.compare(left.id, right.id) })
  let items =
    pending
    |> list.take(max_items)
    |> list.filter_map(fn(record) { item(runtime, record, today) })

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
) -> Result(JsonValue, Nil) {
  use cell <- result.map(
    api.escalation_cell(runtime, record.id) |> result.replace_error(Nil),
  )
  let record = cell.record
  let #(call, command) = code_call(tool_of(record), record.preview)

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
        option.map(network_word(today, record.denial), json.String),
      ),
      optional("policy", option.map(today, policy_json)),
      optional("call", option.map(call, json.String)),
      optional("command", option.map(command, json.String)),
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

/// The network the call would have if it were approved: `on` when the policy
/// lets tools out today or when the denial wants a network grant that is not
/// `off`, and `off` otherwise. Nothing when the host lent no policy and the
/// denial asks for no network, since the answer would then be a guess.
fn network_word(today: Option(Today), denial: JsonValue) -> Option(String) {
  let wants_network = list.any(wanted_list(denial), wants_network_on)

  // A network grant that is on, or a policy that lets tools out, gives the call a network.
  case wants_network, today {
    True, _ -> Some("on")
    False, Some(Today(network: "proxy", ..))
    | False, Some(Today(network: "on", ..))
    -> Some("on")
    False, Some(_) -> Some("off")
    False, None -> None
  }
}

/// Whether a wanted grant is a network grant for a mode other than `off`.
fn wants_network_on(grant: JsonValue) -> Bool {
  field_text(grant, "grant") == "network"
  && network_mode(grant) != "off"
  && network_mode(grant) != ""
}

/// The call a `code_mode` program makes and the command it runs, when the
/// program's source names one. The preview of a `code_mode` call is the
/// canonical JSON of its arguments, so the program is its `program` string.
/// The capability that runs a command is `proc.run`, and its argv is the list
/// of string literals in the first `proc.command([...])`. A preview that was
/// cut, a program that is not inline, a source with no such call, or an argv
/// with an escape in it gives neither: a command read wrongly is worse than
/// none, and a page then draws only the tool.
///
/// ## Examples
///
/// ```gleam
/// assert approval_evidence.code_call("bash", Some("{}")) == #(None, None)
/// ```
pub fn code_call(
  tool: String,
  preview: Option(String),
) -> #(Option(String), Option(String)) {
  // Only a `code_mode` call that has a preview has a program to read.
  let argv = case tool, preview {
    "code_mode", Some(text) -> proc_argv(text)
    _, _ -> Error(Nil)
  }

  // A readable program names the call and the command, and any other names neither.
  case argv {
    Ok(command) -> #(
      Some("proc.run"),
      Some(glance.clip(command, command_bytes)),
    )
    Error(Nil) -> #(None, None)
  }
}

/// The first `proc.command` argv of the program in a `code_mode` preview, as
/// one line.
fn proc_argv(preview: String) -> Result(String, Nil) {
  use parsed <- result.try(json.parse(preview) |> result.replace_error(Nil))

  // The preview of a `code_mode` call is an object whose `program` is the source.
  use program <- result.try(case parsed {
    json.Object(fields) ->
      case list.key_find(fields, "program") {
        Ok(json.String(program)) -> Ok(program)
        Ok(_) | Error(Nil) -> Error(Nil)
      }
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error(Nil)
  })

  use #(_, after) <- result.try(string.split_once(program, "proc.command(["))
  use #(inside, _) <- result.try(string.split_once(after, "]"))

  // Between the quotes of a list of strings the odd pieces are the literals. A
  // backslash means an escape this reader does not decode, so it refuses.
  let literals =
    string.split(inside, "\"")
    |> list.index_map(fn(piece, index) { #(index, piece) })
    |> list.filter_map(fn(pair) {
      case pair.0 % 2 {
        1 -> Ok(pair.1)
        _ -> Error(Nil)
      }
    })

  // An escape in the argv, or no literal at all, is not a command this reader trusts.
  case string.contains(inside, "\\"), literals {
    True, _ | False, [] -> Error(Nil)
    False, [_, ..] -> Ok(string.join(literals, " "))
  }
}

/// The tool the record was raised for. A record raised through a door that
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
