//// `client/hookserve` — loads the imported hook sources a session
//// serves, and composes the compatibility gates into the session's
//// `Effects`.
////
//// # The load, and what trust means here
////
//// Four sources merge, in the precedence the design note fixes:
//// the operator's `~/.claude/settings.json`, the workspace's
//// `.claude/settings.json`, its gitignored `.claude/settings.local.json`,
//// and the `[hooks]` tables of Loom's own `loom.toml`. Merging is
//// concatenation — no layer replaces another's hooks — and each
//// source is trust-checked on its own, against the record
//// `client/hooktrust` keeps: a source whose current hash is not the
//// trusted one is **skipped with a logged line**, not a boot failure
//// and not a silent pass. The operator's own user-level file is the
//// one source trusted by default the first time it is seen, the same
//// trust an operator's `loom.toml` carries; a *project* file arrives
//// with the repository and so asks first.
////
//// # What is composed, and what is not
////
//// The composed gates are the ones whose harness moments exist: the
//// `PreToolUse` permission at the tool clearance, the `PostToolUse`
//// feedback at the result fold, the `PreCompact` note at the
//// compaction boundary, the `Stop` continuation at the run-end
//// boundary, and the `SessionStart` context at run start. Events
//// with no moment (`Notification`, `PermissionRequest`, …) load and
//// match and then find no gate to sit in: their rows in the parity
//// matrix carry that honestly, and this module says so once at boot
//// through the load notes rather than pretending a wiring that does
//// not exist.
////
//// This module is the composer, not the executor: each gate runs its
//// matching handlers through `client/hookwire.ask` over the runner
//// context the session already owns, and applies the combined
//// decision through the same `Effects` slots the native extension
//// bus uses — which is what keeps one authority story: a compat
//// hook's `allow` lands after the harness's own clearance, exactly
//// where the native `tool_call` hook's does.

import client/hookcompat
import client/hookdecisions
import client/hookrunner
import client/hooktrust
import client/hookwire
import core/clock.{type Clock}
import core/ids
import core/json.{type JsonValue}
import core/message.{type AgentMessage}
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import runtime/effects.{type Effects}
import simplifile
import weft/actor

/// One discovered source file, before parsing: where it is and which
/// precedence class it belongs to.
pub type Located {
  Located(
    /// The path as discovered, reported in diagnostics verbatim.
    path: String,
    /// Whether the parse is the Claude JSON shape or Loom's TOML.
    shape: Shape,
    /// The precedence class, which is also the trust posture.
    origin: hookcompat.Origin,
  )
}

/// Which parser a located file feeds.
pub type Shape {
  /// A Claude settings file or a plugin's `hooks/hooks.json`.
  ClaudeJson

  /// Loom's `loom.toml` with its `[hooks]` tables.
  LoomToml
}

/// Everything the session needs to serve imported hooks, or nothing
/// when no source yielded a trusted entry.
pub type Serving {
  Serving(
    /// The merged, trust-checked configuration.
    config: hookcompat.Config,
    /// The identity facts every payload's common fields carry.
    wiring: hookwire.Wiring,
    /// The runner context the gates execute hooks under.
    runner: hookrunner.Context,
    /// How many sources were skipped for trust, for the boot log.
    skipped: List(String),
  )
}

/// The default file locations for a session: the operator's home and
/// the workspace, in merge order. The home is the daemon home this
/// server was configured with, which is where Claude itself would
/// look on this machine; the workspace files are relative to the
/// session workspace the way a repo commits them.
pub fn locations(home: Option(String), workspace: String) -> List(Located) {
  [
    case home {
      Some(home) ->
        Located(
          home <> "/.claude/settings.json",
          ClaudeJson,
          hookcompat.UserSettings,
        )
      None -> Located("", ClaudeJson, hookcompat.UserSettings)
    },
    Located(
      workspace <> "/.claude/settings.json",
      ClaudeJson,
      hookcompat.ProjectSettings,
    ),
    Located(
      workspace <> "/.claude/settings.local.json",
      ClaudeJson,
      hookcompat.LocalSettings,
    ),
  ]
  |> list.filter(fn(located) { located.path != "" })
}

/// Loads, parses, trust-checks, and merges every located source.
///
/// A source that does not exist is not an event: absent files are how
/// an operator says "no hooks here", and a missing file was never a
/// trust decision to revisit. A file that exists but will not parse
/// is a boot log line naming the path and the parse error, skipped
/// without touching the others — one broken source cannot take the
/// session's hooks down with it.
pub fn load(
  located: List(Located),
  trust_root: Option(String),
  wiring: hookwire.Wiring,
  runner: hookrunner.Context,
) -> Serving {
  // Reading, parsing, and trust are one step per file because a file
  // nobody trusts is a file whose parse errors the operator cannot
  // act on yet anyway — the trust prompt is what surfaces them next.
  // A source that does not exist is not an event: absent files are
  // how an operator says "no hooks here", and one broken source
  // cannot take the session's hooks down with it.
  let #(configs, skipped) =
    list.fold(located, #([], []), fn(state, one) {
      let #(configs, skipped) = state
      case read(one, trust_root) {
        Ok(#(config, _located)) -> #([config, ..configs], skipped)
        Error(_located) -> #(configs, [one, ..skipped])
      }
    })
  let merged = hookcompat.merge(list.reverse(configs))
  Serving(
    config: merged,
    wiring:,
    runner:,
    skipped: list.map(list.reverse(skipped), fn(one) { one.path }),
  )
}

// One located file as a trusted config, or the word that it was
// skipped. Reading, parsing, and trust are one step because a file
// nobody trusts is a file whose parse errors the operator cannot act
// on yet anyway — the trust prompt is what surfaces them next.
fn read(
  located: Located,
  trust_root: Option(String),
) -> Result(#(hookcompat.Config, Located), Located) {
  use text <- result.try(
    simplifile.read(located.path)
    |> result.replace_error(located),
  )
  let source = hookcompat.Source(label: located.path, origin: located.origin)
  let parsed = case located.shape {
    ClaudeJson -> hookcompat.parse_claude(text, source)
    LoomToml -> hookcompat.parse_loom(text, source)
  }
  use config <- result.try(parsed |> result.replace_error(located))
  case trusted(trust_root, located, config) {
    hooktrust.Trusted -> Ok(#(config, located))
    hooktrust.NeedsReview -> Error(located)
  }
}

// Whether this source's current definition is the trusted one. A
// first-seen user-level source is trusted on sight: it is the
// operator's own file on the operator's own machine, the same trust
// `~/.claude/settings.json` carries in Claude itself. A project file
// is code the repository brought, and so asks before it runs.
fn trusted(
  trust_root: Option(String),
  located: Located,
  config: hookcompat.Config,
) -> hooktrust.Verdict {
  case trust_root {
    None -> hooktrust.Trusted
    Some(root) -> {
      let path = hooktrust.record_path(root, located.path)
      let record = hooktrust.load(path) |> option.from_result
      case hooktrust.check(record, config) {
        hooktrust.Trusted -> hooktrust.Trusted
        hooktrust.NeedsReview ->
          case located.origin {
            hookcompat.UserSettings -> hooktrust.Trusted
            _ -> hooktrust.NeedsReview
          }
      }
    }
  }
}

// --- the gates ---------------------------------------------------------------

/// Whether any trusted, matching handler exists for one occurrence.
/// The gates call this before they spend a process: an event with no
/// matching handler is not an event at all, and a gate that ran an
/// empty fan-out would add a process spawn's latency to every tool
/// call for nothing.
pub fn has_matching(
  serving: Serving,
  event: hookcompat.Event,
  field: String,
) -> Bool {
  case hookwire.matching_handlers(serving.wiring, event, field) {
    [] -> False
    [_, ..] -> True
  }
}

/// The `PreToolUse` gate: asks every matching handler, combines the
/// verdicts, and answers as the clearance's contribution. `Proceed`
/// is the caller's signal to clear exactly as the harness already
/// decided; `Deny` carries the reason the model reads; `Ask` rides
/// the harness's own escalation; `Rewrite` replaces the arguments —
/// but only after the harness's own clearance, so a hook's rewrite
/// of a call the harness would refuse is a rewrite of nothing.
pub fn tool_gate(
  serving: Serving,
  tool: String,
  call_id: String,
  arguments: JsonValue,
) -> hookdecisions.ToolPermission {
  let matched =
    hookwire.matching_handlers(
      serving.wiring,
      hookcompat.PreToolUse,
      hookwire.claude_tool_name(tool),
    )
  let payload =
    hookwire.common_payload(
      serving.wiring,
      hookcompat.PreToolUse,
      hookwire.tool_fields(tool, arguments, call_id),
    )
  matched
  |> list.filter_map(fn(pair) {
    let #(_description, handler) = pair
    use outcome <- result.try(hookwire.ask(
      serving.runner,
      hookcompat.PreToolUse,
      handler,
      payload,
    ))
    Ok(hookdecisions.tool_permission(
      outcome.code,
      outcome.stderr,
      outcome.stdout,
      outcome.timed_out,
    ))
  })
  |> hookwire.combine_permissions
}

/// The `Stop` continuation: asks every matching handler whether the
/// run may finish. `Finish` is the caller's signal to finish as the
/// harness was about to; `Continue(reason)` is the born-placed
/// follow-up the run-end slot already commits, which is what makes a
/// compat stop gate durable under the harness's replay rules rather
/// than a second completion path bolted beside the machine's.
pub fn stop_gate(serving: Serving) -> hookdecisions.Continuation {
  let matched = hookwire.matching_handlers(serving.wiring, hookcompat.Stop, "")
  let payload = hookwire.common_payload(serving.wiring, hookcompat.Stop, [])
  matched
  |> list.filter_map(fn(pair) {
    let #(_description, handler) = pair
    use outcome <- result.try(hookwire.ask(
      serving.runner,
      hookcompat.Stop,
      handler,
      payload,
    ))
    Ok(hookdecisions.continuation(
      outcome.code,
      outcome.stderr,
      outcome.stdout,
      outcome.timed_out,
    ))
  })
  |> hookwire.combine_continuations
}

/// The `SessionStart` context: plain stdout and `additionalContext`
/// alike become the run-start injection, fenced and attributed by the
/// harness the way a native `before_agent_start` injection is.
pub fn session_context(
  serving: Serving,
  source: String,
) -> hookdecisions.ContextInjection {
  let matched =
    hookwire.matching_handlers(serving.wiring, hookcompat.SessionStart, source)
  let payload =
    hookwire.common_payload(serving.wiring, hookcompat.SessionStart, [
      #("source", json.String(source)),
    ])
  matched
  |> list.filter_map(fn(pair) {
    let #(_description, handler) = pair
    use outcome <- result.try(hookwire.ask(
      serving.runner,
      hookcompat.SessionStart,
      handler,
      payload,
    ))
    Ok(hookdecisions.context_injection(
      "SessionStart",
      False,
      outcome.code,
      outcome.stderr,
      outcome.stdout,
      outcome.timed_out,
    ))
  })
  |> hookwire.combine_injections
}

/// The `PostToolUse` feedback for one settled call.
pub fn tool_feedback(
  serving: Serving,
  tool: String,
  call_id: String,
  arguments: JsonValue,
) -> hookwire.Feedback {
  let matched =
    hookwire.matching_handlers(
      serving.wiring,
      hookcompat.PostToolUse,
      hookwire.claude_tool_name(tool),
    )
  let payload =
    hookwire.common_payload(
      serving.wiring,
      hookcompat.PostToolUse,
      hookwire.tool_fields(tool, arguments, call_id),
    )
  matched
  |> list.filter_map(fn(pair) {
    let #(_description, handler) = pair
    use outcome <- result.try(hookwire.ask(
      serving.runner,
      hookcompat.PostToolUse,
      handler,
      payload,
    ))
    Ok(hookdecisions.tool_feedback(
      outcome.code,
      outcome.stderr,
      outcome.stdout,
      outcome.timed_out,
    ))
  })
  |> hookwire.combine_feedback
}

/// The `PreCompact` note for one compaction, by its trigger's
/// Claude-side name.
pub fn compaction_note(serving: Serving, trigger: String) -> Option(String) {
  let matched =
    hookwire.matching_handlers(serving.wiring, hookcompat.PreCompact, trigger)
  let payload =
    hookwire.common_payload(serving.wiring, hookcompat.PreCompact, [
      #("trigger", json.String(trigger)),
    ])
  let notes =
    matched
    |> list.filter_map(fn(pair) {
      let #(_description, handler) = pair
      use outcome <- result.try(hookwire.ask(
        serving.runner,
        hookcompat.PreCompact,
        handler,
        payload,
      ))
      Ok(hookdecisions.context_injection(
        "PreCompact",
        False,
        outcome.code,
        outcome.stderr,
        outcome.stdout,
        outcome.timed_out,
      ))
    })
  case hookwire.combine_injections(notes) {
    hookdecisions.Injected(text) -> Some(text)
    hookdecisions.NoContext | hookdecisions.Blocked(_) -> None
  }
}

// --- the composition ---------------------------------------------------------

/// The consecutive-continuation cap, the contract's own override of a
/// Stop hook that keeps blocking on a condition that will never
/// resolve: after this many follow-ups placed by the gate for one
/// operation, the gate stops asking and the run finishes.
pub const stop_block_cap = 8

/// Composes the imported gates into one session's `Effects`, wrapping
/// rather than replacing — the same discipline the native extension
/// bus's `wire` holds, so the two layers coexist: a native `[[hook]]`
/// and an imported `Stop` hook both sit at the run-end boundary, and
/// either's follow-up is placed through the same born-placed slot.
///
/// The continuation counter is one small actor rather than a field
/// because the `run_end` slot is a plain function the driver calls from
/// its own process: the only state a plain function can keep is state
/// somebody else owns, and an actor keyed on the operation is the house
/// shape for that (`weft/actor`, per the mapping in `docs/weft.md`).
///
/// ## Examples
///
/// ```gleam
/// // let composed = hookserve.wire(effects, serving, logger)
/// ```
///
pub fn wire(
  effects: Effects,
  serving: Serving,
  clock: Clock,
) -> Result(Effects, String) {
  let counters =
    actor.new(dict.new())
    |> actor.on_message(fn(counters, message) {
      case message {
        Tally(operation, reply) -> {
          let count = dict.get(counters, operation) |> result.unwrap(0)
          process.send(reply, count)
          actor.continue(dict.insert(counters, operation, count + 1))
        }
      }
    })
    |> actor.start
    |> result.map(fn(started) { started.data })
  use counters <- result.try(
    counters
    |> result.map_error(fn(_reason) {
      "the stop-gate counter would not start; imported Stop hooks are off"
    }),
  )
  let built = effects.hooks
  let tools = effects.tools
  Ok(
    effects.Effects(
      ..effects,
      hooks: effects.Hooks(
        ..built,
        run_start: fn(operation) {
          list.append(
            built.run_start(operation),
            started_context(serving, clock),
          )
        },
        run_end: fn(operation) {
          // A notification beside the existing slot, never instead of it,
          // and the continuation gate asked only when the harness itself
          // had no follow-up to place: a harness follow-up and a hook
          // continuation are the same slot, and the harness's own wins.
          let follow_up = built.run_end(operation)
          case
            follow_up,
            stop_block(ids.op_id_to_string(operation), serving, counters)
          {
            Some(_harness), _ -> follow_up
            None, hookdecisions.Continue(reason) ->
              Some(continuation_message(reason, clock))
            None, hookdecisions.Finish -> None
          }
        },
        compaction_note: fn(operation, cue) {
          list.append(
            built.compaction_note(operation, cue),
            case hookserve_compaction_note(serving, cue) {
              Some(note) -> [note]
              None -> []
            },
          )
        },
      ),
      tools: effects.ToolSurface(
        ..tools,
        clear: fn(query) { cleared(serving, tools.clear(query), query) },
        run: fn(run) { ran(serving, tools.run(run), run) },
      ),
    ),
  )
}

// One question to the continuation counter: how many follow-ups
// has the gate placed for this operation so far, incrementing as it
// answers. A `call` rather than a cast because the run-end slot is
// about to decide on the answer, and a decision on a count it has
// not read is not a decision.
type CounterMessage {
  Tally(operation: String, reply: Subject(Int))
}

// The Stop gate with the cap applied: the count is read (and
// incremented) first, so a gate that has already placed the cap's
// worth of continuations stops asking and lets the run finish — the
// contract's own override, expressed as the harness's bound rather
// than a new one.
fn stop_block(
  operation: String,
  serving: Serving,
  counters: Subject(CounterMessage),
) -> hookdecisions.Continuation {
  let placed =
    actor.call(counters, waiting: 1000, sending: fn(reply) {
      Tally(operation, reply)
    })
  case placed >= stop_block_cap {
    True -> hookdecisions.Finish
    False -> stop_gate(serving)
  }
}

// The follow-up message the gate places when a Stop hook continues:
// a user message carrying the hook's reason, attributed in its text
// the way the contract's continuation prompt is — the hook said it,
// and the model reading it should know that.
fn continuation_message(reason: String, clock: Clock) -> AgentMessage {
  let #(now, _clock) = clock.read(clock)
  message.UserMessage(
    content: [
      message.UserText(
        // The attribution is the contract's own shape: the
        // continuation prompt is the hook's reason, and the model
        // reading it should know a hook said it rather than the
        // operator.
        text: "[Stop hook] " <> reason,
        text_signature: None,
      ),
    ],
    timestamp: now,
    origin: None,
  )
}

// The SessionStart injection as one run-start message: fired once
// per composed Effects, at the first run start, in the shape the
// native bus renders its own injections in so both kinds of hook
// read identically in the transcript.
fn started_context(serving: Serving, clock: Clock) -> List(AgentMessage) {
  case session_context(serving, "startup") {
    hookdecisions.Injected(text) -> [continuation_message(text, clock)]
    hookdecisions.NoContext | hookdecisions.Blocked(_) -> []
  }
}

// The PreCompact note for one cue, in the cue's own trigger names.
fn hookserve_compaction_note(
  serving: Serving,
  cue: effects.CompactionCue,
) -> Option(String) {
  compaction_note(serving, trigger_of(cue.cause))
}

fn trigger_of(cause: effects.CompactionCause) -> String {
  case cause {
    effects.RequestedCompaction -> "manual"
    effects.ThresholdCompaction | effects.OverflowCompaction -> "auto"
  }
}

// The PreToolUse gate applied to a clearance the harness already
// granted — the same ordering the native bus's `cleared` holds: a
// refusal passes through untouched, and only a cleared call is ever
// asked about, because asking about a call that will not run wakes
// a satellite for nothing and invites a second, contradictory
// reason.
fn cleared(
  serving: Serving,
  clearance: effects.Clearance,
  query: effects.ClearanceQuery,
) -> effects.Clearance {
  case clearance {
    effects.ClearanceRefused(..) -> clearance
    effects.Cleared(effective_arguments: _, replay:) -> {
      let verdict =
        tool_gate(serving, query.call.name, query.call.id, query.call.arguments)
      case verdict {
        hookdecisions.Proceed -> clearance
        hookdecisions.Deny(reason) ->
          effects.ClearanceRefused(
            reason: "a PreToolUse hook blocked "
            <> query.call.name
            <> ": "
            <> reason,
          )
        hookdecisions.Ask(reason) ->
          // `ask` cannot escalate from inside a clearance the harness
          // already granted; the honest degradation is to refuse with
          // the reason, and the parity matrix says so.
          effects.ClearanceRefused(
            reason: "a PreToolUse hook asks for confirmation on "
            <> query.call.name
            <> ": "
            <> reason,
          )
        hookdecisions.Rewrite(updated) ->
          effects.Cleared(effective_arguments: updated, replay:)
      }
    }
  }
}

// The PostToolUse feedback folded over a settled result: the
// replacement narrows to the content the model reads, the same rule
// the native `tool_result` fold holds, and feedback and context ride
// beside the original in one attributed text rather than three
// fields.
fn ran(
  serving: Serving,
  outcome: effects.ToolOutcome,
  run: effects.ToolRun,
) -> effects.ToolOutcome {
  case outcome {
    effects.ToolFailed(..) -> outcome
    effects.ToolCompleted(result:, terminate:) -> {
      let feedback =
        tool_feedback(serving, run.call.name, run.call.id, run.arguments)
      case feedback.replacement, feedback.context, feedback.reason {
        None, None, None -> outcome
        _, _, _ ->
          effects.ToolCompleted(result: retexted(result, feedback), terminate:)
      }
    }
  }
}

// A settled result with the hook feedback applied.
//
// A full `updatedToolOutput` replacement substitutes the content the
// model reads: the hook's JSON is rendered as the result's one text
// block, which is the honest narrowing — the contract's own warning
// that a replacement must match the tool's output shape is a shape
// the model reads, and a text rendering is the shape every tool
// result carries here. Feedback and context ride after it as one
// attributed block: a tool result the hook annotated is one result,
// and the attribution stays in the text the model reads.
fn retexted(result: AgentMessage, feedback: hookwire.Feedback) -> AgentMessage {
  case result {
    message.ToolResultMessage(..) as original ->
      message.ToolResultMessage(
        ..original,
        content: annotated(original.content, feedback),
      )
    _ -> result
  }
}

// The content of one settled result after the hook's say-so: the
// replacement when the hook made one, else the original, then the
// note the hook attached — or nothing at all when the hook had
// neither, which is the common case and the one that costs nothing.
fn annotated(
  original: List(message.ToolResultBlock),
  feedback: hookwire.Feedback,
) -> List(message.ToolResultBlock) {
  let replaced = case feedback.replacement {
    Some(replacement) -> [
      message.ToolResultText(
        text: json.to_string(replacement),
        text_signature: None,
      ),
    ]
    None -> original
  }
  let note = case feedback.reason, feedback.context {
    None, None -> ""
    Some(reason), None -> reason
    None, Some(context) -> context
    Some(reason), Some(context) -> reason <> "\n\n" <> context
  }
  case note {
    "" -> replaced
    _ ->
      list.append(replaced, [
        message.ToolResultText(
          text: "[PostToolUse hook] " <> note,
          text_signature: None,
        ),
      ])
  }
}
