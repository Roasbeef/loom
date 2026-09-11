//// Default development tools through the real broker and sandbox helper.
//// The fixture supplies a workspace and installed host tools, with no custom
//// mounts or per-command PATH/cache repairs. Assertions happen after helper
//// retirement so a failed command cannot leave a live fixture behind.

import broker/broker
import broker/exec
import broker/policy
import broker/token
import client/catalog
import client/internal/ffi_os
import client/serve
import core/clock
import core/ids
import core/json
import core/message
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import provider/secret
import simplifile
import tools/bash
import tools/fs
import tools/grep
import tools/job
import tools/tool

pub fn default_developer_tools_run_without_environment_repairs_test() {
  let assert Ok(here) = simplifile.current_directory()
    as "the fixture needs an absolute workspace"
  let workspace =
    here
    <> "/build/developer-environment-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let external = workspace <> "-external"
  write(external, "outside-workspace-fixture\n")
  let home = serve.tool_home_directory(workspace)
  let temp = serve.tool_tmp_directory(workspace)
  let assert Ok(Nil) = simplifile.create_directory_all(home)
    as "the tool home must exist"
  let assert Ok(Nil) = simplifile.create_directory_all(temp)
    as "the tool temporary directory must exist"

  // Production boot creates the protected store before any read-only tool
  // starts. A read-only jail cannot create the missing mask mount point.
  let assert Ok(Nil) = simplifile.create_directory_all(workspace <> "/.blobs")
    as "the protected store must exist before native search starts"
  write(workspace <> "/go.mod", "module developerfixture\n\ngo 1.26\n")
  write(
    workspace <> "/sum.go",
    "package developerfixture\n"
      <> "/* static int sum(int a, int b) { return a + b; } */\n"
      <> "import \"C\"\n"
      <> "func Sum(a, b int) int { return int(C.sum(C.int(a), C.int(b))) }\n",
  )
  write(
    workspace <> "/sum_test.go",
    "package developerfixture\n"
      <> "import \"testing\"\n"
      <> "func TestSum(t *testing.T) { if Sum(2, 3) != 5 { t.Fatal(\"sum\") } }\n",
  )

  let #(environment, missing) =
    serve.tool_environment(
      workspace,
      None,
      catalog.default_tools(),
      reading: fn(name) { secret.lookup(secret.env(), name) },
    )
  let base =
    serve.base_policy(workspace)
    |> serve.merging_mounts

  // Session assembly admits its owned TMPDIR before tools are wired.
  let base = policy.SandboxPolicy(..base, env_allow: ["PATH", "HOME", "TMPDIR"])
  assert missing == [] as "default tools must need no configured secrets"
  let assert Ok(helper) =
    exec.spawn_helper(exec.SpawnConfig(
      helper_path: here <> "/../sandbox/loom-exec",
      shell_path: "/bin/sh",
      base_policy: base,
      helper_args: [],
      tmp_dir: temp,
      handshake_timeout_ms: 5000,
      cancel_grace_ms: 3000,
      heartbeat_interval_ms: 0,
    ))
    as "build the real helper with make sandbox before running this fixture"
  let wall = clock.from_function(ffi_os.system_time_ms)
  let assert Ok(owner) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: wall,
        checkout: fn() { Ok(helper) },
        checkin: fn(_helper) { Nil },
      ),
    )
    as "the fixture broker must start"
  let #(op_id, _generator) = ids.mint_op(ids.generator(wall, seed: 20_260_910))
  let ctx =
    tool.Ctx(
      workspace:,
      strand: "main",
      op_id:,
      step_id: "developer-tools",
      source_index: 0,
      base_policy: base,
      grants: [],
      demand: exec.BestEffort,
      env: environment,
      clock: wall,
      filesystem: fs.real_filesystem(),
      blob_root: workspace <> "/.blobs",
      clear_call: tool.broker_runner(broker: owner, waiting: 10_000),
      raise_refusal: tool.no_raise(),
      observe_output: tool.ignore_output(),
    )

  // Native search must use the same installed rg as the shell. Its own
  // policy remains read-only and offline even though the shell can write.
  let search =
    grep.tool().run(
      ctx,
      json.Object([
        #("pattern", json.String("func TestSum")),
        #("path", json.String("sum_test.go")),
      ]),
    )
  let shell =
    run(
      ctx,
      "git --version && python3 -c 'print(2 + 3)' "
        <> "&& go test -mod=readonly ./... && go env GOPATH GOMODCACHE",
    )
  let failed_pipeline = run(ctx, "(exit 23) | tail -n 1")
  let outside_read = run(ctx, "cat " <> quoted(external))
  let outside_write = run(ctx, "printf changed > " <> quoted(external))
  let restricted =
    tool.Ctx(
      ..ctx,
      base_policy: policy.SandboxPolicy(
        ..base,
        readable_roots: [workspace],
        network: policy.NetworkOff,
      ),
    )
  let restricted_read = run(restricted, "cat " <> quoted(external))
  broker.stop(owner)
  exec.shutdown(helper)

  assert !search.is_error as rendered(search)
  assert string.contains(rendered(search), "func TestSum")
  assert !shell.is_error as rendered(shell)
  assert string.contains(rendered(shell), "ok")
  assert string.contains(rendered(shell), home <> "/go/pkg/mod")
  assert failed_pipeline.is_error
    as "tail must not erase the tested exit status"
  let assert Some(json.Object(details)) = failed_pipeline.details
    as "the shell must preserve a structured exit status"
  assert list.key_find(details, "exit_code") == Ok(json.Int(23))
  assert !outside_read.is_error as rendered(outside_read)
  assert outside_write.is_error as "host-readable does not grant host writes"
  assert simplifile.read(external) == Ok("outside-workspace-fixture\n")
  assert restricted_read.is_error as "workspace reads exclude external files"
  let assert Ok(Nil) = simplifile.delete_all([workspace, external])
    as "the retired fixture workspace must be removable"
}

fn quoted(path: String) -> String {
  "'" <> string.replace(path, "'", "'\\''") <> "'"
}

fn run(ctx: tool.Ctx, command: String) -> tool.ToolOutcome {
  bash.tool(job.unavailable()).run(
    ctx,
    json.Object([
      #("command", json.String(command)),
      #("timeout_ms", json.Int(120_000)),
    ]),
  )
}

fn write(path: String, contents: String) -> Nil {
  let assert Ok(Nil) = simplifile.write(path, contents)
    as "the fixture source must be writable"
  Nil
}

fn rendered(outcome: tool.ToolOutcome) -> String {
  list.map(outcome.content, fn(block) {
    case block {
      message.ToolResultText(text:, ..) -> text
      message.ToolResultImage(..) -> ""
    }
  })
  |> string.join("\n")
}
