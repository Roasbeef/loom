//// Peer discovery and delivery through resident-only daemon routing.
////
//// A link is an operator decision, independent of lineage, child custody,
//// repository similarity, or permission to join. The sender's durable index
//// bounds discovery; the recipient's grant remains the delivery authority.
//// Saved sessions are described without opening their conversation stores.

import broker/framing
import broker/policy
import client/peer_mail
import codemode/internal/args
import codemode/satellite
import core/json.{type JsonValue}
import core/msgpack
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import tools/tool

/// Narrow lookups over the daemon manager, evaluated outside its mailbox.
pub type Directory {
  Directory(
    /// Looks up only a currently resident endpoint; never opens a session.
    resolve: fn(String) -> Result(peer_mail.Endpoint, String),
    /// Current catalogue metadata and lifecycle, without opening a session.
    describe: fn(String) -> Result(JsonValue, String),
  )
}

/// The source session's authenticated endpoint and optional daemon directory.
pub type Wiring {
  Wiring(
    /// Bound by session assembly, never selected by tool arguments.
    own: peer_mail.Endpoint,
    /// Local fallback metadata for an embedded session.
    metadata: JsonValue,
    /// The daemon's resident-only directory, absent in an embedded host.
    directory: Option(Directory),
  )
}

/// Changes an exact directional link after owner authorization by the control
/// server. Creation writes recipient permission before publishing discovery;
/// revocation removes discovery before removing recipient permission. A failed
/// half is reported and the same operation can be retried idempotently.
///
/// ## Examples
///
/// ```gleam
/// // peers.link(source, recipient, "main", "reviewer", peer_mail.BusyOnly)
/// ```
pub fn link(
  source: peer_mail.Endpoint,
  recipient: peer_mail.Endpoint,
  from: String,
  to: String,
  wake: peer_mail.Wake,
) -> Result(JsonValue, String) {
  use _ <- result.try(
    recipient.call(
      peer_mail.Allow(peer_mail.Grant(source.session, from, to, wake)),
    ),
  )
  source.call(peer_mail.Link(from, recipient.session, to))
}

/// Removes one exact directional link; unrelated grants retain their policy.
///
/// ## Examples
///
/// ```gleam
/// // peers.unlink(source, recipient, "main", "reviewer")
/// ```
pub fn unlink(
  source: peer_mail.Endpoint,
  recipient: peer_mail.Endpoint,
  from: String,
  to: String,
) -> Result(JsonValue, String) {
  use _ <- result.try(
    source.call(peer_mail.Unlink(from, recipient.session, to)),
  )
  recipient.call(
    peer_mail.Revoke(peer_mail.Grant(
      source.session,
      from,
      to,
      peer_mail.BusyOnly,
    )),
  )
}

/// Sends using a stable caller-chosen request identity. Reusing the identity
/// for different content is refused by the recipient, even after a restart.
///
/// ## Examples
///
/// ```gleam
/// // peers.send(wiring, "main", target_session, "main", "review-1", "finding")
/// ```
pub fn send(
  wiring: Wiring,
  strand: String,
  session: String,
  target: String,
  id: String,
  text: String,
) -> Result(JsonValue, String) {
  use links <- result.try(links(wiring, strand))
  use Nil <- result.try(
    case
      list.any(links, fn(link) {
        field(link, "session") == Ok(json.String(session))
        && field(link, "strand") == Ok(json.String(target))
      })
    {
      True -> Ok(Nil)
      False -> Error("no operator-authorized outgoing link")
    },
  )
  use destination <- result.try(resolve(wiring, session))
  use Nil <- result.try(case destination.session == session {
    True -> Ok(Nil)
    False -> Error("peer directory identity mismatch")
  })
  use catalogue <- result.try(describe(wiring, wiring.own.session))
  use activity <- result.try(wiring.own.call(peer_mail.Activity(strand)))
  let metadata =
    json.Object([#("catalogue", catalogue), #("activity", activity)])
  destination.call(peer_mail.Deliver(
    peer_mail.Source(wiring.own.session, strand, metadata),
    target,
    id,
    text,
  ))
}

/// Lists only explicitly linked sessions and exported strands. An unavailable
/// recipient remains visible with catalogue lifecycle; discovery never opens it.
///
/// ## Examples
///
/// ```gleam
/// // peers.roster(wiring, "main")
/// ```
pub fn roster(wiring: Wiring, strand: String) -> Result(JsonValue, String) {
  use links <- result.try(links(wiring, strand))
  use rows <- result.try(
    list.try_map(links, fn(link) {
      use session <- result.try(text(link, "session"))
      use target <- result.try(text(link, "strand"))
      let metadata = case describe(wiring, session) {
        Ok(value) -> value
        Error(reason) -> json.Object([#("unavailable", json.String(reason))])
      }
      let strands = case resolve(wiring, session) {
        Error(_) -> json.Null
        Ok(endpoint) ->
          case endpoint.call(peer_mail.Roster(wiring.own.session, strand)) {
            Ok(rows) -> rows
            Error(reason) ->
              json.Object([#("unavailable", json.String(reason))])
          }
      }
      Ok(
        json.Object([
          #("session", json.String(session)),
          #("target_strand", json.String(target)),
          #("metadata", metadata),
          #("exported_strands", strands),
        ]),
      )
    }),
  )
  Ok(json.Array(rows))
}

/// Reads one resident strand's outgoing links and incoming operator grants.
/// Saved recipients remain visible as unavailable rows; inspection never
/// resolves them into a running session.
///
/// ## Examples
///
/// ```gleam
/// // peers.inspect(wiring, "main", None, 59000)
/// ```
pub fn inspect(
  wiring: Wiring,
  strand: String,
  after: Option(String),
  body_budget: Int,
) -> Result(JsonValue, String) {
  use _ <- result.try(wiring.own.call(peer_mail.Activity(strand)))
  use outgoing <- result.try(links(wiring, strand))
  use incoming <- result.try(wiring.own.call(peer_mail.Grants(strand)))
  use outgoing <- result.try(
    list.try_map(outgoing, fn(link) {
      use session <- result.try(text(link, "session"))
      use target <- result.try(text(link, "strand"))
      let metadata = case describe(wiring, session) {
        Ok(value) -> value
        Error(reason) -> json.Object([#("unavailable", json.String(reason))])
      }
      let wake = case resolve(wiring, session) {
        Error(_) -> json.Null
        Ok(endpoint) ->
          case endpoint.call(peer_mail.Roster(wiring.own.session, strand)) {
            Error(_) -> json.Null
            Ok(json.Array(rows)) ->
              case
                list.find(rows, fn(row) {
                  field(row, "strand") == Ok(json.String(target))
                })
              {
                Error(Nil) -> json.Null
                Ok(row) -> field(row, "wake") |> result.unwrap(json.Null)
              }
            Ok(_) -> json.Null
          }
      }
      Ok(InspectRow(
        inspect_key("o", session, target),
        OutgoingRow,
        json.Object([
          #("session", json.String(session)),
          #("target_strand", json.String(target)),
          #("wake", wake),
          #("metadata", metadata),
        ]),
      ))
    }),
  )
  use incoming <- result.try(case incoming {
    json.Array(rows) ->
      list.try_map(rows, fn(row) {
        use source <- result.try(text(row, "source_session"))
        use source_strand <- result.try(text(row, "source_strand"))
        let metadata = case describe(wiring, source) {
          Ok(value) -> value
          Error(reason) -> json.Object([#("unavailable", json.String(reason))])
        }
        case row {
          json.Object(fields) ->
            Ok(InspectRow(
              inspect_key("i", source, source_strand),
              IncomingRow,
              json.Object([#("metadata", metadata), ..fields]),
            ))
          _ -> Error("invalid incoming peer grant")
        }
      })
    _ -> Error("invalid incoming peer grants")
  })
  let rows =
    list.sort(list.append(outgoing, incoming), fn(a, b) {
      string.compare(a.key, b.key)
    })
  let rows = case after {
    None -> rows
    Some(cursor) ->
      list.filter(rows, fn(row) { string.compare(row.key, cursor) == order.Gt })
  }
  page_inspection(wiring, strand, rows, [], [], None, body_budget)
}

type InspectKind {
  OutgoingRow
  IncomingRow
}

type InspectRow {
  InspectRow(key: String, kind: InspectKind, value: JsonValue)
}

fn inspect_key(direction: String, session: String, strand: String) -> String {
  direction
  <> ":"
  <> json.to_string(json.Array([json.String(session), json.String(strand)]))
}

fn inspection_body(
  wiring: Wiring,
  strand: String,
  outgoing: List(JsonValue),
  incoming: List(JsonValue),
  next: Option(String),
) -> JsonValue {
  json.Object([
    #("source_session", json.String(wiring.own.session)),
    #("source_strand", json.String(strand)),
    #("metadata", wiring.metadata),
    #("outgoing", json.Array(list.reverse(outgoing))),
    #("incoming", json.Array(list.reverse(incoming))),
    #("next", case next {
      Some(cursor) -> json.String(cursor)
      None -> json.Null
    }),
  ])
}

fn page_inspection(
  wiring: Wiring,
  strand: String,
  rows: List(InspectRow),
  outgoing: List(JsonValue),
  incoming: List(JsonValue),
  last: Option(String),
  budget: Int,
) -> Result(JsonValue, String) {
  case rows {
    [] -> {
      let body = inspection_body(wiring, strand, outgoing, incoming, None)
      case string.byte_size(json.to_string(body)) <= budget {
        True -> Ok(body)
        False -> Error("metadata_too_large")
      }
    }
    [row, ..rest] -> {
      let #(outgoing_next, incoming_next) = case row.kind {
        OutgoingRow -> #([row.value, ..outgoing], incoming)
        IncomingRow -> #(outgoing, [row.value, ..incoming])
      }
      let candidate =
        inspection_body(
          wiring,
          strand,
          outgoing_next,
          incoming_next,
          Some(row.key),
        )
      case string.byte_size(json.to_string(candidate)) <= budget {
        True ->
          page_inspection(
            wiring,
            strand,
            rest,
            outgoing_next,
            incoming_next,
            Some(row.key),
            budget,
          )
        False ->
          case last {
            None -> Error("metadata_too_large")
            Some(_) ->
              Ok(inspection_body(wiring, strand, outgoing, incoming, last))
          }
      }
    }
  }
}

fn links(wiring: Wiring, strand: String) -> Result(List(JsonValue), String) {
  use value <- result.try(wiring.own.call(peer_mail.Links(strand)))
  case value {
    json.Array(links) ->
      case list.length(links) <= peer_mail.outgoing_link_limit {
        True -> Ok(links)
        False -> Error("peer roster exceeds the 64-link bound")
      }
    _ -> Error("invalid outgoing peer index")
  }
}

fn resolve(
  wiring: Wiring,
  session: String,
) -> Result(peer_mail.Endpoint, String) {
  case session == wiring.own.session, wiring.directory {
    True, _ -> Ok(wiring.own)
    False, Some(directory) -> directory.resolve(session)
    False, None -> Error("this embedded session has no daemon peer directory")
  }
}

fn describe(wiring: Wiring, session: String) -> Result(JsonValue, String) {
  case wiring.directory {
    Some(directory) -> directory.describe(session)
    None ->
      case session == wiring.own.session {
        True -> Ok(wiring.metadata)
        False -> Error("unknown peer session")
      }
  }
}

/// Model-facing discovery and messaging, with no grant-management operation.
///
/// ## Examples
///
/// ```gleam
/// // peers.tools(wiring)
/// ```
pub fn tools(wiring: Wiring) -> List(tool.Tool) {
  [
    tool.Tool(
      name: "peer_describe",
      description: "Set your own peer-discovery description (at most 2048 bytes). It is labeled as a model claim and grants no authority.",
      prompt_snippet: None,
      schema: tool.object_schema(
        [
          #(
            "description",
            tool.string_property("model-authored self-description"),
          ),
        ],
        ["description"],
      ),
      replay: tool.Safe,
      execution_mode: tool.Concurrent,
      requirements: requirements,
      run: fn(ctx, args) {
        use description <- tool.with_arg(tool.required_string(
          args,
          "description",
        ))
        outcome(wiring.own.call(peer_mail.Describe(ctx.strand, description)))
      },
    ),
    tool.Tool(
      name: "peer_roster",
      description: "List operator-linked sessions and exported strands, including saved-session lifecycle. Repository similarity does not grant access. Model self-description is not authority.",
      prompt_snippet: None,
      schema: tool.object_schema([], []),
      replay: tool.Safe,
      execution_mode: tool.Concurrent,
      requirements: requirements,
      run: fn(ctx, _) { outcome(roster(wiring, ctx.strand)) },
    ),
    tool.Tool(
      name: "peer_send",
      description: "Send to an operator-linked strand in a resident session. Supply a stable message_id and reuse it only when retrying the same message. The receipt proves durable admission, not consumption or completion. Idle recipients wake only when the operator granted it.",
      prompt_snippet: None,
      schema: tool.object_schema(
        [
          #("session", tool.string_property("canonical recipient session ID")),
          #(
            "strand",
            tool.string_property("explicitly exported recipient strand"),
          ),
          #(
            "message_id",
            tool.string_property("stable request identity, at most 128 bytes"),
          ),
          #("text", tool.string_property("message body, at most 32768 bytes")),
        ],
        ["session", "strand", "message_id", "text"],
      ),
      replay: tool.Safe,
      execution_mode: tool.Concurrent,
      requirements: requirements,
      run: fn(ctx, args) {
        use session <- tool.with_arg(tool.required_string(args, "session"))
        use strand <- tool.with_arg(tool.required_string(args, "strand"))
        use id <- tool.with_arg(tool.required_string(args, "message_id"))
        use text <- tool.with_arg(tool.required_string(args, "text"))
        outcome(send(wiring, ctx.strand, session, strand, id, text))
      },
    ),
  ]
}

fn requirements(workspace: String) -> policy.SandboxPolicy {
  let base = policy.workspace_default(workspace)
  policy.SandboxPolicy(
    ..base,
    readable_roots: [],
    writable_roots: [],
    env_allow: [],
  )
}

fn outcome(answer: Result(JsonValue, String)) -> tool.ToolOutcome {
  case answer {
    Ok(value) -> tool.success(json.to_string(value)) |> tool.with_details(value)
    Error(reason) -> tool.failure(reason)
  }
}

fn field(value: JsonValue, key: String) -> Result(JsonValue, String) {
  case value {
    json.Object(fields) ->
      list.key_find(fields, key) |> result.replace_error("missing peer field")
    _ -> Error("expected peer object")
  }
}

fn text(value: JsonValue, key: String) -> Result(String, String) {
  use value <- result.try(field(value, key))
  case value {
    json.String(value) -> Ok(value)
    _ -> Error("expected peer text")
  }
}

/// The peer calls this router services on every installed program mode.
pub const serviced_caps = ["peer.roster", "peer.send"]

/// Routes peer calls with the launching strand's authenticated identity.
/// No argument can select a different sending session or strand.
///
/// ## Examples
///
/// ```gleam
/// // peers.router(wiring, request.strand, fallback)
/// ```
pub fn router(
  wiring: Wiring,
  strand: String,
  fallback: satellite.CapRouter,
) -> satellite.CapRouter {
  fn(request: satellite.CapRequest) {
    case request.cap {
      "peer.send" | "peer.roster" if request.ordinal >= 128 ->
        Error(satellite.CapDenial(
          "admission_ceiling",
          "peer capability admission ceiling reached",
        ))
      "peer.roster" ->
        Ok(satellite.ServedHere(fn() { wire_answer(roster(wiring, strand)) }))
      "peer.send" -> {
        use session <- result.try(args.string(request.args, "session"))
        use target <- result.try(args.string(request.args, "strand"))
        use id <- result.try(args.string(request.args, "message_id"))
        use body <- result.try(args.string(request.args, "text"))
        Ok(
          satellite.ServedHere(fn() {
            wire_answer(send(wiring, strand, session, target, id, body))
          }),
        )
      }
      _ -> fallback(request)
    }
  }
}

fn wire_answer(answer: Result(JsonValue, String)) {
  case answer {
    Ok(value) -> framing.CapOk(msgpack.StringValue(json.to_string(value)))
    Error(reason) -> framing.CapErr("peer_refused", reason)
  }
}
