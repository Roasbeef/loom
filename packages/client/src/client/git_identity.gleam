//// Git identity defaults cross the tool-home boundary as data.
////
//// Tools use an empty HOME, so Git otherwise guesses a hostname-based email.
//// A read-only Git query resolves the operator's global identity, including
//// conditional includes, and the helper publishes only those values through
//// directory descriptors anchored to the original write grant. The
//// global scope leaves repository overrides and preserved commit authors intact.
//// Neither query nor publication can exceed the session's filesystem policy.
//// A snapshot caller can instead resolve the source repository's effective
//// name and email; that projection never copies the surrounding configuration.

import broker/broker
import broker/budget
import broker/policy
import client/internal/ffi_os
import client/worktree_diff
import core/clock
import core/ids
import core/json
import gleam/bit_array
import gleam/bool
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tools/tool

/// The server selects the generated global configuration for every tool.
pub const environment_name = "GIT_CONFIG_GLOBAL"

/// The resolved identity values copied into a child's isolated tool home.
///
/// These values are convenience configuration, not an authentication authority.
pub type Identity {
  Identity(
    /// The last configured user.name, if present.
    name: Option(String),
    /// The last configured user.email, if present.
    email: Option(String),
  )
}

/// Resolves the parent's effective identity under its existing read policy.
///
/// Repository settings override global settings, and the last value wins.
/// Missing values remain missing rather than being inferred from the host.
///
/// ## Examples
///
/// ```gleam
/// // git_identity.resolve(wiring, Some("/home/operator"), reading: host_env)
/// // -> Ok(git_identity.Identity(Some("Operator"), Some("operator@example.com")))
/// ```
pub fn resolve(
  wiring: worktree_diff.Wiring,
  home: Option(String),
  reading reading: fn(String) -> Result(String, Nil),
) -> Result(Identity, String) {
  configured_identity(wiring, home, reading, scope: Effective)
}

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
/// // git_identity.prepare(wiring, Some("/home/operator"), helper: helper_path, reading: host_env)
/// // -> Ok(None)
/// ```
pub fn prepare(
  wiring: worktree_diff.Wiring,
  home: Option(String),
  helper helper: String,
  reading reading: fn(String) -> Result(String, Nil),
) -> Result(Option(String), String) {
  let configured = configured_identity(wiring, home, reading, scope: Global)

  // A failed query still publishes the restrictive empty projection.
  let #(identity, query_warning) = case configured {
    Ok(identity) -> #(identity, None)
    Error(_) -> #(
      Identity(None, None),
      Some(
        "global Git identity could not be read; configure user.name and user.email in the repository",
      ),
    )
  }

  use warning <- result.try(publish(wiring, identity, helper:))

  // A query failure explains the warning more precisely than missing fields.
  case query_warning {
    Some(_) -> Ok(query_warning)
    None -> Ok(warning)
  }
}

/// Publishes only the resolved identity to a fresh tool home.
///
/// A missing or empty value yields a warning and remains unconfigured.
///
/// ## Examples
///
/// ```gleam
/// // git_identity.publish(wiring, identity, helper: helper_path)
/// // -> Ok(None)
/// ```
pub fn publish(
  wiring: worktree_diff.Wiring,
  identity: Identity,
  helper helper: String,
) -> Result(Option(String), String) {
  // Both values are required to prevent Git from guessing an identity.
  let warning = case identity {
    Identity(Some(name), Some(email)) ->
      case string.trim(name) == "" || string.trim(email) == "" {
        True -> Some(incomplete_warning)
        False -> None
      }
    _ -> Some(incomplete_warning)
  }

  let entries =
    [#("user.name", identity.name), #("user.email", identity.email)]
    |> list.filter_map(fn(pair) {
      pair.1
      |> option.to_result(Nil)
      |> result.map(fn(value) { #(pair.0, value) })
    })

  use destination <- result.try(
    list.key_find(wiring.env, environment_name)
    |> result.replace_error("the tool Git configuration path is missing"),
  )

  // The output location is server-owned. The helper walks its parent
  // directories from the original granted root with no symlink traversal,
  // then renames an exclusive temporary file through the opened directory.
  // A model-planted HOME cannot become a new grant, and publication creates
  // no unrelated mountpoints in the host's SQLite state directories.
  use <- bool.guard(
    destination != wiring.workspace <> "/.codemode/home/gitconfig",
    Error("the tool Git configuration path is invalid"),
  )
  use encoded <- result.try(
    policy.encode(wiring.base_policy)
    |> result.replace_error("the Git publication policy could not be encoded"),
  )
  let entries =
    json.Array(
      list.map(entries, fn(pair) {
        json.Array([json.String(pair.0), json.String(pair.1)])
      }),
    )
    |> json.to_string
  use #(code, output) <- result.try(
    ffi_os.run_capture(
      helper,
      [
        "--publish-git-identity",
        bit_array.base64_encode(encoded, True),
        wiring.workspace,
        entries,
      ],
      8000,
    )
    |> result.replace_error("Git identity publication did not settle"),
  )

  // Verify that identity publishing exited cleanly before returning warnings.
  case code {
    0 -> Ok(warning)
    _ -> Error(publication_failure(output))
  }
}

/// The session-start error for a refused publication.
///
/// The helper reports its reason as one fixed `loom-exec: ...` line on
/// stdout and never includes policy, path, or identity values. The line is
/// still treated as untrusted text here: only a line with that prefix is
/// kept, control characters and non-ASCII are dropped, and its length is
/// bounded, so no other output can reach the operator's screen.
///
/// ## Examples
///
/// ```gleam
/// // publication_failure("loom-exec: outside the writable policy\n")
/// // -> "could not publish the sandbox Git identity defaults (outside the writable policy)"
/// ```
pub fn publication_failure(output: String) -> String {
  let base = "could not publish the sandbox Git identity defaults"

  // Extract the leading stdout line reported by the helper process.
  let line = case string.split(output, "\n") {
    [first, ..] -> first
    [] -> ""
  }

  use <- bool.guard(!string.starts_with(line, helper_prefix), base)
  let printable =
    line
    |> string.drop_start(string.length(helper_prefix))
    |> string.to_graphemes
    |> list.filter(is_printable_ascii)
    |> list.take(reason_limit)
    |> string.concat
    |> string.trim

  // Format the failure message with reason details if any printable text survived.
  case printable {
    "" -> base
    reason -> base <> " (" <> reason <> ")"
  }
}

const incomplete_warning =
  "Git identity is incomplete; configure user.name and user.email in the repository"

const helper_prefix = "loom-exec: "

const reason_limit = 160

/// Validates whether a single grapheme falls within printable ASCII character bounds.
fn is_printable_ascii(grapheme: String) -> Bool {
  // Check the UTF-8 codepoint value against standard printable ASCII limits.
  case string.to_utf_codepoints(grapheme) {
    [point] -> {
      let code = string.utf_codepoint_to_int(point)
      code >= 0x20 && code < 0x7f
    }
    _ -> False
  }
}

type Scope {
  Global
  Effective
}

/// Reads user.name and user.email through the broker under the selected scope.
fn configured_identity(
  wiring: worktree_diff.Wiring,
  home: Option(String),
  reading: fn(String) -> Result(String, Nil),
  scope scope: Scope,
) -> Result(Identity, String) {
  let environment =
    list.append(
      [#("PATH", "/usr/bin:/bin"), #("HOME", option_home(home))],
      list.filter_map(["XDG_CONFIG_HOME", environment_name], fn(name) {
        reading(name) |> result.map(fn(value) { #(name, value) })
      }),
    )

  // `wiring.git` is the host-resolved binary, never the Xcode shim. A fresh
  // operator HOME misses `xcrun`'s cache, and the shim's cache rewrite would
  // be killed by this call's one-megabyte file-size limit before Git ran.
  let scope = case scope {
    Global -> ["--global"]
    Effective -> []
  }

  use #(code, output) <- result.try(run(
    wiring,
    worktree_diff.read_policy(wiring.base_policy),
    [
      wiring.git,
      "config",
      ..list.append(scope, [
        "--includes",
        "--null",
        "--get-regexp",
        "^user\\.(name|email)$",
      ])
    ],
    environment,
  ))

  // Decode identity records on success or treat status 1 as empty configuration.
  case code {
    0 -> decode(output) |> result.map(identity_from_entries)
    1 -> Ok(Identity(None, None))
    _ -> Error("Git identity query failed")
  }
}

/// Reduces Git's ordered records so each field keeps its last value.
fn identity_from_entries(entries: List(#(String, String))) -> Identity {
  list.fold(entries, Identity(None, None), fn(identity, pair) {
    case pair {
      #("user.name", value) -> Identity(..identity, name: Some(value))
      #("user.email", value) -> Identity(..identity, email: Some(value))
      _ -> identity
    }
  })
}

fn option_home(home: Option(String)) -> String {
  case home {
    Some(path) -> path
    None -> "/nonexistent"
  }
}

/// Decodes null-byte separated Git config output into structured key-value identity pairs.
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

/// Executes a read-only Git probe command through the broker sandbox.
///
/// The fixed query settles through the existing broker with filesystem access
/// demoted to reads. Publication is a separate, descriptor-confined operation.
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
      // Fixed metadata setup keeps the filesystem and network demand, but
      // does not require delegated cgroups before a session can open. Model
      // work retains the original policy's memory and process ceilings.
      limits: policy.Limits(..base.limits, mem_bytes: 0, pids: 0),
    )
  let requirements =
    policy.SandboxPolicy(
      ..base,
      limits: policy.Limits(8, 8, 0, 0, 1_048_576, 65_536),
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

  // Verify that the broker run completed without failure or truncated streams.
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
