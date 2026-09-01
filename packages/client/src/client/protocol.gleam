//// The Part 1.6 client protocol: the frozen websocket envelope plus the
//// normative body shapes from the TUI's `protocol.md`, as plain Gleam
//// values with total codecs over `core/json`.
////
//// The envelope is frozen by the implementation spec (Part 1.6); the
//// bodies are pinned by the golden fixtures under
//// `packages/client/testdata/protocol/`, which this package's
//// conformance test decodes and re-encodes byte-for-byte. Changing
//// either side is a protocol change (`protocol-change/NNN.md`), never
//// silent drift.
////
//// Vocabulary rules (protocol.md "Conventions"):
////
//// - Gateway-defined field names are `snake_case`. Values that already
////   have a durable JSON form in the harness — entries, messages, usage
////   — are carried **verbatim** in `core/codec`'s vocabulary (pi field
////   names, camelCase), so this module encodes them with the codec the
////   harness already has.
//// - Envelope decoding is strict: `v` must be `1`; `cmd`/`event` and
////   the command `id` must be present. Unknown `cmd`/`event` *names*
////   are tolerated as data (`UnknownCommand` / `UnknownEvent`) so the
////   receiver can answer in-band; unknown *fields* inside known bodies
////   are ignored (forward compatibility within v1).
//// - Everything here is pure and total: malformed input yields a
////   `ProtocolFault` value, never a crash.
////
//// ## Where the wire form and `core/codec` disagree
////
//// The golden fixtures pin three details the core codec renders
//// differently, and the wire form follows the fixtures (this module
//// adapts in both directions, so the rest of the harness keeps the
//// codec's canonical form):
////
//// - assistant `toolCall` blocks nest the call under a `toolCall` key
////   (`{"type":"toolCall","toolCall":{...}}`) where the codec inlines
////   its fields;
//// - `thinking` blocks always carry `redacted` (the codec omits the
////   default `false`);
//// - floats print in Go's positional style (`0.00027`), where the
////   BEAM's shortest form is scientific (`2.7e-4`) — see
////   `to_wire_text`.

import broker/policy.{type Grant}
import core/codec
import core/corruption.{type CorruptionReport}
import core/entry.{type Entry}
import core/json.{type JsonValue}
import core/message.{type Usage, type UserBlock, UserImage, UserText}
import gleam/bit_array
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The one protocol version this gateway speaks. A different `v` on the
/// wire is a refused frame, never tolerated drift.
pub const version = 1

/// Why a frame was refused. Every constructor is data the receiver can
/// answer in-band; nothing here crashes a connection process.
pub type ProtocolFault {
  /// The frame is not a well-formed JSON document.
  MalformedFrame(report: CorruptionReport)
  /// The envelope is malformed: wrong `v`, missing `cmd`/`event`,
  /// missing or non-positive command `id`. `id` carries the command id
  /// when one was readable, so the answer can still say `reply_to`.
  BadEnvelope(reason: String, id: Option(Int))
  /// The envelope was well-formed but a known command's body was not.
  BadBody(id: Int, cmd: String, reason: String)
}

// --- commands (client → server) -------------------------------------------

/// What a fork command copies. Both scopes currently fork **in place** —
/// a new strand cursor over the shared tree — because the protocol's
/// reply (a `strands` snapshot of this session) can only name strands of
/// the subscribed session; `session/repo.fork` into a separate session
/// file is not reachable through v1 (see the module doc of
/// `client/gateway`).
pub type ForkScope {
  /// Fork the source strand's branch.
  ScopeBranch
  /// Fork the whole tree.
  ScopeTree
}

/// One decoded client command body.
///
/// Constructor invariants mirror protocol.md's command table: strand and
/// session names are non-empty as sent (emptiness is a semantic check
/// the gateway answers in-band, not a decode failure); `Approve.grants`
/// and `Approve.action` are the echo of what the client rendered, both
/// required on the wire; `UnknownCommand` carries any well-formed
/// envelope whose `cmd` name this build does not know — the server
/// answers it with `error` (`unsupported`).
pub type Command {
  /// Scope the connection to a session and start the event stream.
  Subscribe(session: String, from_seq: Option(Int))
  /// Re-request durable events from a seq on the subscribed session.
  CatchUp(from_seq: Int)
  /// Start a run on an idle strand.
  Prompt(strand: String, text: String)
  /// Start a run on an idle strand from ordered user content blocks.
  PromptContent(strand: String, content: List(UserBlock))
  /// Inject into the live run at the next checkpoint.
  Steer(strand: String, text: String)
  /// Queue a turn to run after the live operation settles.
  FollowUp(strand: String, text: String)
  /// Cancel the strand's live operation.
  Abort(strand: String)
  /// Approve a pending escalation. `grants` is the policy diff the
  /// client displayed and `action` the action digest it displayed
  /// beside it; the gateway checks both against the record it is about
  /// to commit and refuses a mismatch (`code_stale_approval`) rather
  /// than reconciling one. `grants` must additionally be a subset of
  /// the denial's wanted diff — an approval may narrow what was asked
  /// for, never widen it — and `action` is the empty string exactly
  /// when the record names no action.
  Approve(escalation_id: String, grants: List(Grant), action: String)
  /// Reject a pending escalation.
  Deny(escalation_id: String)
  /// Fork a strand; the new strand appears in the `strands` reply.
  Fork(strand: String, scope: ForkScope, name: Option(String))
  /// Move a strand's leaf to an entry.
  Navigate(strand: String, to_entry: String)
  /// Run a standalone compaction on a strand.
  Compact(strand: String, instructions: Option(String))
  /// Create a fresh strand.
  CreateStrand(name: Option(String))
  /// Request the model catalogue; answered by a `models` snapshot.
  ListModels
  /// Change gateway-defined configuration keys.
  SetConfig(strand: Option(String), config: JsonValue)
  /// A well-formed envelope with an unknown command name, kept as data.
  UnknownCommand(cmd: String, body: JsonValue)
}

/// One command envelope: the client-assigned id plus the command.
///
/// Constructor invariants: `id` is non-zero and unique per connection
/// (the decoder refuses a missing or non-positive id).
pub type CommandEnvelope {
  CommandEnvelope(id: Int, command: Command)
}

// --- events (server → client) ---------------------------------------------

/// A snapshot body, discriminated by `mode`. Field presence follows
/// protocol.md: `full` carries session, next_seq, strands, entries,
/// pending escalations, and the usage total; `resume` carries next_seq
/// only; `strands` and `config` carry their one field.
pub type Snapshot {
  /// The full rebuild-from-scratch snapshot.
  FullSnapshot(
    session: String,
    next_seq: Int,
    strands: List(Strand),
    entries: List(EntryRecord),
    escalations: List(EscalationRecord),
    usage: Usage,
  )
  /// A resume marker: replay of `from_seq <= seq < next_seq` follows.
  ResumeSnapshot(next_seq: Int)
  /// A full replacement strand list.
  StrandsSnapshot(strands: List(Strand))
  /// The effective config object.
  ConfigSnapshot(config: JsonValue)
  /// The model catalogue (the `models` command's reply).
  ModelsSnapshot(models: List(ModelInfo))
}

/// One catalogue entry as the protocol lists it.
///
/// Constructor invariants: `name` is the catalogue name `set_config`'s
/// `model_name` key accepts; `dialect` is `"anthropic"` or `"openai"`
/// (open set — clients display unknown dialects verbatim); `roles` are
/// the roles whose fallback chain lists this entry, and `active` the
/// subset it currently resolves for, both possibly empty.
pub type ModelInfo {
  ModelInfo(
    name: String,
    dialect: String,
    model_id: String,
    roles: List(String),
    active: List(String),
  )
}

/// One strand in a snapshot.
///
/// Constructor invariants: `id` is the strand's durable name; `leaf`
/// is an entry-id string when the strand has one; `live_op` pairs the
/// open operation's id with its display phase.
pub type Strand {
  Strand(
    id: String,
    name: Option(String),
    leaf: Option(String),
    live_op: Option(LiveOp),
  )
}

/// A strand's open operation and its display phase.
pub type LiveOp {
  LiveOp(op: String, phase: String)
}

/// One appended entry attributed to a strand. The nested entry is
/// exactly what `core/codec.encode_entry` produces; its nested `seq` is
/// the storage seq.
pub type EntryRecord {
  EntryRecord(strand: String, entry: Entry)
}

/// One escalation as the protocol carries it.
///
/// Constructor invariants: `status` is one of the four lifecycle names;
/// `denial` is present exactly when the record is pending (and in
/// snapshots of pending escalations). `op`/`strand` are the record's
/// own `CallScope` — the operation and the strand the denial was
/// raised for, read off the record and never inferred — and are empty
/// together exactly when the record names no call.
///
/// `tool`, `action` and `preview` are the action an approval would
/// authorize: the tool's name, a digest of its effective arguments,
/// and a bounded rendering of those arguments. All three are empty on
/// a record raised through a door that names no action, and on one
/// written before this field existed; a client must still render and
/// still be able to approve such a record.
///
/// `preview` is **model-controlled untrusted display data**. Every
/// client sanitises it before it reaches a terminal and fences it away
/// from the client's own words — protocol.md's `escalation` section is
/// the normative statement, and it binds any client, not just this
/// one. `action` is compared for equality and never interpreted.
///
/// `asked` counts the questions this row has put to a human: one for
/// the raise that opened it and one more for each re-opening. It is
/// `0` on a record written before it existed.
pub type EscalationRecord {
  EscalationRecord(
    escalation_id: String,
    op: String,
    strand: String,
    status: String,
    tool: String,
    action: String,
    preview: String,
    asked: Int,
    denial: Option(Denial),
  )
}

/// A structured denial: why, from where, and the exact widening that
/// would satisfy it, mirroring `broker/escalation.Denial`.
pub type Denial {
  Denial(
    reason: String,
    source: String,
    enforcement: Option(List(String)),
    wanted: List(Grant),
  )
}

/// A live streaming fragment. Ephemeral by definition: never persisted,
/// never seq'd, never replayed.
pub type DeltaKind {
  /// A text fragment (carried in `text`).
  TextKind
  /// A thinking fragment (carried in `text`).
  ThinkingKind
  /// A tool-call fragment (carried in `call_id`/`tool_name`/
  /// `arguments_fragment`).
  ToolCallKind
}

/// One decoded server event body.
///
/// Constructor invariants follow the protocol.md event sections;
/// `UnknownEvent` keeps the raw body of an event name this build does
/// not know, which a client ignores (tolerant reading).
pub type Event {
  /// A snapshot reply.
  SnapshotEvent(snapshot: Snapshot)
  /// One appended entry.
  EntryEvent(record: EntryRecord)
  /// A display-level operation phase change.
  OpTransitionEvent(op: String, strand: String, phase: String)
  /// A live streaming fragment (`ephemeral` always true on the wire).
  StreamDeltaEvent(
    strand: String,
    op: String,
    kind: DeltaKind,
    text: Option(String),
    call_id: Option(String),
    tool_name: Option(String),
    arguments_fragment: Option(String),
  )
  /// One usage-ledger append.
  UsageEvent(strand: String, op: Option(String), usage: Usage)
  /// An escalation lifecycle change.
  EscalationEvent(record: EscalationRecord)
  /// A strand's operation settled terminally.
  StrandResultEvent(
    strand: String,
    op: String,
    status: String,
    error: Option(ResultError),
  )
  /// A command failure (with `reply_to`) or a connection-scoped fault.
  ErrorEvent(code: String, message: String, details: Option(JsonValue))
  /// A well-formed envelope with an unknown event name, kept as data.
  UnknownEvent(event: String, body: JsonValue)
}

/// The `{code, message}` of a failed strand result.
pub type ResultError {
  ResultError(code: String, message: String)
}

/// One event envelope. `reply_to` names the command this answers on the
/// issuing connection; `seq` is present exactly on durable-stream events
/// (`snapshot`, `stream_delta`, and `error` never carry one).
pub type EventEnvelope {
  EventEnvelope(reply_to: Option(Int), seq: Option(Int), event: Event)
}

/// Error codes protocol.md defines. The set is open; these constants
/// exist so the gateway and tests spell them once.
pub const code_bad_request = "bad_request"

/// The subscribed-to session is not the one this gateway serves.
pub const code_unknown_session = "unknown_session"

/// The named strand has no durable registers.
pub const code_unknown_strand = "unknown_strand"

/// No escalation with the named id is recorded.
pub const code_unknown_escalation = "unknown_escalation"

/// The escalation is not pending (or not approved, for consume).
pub const code_not_pending = "not_pending"

/// An `approve` echoed a policy diff or an action digest that is not
/// the record's own as the gateway read it. The record moved between
/// the render and the answer; the error's `details` carry the record
/// as it now stands, in the `escalation` event's body shape, so the
/// client re-renders and asks again.
pub const code_stale_approval = "stale_approval"

/// The command conflicts with the strand's live state.
pub const code_conflict = "conflict"

/// The command name is not supported by this gateway build.
pub const code_unsupported = "unsupported"

/// The gateway failed internally; the command had no effect.
pub const code_internal = "internal"

// --- command encoding ------------------------------------------------------

/// Encodes a command envelope as its canonical wire text (the byte form
/// the golden fixtures pin, modulo the values themselves).
///
/// ## Examples
///
/// ```gleam
/// assert protocol.encode_command(protocol.CommandEnvelope(
///     id: 5,
///     command: protocol.Abort(strand: "main"),
///   ))
///   == "{\"v\":1,\"id\":5,\"cmd\":\"abort\",\"body\":{\"strand\":\"main\"}}"
/// ```
///
pub fn encode_command(envelope: CommandEnvelope) -> String {
  let #(cmd, body) = command_body(envelope.command)
  to_wire_text(
    json.Object([
      #("v", json.Int(version)),
      #("id", json.Int(envelope.id)),
      #("cmd", json.String(cmd)),
      #("body", body),
    ]),
  )
}

fn command_body(command: Command) -> #(String, JsonValue) {
  case command {
    Subscribe(session:, from_seq:) -> #(
      "subscribe",
      object_of([
        #("session", Some(json.String(session))),
        #("from_seq", option.map(from_seq, json.Int)),
      ]),
    )
    CatchUp(from_seq:) -> #(
      "catch_up",
      json.Object([#("from_seq", json.Int(from_seq))]),
    )
    Prompt(strand:, text:) -> #("prompt", strand_text(strand, text))
    PromptContent(strand:, content:) -> #(
      "prompt_content",
      json.Object([
        #("strand", json.String(strand)),
        #("content", json.Array(list.map(content, codec.encode_user_block))),
      ]),
    )
    Steer(strand:, text:) -> #("steer", strand_text(strand, text))
    FollowUp(strand:, text:) -> #("follow_up", strand_text(strand, text))
    Abort(strand:) -> #(
      "abort",
      json.Object([#("strand", json.String(strand))]),
    )
    Approve(escalation_id:, grants:, action:) -> #(
      "approve",
      json.Object([
        #("escalation_id", json.String(escalation_id)),
        #("grants", json.Array(list.map(grants, encode_grant))),
        #("action", json.String(action)),
      ]),
    )
    Deny(escalation_id:) -> #(
      "deny",
      json.Object([#("escalation_id", json.String(escalation_id))]),
    )
    Fork(strand:, scope:, name:) -> #(
      "fork",
      object_of([
        #("strand", Some(json.String(strand))),
        #("scope", Some(json.String(scope_to_string(scope)))),
        #("name", option.map(name, json.String)),
      ]),
    )
    Navigate(strand:, to_entry:) -> #(
      "navigate",
      json.Object([
        #("strand", json.String(strand)),
        #("to_entry", json.String(to_entry)),
      ]),
    )
    Compact(strand:, instructions:) -> #(
      "compact",
      object_of([
        #("strand", Some(json.String(strand))),
        #("instructions", option.map(instructions, json.String)),
      ]),
    )
    CreateStrand(name:) -> #(
      "create_strand",
      object_of([#("name", option.map(name, json.String))]),
    )
    ListModels -> #("models", json.Object([]))
    SetConfig(strand:, config:) -> #(
      "set_config",
      object_of([
        #("strand", option.map(strand, json.String)),
        #("config", Some(config)),
      ]),
    )
    UnknownCommand(cmd:, body:) -> #(cmd, body)
  }
}

fn strand_text(strand: String, text: String) -> JsonValue {
  json.Object([
    #("strand", json.String(strand)),
    #("text", json.String(text)),
  ])
}

fn scope_to_string(scope: ForkScope) -> String {
  case scope {
    ScopeBranch -> "branch"
    ScopeTree -> "tree"
  }
}

// --- command decoding ------------------------------------------------------

/// Decodes one command frame. Total: every malformed input is a
/// `ProtocolFault` value. Unknown command names decode successfully as
/// `UnknownCommand` so the server can answer `error` (`unsupported`)
/// in-band; unknown fields inside known bodies are ignored.
///
/// ## Examples
///
/// ```gleam
/// assert protocol.decode_command(
///     "{\"v\":1,\"id\":5,\"cmd\":\"abort\",\"body\":{\"strand\":\"main\"}}",
///   )
///   == Ok(protocol.CommandEnvelope(id: 5, command: protocol.Abort("main")))
/// ```
///
pub fn decode_command(text: String) -> Result(CommandEnvelope, ProtocolFault) {
  use value <- result.try(
    json.parse(text)
    |> result.map_error(fn(report) { MalformedFrame(report:) }),
  )
  use fields <- result.try(envelope_fields(value, None))
  let id = case list.key_find(fields, "id") {
    Ok(json.Int(id)) if id > 0 -> Some(id)
    _ -> None
  }
  use Nil <- result.try(check_version(fields, id))
  use id <- result.try(case id {
    Some(id) -> Ok(id)
    None ->
      Error(BadEnvelope(reason: "a positive integer command id", id: None))
  })
  use cmd <- result.try(case list.key_find(fields, "cmd") {
    Ok(json.String(cmd)) -> Ok(cmd)
    _ -> Error(BadEnvelope(reason: "a string cmd name", id: Some(id)))
  })
  let body = case list.key_find(fields, "body") {
    Ok(body) -> body
    Error(Nil) -> json.Object([])
  }
  use command <- result.try(
    decode_command_body(cmd, body)
    |> result.map_error(fn(reason) { BadBody(id:, cmd:, reason:) }),
  )
  Ok(CommandEnvelope(id:, command:))
}

fn decode_command_body(
  cmd: String,
  body: JsonValue,
) -> Result(Command, String) {
  case cmd {
    "subscribe" -> {
      use fields <- result.try(body_fields(body))
      use session <- result.try(required_string(fields, "session"))
      use from_seq <- result.try(optional_int(fields, "from_seq"))
      Ok(Subscribe(session:, from_seq:))
    }
    "catch_up" -> {
      use fields <- result.try(body_fields(body))
      use from_seq <- result.try(required_int(fields, "from_seq"))
      Ok(CatchUp(from_seq:))
    }
    "prompt" -> decode_strand_text(body, Prompt)
    "prompt_content" -> {
      use fields <- result.try(body_fields(body))
      use strand <- result.try(required_string(fields, "strand"))
      use content <- result.try(case list.key_find(fields, "content") {
        Ok(json.Array([])) -> Error("content must be a non-empty array")
        Ok(json.Array(items)) ->
          items
          |> list.try_map(decode_prompt_block)
        Ok(_) -> Error("content must be a non-empty array")
        Error(Nil) -> Error("content is required")
      })
      Ok(PromptContent(strand:, content:))
    }
    "steer" -> decode_strand_text(body, Steer)
    "follow_up" -> decode_strand_text(body, FollowUp)
    "abort" -> {
      use fields <- result.try(body_fields(body))
      use strand <- result.try(required_string(fields, "strand"))
      Ok(Abort(strand:))
    }
    "approve" -> {
      use fields <- result.try(body_fields(body))
      use escalation_id <- result.try(required_string(fields, "escalation_id"))
      // Both echoes are required, and their absence is a refused frame
      // rather than a tolerated default. A client that cannot say what
      // it rendered has not carried anyone's consent, and defaulting
      // either one would restore precisely the commit-time resolution
      // this replaced.
      use grants <- result.try(case list.key_find(fields, "grants") {
        Ok(json.Array(items)) -> list.try_map(items, decode_grant)
        Ok(_) -> Error("grants must be an array of grant objects")
        Error(Nil) -> Error("grants is required")
      })
      use action <- result.try(required_string(fields, "action"))
      Ok(Approve(escalation_id:, grants:, action:))
    }
    "deny" -> {
      use fields <- result.try(body_fields(body))
      use escalation_id <- result.try(required_string(fields, "escalation_id"))
      Ok(Deny(escalation_id:))
    }
    "fork" -> {
      use fields <- result.try(body_fields(body))
      use strand <- result.try(required_string(fields, "strand"))
      use scope_text <- result.try(required_string(fields, "scope"))
      use scope <- result.try(case scope_text {
        "branch" -> Ok(ScopeBranch)
        "tree" -> Ok(ScopeTree)
        other -> Error("unknown fork scope: " <> other)
      })
      use name <- result.try(optional_string(fields, "name"))
      Ok(Fork(strand:, scope:, name:))
    }
    "navigate" -> {
      use fields <- result.try(body_fields(body))
      use strand <- result.try(required_string(fields, "strand"))
      use to_entry <- result.try(required_string(fields, "to_entry"))
      Ok(Navigate(strand:, to_entry:))
    }
    "compact" -> {
      use fields <- result.try(body_fields(body))
      use strand <- result.try(required_string(fields, "strand"))
      use instructions <- result.try(optional_string(fields, "instructions"))
      Ok(Compact(strand:, instructions:))
    }
    "create_strand" -> {
      use fields <- result.try(body_fields(body))
      use name <- result.try(optional_string(fields, "name"))
      Ok(CreateStrand(name:))
    }
    // The body is deliberately empty today; tolerant reading applies.
    "models" -> Ok(ListModels)
    "set_config" -> {
      use fields <- result.try(body_fields(body))
      use strand <- result.try(optional_string(fields, "strand"))
      use config <- result.try(case list.key_find(fields, "config") {
        Ok(config) -> Ok(config)
        Error(Nil) -> Error("a config object is required")
      })
      Ok(SetConfig(strand:, config:))
    }
    other -> Ok(UnknownCommand(cmd: other, body:))
  }
}

fn decode_prompt_block(value: JsonValue) -> Result(UserBlock, String) {
  use block <- result.try(
    codec.decode_user_block(value)
    |> result.map_error(fn(report) { report.expected }),
  )
  case block {
    UserText(..) -> Ok(block)
    UserImage(data:, mime_type:) ->
      case string.trim(mime_type), bit_array.base64_decode(data) {
        "", _ -> Error("a non-empty media type")
        _, Error(_) -> Error("valid base64 image bytes")
        _, Ok(_) -> Ok(block)
      }
  }
}

fn decode_strand_text(
  body: JsonValue,
  build: fn(String, String) -> Command,
) -> Result(Command, String) {
  use fields <- result.try(body_fields(body))
  use strand <- result.try(required_string(fields, "strand"))
  use text <- result.try(required_string(fields, "text"))
  Ok(build(strand, text))
}

// --- event encoding --------------------------------------------------------

/// Encodes an event envelope as its canonical wire text.
///
/// ## Examples
///
/// ```gleam
/// assert protocol.encode_event(protocol.EventEnvelope(
///     reply_to: option.None,
///     seq: option.None,
///     event: protocol.ErrorEvent("conflict", "busy", option.None),
///   ))
///   == "{\"v\":1,\"event\":\"error\",\"body\":"
///   <> "{\"code\":\"conflict\",\"message\":\"busy\"}}"
/// ```
///
pub fn encode_event(envelope: EventEnvelope) -> String {
  let #(name, body) = event_body(envelope.event)
  to_wire_text(
    object_of([
      #("v", Some(json.Int(version))),
      #("reply_to", option.map(envelope.reply_to, json.Int)),
      #("event", Some(json.String(name))),
      #("seq", option.map(envelope.seq, json.Int)),
      #("body", Some(body)),
    ]),
  )
}

fn event_body(event: Event) -> #(String, JsonValue) {
  case event {
    SnapshotEvent(snapshot:) -> #("snapshot", encode_snapshot(snapshot))
    EntryEvent(record:) -> #("entry", encode_entry_record(record))
    OpTransitionEvent(op:, strand:, phase:) -> #(
      "op_transition",
      json.Object([
        #("op", json.String(op)),
        #("strand", json.String(strand)),
        #("phase", json.String(phase)),
      ]),
    )
    StreamDeltaEvent(
      strand:,
      op:,
      kind:,
      text:,
      call_id:,
      tool_name:,
      arguments_fragment:,
    ) -> #(
      "stream_delta",
      object_of([
        #("strand", Some(json.String(strand))),
        #("op", Some(json.String(op))),
        #("ephemeral", Some(json.Bool(True))),
        #("kind", Some(json.String(kind_to_string(kind)))),
        #("text", option.map(text, json.String)),
        #("call_id", option.map(call_id, json.String)),
        #("tool_name", option.map(tool_name, json.String)),
        #("arguments_fragment", option.map(arguments_fragment, json.String)),
      ]),
    )
    UsageEvent(strand:, op:, usage:) -> #(
      "usage",
      object_of([
        #("strand", Some(json.String(strand))),
        #("op", option.map(op, json.String)),
        #("usage", Some(codec.encode_usage(usage))),
      ]),
    )
    EscalationEvent(record:) -> #("escalation", encode_escalation(record))
    StrandResultEvent(strand:, op:, status:, error:) -> #(
      "strand_result",
      object_of([
        #("strand", Some(json.String(strand))),
        #("op", Some(json.String(op))),
        #("status", Some(json.String(status))),
        #(
          "error",
          option.map(error, fn(error) {
            json.Object([
              #("code", json.String(error.code)),
              #("message", json.String(error.message)),
            ])
          }),
        ),
      ]),
    )
    ErrorEvent(code:, message:, details:) -> #(
      "error",
      object_of([
        #("code", Some(json.String(code))),
        #("message", Some(json.String(message))),
        #("details", details),
      ]),
    )
    UnknownEvent(event:, body:) -> #(event, body)
  }
}

fn encode_snapshot(snapshot: Snapshot) -> JsonValue {
  case snapshot {
    FullSnapshot(session:, next_seq:, strands:, entries:, escalations:, usage:) ->
      object_of([
        #("mode", Some(json.String("full"))),
        #("session", Some(json.String(session))),
        #("next_seq", Some(json.Int(next_seq))),
        #("strands", Some(json.Array(list.map(strands, encode_strand)))),
        #("entries", Some(json.Array(list.map(entries, encode_entry_record)))),
        #("escalations", case escalations {
          [] -> None
          records -> Some(json.Array(list.map(records, encode_escalation)))
        }),
        #("usage", Some(codec.encode_usage(usage))),
      ])
    ResumeSnapshot(next_seq:) ->
      json.Object([
        #("mode", json.String("resume")),
        #("next_seq", json.Int(next_seq)),
      ])
    StrandsSnapshot(strands:) ->
      json.Object([
        #("mode", json.String("strands")),
        #("strands", json.Array(list.map(strands, encode_strand))),
      ])
    ConfigSnapshot(config:) ->
      json.Object([#("mode", json.String("config")), #("config", config)])
    ModelsSnapshot(models:) ->
      json.Object([
        #("mode", json.String("models")),
        #("models", json.Array(list.map(models, encode_model_info))),
      ])
  }
}

fn encode_model_info(info: ModelInfo) -> JsonValue {
  json.Object([
    #("name", json.String(info.name)),
    #("dialect", json.String(info.dialect)),
    #("model_id", json.String(info.model_id)),
    #("roles", json.Array(list.map(info.roles, json.String))),
    #("active", json.Array(list.map(info.active, json.String))),
  ])
}

fn encode_strand(strand: Strand) -> JsonValue {
  object_of([
    #("id", Some(json.String(strand.id))),
    #("name", option.map(strand.name, json.String)),
    #("leaf", option.map(strand.leaf, json.String)),
    #(
      "live_op",
      option.map(strand.live_op, fn(live) {
        json.Object([
          #("op", json.String(live.op)),
          #("phase", json.String(live.phase)),
        ])
      }),
    ),
  ])
}

fn encode_entry_record(record: EntryRecord) -> JsonValue {
  json.Object([
    #("strand", json.String(record.strand)),
    #("entry", wire_entry(codec.encode_entry(record.entry))),
  ])
}

// The action fields are additive within v1, so each is emitted only
// when it says something: a record that names no action encodes
// exactly as one written before the fields existed, and a reader that
// does not know them is unaffected either way.
fn encode_escalation(record: EscalationRecord) -> JsonValue {
  object_of([
    #("escalation_id", Some(json.String(record.escalation_id))),
    #("op", Some(json.String(record.op))),
    #("strand", Some(json.String(record.strand))),
    #("status", Some(json.String(record.status))),
    #("tool", non_empty(record.tool)),
    #("action", non_empty(record.action)),
    #("preview", non_empty(record.preview)),
    #("asked", case record.asked {
      0 -> None
      asked -> Some(json.Int(asked))
    }),
    #("denial", option.map(record.denial, encode_denial)),
  ])
}

/// The `details` object a `stale_approval` error carries: the record
/// as the gateway read it, under an `escalation` key, in exactly the
/// shape the `escalation` event's body has. A client re-renders its
/// prompt from this and asks again — the one reply to a refused
/// `approve` is therefore enough to recover without a `catch_up`.
///
/// ## Examples
///
/// ```gleam
/// // protocol.stale_approval_details(record)
/// ```
///
pub fn stale_approval_details(record: EscalationRecord) -> JsonValue {
  json.Object([#("escalation", encode_escalation(record))])
}

fn non_empty(text: String) -> Option(JsonValue) {
  case text {
    "" -> None
    text -> Some(json.String(text))
  }
}

fn encode_denial(denial: Denial) -> JsonValue {
  object_of([
    #("reason", Some(json.String(denial.reason))),
    #("source", Some(json.String(denial.source))),
    #(
      "enforcement",
      option.map(denial.enforcement, fn(entries) {
        json.Array(list.map(entries, json.String))
      }),
    ),
    #("wanted", Some(json.Array(list.map(denial.wanted, encode_grant)))),
  ])
}

fn kind_to_string(kind: DeltaKind) -> String {
  case kind {
    TextKind -> "text"
    ThinkingKind -> "thinking"
    ToolCallKind -> "tool_call"
  }
}

// --- event decoding --------------------------------------------------------

/// Decodes one event frame (the client half; the demo and the
/// conformance tests read events with this). Total. Unknown event names
/// decode as `UnknownEvent` with the raw body kept, which a client
/// ignores; unknown fields inside known bodies are ignored.
///
/// ## Examples
///
/// ```gleam
/// // protocol.decode_event(frame_text)
/// ```
///
pub fn decode_event(text: String) -> Result(EventEnvelope, ProtocolFault) {
  use value <- result.try(
    json.parse(text)
    |> result.map_error(fn(report) { MalformedFrame(report:) }),
  )
  use fields <- result.try(envelope_fields(value, None))
  use Nil <- result.try(check_version(fields, None))
  use name <- result.try(case list.key_find(fields, "event") {
    Ok(json.String(name)) -> Ok(name)
    _ -> Error(BadEnvelope(reason: "a string event name", id: None))
  })
  let reply_to = case list.key_find(fields, "reply_to") {
    Ok(json.Int(id)) -> Some(id)
    _ -> None
  }
  let seq = case list.key_find(fields, "seq") {
    Ok(json.Int(seq)) -> Some(seq)
    _ -> None
  }
  let body = case list.key_find(fields, "body") {
    Ok(body) -> body
    Error(Nil) -> json.Object([])
  }
  use event <- result.try(
    decode_event_body(name, body)
    |> result.map_error(fn(reason) {
      BadEnvelope(reason: name <> " body: " <> reason, id: None)
    }),
  )
  Ok(EventEnvelope(reply_to:, seq:, event:))
}

fn decode_event_body(name: String, body: JsonValue) -> Result(Event, String) {
  case name {
    "snapshot" -> decode_snapshot(body)
    "entry" -> {
      use record <- result.try(decode_entry_record(body))
      Ok(EntryEvent(record:))
    }
    "op_transition" -> {
      use fields <- result.try(body_fields(body))
      use op <- result.try(required_string(fields, "op"))
      use strand <- result.try(required_string(fields, "strand"))
      use phase <- result.try(required_string(fields, "phase"))
      Ok(OpTransitionEvent(op:, strand:, phase:))
    }
    "stream_delta" -> {
      use fields <- result.try(body_fields(body))
      use strand <- result.try(required_string(fields, "strand"))
      use op <- result.try(required_string(fields, "op"))
      use kind_text <- result.try(required_string(fields, "kind"))
      use kind <- result.try(case kind_text {
        "text" -> Ok(TextKind)
        "thinking" -> Ok(ThinkingKind)
        "tool_call" -> Ok(ToolCallKind)
        other -> Error("unknown delta kind: " <> other)
      })
      use text <- result.try(optional_string(fields, "text"))
      use call_id <- result.try(optional_string(fields, "call_id"))
      use tool_name <- result.try(optional_string(fields, "tool_name"))
      use arguments_fragment <- result.try(optional_string(
        fields,
        "arguments_fragment",
      ))
      Ok(StreamDeltaEvent(
        strand:,
        op:,
        kind:,
        text:,
        call_id:,
        tool_name:,
        arguments_fragment:,
      ))
    }
    "usage" -> {
      use fields <- result.try(body_fields(body))
      use strand <- result.try(required_string(fields, "strand"))
      use op <- result.try(optional_string(fields, "op"))
      use usage_value <- result.try(case list.key_find(fields, "usage") {
        Ok(value) -> Ok(value)
        Error(Nil) -> Error("a usage object is required")
      })
      use usage <- result.try(
        codec.decode_usage(usage_value)
        |> result.map_error(fn(report) { report.expected }),
      )
      Ok(UsageEvent(strand:, op:, usage:))
    }
    "escalation" -> {
      use record <- result.try(decode_escalation(body))
      Ok(EscalationEvent(record:))
    }
    "strand_result" -> {
      use fields <- result.try(body_fields(body))
      use strand <- result.try(required_string(fields, "strand"))
      use op <- result.try(required_string(fields, "op"))
      use status <- result.try(required_string(fields, "status"))
      use error <- result.try(case list.key_find(fields, "error") {
        Error(Nil) -> Ok(None)
        Ok(value) -> {
          use error_fields <- result.try(body_fields(value))
          use code <- result.try(required_string(error_fields, "code"))
          use message <- result.try(required_string(error_fields, "message"))
          Ok(Some(ResultError(code:, message:)))
        }
      })
      Ok(StrandResultEvent(strand:, op:, status:, error:))
    }
    "error" -> {
      use fields <- result.try(body_fields(body))
      use code <- result.try(required_string(fields, "code"))
      use message <- result.try(required_string(fields, "message"))
      let details = case list.key_find(fields, "details") {
        Ok(details) -> Some(details)
        Error(Nil) -> None
      }
      Ok(ErrorEvent(code:, message:, details:))
    }
    other -> Ok(UnknownEvent(event: other, body:))
  }
}

fn decode_snapshot(body: JsonValue) -> Result(Event, String) {
  use fields <- result.try(body_fields(body))
  use mode <- result.try(required_string(fields, "mode"))
  case mode {
    "full" -> {
      use session <- result.try(required_string(fields, "session"))
      use next_seq <- result.try(required_int(fields, "next_seq"))
      use strands <- result.try(decode_strands(fields))
      use entries <- result.try(case list.key_find(fields, "entries") {
        Error(Nil) -> Ok([])
        Ok(json.Array(items)) -> list.try_map(items, decode_entry_record)
        Ok(_) -> Error("entries must be an array")
      })
      use escalations <- result.try(case list.key_find(fields, "escalations") {
        Error(Nil) -> Ok([])
        Ok(json.Array(items)) -> list.try_map(items, decode_escalation)
        Ok(_) -> Error("escalations must be an array")
      })
      use usage_value <- result.try(case list.key_find(fields, "usage") {
        Ok(value) -> Ok(value)
        Error(Nil) -> Error("a usage object is required")
      })
      use usage <- result.try(
        codec.decode_usage(usage_value)
        |> result.map_error(fn(report) { report.expected }),
      )
      Ok(
        SnapshotEvent(FullSnapshot(
          session:,
          next_seq:,
          strands:,
          entries:,
          escalations:,
          usage:,
        )),
      )
    }
    "resume" -> {
      use next_seq <- result.try(required_int(fields, "next_seq"))
      Ok(SnapshotEvent(ResumeSnapshot(next_seq:)))
    }
    "strands" -> {
      use strands <- result.try(decode_strands(fields))
      Ok(SnapshotEvent(StrandsSnapshot(strands:)))
    }
    "config" -> {
      use config <- result.try(case list.key_find(fields, "config") {
        Ok(config) -> Ok(config)
        Error(Nil) -> Error("a config object is required")
      })
      Ok(SnapshotEvent(ConfigSnapshot(config:)))
    }
    "models" -> {
      use models <- result.try(case list.key_find(fields, "models") {
        Error(Nil) -> Ok([])
        Ok(json.Array(items)) -> list.try_map(items, decode_model_info)
        Ok(_) -> Error("models must be an array")
      })
      Ok(SnapshotEvent(ModelsSnapshot(models:)))
    }
    other -> Error("unknown snapshot mode: " <> other)
  }
}

fn decode_model_info(value: JsonValue) -> Result(ModelInfo, String) {
  use fields <- result.try(body_fields(value))
  use name <- result.try(required_string(fields, "name"))
  use dialect <- result.try(required_string(fields, "dialect"))
  use model_id <- result.try(required_string(fields, "model_id"))
  use roles <- result.try(string_array(fields, "roles"))
  use active <- result.try(string_array(fields, "active"))
  Ok(ModelInfo(name:, dialect:, model_id:, roles:, active:))
}

// A possibly-absent array of strings (absent reads as empty).
fn string_array(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(List(String), String) {
  case list.key_find(fields, key) {
    Error(Nil) -> Ok([])
    Ok(json.Array(items)) ->
      list.try_map(items, fn(item) {
        case item {
          json.String(text) -> Ok(text)
          _ -> Error(key <> " entries must be strings")
        }
      })
    Ok(_) -> Error(key <> " must be an array of strings")
  }
}

fn decode_strands(
  fields: List(#(String, JsonValue)),
) -> Result(List(Strand), String) {
  case list.key_find(fields, "strands") {
    Error(Nil) -> Ok([])
    Ok(json.Array(items)) -> list.try_map(items, decode_strand)
    Ok(_) -> Error("strands must be an array")
  }
}

fn decode_strand(value: JsonValue) -> Result(Strand, String) {
  use fields <- result.try(body_fields(value))
  use id <- result.try(required_string(fields, "id"))
  use name <- result.try(optional_string(fields, "name"))
  use leaf <- result.try(optional_string(fields, "leaf"))
  use live_op <- result.try(case list.key_find(fields, "live_op") {
    Error(Nil) -> Ok(None)
    Ok(value) -> {
      use live_fields <- result.try(body_fields(value))
      use op <- result.try(required_string(live_fields, "op"))
      use phase <- result.try(required_string(live_fields, "phase"))
      Ok(Some(LiveOp(op:, phase:)))
    }
  })
  Ok(Strand(id:, name:, leaf:, live_op:))
}

fn decode_entry_record(value: JsonValue) -> Result(EntryRecord, String) {
  use fields <- result.try(body_fields(value))
  use strand <- result.try(required_string(fields, "strand"))
  use entry_value <- result.try(case list.key_find(fields, "entry") {
    Ok(value) -> Ok(value)
    Error(Nil) -> Error("an entry object is required")
  })
  use entry <- result.try(
    codec.decode_entry(codec_entry(entry_value))
    |> result.map_error(fn(report) { report.expected }),
  )
  Ok(EntryRecord(strand:, entry:))
}

fn decode_escalation(value: JsonValue) -> Result(EscalationRecord, String) {
  use fields <- result.try(body_fields(value))
  use escalation_id <- result.try(required_string(fields, "escalation_id"))
  use op <- result.try(required_string(fields, "op"))
  use strand <- result.try(required_string(fields, "strand"))
  use status <- result.try(required_string(fields, "status"))
  use denial <- result.try(case list.key_find(fields, "denial") {
    Error(Nil) -> Ok(None)
    Ok(value) -> {
      use denial <- result.try(decode_denial(value))
      Ok(Some(denial))
    }
  })
  use tool <- result.try(defaulted_string(fields, "tool"))
  use action <- result.try(defaulted_string(fields, "action"))
  use preview <- result.try(defaulted_string(fields, "preview"))
  use asked <- result.try(
    optional_int(fields, "asked") |> result.map(option.unwrap(_, 0)),
  )
  Ok(EscalationRecord(
    escalation_id:,
    op:,
    strand:,
    status:,
    tool:,
    action:,
    preview:,
    asked:,
    denial:,
  ))
}

// Absent reads as empty — that is the tolerance the additive fields
// were specified with — but present-and-not-a-string is still a
// malformed body, the same distinction `optional_string` draws.
fn defaulted_string(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(String, String) {
  optional_string(fields, key) |> result.map(option.unwrap(_, ""))
}

fn decode_denial(value: JsonValue) -> Result(Denial, String) {
  use fields <- result.try(body_fields(value))
  use reason <- result.try(required_string(fields, "reason"))
  use source <- result.try(required_string(fields, "source"))
  use enforcement <- result.try(case list.key_find(fields, "enforcement") {
    Error(Nil) -> Ok(None)
    Ok(json.Array(items)) ->
      items
      |> list.try_map(fn(item) {
        case item {
          json.String(text) -> Ok(text)
          _ -> Error("enforcement entries must be strings")
        }
      })
      |> result.map(Some)
    Ok(_) -> Error("enforcement must be an array of strings")
  })
  use wanted <- result.try(case list.key_find(fields, "wanted") {
    Error(Nil) -> Ok([])
    Ok(json.Array(items)) -> list.try_map(items, decode_grant)
    Ok(_) -> Error("wanted must be an array of grants")
  })
  Ok(Denial(reason:, source:, enforcement:, wanted:))
}

// --- the wire grant vocabulary ---------------------------------------------

/// Encodes one `broker/policy.Grant` in the protocol's grant vocabulary
/// (`type`-discriminated; limit fields named `cpu_seconds`,
/// `wall_seconds`, ...). The internal escalation vocabulary the harness
/// stores (`grant`-discriminated, wire limit names) lives in
/// `client/grants`.
///
/// ## Examples
///
/// ```gleam
/// assert protocol.encode_grant(policy.GrantEnv(name: "PATH"))
///   == json.Object([
///     #("type", json.String("env")),
///     #("name", json.String("PATH")),
///   ])
/// ```
///
pub fn encode_grant(grant: Grant) -> JsonValue {
  case grant {
    policy.GrantWritableRoot(path:) ->
      json.Object([
        #("type", json.String("writable_root")),
        #("path", json.String(path)),
      ])
    policy.GrantReadableRoot(path:) ->
      json.Object([
        #("type", json.String("readable_root")),
        #("path", json.String(path)),
      ])
    policy.GrantNetwork(network:) ->
      json.Object([
        #("type", json.String("network")),
        #("network", encode_network(network)),
      ])
    policy.GrantEnv(name:) ->
      json.Object([
        #("type", json.String("env")),
        #("name", json.String(name)),
      ])
    policy.GrantLimit(field:, value:) ->
      json.Object([
        #("type", json.String("limit")),
        #("field", json.String(limit_field_to_string(field))),
        #("value", json.Int(value)),
      ])
    policy.GrantScratch(scratch:) ->
      json.Object([
        #("type", json.String("scratch")),
        #("scratch", encode_scratch(scratch)),
      ])
  }
}

/// Decodes one grant from the protocol's wire vocabulary. Total.
///
/// ## Examples
///
/// ```gleam
/// // protocol.decode_grant(value) == Ok(policy.GrantEnv(name: "PATH"))
/// ```
///
pub fn decode_grant(value: JsonValue) -> Result(Grant, String) {
  use fields <- result.try(body_fields(value))
  use kind <- result.try(required_string(fields, "type"))
  case kind {
    "writable_root" -> {
      use path <- result.try(required_string(fields, "path"))
      Ok(policy.GrantWritableRoot(path:))
    }
    "readable_root" -> {
      use path <- result.try(required_string(fields, "path"))
      Ok(policy.GrantReadableRoot(path:))
    }
    "network" -> {
      use network_value <- result.try(case list.key_find(fields, "network") {
        Ok(value) -> Ok(value)
        Error(Nil) -> Error("a network object is required")
      })
      use network <- result.try(decode_network(network_value))
      Ok(policy.GrantNetwork(network:))
    }
    "env" -> {
      use name <- result.try(required_string(fields, "name"))
      Ok(policy.GrantEnv(name:))
    }
    "limit" -> {
      use field_text <- result.try(required_string(fields, "field"))
      use field <- result.try(parse_limit_field(field_text))
      use value <- result.try(required_int(fields, "value"))
      Ok(policy.GrantLimit(field:, value:))
    }
    "scratch" -> {
      use scratch_value <- result.try(case list.key_find(fields, "scratch") {
        Ok(value) -> Ok(value)
        Error(Nil) -> Error("a scratch object is required")
      })
      use scratch <- result.try(decode_scratch(scratch_value))
      Ok(policy.GrantScratch(scratch:))
    }
    other -> Error("unknown grant type: " <> other)
  }
}

fn encode_network(network: policy.NetworkPolicy) -> JsonValue {
  case network {
    policy.NetworkOff -> json.Object([#("mode", json.String("off"))])
    policy.NetworkFull -> json.Object([#("mode", json.String("full"))])
    policy.NetworkProxy(allow:, proxy:) ->
      json.Object([
        #("mode", json.String("proxy")),
        #("allow", json.Array(list.map(allow, json.String))),
        #("proxy", json.String(proxy)),
      ])
  }
}

fn decode_network(value: JsonValue) -> Result(policy.NetworkPolicy, String) {
  use fields <- result.try(body_fields(value))
  use mode <- result.try(required_string(fields, "mode"))
  case mode {
    "off" -> Ok(policy.NetworkOff)
    "full" -> Ok(policy.NetworkFull)
    "proxy" -> {
      use allow <- result.try(case list.key_find(fields, "allow") {
        Error(Nil) -> Ok([])
        Ok(json.Array(items)) ->
          list.try_map(items, fn(item) {
            case item {
              json.String(host) -> Ok(host)
              _ -> Error("allow entries must be strings")
            }
          })
        Ok(_) -> Error("allow must be an array of host globs")
      })
      use proxy <- result.try(required_string(fields, "proxy"))
      Ok(policy.NetworkProxy(allow:, proxy:))
    }
    other -> Error("unknown network mode: " <> other)
  }
}

fn encode_scratch(scratch: policy.Scratch) -> JsonValue {
  case scratch {
    policy.ScratchTmpfs -> json.Object([#("mode", json.String("tmpfs"))])
    policy.ScratchPath(path:) ->
      json.Object([
        #("mode", json.String("path")),
        #("path", json.String(path)),
      ])
  }
}

fn decode_scratch(value: JsonValue) -> Result(policy.Scratch, String) {
  use fields <- result.try(body_fields(value))
  use mode <- result.try(required_string(fields, "mode"))
  case mode {
    "tmpfs" -> Ok(policy.ScratchTmpfs)
    "path" -> {
      use path <- result.try(required_string(fields, "path"))
      Ok(policy.ScratchPath(path:))
    }
    other -> Error("unknown scratch mode: " <> other)
  }
}

/// The wire name of one limit field: `cpu_seconds`, `wall_seconds`,
/// `mem_bytes`, `pids`, `fsize_bytes`, or `output_bytes`.
///
/// ## Examples
///
/// ```gleam
/// assert protocol.limit_field_to_string(policy.CpuSeconds) == "cpu_seconds"
/// ```
///
pub fn limit_field_to_string(field: policy.LimitField) -> String {
  case field {
    policy.CpuSeconds -> "cpu_seconds"
    policy.WallSeconds -> "wall_seconds"
    policy.MemBytes -> "mem_bytes"
    policy.Pids -> "pids"
    policy.FsizeBytes -> "fsize_bytes"
    policy.OutputBytes -> "output_bytes"
  }
}

/// Parses one limit-field wire name.
///
/// ## Examples
///
/// ```gleam
/// assert protocol.parse_limit_field("pids") == Ok(policy.Pids)
/// ```
///
pub fn parse_limit_field(text: String) -> Result(policy.LimitField, String) {
  case text {
    "cpu_seconds" -> Ok(policy.CpuSeconds)
    "wall_seconds" -> Ok(policy.WallSeconds)
    "mem_bytes" -> Ok(policy.MemBytes)
    "pids" -> Ok(policy.Pids)
    "fsize_bytes" -> Ok(policy.FsizeBytes)
    "output_bytes" -> Ok(policy.OutputBytes)
    other -> Error("unknown limit field: " <> other)
  }
}

// --- shared helpers --------------------------------------------------------

// Builds an object keeping only the present fields, in the given order.
fn object_of(fields: List(#(String, Option(JsonValue)))) -> JsonValue {
  fields
  |> list.filter_map(fn(field) {
    let #(name, value) = field
    case value {
      Some(value) -> Ok(#(name, value))
      None -> Error(Nil)
    }
  })
  |> json.Object
}

fn envelope_fields(
  value: JsonValue,
  id: Option(Int),
) -> Result(List(#(String, JsonValue)), ProtocolFault) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error(BadEnvelope(reason: "a json object envelope", id:))
  }
}

fn check_version(
  fields: List(#(String, JsonValue)),
  id: Option(Int),
) -> Result(Nil, ProtocolFault) {
  case list.key_find(fields, "v") {
    Ok(json.Int(v)) if v == version -> Ok(Nil)
    _ ->
      Error(BadEnvelope(
        reason: "protocol version " <> int.to_string(version),
        id:,
      ))
  }
}

fn body_fields(value: JsonValue) -> Result(List(#(String, JsonValue)), String) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("a json object body")
  }
}

fn required_string(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(String, String) {
  case list.key_find(fields, key) {
    Ok(json.String(text)) -> Ok(text)
    Ok(_) -> Error(key <> " must be a string")
    Error(Nil) -> Error(key <> " is required")
  }
}

fn optional_string(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(Option(String), String) {
  case list.key_find(fields, key) {
    Error(Nil) -> Ok(None)
    Ok(json.String(text)) -> Ok(Some(text))
    Ok(_) -> Error(key <> " must be a string")
  }
}

fn required_int(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(Int, String) {
  case list.key_find(fields, key) {
    Ok(json.Int(value)) -> Ok(value)
    Ok(_) -> Error(key <> " must be an integer")
    Error(Nil) -> Error(key <> " is required")
  }
}

fn optional_int(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(Option(Int), String) {
  case list.key_find(fields, key) {
    Error(Nil) -> Ok(None)
    Ok(json.Int(value)) -> Ok(Some(value))
    Ok(_) -> Error(key <> " must be an integer")
  }
}

// --- the wire form of codec-encoded entries --------------------------------

// codec → wire: rewrites assistant content blocks (in messages and in
// compaction retained tails) into the fixture-pinned shapes.
fn wire_entry(value: JsonValue) -> JsonValue {
  map_object_field(value, "message", wire_message)
  |> map_object_field("retainedTail", fn(tail) {
    case tail {
      json.Array(items) -> json.Array(list.map(items, wire_message))
      other -> other
    }
  })
}

// wire → codec: the inverse rewrite, applied before total decoding.
fn codec_entry(value: JsonValue) -> JsonValue {
  map_object_field(value, "message", codec_message)
  |> map_object_field("retainedTail", fn(tail) {
    case tail {
      json.Array(items) -> json.Array(list.map(items, codec_message))
      other -> other
    }
  })
}

fn wire_message(value: JsonValue) -> JsonValue {
  map_object_field(value, "content", fn(content) {
    case content {
      json.Array(items) -> json.Array(list.map(items, wire_block))
      other -> other
    }
  })
}

fn codec_message(value: JsonValue) -> JsonValue {
  map_object_field(value, "content", fn(content) {
    case content {
      json.Array(items) -> json.Array(list.map(items, codec_block))
      other -> other
    }
  })
}

fn wire_block(value: JsonValue) -> JsonValue {
  case value {
    json.Object(fields) ->
      case list.key_find(fields, "type") {
        // The wire nests the call under `toolCall`; the codec inlines it.
        Ok(json.String("toolCall")) ->
          json.Object([
            #("type", json.String("toolCall")),
            #(
              "toolCall",
              json.Object(list.filter(fields, fn(field) { field.0 != "type" })),
            ),
          ])
        // The wire always carries `redacted`; the codec omits `false`.
        Ok(json.String("thinking")) ->
          case list.key_find(fields, "redacted") {
            Ok(_) -> value
            Error(Nil) ->
              json.Object(
                list.append(fields, [#("redacted", json.Bool(False))]),
              )
          }
        _ -> value
      }
    other -> other
  }
}

fn codec_block(value: JsonValue) -> JsonValue {
  case value {
    json.Object(fields) ->
      case list.key_find(fields, "type"), list.key_find(fields, "toolCall") {
        Ok(json.String("toolCall")), Ok(json.Object(call_fields)) ->
          json.Object([#("type", json.String("toolCall")), ..call_fields])
        _, _ -> value
      }
    other -> other
  }
}

fn map_object_field(
  value: JsonValue,
  key: String,
  change: fn(JsonValue) -> JsonValue,
) -> JsonValue {
  case value {
    json.Object(fields) ->
      json.Object(
        list.map(fields, fn(field) {
          case field.0 == key {
            True -> #(key, change(field.1))
            False -> field
          }
        }),
      )
    other -> other
  }
}

// --- wire serialization ----------------------------------------------------

/// Serializes a value for the wire. Identical to `core/json.to_string`
/// except for float rendering: the golden fixtures print floats the way
/// Go's `encoding/json` does — positional digits for decimal exponents
/// in `(-7, 21)` (`0.00027`), scientific only outside that range —
/// where the BEAM's shortest form goes scientific much sooner
/// (`2.7e-4`). Both parse to the same value; the fixtures pin the
/// bytes, so the wire follows Go.
///
/// ## Examples
///
/// ```gleam
/// assert protocol.to_wire_text(json.Array([json.Float(0.00027)]))
///   == "[0.00027]"
/// ```
///
pub fn to_wire_text(value: JsonValue) -> String {
  case value {
    json.Null -> "null"
    json.Bool(True) -> "true"
    json.Bool(False) -> "false"
    json.Int(number) -> int.to_string(number)
    json.Float(number) -> wire_float(number)
    json.String(_) -> json.to_string(value)
    json.Array(items) ->
      "[" <> string.join(list.map(items, to_wire_text), ",") <> "]"
    json.Object(fields) ->
      "{"
      <> string.join(
        list.map(fields, fn(field) {
          json.to_string(json.String(field.0)) <> ":" <> to_wire_text(field.1)
        }),
        ",",
      )
      <> "}"
  }
}

// Renders one float Go-style: take the BEAM's shortest form and, when
// it chose scientific notation with a decimal exponent in Go's
// positional range, expand it positionally. Anything outside the range
// keeps the BEAM form (still valid JSON parsing to the same value).
fn wire_float(number: Float) -> String {
  let text = float.to_string(number)
  case string.split_once(text, "e") {
    Error(Nil) -> text
    Ok(#(mantissa, exponent_text)) ->
      expand_scientific(text, mantissa, exponent_text)
  }
}

fn expand_scientific(
  text: String,
  mantissa: String,
  exponent_text: String,
) -> String {
  case int.parse(exponent_text) {
    Error(Nil) -> text
    Ok(exponent) -> positional_float(text, mantissa, exponent)
  }
}

fn positional_float(text: String, mantissa: String, exponent: Int) -> String {
  let #(sign, mantissa) = case mantissa {
    "-" <> rest -> #("-", rest)
    other -> #("", other)
  }
  let #(whole, fraction) = case string.split_once(mantissa, ".") {
    Ok(#(whole, fraction)) -> #(whole, fraction)
    Error(Nil) -> #(mantissa, "")
  }
  let digits = whole <> fraction
  // The decimal point sits after `point` digits of `digits`.
  let point = string.length(whole) + exponent
  let total = string.length(digits)
  case point > -7 && point < 21 {
    False -> text
    True -> place_decimal_point(sign, digits, point, total)
  }
}

// `point <= 0`: the point sits before every digit, padded with zeros.
// `point >= total`: the point sits after every digit, padded the other
// way. Otherwise it falls inside `digits` and splits it in two.
fn place_decimal_point(
  sign: String,
  digits: String,
  point: Int,
  total: Int,
) -> String {
  case point <= 0 {
    True -> sign <> "0." <> string.repeat("0", int.negate(point)) <> digits
    False ->
      case point >= total {
        True -> sign <> digits <> string.repeat("0", point - total) <> ".0"
        False ->
          sign
          <> string.slice(digits, at_index: 0, length: point)
          <> "."
          <> string.slice(digits, at_index: point, length: total - point)
      }
  }
}
