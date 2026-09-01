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
import gleam/bool
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

/// The outstanding-effect cap this tool's budget declares.
///
/// The broker pools budget per `{op_id, step_id}` — the whole batch under
/// one turn, not any single call's own fan-out (`broker/budget`'s module
/// doc, ADR-005) — so this bounds how many `grep` calls one batch may run
/// at once, not how many any one call may start. `Concurrent` and `1`
/// contradicted each other: a second genuinely concurrent `grep` in the
/// same batch shared this tool's own first-opened ledger and was refused
/// `OutstandingCapReached` (issue #50), which every test missed because
/// the only other concurrent-capable tool in the suite is `bash`, and
/// `bash` is `Exclusive`. `16` is a real ceiling — comfortably above the
/// handful of searches one turn plausibly asks for, and nowhere near the
/// "10,000 polite parallel reads" the pooling exists to refuse — not an
/// attempt to size it exactly; #23's per-execution spawn ceiling is where
/// that gets decided properly.
pub const max_concurrent_searches = 16

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
  use <- bool.guard(
    when: context < 0 || max_results < 1,
    return: tool.failure(
      "invalid arguments: `context` must be >= 0 and `max_results` >= 1",
    ),
  )
  use root <- tool.or_outcome(search_root(ctx, path), identity_outcome)
  let #(now, _clock) = clock.read(ctx.clock)
  let spec = call_spec(ctx, pattern, root, globs, context, now)
  let events = process.new_subject()
  use call <- tool.or_outcome(
    ctx.clear_call(spec, events),
    tool.refusal_outcome,
  )
  call.stdin(<<>>, True)
  use collected <- tool.or_outcome(
    tool.collect_events(events, waiting: timeout_ms + settle_grace_ms),
    fn(_nil) {
      call.cancel()
      tool.failure("the sandbox did not settle the search within its window")
    },
  )
  settle(ctx, collected, max_results)
}

// `search_root` and `collect_events` (below) already render their
// failure as a `ToolOutcome`, so chaining them through `tool.or_outcome`
// needs no mapping.
fn identity_outcome(outcome: ToolOutcome) -> ToolOutcome {
  outcome
}

// Lexical resolution never inspects the real filesystem; the jailed rg
// owns symlink containment for this tool, so `fs.resolve_path` (not
// `resolve_real`) is enough here.
fn search_root(ctx: Ctx, path: Option(String)) -> Result(String, ToolOutcome) {
  case path {
    None -> Ok(ctx.workspace)
    Some(path) ->
      fs.resolve_path(workspace: ctx.workspace, path:)
      |> result.map_error(fs.path_outcome)
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
    budget: budget.Budget(
      max_outstanding: max_concurrent_searches,
      deadline_ms: now + timeout_ms,
    ),
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
    0 | 1 -> matched_outcome(ctx, collected, max_results)

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

fn matched_outcome(
  ctx: Ctx,
  collected: tool.Collected,
  max_results: Int,
) -> ToolOutcome {
  use stdout <- tool.or_outcome(
    bit_array.to_string(collected.stdout),
    non_utf8_stdout,
  )
  let all_matches = parse_matches(stdout)
  let matches = list.take(all_matches, max_results)

  // `list.take` above already stopped at `max_results`; asking whether
  // there is anything left needs only `max_results` steps of `drop`, not
  // a walk of the whole (unbounded) match list `list.length` would do.
  let capped = list.drop(all_matches, max_results) != []
  render(ctx, matches, capped:, truncated: collected.stdout_truncated)
}

fn non_utf8_stdout(_nil: Nil) -> ToolOutcome {
  tool.failure("ripgrep produced non-UTF-8 output")
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
      #("matches", json.Array(list.map(matches, encode_match))),
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

fn encode_match(match: Match) -> JsonValue {
  json.Object([
    #("path", json.String(match.path)),
    #("line", json.Int(match.line)),
    #("text", json.String(match.text)),
  ])
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
