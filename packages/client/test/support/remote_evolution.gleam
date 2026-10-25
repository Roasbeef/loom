//// A scripted evolution plane for the fake executor of `remote_orchestrator`.
////
//// The plane answers the eight evolution messages from a `Script` of plain
//// values and reports every request it was asked to a `Subject(Seen)`, in the
//// order the host handed them over. A test reads that subject to learn what
//// reached the executor and with which coordinates, so it can assert that a
//// refusal sent nothing and that a promoted tool's call sent exactly one
//// `EvolutionRun`.
////
//// The host owns admission, so a keyed call (`evaluate`, `run`) is reported once
//// however often the orchestrator sends it. The plane itself holds no state: a
//// test that needs an answer to depend on an earlier request scripts a function
//// of the request.

import client/evolution/evaluate
import client/evolution/record
import client/executor_evolution
import client/extension/archive
import client/extension/hooks
import client/remote/host
import client/remote/protocol.{type Handle}
import core/json.{type JsonValue}
import core/message
import core/msgpack.{type MsgPackValue}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import runtime/effects
import tools/tool

/// One request the scripted plane was asked, with the fields a test reads.
pub type Seen {
  Snapshot(coordinates: protocol.Coordinates, directory: String)
  Evaluate(coordinates: protocol.Coordinates, candidate: record.Candidate)
  Run(
    coordinates: protocol.Coordinates,
    target: protocol.Target,
    args: JsonValue,
  )
  Stage(selection: record.Selection, candidate: record.Candidate)
  Hook(handle: Handle, event: String, within_ms: Int)
  Transition(step: protocol.TransitionStep)
  Retire(handle: Handle)
  Inventory(handle: Handle)
}

/// What the plane answers.
pub type Script {
  Script(
    /// The reply to every stage.
    staged: protocol.Staged,
    /// The reply to a retire of the handle, or `None` to leave it unanswered.
    retire: fn(Handle) -> Option(protocol.CloseOutcome),
    /// The reply to each step of an upgrade.
    transition: fn(protocol.TransitionStep) ->
      Result(protocol.TransitionAnswer, protocol.Refusal),
    /// The reply to a hook.
    hook: Result(MsgPackValue, hooks.HookFailure),
    /// The value an evaluation stores as its report.
    report: JsonValue,
    /// The outcome of a promoted tool or a program run.
    outcome: effects.ToolOutcome,
  )
}

/// A script that stages `staged`, retires everything, publishes every
/// transition, declines every hook and passes every check.
pub fn script(staged: protocol.Staged) -> Script {
  Script(
    staged:,
    retire: fn(_handle) { Some(protocol.AllRetired) },
    transition: fn(_step) { Ok(protocol.TransitionPublished) },
    hook: Ok(msgpack.NilValue),
    report: executor_evolution.report_json(
      Ok(evaluate.Report(record.Passed, "{}")),
    ),
    outcome: echoed(),
  )
}

/// The outcome a successful promoted tool completes with.
pub fn echoed() -> effects.ToolOutcome {
  effects.ToolCompleted(
    result: message.ToolResultMessage(
      tool_call_id: "call",
      tool_name: "echo",
      content: [message.ToolResultText(text: "echoed", text_signature: None)],
      details: None,
      usage: None,
      added_tool_names: None,
      is_error: False,
      timestamp: 0,
    ),
    terminate: False,
  )
}

/// A generation handle with `ordinal`, from one boot.
pub fn handle(ordinal: Int) -> Handle {
  protocol.Handle(boot: <<7:size(128)>>, ordinal:)
}

/// A staged answer for a replacement-only extension called `name`.
pub fn staged(
  handle: Handle,
  name: String,
  tools: List(tool.Described),
) -> protocol.Staged {
  protocol.Staged(
    handle:,
    name:,
    tools:,
    hooks: ["tool_call"],
    activation: protocol.Replacement,
    superseded: [],
  )
}

/// The plane the host calls, answering from `script` and reporting to `seen`.
pub fn plane(script: Script, seen: Subject(Seen)) -> host.Evolution {
  host.Evolution(
    evaluate: fn(coordinates, candidate) {
      process.send(seen, Evaluate(coordinates, candidate))
      script.report
    },
    run: fn(coordinates, target, args) {
      process.send(seen, Run(coordinates, target, args))
      script.outcome
    },
    serve: fn(request) { serve(script, seen, request) },
  )
}

fn serve(
  script: Script,
  seen: Subject(Seen),
  request: protocol.EvolutionRequest,
) -> Nil {
  case request {
    protocol.SnapshotRequest(coordinates:, directory:, reply:) -> {
      process.send(seen, Snapshot(coordinates, directory))
      process.send(
        reply,
        Ok(archive.Tree(root: directory, files: [], commit: None)),
      )
    }

    protocol.StageRequest(selection:, candidate:, reply:) -> {
      process.send(seen, Stage(selection, candidate))
      process.send(reply, Ok(script.staged))
    }

    protocol.HookRequest(handle:, event:, within_ms:, reply:, ..) -> {
      process.send(seen, Hook(handle, event, within_ms))
      process.send(reply, script.hook)
    }

    protocol.TransitionRequest(step:, reply:) -> {
      process.send(seen, Transition(step))
      process.send(reply, script.transition(step))
    }

    protocol.RetireRequest(handle:, reply:) -> {
      process.send(seen, Retire(handle))

      // A retire the script leaves unanswered is a host that never replied.
      case script.retire(handle) {
        Some(outcome) -> process.send(reply, Ok(outcome))
        None -> Nil
      }
    }

    protocol.InventoryRequest(handle:, reply:) -> {
      process.send(seen, Inventory(handle))
      process.send(reply, Ok(json.Object([#("capacity", json.Int(2))])))
    }
  }
}
