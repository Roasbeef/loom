//// The owner's view of a daemon's membership ledger over the control socket
//// (protocol-change/086): `ledger.append`, `ledger.entries`, `ledger.status` and
//// `ledger.holdings`.
////
//// Both halves of the exchange live here so they cannot drift. The daemon's
//// half turns a decoded request into a reply by asking the `loom_ledger`
//// process (`ledger_service`), and the operator's half turns a reply back into
//// values with total decoders. A reply from a daemon is data at a boundary: an
//// operator tool that reads one decides what to sign from it, so every field is
//// checked and a missing or mistyped one is an `Error`, never a default.
////
//// ## What each command is
////
//// - `append` offers lines to the process one at a time, in order, through the
////   same acceptance procedure a peer's line goes through. The control socket
////   adds no trust in the caller beyond the owner check, because the process
////   verifies the signature and the chain. A refusal names the step. Lines
////   applied before the failing one stay applied.
//// - `entries` is the local twin of a peer's `Pull`: the lines after a sequence
////   number. The operator's tool reads it to fetch what its own copy lacks
////   before it signs.
//// - `status` reports the head, this node's standing, every active member with
////   its links, its certificate pin and the head it last reported, and the last
////   refusal.
//// - `holdings` asks each orchestrator the daemon is linked to, and the daemon
////   itself, what its catalogue holds (`client/ledger_holdings`). The operator's
////   tool reads it before it signs a `revoke`. It is the one command that
////   reaches other machines, so it is bounded by its own deadline and reports
////   an orchestrator that did not answer as silent.
////
//// ## Frames are 64 KiB
////
//// The control protocol bounds a frame at 64 KiB in both directions
//// (`daemon/protocol.max_bytes`). A page of entries is therefore cut to
//// `max_page_bytes` of lines even when `limit` allowed more, and a caller
//// continues from the last line it received. An append is bounded by the same
//// frame, so a caller sends pages of at most `max_append_lines` and
//// `max_page_bytes` bytes, whichever is reached first (`pages`).

import client/distribution_plan
import client/ledger_holdings.{type Asker}
import client/ledger_service.{type Service}
import client/membership_entry
import client/membership_ledger
import client/remote/orchestrator_port
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The most lines one `ledger.append` carries.
pub const max_append_lines = 64

/// The most bytes of lines one frame carries, in either direction. Well under
/// the 64 KiB frame, which also holds the envelope and the JSON quoting.
pub const max_page_bytes = 48_000

/// How long the daemon waits for the ledger process to answer one request.
const within_ms = 5000

// --- the daemon's half -------------------------------------------------------

/// A daemon's ledger and what it needs to describe itself: the process, the
/// node name from its `[distribution]` table, and its plan name from the ledger
/// it started with. The name is fixed at start because a node that has since
/// been revoked can no longer find itself in the ledger by node name, and
/// `ledger.status` still has to say it was revoked.
pub type Handle {
  Handle(
    /// The `loom_ledger` process.
    service: Service,
    /// This node's Erlang node name.
    local: String,
    /// This node's plan name.
    name: String,
    /// How `ledger.holdings` asks an orchestrator what it holds. A handle
    /// built by `handle` asks nobody, so every orchestrator reads as silent;
    /// the daemon gives it the production asker with `asking`.
    asker: Asker,
  )
}

/// Builds the handle for a running service, finding the node's plan name in
/// the ledger the process holds. The node was an active member when the
/// process started, so a miss means the process is not answering.
///
/// ## Examples
///
/// ```gleam
/// ledger_control.handle(service, "loom@hub.example") // -> Ok(Handle(..))
/// ```
pub fn handle(service: Service, local: String) -> Result(Handle, String) {
  use status <- result.try(
    ledger_service.status(service, within_ms)
    |> result.replace_error("the ledger process did not answer"),
  )
  use member <- result.map(
    membership_ledger.member_at(status.ledger, local)
    |> result.map_error(fn(_) {
      local <> " is not an active member of its ledger"
    }),
  )
  Handle(service:, local:, name: member.name, asker: ledger_holdings.silent)
}

/// The same handle with the way `ledger.holdings` reaches the orchestrators.
///
/// ## Examples
///
/// ```gleam
/// ledger_control.asking(handle, ledger_holdings.over_distribution(membership, local))
/// ```
pub fn asking(handle: Handle, asker: Asker) -> Handle {
  Handle(..handle, asker:)
}

/// Why a request was not answered with a reply.
pub type Failure {
  /// A line failed the acceptance procedure. `step` is the word of the control
  /// protocol: `malformed`, `bad_signature`, `fork`, `chain`, `invalid` or
  /// `unsupported_format`, and `gap` for a line more than one past the head.
  Invalid(step: String)

  /// The line is valid and the file could not take it, or the process did not
  /// answer in time.
  Unavailable(reason: String)
}

/// `ledger.append`: offers each line in order and reports how many were
/// applied and the head afterwards. A line the ledger already holds is not an
/// error and is not counted.
///
/// ## Examples
///
/// ```gleam
/// ledger_control.append(handle, [line])
/// // -> Ok(json.Object([#("applied", json.Int(1)), #("head", ..)]))
/// ```
pub fn append(
  handle: Handle,
  lines: List(String),
) -> Result(JsonValue, Failure) {
  use applied <- result.try(offer_all(handle.service, lines, 0))
  use head <- result.map(head_of(handle))
  json.Object([#("applied", json.Int(applied)), #("head", head_json(head))])
}

/// Recursively offers signed lines to the ledger service until the list is exhausted.
fn offer_all(
  service: Service,
  lines: List(String),
  applied: Int,
) -> Result(Int, Failure) {
  // Offer next line or return count of applied lines.
  case lines {
    [] -> Ok(applied)
    [line, ..rest] -> {
      use offered <- result.try(
        ledger_service.offer(service, bit_array.from_string(line), within_ms)
        |> result.replace_error(Unavailable("the ledger process did not answer")),
      )

      // Handle service offer outcome.
      case offered {
        ledger_service.Accepted(..) -> offer_all(service, rest, applied + 1)
        ledger_service.AlreadyHeld -> offer_all(service, rest, applied)
        ledger_service.Behind(..) -> Error(Invalid("gap"))
        ledger_service.Refused(refusal:) ->
          Error(Invalid(membership_ledger.step(refusal)))
        ledger_service.NotDurable(reason:) -> Error(Unavailable(reason))
      }
    }
  }
}

/// `ledger.entries`: the lines after `after`, at most `limit` of them (clamped
/// as a peer's `Pull` is) and at most `max_page_bytes` bytes, with the head's
/// sequence number so the caller knows whether to ask again.
///
/// ## Examples
///
/// ```gleam
/// ledger_control.entries(handle, 7, 64)
/// // -> Ok(json.Object([#("lines", ..), #("head_seq", json.Int(9))]))
/// ```
pub fn entries(
  handle: Handle,
  after: Int,
  limit: Int,
) -> Result(JsonValue, Failure) {
  use read <- result.try(
    ledger_service.entries(handle.service, after, limit, within_ms)
    |> result.replace_error(Unavailable("the ledger process did not answer")),
  )
  let texts =
    list.filter_map(read.lines, fn(line) { bit_array.to_string(line) })
  Ok(
    json.Object([
      #("lines", json.Array(list.map(fit_page(texts), json.String))),
      #("head_seq", json.Int(read.head_seq)),
    ]),
  )
}

/// The leading lines that fit one frame, oldest first. The first line is always
/// kept so that a caller makes progress; a line that large is refused by the
/// ledger's own 4 KiB body bound long before it reaches here.
///
/// ## Examples
///
/// ```gleam
/// assert ledger_control.fit_page(["a", "b"]) == ["a", "b"]
/// ```
pub fn fit_page(lines: List(String)) -> List(String) {
  let #(kept, _) =
    list.fold(lines, #([], 0), fn(state, line) {
      let #(kept, bytes) = state
      let size = bit_array.byte_size(bit_array.from_string(line))

      // Keep lines within maximum page byte boundary.
      case kept, bytes + size > max_page_bytes {
        [_, ..], True -> state
        _, _ -> #([line, ..kept], bytes + size)
      }
    })
  list.reverse(kept)
}

/// `ledger.status`: the head, this node's standing, each active member with its
/// links, the hex SHA-256 of its certificate and the head it last reported, and
/// the last refusal.
///
/// ## Examples
///
/// ```gleam
/// ledger_control.status(handle) // -> Ok(json.Object([#("deployment", ..), ..]))
/// ```
pub fn status(handle: Handle) -> Result(JsonValue, Failure) {
  use status <- result.map(
    ledger_service.status(handle.service, within_ms)
    |> result.replace_error(Unavailable("the ledger process did not answer")),
  )
  let ledger = status.ledger
  let head = membership_ledger.head(ledger)

  // Map membership status tag to string.
  let state = case membership_ledger.enrollment(ledger, handle.name) {
    membership_ledger.Enrolled(..) -> "ok"
    membership_ledger.Revoked -> "revoked"
    membership_ledger.NotEnrolled -> "not_enrolled"
  }

  let members =
    list.map(membership_ledger.members(ledger), fn(member) {
      // Map reported status sequence for local or remote member.
      let reported = case member.node == handle.local {
        True -> [
          #("reported_seq", json.Int(head.seq)),
          #("ms_since_report", json.Int(0)),
        ]
        False ->
          case
            list.find(status.reported, fn(seen) { seen.node == member.node })
          {
            Ok(seen) -> [
              #("reported_seq", json.Int(seen.seq)),
              #("ms_since_report", json.Int(seen.ms_since)),
            ]
            Error(Nil) -> []
          }
      }

      json.Object(
        list.flatten([
          [
            #("name", json.String(member.name)),
            #("node", json.String(member.node)),
            #("role", json.String(distribution_plan.role_word(member.role))),
            #(
              "directory",
              json.String(membership_entry.directory_word(member.directory)),
            ),
            #("links", json.Array(list.map(member.links, json.String))),
            #("pin", json.String(pin_hex(member.pin))),
          ],
          reported,
        ]),
      )
    })
  json.Object([
    #("deployment", json.String(membership_ledger.deployment(ledger))),
    #("state", json.String(state)),
    #("head", head_json(head)),
    #(
      "self",
      json.Object([
        #("name", json.String(handle.name)),
        #("enrolled", json.Bool(state == "ok")),
      ]),
    ),
    #("members", json.Array(members)),
    #("last_refusal", refusal_json(status.last_refusal)),
  ])
}

// The hex of a certificate pin, lower case: the SHA-256 of the leaf, which the
// pin table already holds and a certificate's public bytes already determine.
fn pin_hex(pin: BitArray) -> String {
  string.lowercase(bit_array.base16_encode(pin))
}

/// `ledger.holdings`: asks every orchestrator this node is linked to, and this
/// node itself if it is one, what its catalogue holds, and reports each answer.
/// An orchestrator that did not answer is listed without `sessions`, so that a
/// reader can tell silence from none. The operator's tool decides what the
/// answers mean for a `revoke` (`client/ledger_operator.holdings`).
///
/// The request waits for the slowest ask, at most `ledger_holdings.deadline_ms`.
///
/// ## Examples
///
/// ```gleam
/// ledger_control.holdings(handle)
/// // -> Ok(json.Object([#("orchestrators", json.Array([..]))]))
/// ```
pub fn holdings(handle: Handle) -> Result(JsonValue, Failure) {
  use status <- result.map(
    ledger_service.status(handle.service, within_ms)
    |> result.replace_error(Unavailable("the ledger process did not answer")),
  )
  let answers =
    ledger_holdings.collect(status.ledger, handle.local, handle.asker)
  json.Object([
    #("orchestrators", json.Array(list.map(answers, answer_json))),
  ])
}

/// Serializes a node session holding answer to JSON.
fn answer_json(answer: ledger_holdings.Answer) -> JsonValue {
  let who = [
    #("name", json.String(answer.name)),
    #("node", json.String(answer.node)),
  ]

  // Encode held session details if present.
  case answer.held {
    None -> json.Object(who)
    Some(held) ->
      json.Object(
        list.append(who, [
          #("sessions", json.Int(held.sessions)),
          #(
            "placed",
            json.Array(
              list.map(held.placed, fn(placed) {
                json.Object([
                  #("node", json.String(placed.executor_node)),
                  #("sessions", json.Int(placed.sessions)),
                ])
              }),
            ),
          ),
        ]),
      )
  }
}

fn head_of(handle: Handle) -> Result(membership_ledger.Head, Failure) {
  ledger_service.head(handle.service, within_ms)
  |> result.replace_error(Unavailable("the ledger process did not answer"))
}

fn head_json(head: membership_ledger.Head) -> JsonValue {
  json.Object([
    #("seq", json.Int(head.seq)),
    #("id", json.String(membership_entry.id_to_hex(head.id))),
  ])
}

/// Serializes a rejected ledger entry refusal into JSON value.
fn refusal_json(last: Option(ledger_service.Rejected)) -> JsonValue {
  // Check whether a rejected entry record is present.
  case last {
    None -> json.Null
    Some(rejected) -> {
      // Format fork details if refusal represents a chain fork.
      let forked = case rejected.refusal {
        membership_ledger.Fork(ours:, theirs:, ..) -> [
          #("ours", json.String(membership_entry.id_to_hex(ours))),
          #("theirs", json.String(membership_entry.id_to_hex(theirs))),
        ]
        _ -> []
      }

      json.Object(
        list.flatten([
          [
            #("seq", case rejected.seq {
              Some(seq) -> json.Int(seq)
              None -> json.Null
            }),
            #("step", json.String(membership_ledger.step(rejected.refusal))),
          ],
          forked,
        ]),
      )
    }
  }
}

// --- the operator's half -----------------------------------------------------

/// A head as a daemon reported it: the sequence number and the 64 hex
/// characters of the identity.
pub type HeadView {
  HeadView(seq: Int, id: String)
}

/// One active member in a status reply.
pub type MemberView {
  MemberView(
    name: String,
    node: String,
    role: String,
    directory: String,
    /// The sequence number of the newest entry the member reported, or `None`
    /// when it has not reported to the answering daemon.
    reported_seq: Option(Int),
    /// Milliseconds on the answering daemon's own clock since that report.
    ms_since_report: Option(Int),
    /// The plan names of the members this one is linked to. A daemon that
    /// predates the member sends none, which reads as an empty list.
    links: List(String),
    /// The hex SHA-256 of the member's certificate, which its peers pin. `None`
    /// from a daemon that predates the member.
    pin: Option(String),
  )
}

/// The last line a daemon refused.
pub type RefusalView {
  RefusalView(
    /// The sequence number the line claimed, when it had one.
    seq: Option(Int),
    /// The step that failed.
    step: String,
    /// For a fork, the identity the daemon applied and the one it refused.
    ours: Option(String),
    theirs: Option(String),
  )
}

/// A daemon's standing in its own ledger.
pub type Standing {
  /// An active member.
  Enrolled

  /// Enrolled once and revoked since.
  Revoked

  /// Never enrolled.
  NotEnrolled
}

/// A `ledger.status` reply.
pub type StatusView {
  StatusView(
    /// The 32 hex characters naming the deployment.
    deployment: String,
    standing: Standing,
    head: HeadView,
    /// The answering node's plan name.
    self_name: String,
    members: List(MemberView),
    last_refusal: Option(RefusalView),
  )
}

/// A `ledger.entries` reply.
pub type PageView {
  PageView(lines: List(String), head_seq: Int)
}

/// A `ledger.append` reply.
pub type AppliedView {
  AppliedView(applied: Int, head: HeadView)
}

/// Reads a `ledger.status` reply.
///
/// ## Examples
///
/// ```gleam
/// ledger_control.decode_status(json) // -> Ok(StatusView(..))
/// ```
pub fn decode_status(value: JsonValue) -> Result(StatusView, String) {
  use fields <- result.try(object(Ok(value), "status"))
  use deployment <- result.try(string_of(fields, "deployment"))
  use state <- result.try(string_of(fields, "state"))

  // Parse member standing string from status payload.
  use standing <- result.try(case state {
    "ok" -> Ok(Enrolled)
    "revoked" -> Ok(Revoked)
    "not_enrolled" -> Ok(NotEnrolled)
    _ -> Error("status.state is not a standing")
  })

  use head <- result.try(head_view(field(fields, "head")))
  use self_fields <- result.try(object(field(fields, "self"), "status.self"))
  use self_name <- result.try(string_of(self_fields, "name"))

  // Decode array of member status records.
  use members <- result.try(case field(fields, "members") {
    Ok(json.Array(items)) -> list.try_map(items, member_view)
    _ -> Error("status.members is not an array")
  })

  // Decode optional last rejection record.
  use last_refusal <- result.try(case field(fields, "last_refusal") {
    Ok(json.Null) -> Ok(None)
    other -> refusal_view(other) |> result.map(Some)
  })

  Ok(StatusView(
    deployment:,
    standing:,
    head:,
    self_name:,
    members:,
    last_refusal:,
  ))
}

/// Reads a `ledger.entries` reply.
///
/// ## Examples
///
/// ```gleam
/// ledger_control.decode_entries(json) // -> Ok(PageView(lines: [..], head_seq: 9))
/// ```
pub fn decode_entries(value: JsonValue) -> Result(PageView, String) {
  use fields <- result.try(object(Ok(value), "entries"))

  // Decode array of ledger lines from entries payload.
  use lines <- result.try(case list.key_find(fields, "lines") {
    Ok(json.Array(items)) ->
      list.try_map(items, fn(item) {
        case item {
          json.String(line) -> Ok(line)
          _ -> Error("entries.lines holds something that is not a line")
        }
      })
    _ -> Error("entries.lines is not an array")
  })

  use head_seq <- result.map(int_of(fields, "head_seq"))
  PageView(lines:, head_seq:)
}

/// Reads a `ledger.append` reply.
///
/// ## Examples
///
/// ```gleam
/// ledger_control.decode_applied(json) // -> Ok(AppliedView(applied: 1, head:))
/// ```
pub fn decode_applied(value: JsonValue) -> Result(AppliedView, String) {
  use fields <- result.try(object(Ok(value), "append"))
  use applied <- result.try(int_of(fields, "applied"))
  use head <- result.map(head_view(field(fields, "head")))
  AppliedView(applied:, head:)
}

/// The sessions placed on one executor, as an orchestrator reported them.
pub type PlacedView {
  PlacedView(node: String, sessions: Int)
}

/// What one orchestrator reported holding.
pub type HeldView {
  HeldView(sessions: Int, placed: List(PlacedView))
}

/// One orchestrator in a `ledger.holdings` reply. `held` is `None` when it did
/// not answer, which is silence and not "nothing".
pub type AnswerView {
  AnswerView(name: String, node: String, held: Option(HeldView))
}

/// Reads a `ledger.holdings` reply. At most `membership_ledger.max_active`
/// orchestrators are accepted, each with at most `orchestrator_port.max_placed`
/// placements, and a count below zero is refused.
///
/// ## Examples
///
/// ```gleam
/// ledger_control.decode_holdings(json) // -> Ok([AnswerView(..)])
/// ```
pub fn decode_holdings(value: JsonValue) -> Result(List(AnswerView), String) {
  use fields <- result.try(object(Ok(value), "holdings"))

  // Decode list of orchestrator holdings records.
  case field(fields, "orchestrators") {
    Ok(json.Array(items)) ->
      case list.drop(items, membership_ledger.max_active) == [] {
        True -> list.try_map(items, answer_view)
        False -> Error("holdings.orchestrators holds too many entries")
      }
    _ -> Error("holdings.orchestrators is not an array")
  }
}

/// Decodes a holdings answer view from json object.
fn answer_view(value: JsonValue) -> Result(AnswerView, String) {
  use fields <- result.try(object(Ok(value), "holdings entry"))
  use name <- result.try(string_of(fields, "name"))
  use node <- result.try(string_of(fields, "node"))

  // Decode optional held sessions record.
  use held <- result.map(case field(fields, "sessions") {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(_) -> held_view(fields) |> result.map(Some)
  })

  AnswerView(name:, node:, held:)
}

/// Decodes placed session breakdown for an orchestrator node.
fn held_view(fields: List(#(String, JsonValue))) -> Result(HeldView, String) {
  use sessions <- result.try(count_of(fields, "sessions"))

  // Decode array of placed session counts by node.
  use placed <- result.map(case field(fields, "placed") {
    Ok(json.Array(items)) ->
      case list.drop(items, orchestrator_port.max_placed) == [] {
        True -> list.try_map(items, placed_view)
        False -> Error("holdings placed holds too many entries")
      }
    _ -> Error("holdings placed is not an array")
  })

  HeldView(sessions:, placed:)
}

fn placed_view(value: JsonValue) -> Result(PlacedView, String) {
  use fields <- result.try(object(Ok(value), "holdings placement"))
  use node <- result.try(string_of(fields, "node"))
  use sessions <- result.map(count_of(fields, "sessions"))
  PlacedView(node:, sessions:)
}

/// Reads a non-negative integer count from fields object.
fn count_of(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(Int, String) {
  use number <- result.try(int_of(fields, key))

  // Ensure count value is non-negative.
  case number >= 0 {
    True -> Ok(number)
    False -> Error(key <> " is a negative count")
  }
}

/// Splits lines into the pages an append may carry: at most `max_append_lines`
/// lines and `max_page_bytes` bytes each, in order. A single line past the byte
/// bound is a page of its own, and the daemon refuses it.
///
/// ## Examples
///
/// ```gleam
/// assert ledger_control.pages(["a", "b"]) == [["a", "b"]]
/// ```
pub fn pages(lines: List(String)) -> List(List(String)) {
  let #(done, current, _, _) =
    list.fold(lines, #([], [], 0, 0), fn(state, line) {
      let #(done, current, count, bytes) = state
      let size = bit_array.byte_size(bit_array.from_string(line))

      // Roll current page when line or byte limit is reached.
      case
        count > 0
        && { count >= max_append_lines || bytes + size > max_page_bytes }
      {
        True -> #([list.reverse(current), ..done], [line], 1, size)
        False -> #(done, [line, ..current], count + 1, bytes + size)
      }
    })

  // Finalize any remaining lines in current page accumulator.
  case current {
    [] -> list.reverse(done)
    _ -> list.reverse([list.reverse(current), ..done])
  }
}

/// Decodes a MemberView record from status member object.
fn member_view(value: JsonValue) -> Result(MemberView, String) {
  use fields <- result.try(object(Ok(value), "status.members entry"))
  use name <- result.try(string_of(fields, "name"))
  use node <- result.try(string_of(fields, "node"))
  use role <- result.try(string_of(fields, "role"))
  use directory <- result.try(string_of(fields, "directory"))
  use reported_seq <- result.try(optional_int(fields, "reported_seq"))
  use ms_since_report <- result.try(optional_int(fields, "ms_since_report"))
  use links <- result.try(optional_strings(fields, "links"))
  use pin <- result.map(optional_string(fields, "pin"))
  MemberView(
    name:,
    node:,
    role:,
    directory:,
    reported_seq:,
    ms_since_report:,
    links:,
    pin:,
  )
}

/// Decodes a RefusalView record from rejected entry status json.
fn refusal_view(value: Result(JsonValue, Nil)) -> Result(RefusalView, String) {
  use fields <- result.try(object(value, "status.last_refusal"))
  use step <- result.try(string_of(fields, "step"))
  use seq <- result.try(optional_int(fields, "seq"))
  use ours <- result.try(optional_string(fields, "ours"))
  use theirs <- result.map(optional_string(fields, "theirs"))
  RefusalView(seq:, step:, ours:, theirs:)
}

/// Decodes a HeadView record from status head json.
fn head_view(value: Result(JsonValue, Nil)) -> Result(HeadView, String) {
  use fields <- result.try(object(value, "head"))
  use seq <- result.try(int_of(fields, "seq"))
  use id <- result.try(string_of(fields, "id"))

  // Validate sequence and hex identifier format.
  case seq >= 0 && is_hex_id(id) {
    True -> Ok(HeadView(seq:, id:))
    False -> Error("head is not a sequence number and a 64 character identity")
  }
}

fn is_hex_id(text: String) -> Bool {
  string.drop_start(text, 64) == ""
  && string.drop_start(text, 63) != ""
  && list.all(string.to_graphemes(text), string.contains("0123456789abcdef", _))
}

fn field(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(JsonValue, Nil) {
  list.key_find(fields, key)
}

/// Unwraps a JSON object or reports an error naming the contextual place.
fn object(
  value: Result(JsonValue, Nil),
  place: String,
) -> Result(List(#(String, JsonValue)), String) {
  case value {
    Ok(json.Object(fields)) -> Ok(fields)
    _ -> Error(place <> " is not an object")
  }
}

/// Extracts a string field value by key from an object.
fn string_of(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(String, String) {
  case list.key_find(fields, key) {
    Ok(json.String(text)) -> Ok(text)
    _ -> Error(key <> " is not a string")
  }
}

/// Extracts an integer field value by key from an object.
fn int_of(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(Int, String) {
  case list.key_find(fields, key) {
    Ok(json.Int(number)) -> Ok(number)
    _ -> Error(key <> " is not an integer")
  }
}

/// Extracts an optional integer field value by key from an object.
fn optional_int(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(Option(Int), String) {
  case list.key_find(fields, key) {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(json.Int(number)) -> Ok(Some(number))
    Ok(_) -> Error(key <> " is not an integer")
  }
}

/// Extracts an optional array of strings by key from an object.
fn optional_strings(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(List(String), String) {
  case list.key_find(fields, key) {
    Error(Nil) | Ok(json.Null) -> Ok([])
    Ok(json.Array(items)) ->
      list.try_map(items, fn(item) {
        case item {
          json.String(text) -> Ok(text)
          _ -> Error(key <> " holds something that is not a string")
        }
      })
    Ok(_) -> Error(key <> " is not a list")
  }
}

/// Extracts an optional string field value by key from an object.
fn optional_string(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(Option(String), String) {
  case list.key_find(fields, key) {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(json.String(text)) -> Ok(Some(text))
    Ok(_) -> Error(key <> " is not a string")
  }
}
