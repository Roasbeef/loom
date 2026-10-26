//// The model can inspect bounded traces and request admitted coding comparisons.
////
//// Both reach a program through `cap/evolution`. Native callers supply the
//// source session and its actual resolved identity.
//// The model cannot select an arbitrary private session, supply operator marks,
//// admit fixtures, or author the scorer. Evaluation arguments name an already
//// admitted immutable task set and lower the native hard budget ceilings.

import client/evolution/record
import client/evolution/rollout
import client/evolution/trace
import core/codec
import core/ids
import core/json
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import session/session
import tools/tool

/// The trace door as a plain function of the dispatching context.
///
/// The capability calls this, so the bounds, the
/// native source-session binding and the encoding have one definition.
///
/// ## Examples
///
/// ```gleam
/// // model_door.trace_door(source_for_ctx, actual_model_for_ctx)(ctx, args)
/// ```
///
pub fn trace_door(
  source: fn(tool.Ctx) -> Result(session.Session, String),
  actual: fn(tool.Ctx) -> Result(record.ModelScope, String),
) -> fn(tool.Ctx, json.JsonValue) -> tool.ToolOutcome {
  fn(ctx, args) {
    let result = {
      use source <- result.try(source(ctx))
      use target <- result.try(actual(ctx))
      use requested <- result.try(tool.optional_int(args, "limit"))

      // Default to 12 turns if limit was omitted by caller.
      let limit = case requested {
        None -> 12
        Some(limit) -> limit
      }

      // Verify that trace turn limit is within supported bounds.
      use Nil <- result.try(case limit > 0 && limit <= 32 {
        True -> Ok(Nil)
        False -> Error("Bounds: trace limit must be from one to thirty-two")
      })

      use brief <- result.try(trace.select(
        source,
        target,
        trace.Bounds(100, 256, limit, 1024, 32_768),
      ))
      Ok(encode_brief(brief))
    }

    // Convert brief extraction result to tool outcome.
    case result {
      Ok(value) -> tool.success(json.to_string(value))
      Error(reason) -> tool.failure(reason)
    }
  }
}

/// The most provider turns one comparison may make across every trial. The
/// evaluator's own bound (`rollout.validate`); a trial is at least two turns.
pub const turns_ceiling = 100

/// The longest wall one comparison may hold, in milliseconds. The compare
/// runs synchronously inside the one code-mode capability call that asked
/// for it, and that call's worker is killed at
/// `client/codemode.default_call_timeout_ms` with the fold half-done: the
/// in-flight trial's retirement and cleanup never run and no evidence is
/// kept. The ceiling therefore sits `wall_margin_ms` below that timeout, so
/// the fold's own wall fires first and close, score and cleanup still land
/// inside the call (`model_door_test` pins the relation).
pub const wall_ceiling_ms = 480_000

/// What the fold may still need after its wall has fired: the open trial's
/// retirement, scoring and cleanup, and the evidence write.
pub const wall_margin_ms = 120_000

/// Decodes only a task-set identity and ceilings for the paired native evaluator.
/// Absent limits use twenty trials, `turns_ceiling` turns, one million
/// tokens, two dollars, 64 KiB of retained output and `wall_ceiling_ms`.
/// Requests may only lower them. The turn and wall ceilings were raised from
/// twenty and two minutes (protocol-change/100) because a paired verdict
/// needs at least seven tasks of two or more provider turns each, and no
/// comparison under the old ceilings could end `Passed`; the dollar and
/// token ceilings, which bound the spend, are unchanged.
/// The optional `samples` member asks for that many independent samples of
/// every task per arm, one by default and at most three through this door.
///
/// ## Examples
///
/// ```gleam
/// // model_door.evaluation_request(evolution_test_arguments)
/// ```
pub fn evaluation_request(
  args: json.JsonValue,
) -> Result(#(String, rollout.Limits), String) {
  use task_set <- result.try(tool.required_string(args, "taskset_id"))

  // Parse and validate optional limit overrides against system ceilings.
  use limits <- result.try(case field(args, "limits") {
    Error(Nil) | Ok(json.Null) ->
      Ok(rollout.Limits(
        20,
        turns_ceiling,
        1_000_000,
        2.0,
        65_536,
        wall_ceiling_ms,
        1,
      ))
    Ok(value) -> limits(value)
  })

  Ok(#(task_set, limits))
}

/// Encodes bounded source evidence without exposing excluded source content.
fn encode_brief(brief: trace.Brief) -> json.JsonValue {
  json.Object([
    #("scrubber", json.String(brief.scrubber)),
    #("limitations", json.Array(list.map(brief.limitations, json.String))),
    #(
      "excerpts",
      json.Array(
        list.map(brief.excerpts, fn(excerpt) {
          json.Object([
            #("session_id", json.String(excerpt.session_id)),
            #("entry_id", json.String(ids.entry_id_to_string(excerpt.entry_id))),
            #("provider", json.String(excerpt.target.provider)),
            #("model", json.String(excerpt.target.model)),
            #("api", json.String(excerpt.target.api)),
            #("text", json.String(excerpt.text)),
            #("usage", case excerpt.usage {
              None -> json.Null
              Some(usage) -> codec.encode_usage(usage)
            }),
            #(
              "outcome",
              json.String(case excerpt.outcome {
                trace.Unmarked -> "unmarked"
                trace.Succeeded -> "succeeded"
                trace.Failed -> "failed"
              }),
            ),
          ])
        }),
      ),
    ),
  ])
}

/// Validates and decodes caller evaluation budget limits against ceilings.
fn limits(value: json.JsonValue) -> Result(rollout.Limits, String) {
  // Ensure the limits payload is a structured JSON object.
  use fields <- result.try(case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("Bounds: rollout limits must be an object")
  })

  let names = [
    "trials",
    "turns",
    "tokens",
    "dollars",
    "output_bytes",
    "wall_ms",
  ]

  // Every budget field is required and `samples` is the one optional member;
  // any other name is refused so a request cannot smuggle a scorer or a
  // ceiling this door does not know.
  use Nil <- result.try(
    case
      list.all(names, fn(name) { list.key_find(fields, name) |> result.is_ok })
      && list.all(fields, fn(member) {
        member.0 == "samples" || list.contains(names, member.0)
      })
    {
      True -> Ok(Nil)
      False ->
        Error(
          "Bounds: rollout limits require six exact budget fields and admit only an optional samples count",
        )
    },
  )

  // Extract numeric budget fields from the object payload.
  use trials <- result.try(integer(value, "trials"))
  use turns <- result.try(integer(value, "turns"))
  use tokens <- result.try(integer(value, "tokens"))
  use output_bytes <- result.try(integer(value, "output_bytes"))
  use wall_ms <- result.try(integer(value, "wall_ms"))

  // Parse dollar budget as float or coerce from integer.
  use dollars <- result.try(case field(value, "dollars") {
    Ok(json.Float(dollars)) -> Ok(dollars)
    Ok(json.Int(dollars)) -> Ok(int_to_float(dollars))
    _ -> Error("Bounds: dollars requires a positive number")
  })

  use samples <- result.try(samples(value))

  // Ensure all budget values remain strictly within native ceilings.
  case
    trials > 0
    && trials <= 20
    && turns > 0
    && turns <= turns_ceiling
    && tokens > 0
    && tokens <= 1_000_000
    && dollars >. 0.0
    && dollars <=. 2.0
    && output_bytes > 0
    && output_bytes <= 65_536
    && wall_ms > 0
    && wall_ms <= wall_ceiling_ms
  {
    True ->
      Ok(rollout.Limits(
        trials,
        turns,
        tokens,
        dollars,
        output_bytes,
        wall_ms,
        samples,
      ))
    False -> Error("Bounds: rollout request exceeds native model-door ceilings")
  }
}

// The model-door cap is below the evaluator's own ceiling of five on purpose:
// every sample is a paid fresh runtime, and a model spending the operator's
// money gets the smaller number.
/// Decodes the optional `samples` count, defaulting to one and capped at three.
fn samples(value: json.JsonValue) -> Result(Int, String) {
  // An absent or null member is the default of one; only an integer counts.
  use requested <- result.try(case field(value, "samples") {
    Error(Nil) | Ok(json.Null) -> Ok(1)
    Ok(json.Int(samples)) -> Ok(samples)
    Ok(json.Float(_))
    | Ok(json.String(_))
    | Ok(json.Bool(_))
    | Ok(json.Array(_))
    | Ok(json.Object(_)) -> Error("Bounds: samples requires an integer")
  })

  // Name the cap in the refusal so a program can lower its request.
  case requested > 0 && requested <= 3 {
    True -> Ok(requested)
    False -> Error("Bounds: samples must be from one to three")
  }
}

fn integer(value: json.JsonValue, name: String) -> Result(Int, String) {
  case field(value, name) {
    Ok(json.Int(value)) -> Ok(value)
    _ -> Error("Bounds: rollout counter requires an integer")
  }
}

fn field(value: json.JsonValue, name: String) -> Result(json.JsonValue, Nil) {
  case value {
    json.Object(fields) -> list.key_find(fields, name)
    _ -> Error(Nil)
  }
}

fn int_to_float(value: Int) -> Float {
  value |> int.to_float
}
