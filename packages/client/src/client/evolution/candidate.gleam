//// Capture copies only a caller-authorized directory into immutable records.
//// Archive admission rejects symlinks and bounds the complete snapshot before
//// candidate layout admission retains sources, tests and fixtures together.

import broker/broker
import broker/budget
import broker/exec
import broker/policy as sandbox
import client/evolution/record
import client/evolution/store
import client/extension/archive
import codemode/vet/package
import codemode/vet/policy
import core/clock
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import tools/directory_access
import tools/fs
import tools/tool

/// Author inputs contain no provenance or approval identity.
pub type Proposal {
  Proposal(
    /// The caller-authorized source directory.
    directory: String,
    /// The stable catalogue name.
    name: String,
    /// The runtime boundary to evaluate.
    kind: record.Kind,
    /// The host-admitted publication scope.
    scope: record.Scope,
    /// A vetted module exposing `main() -> report.Outcome`.
    test_entry: Option(String),
    /// The model-visible purpose.
    description: String,
    /// The fresh input contract, as JSON.
    input_schema: String,
  )
}

/// Captures after canonical caller read authorization, then retains exact bytes.
///
/// ## Examples
///
/// `capture_for(store, proposal, host_origin, ctx)` cannot read outside read roots.
pub fn capture_for(
  catalogue: store.Store,
  proposal: Proposal,
  origin: record.Origin,
  ctx: tool.Ctx,
) -> Result(record.Candidate, store.Refusal) {
  capture_with(catalogue, proposal, origin, ctx, fn(_, _) {
    Error(store.Unavailable("jailed source capture is unavailable"))
  })
}

/// Authorizes source reach, then borrows the native owned snapshot capability.
///
/// ## Examples
///
/// `capture_with(store,proposal,origin,ctx,snapshot)` never reads source natively.
pub fn capture_with(
  catalogue: store.Store,
  proposal: Proposal,
  origin: record.Origin,
  ctx: tool.Ctx,
  snapshot: fn(tool.Ctx, String) -> Result(archive.Tree, store.Refusal),
) -> Result(record.Candidate, store.Refusal) {
  let access = directory_access.approved(ctx.directory_access, ctx.grants)
  let readable = list.append(access.readable, access.writable)
  use path <- result.try(
    fs.resolve_readable(
      ctx.filesystem,
      ctx.workspace,
      readable,
      proposal.directory,
    )
    |> result.map_error(fn(error) { store.Authority(string.inspect(error)) }),
  )
  use Nil <- result.try(
    case
      list.any(
        [store.root(catalogue), ..ctx.base_policy.protected],
        fn(protected) {
          path == protected
          || string.starts_with(path, protected <> "/")
          || string.starts_with(protected, path <> "/")
        },
      )
    {
      True -> Error(store.Authority("source snapshot overlaps protected state"))
      False -> Ok(Nil)
    },
  )
  use tree <- result.try(snapshot(ctx, path))
  use files <- result.try(
    list.try_map(tree.files, fn(file) {
      bit_array.to_string(file.bytes)
      |> result.map(fn(text) { #(file.path, text) })
      |> result.map_error(fn(_) {
        store.Corrupt(file.path <> " is not UTF8 text")
      })
    }),
  )
  from_files(catalogue, proposal, origin, files)
}

/// Captures through a fixed tar command under the caller's composed jail policy.
///
/// The archive parser runs only after native retirement acknowledges cleanup.
/// A symlink race is therefore constrained by the same kernel read authority as
/// every caller effect, and archive admission still refuses symlink entries.
///
/// ## Examples
///
/// `snapshot_owned(ctx,path,broker,retire)` returns bounded immutable bytes.
pub fn snapshot_owned(
  ctx: tool.Ctx,
  path: String,
  runner: broker.Broker,
  retire: fn() -> Result(Nil, String),
) -> Result(archive.Tree, store.Refusal) {
  let captured = snapshot_call(ctx, path, runner)

  // Retirement owns all paths, including clearance refusal and timeout.
  use Nil <- result.try(
    retire()
    |> result.map_error(fn(reason) { store.CleanupUnconfirmed(reason, retire) }),
  )
  use bytes <- result.try(captured)
  archive.extract(
    bytes,
    archive.Caps(
      max_entries: 256,
      max_file_bytes: 262_144,
      max_total_bytes: store.max_candidate_bytes,
    ),
  )
  |> result.map_error(fn(error) { store.Bounds(archive.describe(error)) })
}

fn snapshot_call(
  ctx: tool.Ctx,
  path: String,
  runner: broker.Broker,
) -> Result(BitArray, store.Refusal) {
  let #(composed, _) =
    sandbox.compose(ctx.base_policy, ctx.base_policy, ctx.grants)
  let readable_base =
    sandbox.SandboxPolicy(
      ..composed,
      readable_roots: list.unique(list.append(
        composed.readable_roots,
        composed.writable_roots,
      )),
    )
  let requested =
    sandbox.SandboxPolicy(
      ..readable_base,
      writable_roots: [],
      network: sandbox.NetworkOff,
      scratch: sandbox.ScratchTmpfs,
      mounts: list.map(composed.mounts, fn(mount) {
        sandbox.Mount(..mount, access: sandbox.MountReadOnly)
      }),
      env_allow: ["PATH"],
      limits: sandbox.Limits(
        cpu_s: 10,
        wall_s: 15,
        mem_bytes: 268_435_456,
        pids: 8,
        fsize_bytes: 2_097_152,
        output_bytes: 2_097_152,
      ),
    )
  let #(readonly, _) = sandbox.compose(readable_base, requested, [])
  let parts = string.split(path, "/") |> list.reverse
  use name <- result.try(
    list.first(parts) |> result.replace_error(store.Bounds("empty source path")),
  )
  let parent = parts |> list.drop(1) |> list.reverse |> string.join("/")
  let events = process.new_subject()
  let #(now, _) = clock.read(ctx.clock)
  let spec =
    broker.CallSpec(
      op_id: ctx.op_id,
      step_id: ctx.step_id <> ":capture",
      base_policy: readonly,
      requirements: readonly,
      grants: [],
      response: broker.RefuseNarrowed,
      demand: case ctx.demand {
        exec.FullEnforcement -> exec.FullEnforcement
        exec.PlatformEnforcement | exec.BestEffort -> exec.PlatformEnforcement
      },
      argv: [
        "/usr/bin/tar",
        "--format=ustar",
        "--exclude=.git",
        "-czf",
        "-",
        "-C",
        parent,
        "--",
        name,
      ],
      env: [#("PATH", "/usr/bin:/bin")],
      cwd: ctx.workspace,
      budget: budget.Budget(max_outstanding: 1, deadline_ms: now + 20_000),
    )
  use call <- result.try(
    tool.broker_runner(broker: runner, waiting: 5000)(spec, events)
    |> result.map_error(fn(reason) { store.Authority(string.inspect(reason)) }),
  )

  // Cancellation precedes retirement when settlement cannot be observed.
  let collected = tool.collect_events(events, waiting: 20_000)
  use collected <- result.try(case collected {
    Ok(value) -> Ok(value)
    Error(Nil) -> {
      call.cancel()
      Error(store.Unavailable("source capture did not settle"))
    }
  })
  case collected.outcome {
    broker.CallFailed(failure) ->
      Error(store.Authority(string.inspect(failure)))
    broker.CallExited(exited) ->
      case
        exited.code == 0
        && exited.signal == 0
        && !exited.timed_out
        && !exited.cancelled
        && !collected.stdout_truncated
        && !collected.stderr_truncated
      {
        True -> Ok(collected.stdout)
        False ->
          Error(store.Bounds(
            "source capture failed or exceeded its resource bound",
          ))
      }
  }
}

/// Admits already captured bytes; native adapters own provenance construction.
///
/// ## Examples
///
/// `from_files(store, proposal, origin, files)` binds tests into the digest.
pub fn from_files(
  catalogue: store.Store,
  proposal: Proposal,
  origin: record.Origin,
  files: List(#(String, String)),
) -> Result(record.Candidate, store.Refusal) {
  use Nil <- result.try(case legal_name(proposal.name) {
    True -> Ok(Nil)
    False -> Error(store.Bounds("candidate name must be a bounded identifier"))
  })
  use Nil <- result.try(admit_files(proposal.kind, files))
  let candidate =
    record.identified(record.Candidate(
      id: record.placeholder(),
      name: proposal.name,
      kind: proposal.kind,
      scope: proposal.scope,
      origin:,
      identity: store.identity(catalogue),
      files:,
      test_entry: proposal.test_entry,
      description: proposal.description,
      input_schema: proposal.input_schema,
    ))
  store.propose(catalogue, candidate)
}

fn admit_files(
  kind: record.Kind,
  files: List(#(String, String)),
) -> Result(Nil, store.Refusal) {
  case kind {
    record.Extension ->
      package.vet_candidate(files, policy.for_seam(policy.ExtensionSeam))
      |> result.replace(Nil)
      |> result.map_error(fn(refusals) {
        store.TestFailed(string.join(
          list.map(refusals, fn(refusal) {
            refusal.0 <> ": " <> package.describe(refusal.1)
          }),
          "; ",
        ))
      })
    record.Program ->
      case
        list.all(files, fn(file) {
          file.0 == "program.gleam" || string.starts_with(file.0, "fixtures/")
        })
      {
        True -> Ok(Nil)
        False ->
          Error(store.Authority(
            "an executable skill contains program.gleam and fresh fixtures",
          ))
      }
    record.Prompt ->
      case
        list.all(files, fn(file) {
          !string.contains(file.0, "..")
          && !string.starts_with(file.0, "/")
          && !string.contains(file.0, "\\")
        })
      {
        True -> Ok(Nil)
        False -> Error(store.Bounds("unsafe candidate path"))
      }
  }
}

fn legal_name(name: String) -> Bool {
  string.length(name) > 0
  && string.length(name) <= 64
  && list.all(string.to_graphemes(name), fn(char) {
    string.contains("abcdefghijklmnopqrstuvwxyz0123456789_-", char)
  })
}
