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
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import simplifile

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
