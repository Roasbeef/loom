//// Default-router tests: the shape of a `proc.run` settlement, and what
//// the router does with the parts of a `proc.Command` it does not yet
//// service. Both are the harness's half of a contract whose other half
//// lives in `packages/cap` — the router must produce exactly what
//// `cap/proc` decodes, and must never quietly run something other than
//// what the program asked for.

import broker/broker
import broker/budget
import broker/exec
import broker/framing
import broker/policy
import codemode/identity
import codemode/satellite
import core/clock
import core/ids
import core/msgpack.{type MsgPackValue}
import gleam/list
import gleam/string
import tools/tool

const t = 1_700_000_000_000

fn op_id() -> ids.OpId {
  let generator = ids.generator(clock.fixed(at: t), seed: 17)
  let #(op, _generator) = ids.mint_op(generator)
  op
}

fn request(args: MsgPackValue) -> satellite.CapRequest {
  satellite.CapRequest(
    cap: "proc.run",
    args:,
    identity: identity.run_phase(identity.for_execution(
      op_id: op_id(),
      step_id: "step-1",
      budget: budget.Budget(max_outstanding: 4, deadline_ms: t + 30_000),
    )),
    base_policy: policy.workspace_default("/work"),
    demand: exec.BestEffort,
    env: [#("PATH", "/usr/bin")],
    cwd: "/work",
    ordinal: 0,
  )
}

// The argument map `cap/proc` actually sends: every key present, with
// `NilValue` for the parts of the command that were never set.
fn command_args(
  argv argv: List(String),
  cwd cwd: MsgPackValue,
  env env: MsgPackValue,
  stdin stdin: MsgPackValue,
  timeout timeout: MsgPackValue,
) -> MsgPackValue {
  msgpack.MapValue([
    #(
      msgpack.StringValue("argv"),
      msgpack.ArrayValue(list.map(argv, msgpack.StringValue)),
    ),
    #(msgpack.StringValue("cwd"), cwd),
    #(msgpack.StringValue("env"), env),
    #(msgpack.StringValue("stdin"), stdin),
    #(msgpack.StringValue("timeout_ms"), timeout),
  ])
}

fn plain_args(argv: List(String)) -> MsgPackValue {
  command_args(
    argv:,
    cwd: msgpack.NilValue,
    env: msgpack.MapValue([]),
    stdin: msgpack.NilValue,
    timeout: msgpack.NilValue,
  )
}

fn field(value: MsgPackValue, key: String) -> Result(MsgPackValue, Nil) {
  case value {
    msgpack.MapValue(entries:) ->
      list.find_map(entries, fn(entry) {
        case entry.0 == msgpack.StringValue(key) {
          True -> Ok(entry.1)
          False -> Error(Nil)
        }
      })
    _ -> Error(Nil)
  }
}

fn collected(stdout: BitArray, stderr: BitArray) -> tool.Collected {
  tool.Collected(
    stdout:,
    stderr:,
    stdout_truncated: False,
    stderr_truncated: False,
    outcome: broker.CallExited(result: exec.ExecResult(
      code: 0,
      signal: 0,
      stdout_bytes: 0,
      stderr_bytes: 0,
      stdout_truncated: False,
      stderr_truncated: False,
      enforcement: [],
      degraded: False,
      wall_ms: 1,
      timed_out: False,
      cancelled: False,
    )),
  )
}

// --- the settlement shape -------------------------------------------------

pub fn proc_run_reports_output_as_text_test() {
  // `cap/proc` decodes `stdout` and `stderr` with `wire.string_field`,
  // which refuses a msgpack *binary*. Rendering the bytes as a binary
  // therefore produces a settlement the program cannot read at all — it
  // sees `bad proc.run result` instead of its own output.
  let assert framing.CapOk(value:) =
    satellite.proc_render(collected(<<"out\n":utf8>>, <<"err\n":utf8>>))
  assert field(value, "stdout") == Ok(msgpack.StringValue("out\n"))
  assert field(value, "stderr") == Ok(msgpack.StringValue("err\n"))
}

pub fn proc_run_summarizes_output_that_is_not_text_test() {
  // Jailed output is expected to be UTF-8; anything else is summarized
  // rather than corrupted into a program's `String`.
  let assert framing.CapOk(value:) =
    satellite.proc_render(collected(<<0xff, 0xfe>>, <<>>))
  let assert Ok(msgpack.StringValue(text)) = field(value, "stdout")
  assert string.contains(text, "non-UTF-8")
  assert string.contains(text, "2 bytes")
}

// --- what the router will not silently ignore -----------------------------

// The routed plan for one set of arguments, which every routing test but
// the refusal ones wants.
fn router_plan(args: MsgPackValue) -> satellite.CapPlan {
  let assert Ok(plan) = satellite.default_router(request(args))
    as "the default router must route a plain command"
  plan
}

pub fn a_plain_command_is_routed_test() {
  let assert satellite.ClearedCall(spec:, render: _) =
    router_plan(plain_args(["/bin/echo", "hi"]))
  assert spec.argv == ["/bin/echo", "hi"]
}

pub fn a_command_with_a_working_directory_is_refused_test() {
  // `proc.in_dir` is part of the `cap/proc` builder, and the default
  // router does not yet honour it. Running the command in a *different*
  // directory and saying nothing would be the worst of the three options.
  let assert Error(denial) =
    satellite.default_router(
      request(command_args(
        argv: ["/bin/ls"],
        cwd: msgpack.StringValue("/elsewhere"),
        env: msgpack.MapValue([]),
        stdin: msgpack.NilValue,
        timeout: msgpack.NilValue,
      )),
    )
  assert denial.code == "unsupported_argument"
  assert string.contains(denial.message, "cwd")
}

pub fn a_command_with_stdin_is_refused_test() {
  let assert Error(denial) =
    satellite.default_router(
      request(command_args(
        argv: ["/bin/cat"],
        cwd: msgpack.NilValue,
        env: msgpack.MapValue([]),
        stdin: msgpack.StringValue("payload"),
        timeout: msgpack.NilValue,
      )),
    )
  assert denial.code == "unsupported_argument"
  assert string.contains(denial.message, "stdin")
}

pub fn a_command_with_extra_environment_is_refused_test() {
  let assert Error(denial) =
    satellite.default_router(
      request(command_args(
        argv: ["/bin/env"],
        cwd: msgpack.NilValue,
        env: msgpack.MapValue([
          #(msgpack.StringValue("SECRET"), msgpack.StringValue("1")),
        ]),
        stdin: msgpack.NilValue,
        timeout: msgpack.NilValue,
      )),
    )
  assert denial.code == "unsupported_argument"
  assert string.contains(denial.message, "env")
}

pub fn a_command_with_a_timeout_is_refused_test() {
  let assert Error(denial) =
    satellite.default_router(
      request(command_args(
        argv: ["/bin/sleep"],
        cwd: msgpack.NilValue,
        env: msgpack.MapValue([]),
        stdin: msgpack.NilValue,
        timeout: msgpack.IntValue(1000),
      )),
    )
  assert denial.code == "unsupported_argument"
  assert string.contains(denial.message, "timeout_ms")
}
