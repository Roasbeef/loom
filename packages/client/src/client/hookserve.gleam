//// `client/hookserve` — loads the imported hook sources a session
//// serves, and composes the compatibility gates into the session's
//// `Effects`.
////
//// # The load, and what trust means here
////
//// Three sources merge, in the precedence the design note fixes: the
//// operator's `~/.claude/settings.json`, the workspace's
//// `.claude/settings.json`, and its gitignored
//// `.claude/settings.local.json`. The design note names a fourth —
//// the `[hooks]` tables of Loom's own `loom.toml` — and `Shape`
//// carries the parser for it, but `locations` does not emit one yet,
//// so nothing in a session reads the Loom shape today.
////
//// Merging is concatenation — no layer replaces another's hooks — and
//// each source is trust-checked on its own, against the record
//// `client/hooktrust` keeps: a source whose current hash is not the
//// trusted one is **skipped with a logged line**, not a boot failure
//// and not a silent pass. The operator's own user-level file is the
//// one source trusted by default the *first* time it is seen, the
//// same trust it carries in Claude; a project file arrives with the
//// repository and so asks first, and a user-level file whose hooks
//// changed since the record was written asks again like any other.
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
//// where the native `tool_call` hook's does, and can only narrow it.
//// A hook that rewrites the arguments does not escape that, because
//// the rewritten call is put back through the harness's clearance
//// and the narrower of the two verdicts is the one that stands: the
//// arguments upstream approved and the arguments that run are the
//// same arguments.

import client/hookcompat
import client/hookdecisions
import client/hookrunner
import client/hooktrust
import client/hookwire
import core/clock.{type Clock}
import core/ids.{type OpId}
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

/// Which parser a located file feeds. The distinction between the two
/// Claude shapes is the caller's to make and not the parser's: a
/// settings file that declares no hooks and a bare hooks object that
/// declares no events are the same bytes, and guessing between them
/// from an absent `hooks` key read `permissions` as an event name and
/// refused the ordinary user settings file.
pub type Shape {
  /// A Claude settings file: hooks live under its `hooks` key, beside
  /// `permissions`, `model` and everything else Claude reads there.
  ClaudeSettings

  /// A bare hooks object — a plugin's `hooks/hooks.json`, whose whole
  /// document is the event map.
  ClaudeHooks

  /// Loom's `loom.toml` with its `[hooks]` tables.
  LoomToml
}

/// Everything the session needs to serve imported hooks, or nothing
/// when no source yielded a trusted entry.
///
/// The merged configuration lives in `wiring` and nowhere else. It was
/// briefly a field here as well, and the two diverged the moment the
/// caller's wiring was passed through unchanged: every gate reads
/// `wiring.config`, so a second copy is a second answer to the one
/// question that decides whether any hook fires at all.
pub type Serving {
  Serving(
    /// The identity facts every payload's common fields carry, over
    /// the merged, trust-checked configuration.
    wiring: hookwire.Wiring,
    /// The runner context the gates execute hooks under.
    runner: hookrunner.Context,
    /// The sources that contributed nothing, with the reason each
    /// one did not, for the boot log.
    skipped: List(Skipped),
    /// The load-time findings of every source that did contribute:
    /// handler kinds this build parses but does not run, `once`
    /// declarations it ignores, and events with no moment to fire on.
    notes: List(hookcompat.LoadNote),
  )
}

/// One located source that contributed no hooks, and why.
///
/// The reason is carried rather than flattened because the three ways
/// a source contributes nothing are three different things for an
/// operator to do about it: a file that will not parse names the event
/// or field it refused on, and a file whose definition is not the
/// trusted one names the record it does not match.
pub type Skipped {
  Skipped(
    /// The path as discovered, reported verbatim.
    path: String,
    /// The sentence the boot log carries.
    reason: String,
  )
}

/// The default file locations for a session: the operator's home and
/// the workspace, in merge order. The home is the operator's own
/// `HOME` as this server read it (`Settings.home`), which is where
/// Claude itself would look on this machine; the workspace files are
/// relative to the session workspace the way a repo commits them.
pub fn locations(home: Option(String), workspace: String) -> List(Located) {
  [
    case home {
      Some(home) ->
        Located(
          home <> "/.claude/settings.json",
          ClaudeSettings,
          hookcompat.UserSettings,
        )
      None -> Located("", ClaudeSettings, hookcompat.UserSettings)
    },
    Located(
      workspace <> "/.claude/settings.json",
      ClaudeSettings,
      hookcompat.ProjectSettings,
    ),
    Located(
      workspace <> "/.claude/settings.local.json",
      ClaudeSettings,
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
  let #(configs, skipped, notes) =
    list.fold(located, #([], [], []), fn(state, one) {
      let #(configs, skipped, notes) = state
      case read(one, trust_root) {
        // A file that is not there is not a diagnostic. Every session
        // whose operator keeps no `~/.claude` would otherwise open
        // with a warning about a decision nobody made.
        Absent -> state

        Loaded(config:, notes: found) -> #([config, ..configs], skipped, [
          found,
          ..notes
        ])

        Refused(reason:) -> #(
          configs,
          [Skipped(path: one.path, reason:), ..skipped],
          notes,
        )
      }
    })
  let merged = hookcompat.merge(list.reverse(configs))
  Serving(
    wiring: hookwire.Wiring(..wiring, config: merged),
    runner:,
    skipped: list.reverse(skipped),
    notes: list.flatten(list.reverse(notes)),
  )
}

// What one located file contributed. The three answers are three
// different facts and the loader reports them differently: a file that
// is not there was never a decision, a file that parsed is hooks —
// possibly none of them — and a file that refused or is untrusted is a
// line an operator has to be able to act on, which means carrying the
// reason rather than flattening all three into "skipped".
type Reading {
  Absent
  Loaded(config: hookcompat.Config, notes: List(hookcompat.LoadNote))
  Refused(reason: String)
}

// One located file read, parsed, and trust-checked.
fn read(located: Located, trust_root: Option(String)) -> Reading {
  case simplifile.read(located.path) {
    Ok(text) -> parsed(located, trust_root, text)
    Error(simplifile.Enoent) -> Absent
    Error(other) ->
      Refused(
        "the file could not be read: " <> simplifile.describe_error(other),
      )
  }
}

// The text as this shape's parser reads it. Which parser is the
// caller's decision, recorded in `Located.shape` when the file was
// located, because only whoever knows where a file came from knows
// whether its whole document is the hooks object.
fn parsed(
  located: Located,
  trust_root: Option(String),
  text: String,
) -> Reading {
  let source = hookcompat.Source(label: located.path, origin: located.origin)
  let outcome = case located.shape {
    ClaudeSettings -> hookcompat.parse_claude_settings(text, source)
    ClaudeHooks -> hookcompat.parse_claude(text, source)
    LoomToml -> hookcompat.parse_loom(text, source)
  }
  case outcome {
    Ok(config) -> checked(located, trust_root, config)
    Error(reason) -> Refused(reason)
  }
}

// A parsed configuration the operator's trust record admits, or the
// sentence saying why it does not.
fn checked(
  located: Located,
  trust_root: Option(String),
  config: hookcompat.Config,
) -> Reading {
  case trusted(trust_root, located, config) {
    Ok(Nil) -> Loaded(config:, notes: hookcompat.notes(config))
    Error(reason) -> Refused(reason)
  }
}

// Whether this source's current definition is one the operator has
// admitted, and the sentence for the boot log when it is not.
fn trusted(
  trust_root: Option(String),
  located: Located,
  config: hookcompat.Config,
) -> Result(Nil, String) {
  case located.origin {
    // Hooks declared in Loom's own configuration are not imported
    // code. The operator wrote that file or pointed this server at it,
    // so there is no second party whose yes the record would stand
    // for.
    hookcompat.LoomInline -> Ok(Nil)

    hookcompat.UserSettings
    | hookcompat.ProjectSettings
    | hookcompat.LocalSettings
    | hookcompat.Plugin(_) -> imported(trust_root, located, config)
  }
}

// An imported source against the record directory, when there is one.
//
// With no home there is nowhere a yes could have been written, and so
// nowhere one could have been read: a trust decision that fails open
// on a missing directory fails in the direction that runs a
// repository's scripts on a daemon started under a stripped
// environment.
fn imported(
  trust_root: Option(String),
  located: Located,
  config: hookcompat.Config,
) -> Result(Nil, String) {
  case trust_root {
    Some(root) -> against_the_record(root, located, config)
    None ->
      Error(
        "this server has no home directory to keep a trust record in, so "
        <> "no imported hook source runs",
      )
  }
}

// The record for one source, and what it decides.
//
// The two cases the previous reading collapsed are the whole of the
// pin: *no record* is a source seen for the first time, and a record
// whose hash does not match is a file that changed after it was
// trusted. Only the first can be waived by origin. Waiving the second
// meant a user-level file re-entered no review it had ever left, which
// is the property the module doc and the parity matrix both claim.
fn against_the_record(
  root: String,
  located: Located,
  config: hookcompat.Config,
) -> Result(Nil, String) {
  let path = hooktrust.record_path(root, located.path)
  case hooktrust.load(path) |> option.from_result {
    None -> first_sight(located.origin, path)

    Some(record) ->
      case hooktrust.check(Some(record), config) {
        hooktrust.Trusted -> Ok(Nil)
        hooktrust.NeedsReview ->
          Error(
            "its hooks changed since they were trusted; the record at "
            <> path
            <> " is for an earlier version of this file",
          )
      }
  }
}

// A source with no record yet. The operator's own user-level file is
// trusted on sight — it is their file on their machine, the trust
// `~/.claude/settings.json` carries in Claude itself — and every other
// imported source arrived with a repository or a plugin and asks
// first.
fn first_sight(origin: hookcompat.Origin, path: String) -> Result(Nil, String) {
  case origin {
    hookcompat.UserSettings | hookcompat.LoomInline -> Ok(Nil)

    hookcompat.ProjectSettings
    | hookcompat.LocalSettings
    | hookcompat.Plugin(_) ->
      Error(
        "it has no trust record at "
        <> path
        <> "; a source the repository or a plugin brought runs only once one "
        <> "is recorded there, and the command that records it is follow-up "
        <> "work",
      )
  }
}

// --- the gates ---------------------------------------------------------------

/// Whether any trusted, matching handler exists for one occurrence.
///
/// The gates do not need this — their fan-out over an empty match list
/// already spawns nothing — so it is the loader's question rather than
/// the gate's: whether what this session loaded would answer at all
/// for a given event and field. That is the assertion a boot check or
/// a test makes, and the one whose absence let a `Serving` ship whose
/// every gate matched nothing.
///
/// ## Examples
///
/// ```gleam
/// // assert hookserve.has_matching(serving, hookcompat.PreToolUse, "Bash")
/// ```
///
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
/// of a call the harness would refuse is a rewrite of nothing, and
/// the replacement itself is cleared before it runs (`recleared`).
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
      outcome.ending,
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
      outcome.ending,
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
      hookdecisions.CannotBlock,
      outcome.code,
      outcome.stderr,
      outcome.stdout,
      outcome.ending,
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
      outcome.ending,
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
        hookdecisions.CannotBlock,
        outcome.code,
        outcome.stderr,
        outcome.stdout,
        outcome.ending,
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
/// `stops` says whether an operation's run end is one the imported `Stop`
/// hooks were written for. In Claude a `Stop` hook fires when the main
/// agent finishes responding and `SubagentStop` when a subagent does;
/// Loom runs more than one strand under a session, the advisor among
/// them, and a `Stop` hook asked at every strand's run end steered the
/// advisor with instructions meant for the primary. The caller answers
/// from the operation's strand; `SubagentStop` is not composed yet.
///
/// ## Examples
///
/// ```gleam
/// // let composed = hookserve.wire(effects, serving, clock, fn(_) { True })
/// ```
///
pub fn wire(
  effects: Effects,
  serving: Serving,
  clock: Clock,
  stops: fn(OpId) -> Bool,
) -> Result(Effects, String) {
  let counters =
    actor.new(Counters(placed: dict.new(), started: FirstRun))
    |> actor.on_message(fn(counters, message) {
      case message {
        Tally(operation, reply) -> {
          let count = dict.get(counters.placed, operation) |> result.unwrap(0)
          process.send(reply, count)
          actor.continue(
            Counters(
              ..counters,
              placed: dict.insert(counters.placed, operation, count + 1),
            ),
          )
        }

        // The first run start of this composed `Effects` is the
        // session's own start, and every later one is a turn. The flag
        // flips as it is read, so two run starts racing on separate
        // driver processes still see one `FirstRun` between them.
        Position(reply) -> {
          process.send(reply, counters.started)
          actor.continue(Counters(..counters, started: LaterRun))
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
            started_context(serving, clock, counters),
          )
        },
        run_end: fn(operation) {
          // A notification beside the existing slot, never instead of
          // it, and the continuation gate asked only when the harness
          // itself had no follow-up to place: a harness follow-up and a
          // hook continuation are the same slot, and the harness's own
          // wins.
          //
          // The nesting is what makes that true. Gleam evaluates both
          // subjects of a two-subject `case` before it matches, so
          // asking the two questions side by side spawned every
          // matching `Stop` hook — side effects, cap counter and all —
          // on runs whose answer was thrown away before it was read.
          case built.run_end(operation) {
            Some(_harness) as placed -> placed

            None -> {
              // A run end on a strand the `Stop` hooks were not written
              // for finishes without asking them, so none of their side
              // effects run and the continuation cap is not spent.
              let continuation = case stops(operation) {
                True ->
                  stop_block(ids.op_id_to_string(operation), serving, counters)
                False -> hookdecisions.Finish
              }
              case continuation {
                hookdecisions.Continue(reason) ->
                  Some(hook_message(hookcompat.Stop, reason, clock))
                hookdecisions.Finish -> None
              }
            }
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
        clear: fn(query) { cleared(serving, tools.clear, query) },
        run: fn(run) { ran(serving, tools.run(run), run) },
      ),
    ),
  )
}

// The two questions the composed slots ask the one small actor that
// owns their state. Both are calls rather than casts because the slot
// is about to decide on the answer, and a decision on a count it has
// not read is not a decision.
type CounterMessage {
  // How many follow-ups the gate has placed for this operation so far,
  // incrementing as it answers.
  Tally(operation: String, reply: Subject(Int))

  // Whether this run start is the session's first, flipping the flag
  // as it answers.
  Position(reply: Subject(RunPosition))
}

// What the counter actor holds: the per-operation continuation tally
// the `Stop` cap binds on, and whether a run start has been seen yet.
type Counters {
  Counters(placed: dict.Dict(String, Int), started: RunPosition)
}

// Where one run start sits in the session's life. `SessionStart` is a
// session event in the contract, and the harness's only per-session
// moment on this path is "the first time the per-run slot is called",
// so the question is named rather than carried as a boolean.
type RunPosition {
  FirstRun
  LaterRun
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

// The message a gate places into a message slot: a user message
// carrying the hook's text, attributed in that text the way the
// contract's continuation prompt is — the hook said it, and the model
// reading it should know that rather than reading it as the operator's
// own words.
//
// The event is a parameter because two different gates place one of
// these and they are two different claims to the model. A run-end
// continuation is a `Stop` hook refusing to let the run finish; a
// run-start injection is a `SessionStart` hook contributing context
// before anything has run. Both were once stamped `[Stop hook]`, which
// told the model a stop hook had blocked at a moment no stop had been
// attempted.
fn hook_message(
  event: hookcompat.Event,
  text: String,
  clock: Clock,
) -> AgentMessage {
  let #(now, _clock) = clock.read(clock)
  message.UserMessage(
    content: [
      message.UserText(
        text: "[" <> hookcompat.event_name(event) <> " hook] " <> text,
        text_signature: None,
      ),
    ],
    timestamp: now,
    origin: None,
  )
}

// The SessionStart injection as one run-start message: fired once per
// composed Effects, at the first run start, in the shape the native
// bus renders its own injections in so both kinds of hook read
// identically in the transcript.
//
// `run_start` is the per-*operation* slot, so the once-per-session
// promise is the counter's to keep. Without it a `SessionStart` hook
// ran on every turn of the session, each time announcing itself as
// `startup`. The contract's other sources (`resume`, `compact`,
// `clear`) have no moment here, which is why the one this does fire
// on is the one it names.
fn started_context(
  serving: Serving,
  clock: Clock,
  counters: Subject(CounterMessage),
) -> List(AgentMessage) {
  case position(counters) {
    LaterRun -> []

    FirstRun ->
      case session_context(serving, "startup") {
        hookdecisions.Injected(text) -> [
          hook_message(hookcompat.SessionStart, text, clock),
        ]
        hookdecisions.NoContext | hookdecisions.Blocked(_) -> []
      }
  }
}

// Whether this run start is the session's first, asked of the actor
// that owns the flag.
fn position(counters: Subject(CounterMessage)) -> RunPosition {
  actor.call(counters, waiting: 1000, sending: fn(reply) { Position(reply) })
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
  clear: fn(effects.ClearanceQuery) -> effects.Clearance,
  query: effects.ClearanceQuery,
) -> effects.Clearance {
  case clear(query) {
    effects.ClearanceRefused(..) as refused -> refused
    effects.Cleared(effective_arguments: _, replay: _) as clearance -> {
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
        hookdecisions.Rewrite(updated) -> recleared(clear, query, updated)
      }
    }
  }
}

// A rewritten call re-enters the harness's own clearance before it is
// allowed to run.
//
// Everything upstream — the permission tables, the escalation ledger,
// whatever a native extension hook contributes — answered about the
// arguments the model sent. Returning the hook's replacement on the
// strength of that answer is how an imported hook widens what runs:
// `{"command": "ls"}` is what got cleared and `{"command": "curl … | sh"}`
// is what executes. So the second clearance is asked on the arguments
// that will actually reach the tool, and the narrower of the two
// verdicts stands.
//
// Only the harness is re-consulted; the hooks are not re-asked. A gate
// allowed to rewrite the input of its own next ask has no fixed point,
// and one pass is what the contract describes.
//
// The second clearance's whole answer is returned, `effective_arguments`
// included, rather than the hook's `updated` literal. A clearance is
// entitled to hand back arguments that are not the ones it was asked
// about — a wrapping layer that normalizes a path or fills a default
// does exactly that — and this composition sits under an unknown stack
// of them. Returning `updated` here would have discarded whatever the
// layer did on the second pass while keeping it on the first, so the
// arguments that ran would not be the arguments the harness last
// approved. Today the in-tree clearance echoes what it is given and the
// two are equal; this is the arm that stays correct when one stops
// echoing.
fn recleared(
  clear: fn(effects.ClearanceQuery) -> effects.Clearance,
  query: effects.ClearanceQuery,
  updated: JsonValue,
) -> effects.Clearance {
  clear(
    effects.ClearanceQuery(
      ..query,
      call: message.ToolCall(..query.call, arguments: updated),
    ),
  )
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
