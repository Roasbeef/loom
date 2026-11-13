//// A settled join answer, kept as text and read back
//// (protocol-change/107, slice 4b).
////
//// A seeded child's session is ended once the child's entry is `Ready`, and the
//// session is where the entry's report, usage and notes live. A join that is
//// asked again afterwards, because the parent's wait was deferred, because a
//// second wait named the same handle, or because a reply was lost, must get the
//// answer the first one did. `client/spawn_return` keeps the settled `Ready` entry
//// in this form beside the child's verdict before the session is ended, and
//// `client/child_join` answers from it when the session is gone.
////
//// ## What is kept
////
//// Every field of a `Ready` entry. The structured result is kept as its schema and
//// its value and not as the mismatch, which is derived again from the two when the
//// entry is read back, so the text cannot disagree with itself. A `Pending` entry
//// is never kept, because it is not an answer.
////
//// `decode` is total. A file that does not read is no answer, and the caller
//// treats the child as one this orchestrator no longer holds.

import client/remote_spawn.{type Joined}
import client/state_object
import core/json as core_json
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import tools/agent

/// The entry as JSON text, or `Nil` for an entry that is not an answer.
///
/// ## Examples
///
/// ```gleam
/// // joined_record.encode(entry) |> result.try(joined_record.decode) == Ok(entry)
/// ```
pub fn encode(entry: Joined) -> Result(String, Nil) {
  case entry {
    remote_spawn.Pending(..) -> Error(Nil)
    remote_spawn.Ready(
      handle:,
      outcome:,
      report:,
      result:,
      notes:,
      usage:,
      owed:,
      state:,
    ) -> {
      let #(kind, reason) = outcome_words(outcome)
      Ok(
        json.object([
          #("handle", json.string(agent.handle_to_string(handle))),
          #("outcome", json.string(kind)),
          #("reason", json.string(reason)),
          #("report", json.string(report)),
          #("result", result_json(result)),
          #(
            "notes",
            json.array(notes, fn(note) {
              json.object([
                #("key", json.string(note.0)),
                #("value", json.string(core_json.to_string(note.1))),
              ])
            }),
          ),
          #("input", json.int(usage.input)),
          #("output", json.int(usage.output)),
          #("cache_read", json.int(usage.cache_read)),
          #("cache_write", json.int(usage.cache_write)),
          #("cost", json.float(usage.cost)),
          #("owed", json.int(owed)),
          #(
            "state",
            json.nullable(option.map(state, state_object.encode), json.string),
          ),
        ])
        |> json.to_string,
      )
    }
  }
}

/// The word and reason an outcome is kept as.
fn outcome_words(outcome: agent.Outcome) -> #(String, String) {
  case outcome {
    agent.Completed -> #("completed", "")
    agent.Failed(reason:) -> #("failed", reason)
    agent.Aborted -> #("aborted", "")
    agent.BudgetExpired -> #("budget_expired", "")
    agent.ParentFinished -> #("parent_finished", "")
    agent.Released -> #("released", "")
    agent.TokenBudgetSpent -> #("token_budget_spent", "")
  }
}

/// The outcome a word and reason name, or nothing for a word that is not ours.
fn outcome_of(kind: String, reason: String) -> Result(agent.Outcome, Nil) {
  case kind {
    "completed" -> Ok(agent.Completed)
    "failed" -> Ok(agent.Failed(reason:))
    "aborted" -> Ok(agent.Aborted)
    "budget_expired" -> Ok(agent.BudgetExpired)
    "parent_finished" -> Ok(agent.ParentFinished)
    "released" -> Ok(agent.Released)
    "token_budget_spent" -> Ok(agent.TokenBudgetSpent)
    _ -> Error(Nil)
  }
}

/// The structured result as its kind, schema and value, each as text.
fn result_json(result: agent.TerminalResult) -> json.Json {
  let #(kind, schema, value) = case result {
    agent.NoResultAsked -> #("none", "", "")
    agent.ResultGiven(value:) -> #("given", "", core_json.to_string(value))
    agent.ResultAbsent(schema:) -> #(
      "absent",
      core_json.to_string(agent.render_result_schema(schema)),
      "",
    )
    agent.ResultUnusable(schema:, received:, ..) -> #(
      "unusable",
      core_json.to_string(agent.render_result_schema(schema)),
      core_json.to_string(received),
    )
  }
  json.object([
    #("kind", json.string(kind)),
    #("schema", json.string(schema)),
    #("value", json.string(value)),
  ])
}

/// Reads a kept entry back, or says nothing when the text is not one this module
/// wrote.
///
/// ## Examples
///
/// ```gleam
/// // joined_record.decode("not json") == Error(Nil)
/// ```
pub fn decode(text: String) -> Result(Joined, Nil) {
  let result_decoder = {
    use kind <- decode.field("kind", decode.string)
    use schema <- decode.field("schema", decode.string)
    use value <- decode.field("value", decode.string)
    decode.success(#(kind, schema, value))
  }
  let note_decoder = {
    use key <- decode.field("key", decode.string)
    use value <- decode.field("value", decode.string)
    decode.success(#(key, value))
  }
  let decoder = {
    use handle <- decode.field("handle", decode.string)
    use kind <- decode.field("outcome", decode.string)
    use reason <- decode.field("reason", decode.string)
    use report <- decode.field("report", decode.string)
    use result <- decode.field("result", result_decoder)
    use notes <- decode.field("notes", decode.list(note_decoder))
    use input <- decode.field("input", decode.int)
    use output <- decode.field("output", decode.int)
    use cache_read <- decode.field("cache_read", decode.int)
    use cache_write <- decode.field("cache_write", decode.int)
    use cost <- decode.field("cost", decode.float)
    use owed <- decode.field("owed", decode.int)
    use state <- decode.field("state", decode.optional(decode.string))
    decode.success(#(
      handle,
      kind,
      reason,
      report,
      result,
      notes,
      #(input, output, cache_read, cache_write, cost),
      owed,
      state,
    ))
  }
  use #(handle, kind, reason, report, kept, notes, usage, owed, state) <- result.try(
    result.replace_error(json.parse(text, decoder), Nil),
  )
  use handle <- result.try(result.replace_error(agent.parse_handle(handle), Nil))
  use outcome <- result.try(outcome_of(kind, reason))
  use result <- result.try(terminal_of(kept.0, kept.1, kept.2))
  use notes <- result.try(
    list.try_map(notes, fn(note) {
      core_json.parse(note.1)
      |> result.map(fn(value) { #(note.0, value) })
      |> result.replace_error(Nil)
    }),
  )
  use held <- result.map(case state {
    Some(text) ->
      state_object.decode(text) |> result.map(Some) |> result.replace_error(Nil)
    None -> Ok(None)
  })
  remote_spawn.Ready(
    handle:,
    outcome:,
    report:,
    result:,
    notes:,
    usage: remote_spawn.ChildUsage(
      input: usage.0,
      output: usage.1,
      cache_read: usage.2,
      cache_write: usage.3,
      cost: usage.4,
    ),
    owed:,
    state: held,
  )
}

/// The structured result a kind, schema text and value text name. The mismatch of
/// an unusable result is derived from the schema and the value, and a pair that
/// matches after all is not an unusable result.
fn terminal_of(
  kind: String,
  schema: String,
  value: String,
) -> Result(agent.TerminalResult, Nil) {
  case kind {
    "none" -> Ok(agent.NoResultAsked)
    "given" ->
      core_json.parse(value)
      |> result.map(agent.ResultGiven)
      |> result.replace_error(Nil)
    "absent" -> schema_of(schema) |> result.map(agent.ResultAbsent)
    "unusable" -> {
      use schema <- result.try(schema_of(schema))
      use received <- result.try(result.replace_error(
        core_json.parse(value),
        Nil,
      ))
      case agent.validate_result(schema, received) {
        Error(mismatch) ->
          Ok(agent.ResultUnusable(schema:, received:, mismatch:))
        Ok(Nil) -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

/// A schema from its text.
fn schema_of(text: String) -> Result(agent.ResultSchema, Nil) {
  core_json.parse(text)
  |> result.replace_error(Nil)
  |> result.try(fn(value) {
    result.replace_error(agent.parse_result_schema(value), Nil)
  })
}
