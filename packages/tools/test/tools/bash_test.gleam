import broker/broker
import broker/escalation
import broker/exec
import broker/policy
import core/json
import core/message
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import gleam/string
import support/fake_broker
import support/memory_fs
import tools/bash
import tools/blob
import tools/tool

const workspace = "/work"

const now = 50_000

fn run_with_script(
  script: List(broker.CallEvent),
  args: json.JsonValue,
) -> #(tool.ToolOutcome, process.Subject(fake_broker.Recorded)) {
  let filesystem = memory_fs.filesystem(memory_fs.start())
  let recorded = process.new_subject()
  let ctx = fake_broker.ctx(workspace:, filesystem:, now:, script:, recorded:)
  let outcome = bash.tool().run(ctx, args)
  #(outcome, recorded)
}

fn command_args(command: String) -> json.JsonValue {
  json.Object([#("command", json.String(command))])
}

fn first_text(outcome: tool.ToolOutcome) -> String {
  let assert [message.ToolResultText(text:, text_signature: _)] =
    outcome.content
    as "expected a single text block"
  text
}

fn recorded_spec(
  recorded: process.Subject(fake_broker.Recorded),
) -> broker.CallSpec {
  let assert Ok(fake_broker.Spec(spec:)) = process.receive(recorded, 1000)
    as "the tool never cleared a call"
  spec
}

// --- happy path ----------------------------------------------------------

pub fn bash_success_test() {
  let #(outcome, _recorded) =
    run_with_script(
      [
        fake_broker.stdout("hello\n"),
        fake_broker.exited(code: 0, stdout_bytes: 6),
      ],
      command_args("echo hello"),
    )
  assert outcome.is_error == False
  assert string.contains(first_text(outcome), "hello")
  let assert Some(json.Object(fields)) = outcome.details
  assert list.key_find(fields, "exit_code") == Ok(json.Int(0))
  assert list.key_find(fields, "signal") == Ok(json.Int(0))
}

pub fn bash_call_spec_shape_test() {
  let #(_outcome, recorded) =
    run_with_script(
      [fake_broker.exited(code: 0, stdout_bytes: 0)],
      command_args("echo hi"),
    )
  let spec = recorded_spec(recorded)
  assert spec.argv == ["bash", "-lc", "echo hi"]
  assert spec.cwd == workspace
  assert spec.step_id == "step-1"
  assert spec.response == broker.RefuseNarrowed
  assert spec.env == [#("PATH", "/usr/bin:/bin")]
  // Requirements: workspace writable, whole fs readable, network off,
  // exactly the passed env names, tmpfs scratch.
  assert spec.requirements.writable_roots == [workspace]
  assert spec.requirements.readable_roots == ["/"]
  assert spec.requirements.network == policy.NetworkOff
  assert spec.requirements.env_allow == ["PATH"]
  assert spec.requirements.scratch == policy.ScratchTmpfs
  // The wall limit mirrors the default timeout.
  assert spec.requirements.limits.wall_s == bash.default_timeout_ms / 1000
  // Budget: one exec slot, deadline = now + timeout.
  assert spec.budget.max_outstanding == 1
  assert spec.budget.deadline_ms == now + bash.default_timeout_ms
}

pub fn bash_asks_for_every_root_the_base_grants_test() {
  // A linked worktree's base grants the git directories outside the
  // workspace; the shell must ask for them too, or the meet's
  // intersection would leave `git commit` unable to take the index lock.
  let filesystem = memory_fs.filesystem(memory_fs.start())
  let recorded = process.new_subject()
  let ctx =
    fake_broker.ctx(
      workspace:,
      filesystem:,
      now:,
      script: [fake_broker.exited(code: 0, stdout_bytes: 0)],
      recorded:,
    )
  let base = fake_broker.base_policy(workspace)
  let widened =
    policy.SandboxPolicy(..base, writable_roots: [
      workspace,
      "/repo/.git/worktrees/work",
      "/repo/.git",
    ])
  let _outcome =
    bash.tool().run(
      tool.Ctx(..ctx, base_policy: widened),
      command_args("git commit"),
    )
  let spec = recorded_spec(recorded)
  assert spec.requirements.writable_roots
    == [workspace, "/repo/.git/worktrees/work", "/repo/.git"]
  let #(composed, narrowings) =
    policy.compose(base: widened, requirements: spec.requirements, grants: [])
  assert narrowings == []
  assert composed.writable_roots == widened.writable_roots
}

pub fn bash_requirements_compose_without_narrowing_test() {
  // The tool's requirements against the fake session base produce no
  // narrowing: it asked for exactly what the session grants.
  let #(_outcome, recorded) =
    run_with_script(
      [fake_broker.exited(code: 0, stdout_bytes: 0)],
      command_args("true"),
    )
  let spec = recorded_spec(recorded)
  let #(_final, narrowings) =
    policy.compose(
      base: spec.base_policy,
      requirements: spec.requirements,
      grants: [],
    )
  assert narrowings == []
}

pub fn bash_closes_stdin_test() {
  let #(_outcome, recorded) =
    run_with_script(
      [fake_broker.exited(code: 0, stdout_bytes: 0)],
      command_args("cat"),
    )
  let assert Ok(fake_broker.Spec(spec: _)) = process.receive(recorded, 1000)
  let assert Ok(fake_broker.Stdin(data: <<>>, eof: True)) =
    process.receive(recorded, 1000)
}

pub fn bash_timeout_arg_sets_deadline_test() {
  let #(_outcome, recorded) =
    run_with_script(
      [fake_broker.exited(code: 0, stdout_bytes: 0)],
      json.Object([
        #("command", json.String("sleep 1")),
        #("timeout_ms", json.Int(5000)),
      ]),
    )
  let spec = recorded_spec(recorded)
  assert spec.budget.deadline_ms == now + 5000
  assert spec.requirements.limits.wall_s == 5
}

pub fn bash_timeout_clamped_to_ceiling_test() {
  let #(_outcome, recorded) =
    run_with_script(
      [fake_broker.exited(code: 0, stdout_bytes: 0)],
      json.Object([
        #("command", json.String("sleep forever")),
        #("timeout_ms", json.Int(86_400_000)),
      ]),
    )
  let spec = recorded_spec(recorded)
  assert spec.budget.deadline_ms == now + bash.max_timeout_ms
}

// --- output shaping ------------------------------------------------------

pub fn bash_nonzero_exit_is_error_test() {
  let #(outcome, _recorded) =
    run_with_script(
      [
        fake_broker.stderr("boom\n"),
        fake_broker.exited(code: 3, stdout_bytes: 0),
      ],
      command_args("false"),
    )
  assert outcome.is_error
  let text = first_text(outcome)
  assert string.contains(text, "exit code 3")
  assert string.contains(text, "boom")
  assert string.contains(text, "stderr")
}

pub fn bash_truncation_noted_test() {
  let #(outcome, _recorded) =
    run_with_script(
      [
        fake_broker.stdout_truncated("partial"),
        fake_broker.exited(code: 0, stdout_bytes: 7),
      ],
      command_args("yes"),
    )
  assert string.contains(first_text(outcome), "stdout truncated")
}

pub fn bash_chunks_concatenate_in_order_test() {
  let #(outcome, _recorded) =
    run_with_script(
      [
        fake_broker.stdout("one "),
        fake_broker.stdout("two "),
        fake_broker.stdout("three"),
        fake_broker.exited(code: 0, stdout_bytes: 13),
      ],
      command_args("echo"),
    )
  assert string.contains(first_text(outcome), "one two three")
}

pub fn bash_no_output_test() {
  let #(outcome, _recorded) =
    run_with_script(
      [fake_broker.exited(code: 0, stdout_bytes: 0)],
      command_args("true"),
    )
  assert first_text(outcome) == "(no output)"
}

pub fn bash_large_output_overflows_to_blob_test() {
  let big = string.repeat("x", blob.overflow_threshold_bytes + 100)
  let #(outcome, _recorded) =
    run_with_script(
      [
        fake_broker.stdout(big),
        fake_broker.exited(
          code: 0,
          stdout_bytes: blob.overflow_threshold_bytes + 100,
        ),
      ],
      command_args("cat big"),
    )
  assert outcome.is_error == False
  let text = first_text(outcome)
  assert string.contains(text, "sha256-")
  assert string.length(text) < blob.overflow_threshold_bytes
  let assert Some(json.Object(fields)) = outcome.details
  let assert Ok(json.Object(blob_fields)) = list.key_find(fields, "blob")
  let assert Ok(json.Int(size)) = list.key_find(blob_fields, "size")
  assert size > blob.overflow_threshold_bytes
}

// --- failure paths -------------------------------------------------------

pub fn bash_call_failed_settles_in_band_test() {
  let #(outcome, _recorded) =
    run_with_script(
      [
        fake_broker.failed(exec.RefusedByHelper(
          code: "bad_policy",
          message: "no",
        )),
      ],
      command_args("true"),
    )
  assert outcome.is_error
  assert string.contains(first_text(outcome), "bad_policy")
}

pub fn bash_policy_refusal_carries_wanted_grants_test() {
  let filesystem = memory_fs.filesystem(memory_fs.start())
  let denial =
    escalation.Denial(
      reason: "tool requirements exceed the session policy",
      source: escalation.PolicyDenial,
      wanted: [policy.GrantNetwork(network: policy.NetworkFull)],
    )
  let ctx =
    fake_broker.refusing_ctx(
      workspace:,
      filesystem:,
      now:,
      refusal: broker.PolicyRefused(denial:),
    )
  let outcome = bash.tool().run(ctx, command_args("curl example.com"))
  assert outcome.is_error
  assert string.contains(first_text(outcome), "policy refused")
  let assert Some(json.Object(fields)) = outcome.details
  assert list.key_find(fields, "error") == Ok(json.String("policy_refused"))
  let assert Ok(json.Array([json.Object(grant_fields)])) =
    list.key_find(fields, "wanted")
  assert list.key_find(grant_fields, "grant") == Ok(json.String("network"))
}

pub fn bash_missing_settlement_cancels_test() {
  // A broker that clears but never settles: exercised with a 1ms
  // timeout by driving collect_events directly (the tool's own window
  // is minutes long).
  let events = process.new_subject()
  assert tool.collect_events(events, waiting: 1) == Error(Nil)
}

pub fn bash_invalid_args_test() {
  let #(outcome, _recorded) =
    run_with_script([], json.Object([#("cmd", json.String("oops"))]))
  assert outcome.is_error
  assert string.contains(first_text(outcome), "command")
}

pub fn bash_bad_timeout_test() {
  let #(outcome, _recorded) =
    run_with_script(
      [],
      json.Object([
        #("command", json.String("true")),
        #("timeout_ms", json.Int(0)),
      ]),
    )
  assert outcome.is_error
}

// --- contract flags ------------------------------------------------------

pub fn bash_flags_test() {
  let bash_tool = bash.tool()
  assert bash_tool.name == "bash"
  assert bash_tool.replay == tool.Never
  assert bash_tool.execution_mode == tool.Exclusive
}

pub fn bash_schema_requires_command_test() {
  let assert json.Object(fields) = bash.tool().schema
  assert list.key_find(fields, "required")
    == Ok(json.Array([json.String("command")]))
}

// --- the session's network posture, followed (the operator's [tools]) -----

// The same rig with a session base of the caller's choosing: what
// `client/serve` composes from an operator's `[tools]` table is a base
// policy, so that is the only thing a tool sees of the decision.
fn run_under_base(
  base: policy.SandboxPolicy,
  script: List(broker.CallEvent),
  args: json.JsonValue,
) -> process.Subject(fake_broker.Recorded) {
  let filesystem = memory_fs.filesystem(memory_fs.start())
  let recorded = process.new_subject()
  let ctx = fake_broker.ctx(workspace:, filesystem:, now:, script:, recorded:)
  let _outcome = bash.tool().run(tool.Ctx(..ctx, base_policy: base), args)
  recorded
}

pub fn bash_asks_for_the_session_bases_network_test() {
  // An operator who opened the jail's network gets a call that asks for
  // it. The requirement is not a preference: `compose` takes the meet,
  // so a hard-coded `NetworkOff` would pin every shell offline however
  // wide the session's own posture was, and the setting would reach
  // nothing.
  let opened =
    policy.SandboxPolicy(
      ..fake_broker.base_policy(workspace),
      network: policy.NetworkFull,
    )
  let recorded =
    run_under_base(
      opened,
      [fake_broker.exited(code: 0, stdout_bytes: 0)],
      command_args("gh pr list"),
    )
  let spec = recorded_spec(recorded)
  assert spec.requirements.network == policy.NetworkFull
  let #(final, narrowings) =
    policy.compose(
      base: spec.base_policy,
      requirements: spec.requirements,
      grants: [],
    )
  assert final.network == policy.NetworkFull
  assert narrowings == []
}

pub fn bash_stays_offline_under_an_offline_base_test() {
  // Following the base never widens anything: the shipped base is
  // offline, so the requirement is offline with it, which is what
  // `bash_call_spec_shape_test` asserts from the other direction.
  let recorded =
    run_under_base(
      fake_broker.base_policy(workspace),
      [fake_broker.exited(code: 0, stdout_bytes: 0)],
      command_args("true"),
    )
  assert recorded_spec(recorded).requirements.network == policy.NetworkOff
}
