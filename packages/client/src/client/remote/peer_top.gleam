//// Protocol 094's operations inside the stable peer envelope.
////
//// The existing TopHost remains the authority: this module only converts
//// bounded JSON to its arguments and converts its result back to data. It
//// never trusts a caller-supplied node identity.

import client/protocol
import client/remote/orchestrator_port.{type TopHost}
import client/remote_escalation
import client/remote_top
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// Runs one already-fenced operation through the receiving host.
///
/// ## Examples
///
/// ```gleam
/// // peer_top.dispatch(host, "laptop@host", "094.placements.1", json.Array([]))
/// ```
pub fn dispatch(
  host: TopHost,
  node: String,
  revision: String,
  body: JsonValue,
) -> Result(Result(JsonValue, remote_top.Refusal), String) {
  // The exact revision selects the old host function and its complete body.
  case revision, body {
    "094.placements.1", json.Array([]) -> Ok(host.placements(node))
    "094.create.1",
      json.Array([json.String(id), placement, json.String(profile), model])
    -> {
      use placement <- result.try(remote_top.decode_placement(placement))
      use model <- result.try(optional_text(model))
      Ok(
        host.create(node, id, placement, profile, model)
        |> result.map(json.String),
      )
    }
    "094.sessions.1", json.Array([json.String(after), json.Int(limit)]) ->
      Ok(host.sessions(node, after, limit))
    "094.history.1",
      json.Array([json.String(session), json.Int(cursor), json.Int(limit)])
    -> Ok(host.history(node, session, cursor, limit))
    "094.send.1",
      json.Array([json.String(session), json.String(id), json.String(text)])
    -> Ok(host.send(node, session, id, text))
    "094.stop.1", json.Array([json.String(session)]) ->
      Ok(host.stop(node, session) |> result.map(fn(_) { json.Null }))
    "094.archive.1", json.Array([json.String(session)]) ->
      Ok(host.archive(node, session) |> result.map(fn(_) { json.Null }))
    "094.resolve.1",
      json.Array([
        json.String(session),
        json.String(id),
        decision,
        json.Int(seq),
        json.String(principal),
        json.String(name),
      ])
    -> {
      use decision <- result.try(decode_decision(decision))
      Ok(
        host.resolve(
          node,
          session,
          id,
          decision,
          seq,
          remote_escalation.Decider(principal:, name:),
        )
        |> result.map(encode_answer),
      )
    }
    _, _ -> Error("invalid operation body")
  }
}

/// Encodes the existing decision, including the exact echoed grants and action.
///
/// ## Examples
///
/// ```gleam
/// // peer_top.encode_decision(remote_escalation.Deny)
/// ```
pub fn encode_decision(decision: remote_escalation.Decision) -> JsonValue {
  case decision {
    remote_escalation.Deny -> json.Array([json.String("deny")])
    remote_escalation.Forget(grant) ->
      json.Array([json.String("forget"), protocol.encode_grant(grant)])
    remote_escalation.Approve(grants:, action:, scope:) ->
      json.Array([
        json.String("approve"),
        json.Array(list.map(grants, protocol.encode_grant)),
        json.String(action),
        json.String(case scope {
          remote_escalation.Once -> "once"
          remote_escalation.Session -> "session"
        }),
      ])
  }
}

/// Decodes a decision completely before it reaches the host.
fn decode_decision(
  value: JsonValue,
) -> Result(remote_escalation.Decision, String) {
  // An approval cannot reach the host with only part of its echoed grant set.
  case value {
    json.Array([json.String("deny")]) -> Ok(remote_escalation.Deny)
    json.Array([json.String("forget"), grant]) ->
      protocol.decode_grant(grant) |> result.map(remote_escalation.Forget)
    json.Array([
      json.String("approve"),
      json.Array(grants),
      json.String(action),
      json.String(scope),
    ]) -> {
      use grants <- result.try(list.try_map(grants, protocol.decode_grant))
      use scope <- result.map(scope_of(scope))
      remote_escalation.Approve(grants:, action:, scope:)
    }
    json.Array(_)
    | json.Object(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("invalid decision")
  }
}

/// Decodes only the two approved grant lifetimes.
fn scope_of(scope: String) -> Result(remote_escalation.Scope, String) {
  case scope {
    "once" -> Ok(remote_escalation.Once)
    "session" -> Ok(remote_escalation.Session)
    _ -> Error("invalid approval scope")
  }
}

/// Encodes a decision answer with the current record when one is available.
fn encode_answer(answer: remote_escalation.Answer) -> JsonValue {
  case answer {
    remote_escalation.Decided(record) ->
      json.Array([json.String("decided"), protocol.encode_escalation(record)])
    remote_escalation.Forgotten -> json.Array([json.String("forgotten")])
    remote_escalation.Stale(record, reason) ->
      json.Array([
        json.String("stale"),
        protocol.encode_escalation(record),
        json.String(reason),
      ])
    remote_escalation.Refused(reason) ->
      json.Array([json.String("refused"), json.String(reason)])
  }
}

/// Reads a complete decision answer, including its record.
///
/// ## Examples
///
/// ```gleam
/// // peer_top.decode_answer(value)
/// ```
pub fn decode_answer(
  value: JsonValue,
) -> Result(remote_escalation.Answer, String) {
  case value {
    json.Array([json.String("decided"), record]) ->
      protocol.decode_escalation(record)
      |> result.map(remote_escalation.Decided)
    json.Array([json.String("forgotten")]) -> Ok(remote_escalation.Forgotten)
    json.Array([json.String("stale"), record, json.String(reason)]) ->
      protocol.decode_escalation(record)
      |> result.map(fn(record) { remote_escalation.Stale(record, reason) })
    json.Array([json.String("refused"), json.String(reason)]) ->
      Ok(remote_escalation.Refused(reason))
    json.Array(_)
    | json.Object(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("invalid decision answer")
  }
}

/// Reads an optional model selection without treating malformed data as absent.
fn optional_text(value: JsonValue) -> Result(Option(String), String) {
  case value {
    json.Null -> Ok(None)
    json.String(text) -> Ok(Some(text))
    json.Array(_)
    | json.Object(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_) -> Error("invalid optional text")
  }
}
