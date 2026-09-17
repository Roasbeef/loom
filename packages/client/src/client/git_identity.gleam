//// Git identity defaults cross the tool-home boundary as data.
////
//// Tools use an empty HOME, so Git otherwise guesses a hostname-based email.
//// A read-only Git query resolves the operator's global identity, including
//// conditional includes, and a jailed write publishes only those values. The
//// global scope leaves repository overrides and preserved commit authors intact.
//// Neither query nor publication runs outside the session's filesystem policy.

import broker/broker
import broker/budget
import broker/policy
import client/worktree_diff
import core/clock
import core/ids
import gleam/bit_array
import gleam/bool
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import tools/tool

/// The server selects the generated global configuration for every tool.
pub const environment_name = "GIT_CONFIG_GLOBAL"

/// Publishes identity defaults before model work can create commits.
///
/// An unavailable global identity is a warning, not a boot failure: the empty
/// projection still requires configured identity, and local Git settings work.
/// Publication failure refuses boot rather than permitting guessed commits.
/// The returned warning contains no configuration values or command output.
///
/// ## Examples
///
/// ```gleam
/// // git_identity.prepare(wiring, Some("/home/operator"), reading: host_env)
/// // -> Ok(None)
/// ```
pub fn prepare(
  wiring: worktree_diff.Wiring,
  home: Option(String),
  reading reading: fn(String) -> Result(String, Nil),
) -> Result(Option(String), String) {
  let git = bootstrap.find_executable("git")
  let configured = configured_identity(wiring, git, home, reading)
  let #(identity, warning) = case configured {
    Ok(identity) -> #(identity, None)
    Error(_) -> #(
      [],
      Some(
        "global Git identity could not be read; configure user.name and user.email in the repository",
      ),
    )
  }
  use destination <- result.try(
    list.key_find(wiring.env, environment_name)
    |> result.replace_error("the tool Git configuration path is missing"),
  )

  // Content and paths are positional data, never shell source. The kernel
  // checks a planted HOME or file symlink under exactly the tool's authority.
  // Git itself quotes values when writing, including embedded newlines.
  // Sessions sharing a workspace build separate files and publish by rename,
  // so a concurrent commit always reads a complete configuration.
  let arguments =
    list.flatten([
      [
        "/bin/sh",
        "-c",
        "set -eu; destination=$1; git=$2; shift 2; umask 077; "
          <> "file=$(mktemp \"$destination.XXXXXX\"); "
          <> "trap 'rm -f \"$file\"' EXIT HUP INT TERM; "
          <> "printf '[user]\\nuseConfigOnly = true\\n' > \"$file\"; "
          <> "while [ \"$#\" -gt 0 ]; do "
          <> "\"$git\" config --file \"$file\" \"$1\" \"$2\"; shift 2; done; "
          <> "mv -f \"$file\" \"$destination\"",
        "loom-git-identity",
        destination,
        result.unwrap(git, "git"),
      ],
      list.flat_map(identity, fn(pair) { [pair.0, pair.1] }),
    ])
  use #(code, _) <- result.try(
    run(wiring, wiring.base_policy, arguments, [
      #("PATH", "/usr/bin:/bin"),
      #("HOME", "/nonexistent"),
    ]),
  )
  case code {
    0 -> Ok(warning)
    _ -> Error("could not publish the sandbox Git identity defaults")
  }
}

fn configured_identity(
  wiring: worktree_diff.Wiring,
  git: Result(String, String),
  home: Option(String),
  reading: fn(String) -> Result(String, Nil),
) -> Result(List(#(String, String)), String) {
  use git <- result.try(git)
  let environment =
    list.append(
      [#("PATH", "/usr/bin:/bin"), #("HOME", option_home(home))],
      list.filter_map(["XDG_CONFIG_HOME", environment_name], fn(name) {
        reading(name) |> result.map(fn(value) { #(name, value) })
      }),
    )
  use #(code, output) <- result.try(run(
    wiring,
    worktree_diff.read_policy(wiring.base_policy),
    [
      git, "config", "--global", "--includes", "--null", "--get-regexp",
      "^user\\.(name|email)$",
    ],
    environment,
  ))
  case code {
    0 -> decode(output)
    1 -> Ok([])
    _ -> Error("global Git identity query failed")
  }
}

fn option_home(home: Option(String)) -> String {
  case home {
    Some(path) -> path
    None -> "/nonexistent"
  }
}

fn decode(output: String) -> Result(List(#(String, String)), String) {
  use <- bool.guard(
    !string.ends_with(output, "\u{0}"),
    Error("incomplete Git identity response"),
  )
  output
  |> string.drop_end(1)
  |> string.split("\u{0}")
  |> list.try_map(fn(record) {
    case string.split_once(record, "\n") {
      Ok(#("user.name", value)) -> Ok(#("user.name", value))
      Ok(#("user.email", value)) -> Ok(#("user.email", value))
      _ -> Error("invalid Git identity response")
    }
  })
}

// Both fixed commands settle through the existing broker. The query demotes
// filesystem access to reads; publication retains only the session's writes.
fn run(
  wiring: worktree_diff.Wiring,
  base: policy.SandboxPolicy,
  arguments: List(String),
  environment: List(#(String, String)),
) -> Result(#(Int, String), String) {
  let #(now, _) = clock.read(wiring.clock)
  let #(operation, _) =
    ids.mint_op(ids.generator(wiring.clock, seed: wiring.entropy()))
  let base =
    policy.SandboxPolicy(
      ..base,
      network: policy.NetworkOff,
      env_allow: list.map(environment, fn(pair) { pair.0 }),
    )
  let requirements =
    policy.SandboxPolicy(
      ..base,
      limits: policy.Limits(8, 8, 268_435_456, 16, 1_048_576, 65_536),
    )

  // These are ceilings, not minimum resources. A stricter session policy
  // must still be able to prepare identity under its own smaller limits.
  let #(requirements, _) = policy.compose(base, requirements, [])
  let events = process.new_subject()
  use call <- result.try(
    broker.clear_call(
      wiring.broker,
      broker.CallSpec(
        op_id: operation,
        step_id: "git-identity",
        base_policy: base,
        requirements:,
        grants: [],
        response: broker.RefuseNarrowed,
        demand: wiring.demand,
        argv: arguments,
        env: environment,
        cwd: wiring.workspace,
        budget: budget.Budget(1, now + 8000),
      ),
      events:,
      waiting: 8000,
    )
    |> result.replace_error(
      "Git identity preparation was refused by the sandbox",
    ),
  )
  broker.stdin(wiring.broker, call, data: <<>>, eof: True)
  use collected <- result.try(
    tool.collect_events(events, waiting: 13_000)
    |> result.map_error(fn(_) {
      broker.cancel(wiring.broker, call)
      "Git identity preparation did not settle"
    }),
  )
  case collected.outcome {
    broker.CallFailed(_) -> Error("Git identity preparation failed")
    broker.CallExited(report) -> {
      use <- bool.guard(
        report.cancelled
          || report.timed_out
          || report.stdout_truncated
          || report.stderr_truncated
          || collected.stdout_truncated
          || collected.stderr_truncated,
        Error("Git identity preparation was incomplete"),
      )
      collected.stdout
      |> bit_array.to_string
      |> result.map(fn(output) { #(report.code, output) })
      |> result.replace_error("Git identity response was not UTF-8")
    }
  }
}
