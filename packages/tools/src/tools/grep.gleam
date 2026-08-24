//// The `grep` tool: ripgrep through the broker's jailed executor, with
//// structured arguments and structured matches.
////
//// The call runs `rg --json` under a read-only policy (workspace
//// readable, nothing writable, network off) and parses ripgrep's JSON
//// event stream into a match list capped at `max_results`. When the
//// jail has no `rg` binary the call settles as a structured error
//// suggesting the bash tool as a fallback.
////
//// `replay: Safe` — a search is a read; re-executing it after a crash
//// repeats no external effect. `execution_mode` is `Concurrent`.

import broker/broker
import broker/budget
import broker/exec
import core/clock
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tools/blob
import tools/fs
import tools/tool.{type Ctx, type ToolOutcome}

/// Default cap on returned matches.
pub const default_max_results = 100

/// Wall-clock timeout for one search.
pub const timeout_ms = 60_000

/// Slack added to the receive window beyond the execution deadline.
const settle_grace_ms = 10_000

/// The `grep` tool.
pub fn tool() -> tool.Tool {
  tool.Tool(
    name: "grep",
    description: "Search file contents with ripgrep. Returns matching "
      <> "lines as path:line:text plus structured match details.",
    schema: tool.object_schema(
      [
        #("pattern", tool.string_property("the regular expression to search")),
        #(
          "path",
          tool.string_property(
            "file or directory to search, under the workspace (default: the "
            <> "whole workspace)",
          ),
        ),
        #(
          "globs",
          tool.string_array_property("file globs to include, e.g. *.gleam"),
        ),
        #(
          "context",
          tool.integer_property("context lines around each match (default 0)"),
        ),
        #(
          "max_results",
          tool.integer_property(
            "maximum matches to return (default "
            <> int.to_string(default_max_results)
            <> ")",
          ),
        ),
      ],
      ["pattern"],
    ),
    replay: tool.Safe,
    execution_mode: tool.Concurrent,
    requirements: tool.read_requirements,
    run:,
  )
}

fn run(ctx: Ctx, args: JsonValue) -> ToolOutcome {
  use pattern <- tool.with_arg(tool.required_string(args, "pattern"))
  use path <- tool.with_arg(tool.optional_string(args, "path"))
  use globs <- tool.with_arg(tool.optional_string_list(args, "globs"))
  use context <- tool.with_arg(tool.optional_int(args, "context"))
  use max_results <- tool.with_arg(tool.optional_int(args, "max_results"))
  let globs = option.unwrap(globs, [])
  let context = option.unwrap(context, 0)
  let max_results = option.unwrap(max_results, default_max_results)
  case context < 0 || max_results < 1 {
    True ->
      tool.failure(
        "invalid arguments: `context` must be >= 0 and `max_results` >= 1",
      )
    False ->
      case search_root(ctx, path) {
        Error(outcome) -> outcome
        Ok(root) -> {
          let #(now, _clock) = clock.read(ctx.clock)
          let spec = call_spec(ctx, pattern, root, globs, context, now)
          let events = process.new_subject()
          case ctx.clear_call(spec, events) {
            Error(refusal) -> tool.refusal_outcome(refusal)
            Ok(call) -> {
              call.stdin(<<>>, True)
              case
                tool.collect_events(
                  events,
                  waiting: timeout_ms + settle_grace_ms,
                )
              {
                Error(Nil) -> {
                  call.cancel()
                  tool.failure(
                    "the sandbox did not settle the search within its window",
                  )
                }
                Ok(collected) -> settle(ctx, collected, max_results)
              }
            }
          }
        }
      }
  }
}

fn search_root(ctx: Ctx, path: Option(String)) -> Result(String, ToolOutcome) {
  case path {
    None -> Ok(ctx.workspace)
    Some(path) ->
      case fs.resolve_path(workspace: ctx.workspace, path:) {
        Ok(resolved) -> Ok(resolved)
        Error(fs.EmptyPath) ->
          Error(tool.failure("invalid arguments: `path` must not be empty"))
        Error(fs.EscapesWorkspace(path:)) ->
          Error(tool.failure(
            "path `" <> path <> "` resolves outside the workspace root",
          ))
        // Lexical resolution never inspects the real filesystem; the
        // jailed rg owns symlink containment for this tool.
        Error(fs.Unresolvable(path:, reason:)) ->
          Error(tool.failure(
            "path `" <> path <> "` could not be resolved: " <> reason,
          ))
      }
  }
}

fn call_spec(
  ctx: Ctx,
  pattern: String,
  root: String,
  globs: List(String),
  context: Int,
  now: Int,
) -> broker.CallSpec {
  let argv =
    list.flatten([
      ["rg", "--json", "--regexp", pattern],
      case context > 0 {
        True -> ["--context", int.to_string(context)]
        False -> []
      },
      list.flat_map(globs, fn(glob) { ["--glob", glob] }),
      [root],
    ])
  broker.CallSpec(
    op_id: ctx.op_id,
    step_id: ctx.step_id,
    base_policy: ctx.base_policy,
    requirements: tool.read_requirements(ctx.workspace),
    grants: ctx.grants,
    response: broker.RefuseNarrowed,
    demand: ctx.demand,
    argv:,
    env: ctx.env,
    cwd: ctx.workspace,
    budget: budget.Budget(max_outstanding: 1, deadline_ms: now + timeout_ms),
  )
}

fn settle(
  ctx: Ctx,
  collected: tool.Collected,
  max_results: Int,
) -> ToolOutcome {
  case collected.outcome {
    broker.CallFailed(failure:) -> failed(failure)
    broker.CallExited(result:) -> exited(ctx, collected, result, max_results)
  }
}

// A spawn failure means the jail has no rg; every other failure keeps
// its generic in-band rendering.
fn failed(failure: exec.ExecFailure) -> ToolOutcome {
  case failure {
    exec.RefusedByHelper(code: "spawn_failed", message: _) -> rg_unavailable()
    _ -> tool.exec_failure_outcome(failure)
  }
}

fn rg_unavailable() -> ToolOutcome {
  tool.failure(
    "ripgrep (rg) is not available in the sandbox; fall back to the bash "
    <> "tool, e.g. `grep -rn <pattern> .`",
  )
}

/// One structured match from a search.
pub type Match {
  Match(path: String, line: Int, text: String)
}

fn exited(
  ctx: Ctx,
  collected: tool.Collected,
  result: exec.ExecResult,
  max_results: Int,
) -> ToolOutcome {
  let stderr = case bit_array.to_string(collected.stderr) {
    Ok(text) -> text
    Error(Nil) -> ""
  }
  case result.code {
    0 | 1 ->
      case bit_array.to_string(collected.stdout) {
        Error(Nil) -> tool.failure("ripgrep produced non-UTF-8 output")
        Ok(stdout) -> {
          let all_matches = parse_matches(stdout)
          let matches = list.take(all_matches, max_results)
          let capped = list.length(all_matches) > max_results
          render(ctx, matches, capped:, truncated: collected.stdout_truncated)
        }
      }
    // 127: the shell-less exec could not run rg (defensive; the helper
    // usually reports spawn_failed instead).
    127 -> rg_unavailable()
    code ->
      tool.failure(
        "ripgrep failed with exit code "
        <> int.to_string(code)
        <> case stderr {
          "" -> ""
          _ -> ": " <> stderr
        },
      )
  }
}

fn render(
  ctx: Ctx,
  matches: List(Match),
  capped capped: Bool,
  truncated truncated: Bool,
) -> ToolOutcome {
  let body = case matches {
    [] -> "no matches"
    _ ->
      matches
      |> list.map(fn(match) {
        match.path <> ":" <> int.to_string(match.line) <> ":" <> match.text
      })
      |> string.join(with: "\n")
  }
  let body = case capped, truncated {
    True, _ -> body <> "\n[match list capped at max_results]"
    False, True -> body <> "\n[search output truncated at the output cap]"
    False, False -> body
  }
  let details =
    json.Object([
      #(
        "matches",
        json.Array(
          list.map(matches, fn(match) {
            json.Object([
              #("path", json.String(match.path)),
              #("line", json.Int(match.line)),
              #("text", json.String(match.text)),
            ])
          }),
        ),
      ),
      #("match_count", json.Int(list.length(matches))),
      #("capped", json.Bool(capped)),
      #("output_truncated", json.Bool(truncated)),
    ])
  let outcome =
    tool.ToolOutcome(
      content: [tool.text_block(body)],
      details: Some(details),
      is_error: False,
    )
  case blob.bound(ctx, body) {
    Error(_error) -> outcome
    Ok(bounded) ->
      tool.ToolOutcome(..outcome, content: [
        tool.text_block(blob.bounded_text(bounded)),
      ])
      |> blob.with_blob_details(bounded)
  }
}

/// Parses ripgrep `--json` event lines into matches. Unknown or
/// malformed lines are skipped — the stream may be truncated mid-line
/// at the output cap, and a search result must degrade, not crash.
pub fn parse_matches(stdout: String) -> List(Match) {
  stdout
  |> string.split(on: "\n")
  |> list.filter_map(parse_match_line)
}

fn parse_match_line(line: String) -> Result(Match, Nil) {
  use parsed <- result.try(
    json.parse(line)
    |> result.replace_error(Nil),
  )
  use kind <- result.try(json_string_field(parsed, "type"))
  case kind {
    "match" -> {
      use data <- result.try(json_field(parsed, "data"))
      use path_value <- result.try(json_field(data, "path"))
      use path <- result.try(json_string_field(path_value, "text"))
      use line_number <- result.try(json_int_field(data, "line_number"))
      use lines_value <- result.try(json_field(data, "lines"))
      use text <- result.try(json_string_field(lines_value, "text"))
      Ok(Match(path:, line: line_number, text: string_trim_end_newline(text)))
    }
    _ -> Error(Nil)
  }
}

fn string_trim_end_newline(text: String) -> String {
  case string.ends_with(text, "\n") {
    True -> string.drop_end(text, 1)
    False -> text
  }
}

fn json_field(value: JsonValue, key: String) -> Result(JsonValue, Nil) {
  case value {
    json.Object(fields:) ->
      list.find_map(fields, fn(entry) {
        case entry.0 == key {
          True -> Ok(entry.1)
          False -> Error(Nil)
        }
      })
    _ -> Error(Nil)
  }
}

fn json_string_field(value: JsonValue, key: String) -> Result(String, Nil) {
  case json_field(value, key) {
    Ok(json.String(text)) -> Ok(text)
    _ -> Error(Nil)
  }
}

fn json_int_field(value: JsonValue, key: String) -> Result(Int, Nil) {
  case json_field(value, key) {
    Ok(json.Int(number)) -> Ok(number)
    _ -> Error(Nil)
  }
}
