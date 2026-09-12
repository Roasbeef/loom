//// `client/hookwire` — the event mapping: where an imported hook's
//// Claude contract meets the harness moments that already exist.
////
//// # Why a separate module, and why it holds no policy
////
//// The three modules under it each own one thing: `hookcompat` owns
//// the parsed model, `hookrunner` owns one jailed process, and
//// `hookdecisions` owns reading a process back as a decision. What
//// none of them can own is the *event*: which harness moment a
//// `PreToolUse` is, what fields its payload carries, which of its
//// handlers match, and how several matching handlers' verdicts
//// combine. That is this module, and it is deliberately the only place
//// that knows both vocabularies.
////
//// It holds no policy of its own: the trust record decides whether a
//// config runs at all, and the runner's jail decides what a run
//// process may touch. What it *does* enforce is the contract's own
//// combination rules — a deny from any matching hook wins; the first
//// deny's reason is the one reported — and the harness's own
//// authority ordering: a hook's `allow` is advisory on top of a
//// clearance the harness already granted, never a way around it.
////
//// # The payload, and what it honestly says
////
//// Every payload carries the contract's common fields plus the
//// event's own. Two fields are the compatibility layer's honest
//// admissions, written into the payload rather than papered over:
//// `cwd` is the session workspace (the contract's session working
//// directory for Loom), and `transcript_path` names the session's
//// durable file — the SQLite database the conversation lives in,
//// not a JSONL transcript. A hook that reads it as JSONL will find
//// no lines; the parity matrix says so rather than inventing a
//// transcript format the harness does not have.

import client/hookcompat.{type Config, type Event}
import client/hookdecisions
import client/hookrunner
import core/json.{type JsonValue, Object, String}
import gleam/list
import gleam/option.{type Option}
import gleam/regexp
import gleam/result
import gleam/string

/// Everything the mapping needs to fire hooks: the merged, trusted
/// configuration, plus the runner context the events share. One
/// session builds one of these at boot.
/// The session facts every payload's common fields carry: the
/// conversation's subscribe name and its durable file. These live
/// beside the config rather than inside the runner because they are
/// the *conversation's* identity, and a pure reader of payloads — a
/// test, a converter — can state them without a broker.
pub type Wiring {
  Wiring(
    /// The merged configuration, already trust-checked.
    config: Config,
    /// The session's subscribe name, the `session_id` field.
    session_id: String,
    /// The session's durable file, the `transcript_path` field —
    /// which for Loom is the SQLite database, a difference the
    /// parity matrix records rather than papering over.
    transcript_path: String,
    /// The session workspace, the `cwd` field.
    workspace: String,
  )
}

/// Whether a matcher group wants this occurrence, by the contract's
/// own table: tool events match on the tool name, `SessionStart` on
/// its source, `PreCompact` on its trigger — and events with no
/// matcher support (`Stop`, `UserPromptSubmit`, …) match everything.
pub fn group_matches(group: hookcompat.Group, field: String) -> Bool {
  case group.matcher {
    hookcompat.All -> True
    hookcompat.Exact(names) -> list.contains(names, field)
    hookcompat.Regex(raw) ->
      case regexp.from_string(raw) {
        Ok(pattern) -> regexp.check(pattern, field)
        Error(_malformed) ->
          // An unparseable regex is the config's bug, but the
          // contract's own matcher path evaluates it in the
          // engine's own terms and a malformed one matches nothing
          // there too. Failing the whole session over a matcher
          // nobody wrote correctly is the load-time notes' job,
          // which already named the file; matching nothing here is
          // the quieter half of the same honesty.
          False
      }
  }
}

/// The command handlers of every group whose matcher wants this
/// occurrence, in declaration order — the contract's "all matching
/// hooks run".
///
/// The kind filter is here, once, rather than at each of the five
/// gates. This build runs command hooks only, which the parity matrix
/// states and `hookcompat.notes` says again at load time; an `http`,
/// `mcp_tool`, `prompt` or `agent` handler carries no command at all,
/// so a gate that fanned it out spawned `sh -c ""` and folded its exit
/// 0 into the combination as though a hook had answered. Filtering
/// where the matching happens makes "parsed, not run" structural: a
/// non-command handler is not something a gate can reach.
pub fn matching_handlers(
  wiring: Wiring,
  event: Event,
  field: String,
) -> List(#(String, hookcompat.Handler)) {
  case find_event(wiring.config, event) {
    Ok(groups) ->
      groups
      |> list.filter(fn(group) { group_matches(group, field) })
      |> list.flat_map(fn(group) { group.handlers })
      |> list.filter(fn(handler) { handler.kind == hookcompat.Command })
      |> list.map(fn(handler) {
        #(hookcompat.describes_handler(handler), handler)
      })
    Error(Nil) -> []
  }
}

fn find_event(
  config: Config,
  event: Event,
) -> Result(List(hookcompat.Group), Nil) {
  case list.find(config.entries, fn(entry) { entry.0 == event }) {
    Ok(#(_event, groups)) -> Ok(groups)
    Error(Nil) -> Error(Nil)
  }
}

/// The default timeout in seconds for one event, per the contract's
/// own defaults: 600 for most, 30 on `UserPromptSubmit`, and the
/// `SessionEnd` 1.5-second budget rounded to 1.
pub fn default_timeout_s(event: Event) -> Int {
  case event {
    hookcompat.UserPromptSubmit -> 30
    hookcompat.SessionEnd -> 1
    _ -> 600
  }
}

/// One hook's run, read back as the decision its event reads. The
/// runner executes, the decisions module interprets, and this is the
/// one composition so a caller never handles a raw `Outcome` itself.
///
/// The runner context is a parameter rather than a `Wiring` field on
/// purpose: the pure halves of this module — matchers, combinations,
/// payloads — answer without one, and keeping the broker-bearing
/// value out of the type is what keeps those halves testable without
/// a session.
pub fn ask(
  runner: hookrunner.Context,
  event: Event,
  handler: hookcompat.Handler,
  payload: JsonValue,
) -> Result(hookrunner.Outcome, hookrunner.RunError) {
  let command =
    hookrunner.Command(
      command: option.unwrap(handler.command, ""),
      args: handler.args,
      timeout_s: handler.timeout_s,
    )
  hookrunner.run(
    runner,
    command,
    json.to_string(payload),
    default_timeout_s(event),
  )
}

/// The common fields every payload carries, per the contract's
/// common-input table: session, working directory, transcript, the
/// event's own name. `session_id` and `workspace` come from the
/// wiring's runner context, which is the one place the session's
/// identity already lives.
pub fn common_payload(
  wiring: Wiring,
  event: Event,
  extra: List(#(String, JsonValue)),
) -> JsonValue {
  Object([
    #("session_id", String(wiring.session_id)),
    #("transcript_path", String(wiring.transcript_path)),
    #("cwd", String(wiring.workspace)),
    #("hook_event_name", String(hookcompat.event_name(event))),
    ..extra
  ])
}

/// Combines several `PreToolUse` verdicts into the one the clearance
/// takes, by the contract's precedence: deny > defer > ask > allow,
/// with the first deny's reason the one reported. A rewrite from a
/// hook that did not deny applies alongside a bare allow; a deny
/// discards any rewrite the same hook or another offered, because a
/// call that will not run has nothing to rewrite.
pub fn combine_permissions(
  verdicts: List(hookdecisions.ToolPermission),
) -> hookdecisions.ToolPermission {
  let deny =
    list.filter_map(verdicts, fn(verdict) {
      case verdict {
        hookdecisions.Deny(reason) -> Ok(reason)
        _ -> Error(Nil)
      }
    })
  case deny {
    [reason, ..] -> hookdecisions.Deny(reason)
    [] -> {
      let asks =
        list.filter_map(verdicts, fn(verdict) {
          case verdict {
            hookdecisions.Ask(reason) -> Ok(reason)
            _ -> Error(Nil)
          }
        })
      case asks {
        [reason, ..] -> hookdecisions.Ask(reason)
        [] ->
          list.find_map(verdicts, fn(verdict) {
            case verdict {
              hookdecisions.Rewrite(updated) ->
                Ok(hookdecisions.Rewrite(updated))
              _ -> Error(Nil)
            }
          })
          |> result.unwrap(hookdecisions.Proceed)
      }
    }
  }
}

/// Combines several `Stop` continuations: the contract's rule that
/// any block continues the run, with the first block's reason.
pub fn combine_continuations(
  verdicts: List(hookdecisions.Continuation),
) -> hookdecisions.Continuation {
  list.find_map(verdicts, fn(verdict) {
    case verdict {
      hookdecisions.Continue(reason) -> Ok(hookdecisions.Continue(reason))
      hookdecisions.Finish -> Error(Nil)
    }
  })
  |> result.unwrap(hookdecisions.Finish)
}

/// Joins several context injections into one, in the order their
/// hooks were declared. A blocked prompt wins over any context, per
/// the contract's rejection semantics.
pub fn combine_injections(
  verdicts: List(hookdecisions.ContextInjection),
) -> hookdecisions.ContextInjection {
  let blocked =
    list.filter_map(verdicts, fn(verdict) {
      case verdict {
        hookdecisions.Blocked(reason) -> Ok(reason)
        _ -> Error(Nil)
      }
    })
  case blocked {
    [reason, ..] -> hookdecisions.Blocked(reason)
    [] -> {
      let context =
        verdicts
        |> list.filter_map(fn(verdict) {
          case verdict {
            hookdecisions.Injected(text) -> Ok(text)
            _ -> Error(Nil)
          }
        })
        |> string.join("\n\n")
      case context {
        "" -> hookdecisions.NoContext
        text -> hookdecisions.Injected(text)
      }
    }
  }
}

/// Joins several `PostToolUse` feedbacks by the contract's shape: a
/// rewrite from any hook replaces the result (the first one's, in
/// declaration order), feedback rides beside it, and context is
/// folded into the visible result's neighbourhood. The combination
/// returns at most the two things the runtime can carry — a content
/// replacement and a reason — rather than a third invented shape.
pub type Feedback {
  Feedback(
    replacement: Option(JsonValue),
    reason: Option(String),
    context: Option(String),
  )
}

pub fn combine_feedback(
  verdicts: List(hookdecisions.ToolFeedback),
) -> Feedback {
  Feedback(
    replacement: first_rewrite(verdicts),
    reason: first_reason(verdicts),
    context: first_context(verdicts),
  )
}

fn first_rewrite(
  verdicts: List(hookdecisions.ToolFeedback),
) -> Option(JsonValue) {
  list.find_map(verdicts, fn(verdict) {
    case verdict {
      hookdecisions.Rewritten(replacement) -> Ok(replacement)
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

fn first_reason(verdicts: List(hookdecisions.ToolFeedback)) -> Option(String) {
  list.find_map(verdicts, fn(verdict) {
    case verdict {
      hookdecisions.Feedback(reason) -> Ok(reason)
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

fn first_context(verdicts: List(hookdecisions.ToolFeedback)) -> Option(String) {
  list.find_map(verdicts, fn(verdict) {
    case verdict {
      hookdecisions.Context(text) -> Ok(text)
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

// --- payload extras ---------------------------------------------------------

/// The `PreToolUse`/`PostToolUse` payload's tool fields, with the
/// Loom-to-Claude tool-name mapping applied: an existing `Bash` or
/// `Edit` matcher has to fire for the Loom tool whose operation is the
/// same one. The mapping is the identity unless a Loom name differs,
/// which is the table below, and it is applied *only* to matching and
/// never to the payload's `tool_name` — a hook that prints its input
/// should see the name the harness actually used.
pub fn claude_tool_name(loom_name: String) -> String {
  case list.key_find(tool_name_pairs, loom_name) {
    Ok(mapped) -> mapped
    Error(Nil) -> loom_name
  }
}

// The shared operations under two names. Deliberately total about the
// direction: only a Loom tool whose Claude counterpart a matcher was
// written against appears here, and every other name maps to itself —
// including an extension tool Claude never knew, which is the case
// the identity arm is for.
const tool_name_pairs = [
  #("bash", "Bash"),
  #("fs_write", "Write"),
  #("fs_edit", "Edit"),
  #("fs_read", "Read"),
]

/// The tool fields both tool events carry: `tool_name` (the Loom name,
/// verbatim), `tool_input` (the call's arguments object), and the
/// call's id as `tool_use_id`.
pub fn tool_fields(
  name: String,
  arguments: JsonValue,
  id: String,
) -> List(#(String, JsonValue)) {
  [
    #("tool_name", String(name)),
    #("tool_input", arguments),
    #("tool_use_id", String(id)),
  ]
}
