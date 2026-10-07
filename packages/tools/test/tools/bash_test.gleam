import broker/broker
import broker/escalation
import broker/exec
import broker/framing
import broker/policy
import core/json
import core/message
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import gleam/string
import simplifile
import support/fake_broker
import support/memory_fs
import tools/bash
import tools/blob
import tools/fs
import tools/job
import tools/tool
import tools/working_directory

const workspace = "/work"

const now = 50_000

fn run_with_script(
  script: List(broker.CallEvent),
  args: json.JsonValue,
) -> #(tool.ToolOutcome, process.Subject(fake_broker.Recorded)) {
  let filesystem = memory_fs.filesystem(memory_fs.start())
  let recorded = process.new_subject()
  let ctx = fake_broker.ctx(workspace:, filesystem:, now:, script:, recorded:)
  let outcome = bash.tool(job.unavailable()).run(ctx, args)
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

// The system prompt carries only the snippet, so the habit of setting a
// directory once has to be stated there and not only in the description. A
// double quote would be escaped in the request body the prompt index is
// asserted against, so the snippet has none.
pub fn the_snippet_points_at_working_directory_and_cwd_test() {
  let assert Some(snippet) = bash.tool(job.unavailable()).prompt_snippet
  assert string.contains(
    snippet,
    "Set a directory once with `working_directory`, or pass `cwd`, rather than repeating a `cd` or a variable prefix on every command.",
  )
  assert !string.contains(snippet, "\"")
}

pub fn bash_call_spec_shape_test() {
  let #(_outcome, recorded) =
    run_with_script(
      [fake_broker.exited(code: 0, stdout_bytes: 0)],
      command_args("echo hi"),
    )
  let spec = recorded_spec(recorded)
  assert spec.argv == ["bash", "-o", "pipefail", "-c", "echo hi"]
  assert spec.cwd == workspace
  assert spec.step_id == "step-1"
  assert spec.response == broker.RefuseNarrowed
  assert spec.env == [#("PATH", "/usr/bin:/bin")]
  // Requirements: workspace writable, the base's own readable reach and
  // mounts asked for rather than restated, network off, exactly the
  // passed env names, tmpfs scratch.
  assert spec.requirements.writable_roots == [workspace]
  assert spec.requirements.readable_roots
    == [workspace, fake_broker.system_region]
  assert spec.requirements.mounts == spec.base_policy.mounts
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
    bash.tool(job.unavailable()).run(
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

// A cancelled run whose payload backgrounded its work exits zero, so the
// exit code cannot say the run was truncated and only `cancelled` can
// (`protocol-change/006`). Both halves of the result are asserted: the
// model reads the line, a program reads the key.
pub fn bash_cancelled_is_reported_test() {
  let #(outcome, _recorded) =
    run_with_script(
      [fake_broker.stdout("partial\n"), fake_broker.cancelled(code: 0)],
      command_args("sleep 30 &"),
    )
  assert string.contains(first_text(outcome), "cancelled")
  let assert Some(json.Object(fields)) = outcome.details
    as "a settled execution always carries details"
  assert list.key_find(fields, "cancelled") == Ok(json.Bool(True))
  assert list.key_find(fields, "timed_out") == Ok(json.Bool(False))
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

// --- the observer -------------------------------------------------------

// A `Ctx` whose observer records every tail it is shown, so a test can
// see what a watching terminal would have seen and when.
fn observing_ctx(
  script: List(broker.CallEvent),
  recorded: process.Subject(fake_broker.Recorded),
  observed: process.Subject(tool.OutputTail),
) -> tool.Ctx {
  let filesystem = memory_fs.filesystem(memory_fs.start())
  let ctx = fake_broker.ctx(workspace:, filesystem:, now:, script:, recorded:)
  tool.Ctx(..ctx, observe_output: fn(observed_tail) {
    process.send(observed, observed_tail)
  })
}

pub fn bash_shows_the_observer_each_chunk_as_it_lands_test() {
  // Two stdout chunks and one on stderr. The observer must be shown the
  // window three times — once per chunk, not once at settlement — and
  // each observation is the *whole* window so far, not the chunk alone:
  // that is what lets a terminal that missed one observation still show
  // the right thing on the next.
  let recorded = process.new_subject()
  let observed = process.new_subject()
  let ctx =
    observing_ctx(
      [
        fake_broker.stdout("compiling core\n"),
        fake_broker.stderr("warning: unused\n"),
        fake_broker.stdout("compiling tools\n"),
        fake_broker.exited(code: 0, stdout_bytes: 31),
      ],
      recorded,
      observed,
    )
  let outcome = bash.tool(job.unavailable()).run(ctx, command_args("make"))
  assert outcome.is_error == False

  let assert Ok(first) = process.receive(observed, 1000)
  assert first
    == tool.OutputTail(
      stream: framing.Stdout,
      tail: "compiling core\n",
      total_bytes: 15,
    )
  let assert Ok(second) = process.receive(observed, 1000)
  assert second
    == tool.OutputTail(
      stream: framing.Stderr,
      tail: "warning: unused\n",
      total_bytes: 16,
    )
  let assert Ok(third) = process.receive(observed, 1000)
  assert third
    == tool.OutputTail(
      stream: framing.Stdout,
      tail: "compiling core\ncompiling tools\n",
      total_bytes: 31,
    )

  // Settlement is not an observation: the durable result carries the
  // whole output, and a fourth tail would be a duplicate of the third.
  assert process.receive(observed, 50) == Error(Nil)
}

pub fn bash_observes_output_before_settlement_test() {
  let filesystem = memory_fs.filesystem(memory_fs.start())
  let recorded = process.new_subject()
  let observed = process.new_subject()
  let gate = process.new_subject()
  let finished = process.new_subject()
  let ctx =
    fake_broker.held_settlement_ctx(
      workspace:,
      filesystem:,
      now:,
      recorded:,
      gate:,
    )
    |> fn(ctx) {
      tool.Ctx(..ctx, observe_output: fn(tail) { process.send(observed, tail) })
    }

  process.spawn_unlinked(fn() {
    process.send(
      finished,
      bash.tool(job.unavailable()).run(ctx, command_args("make")),
    )
  })

  // The call cannot finish until its gate is released, so receiving this tail
  // first proves that the observer is fed during execution.
  let assert Ok(tail) = process.receive(observed, 1000)
    as "the running call must publish its first output chunk"
  assert tail
    == tool.OutputTail(
      stream: framing.Stdout,
      tail: "still running\n",
      total_bytes: 14,
    )
  assert process.receive(finished, 0) == Error(Nil)
    as "the observed call is still waiting for settlement"

  let assert Ok(release) = process.receive(gate, 1000)
    as "the settlement holder must publish its release subject"
  process.send(release, Nil)
  let assert Ok(outcome) = process.receive(finished, 1000)
    as "the released call must settle"
  assert outcome.is_error == False
}

pub fn bash_observer_sees_a_bounded_tail_of_a_long_stream_test() {
  // A stream longer than the window: the observer is shown the *last*
  // `tail_bytes` of it, the count says how much there really was, and
  // the collected result is still the whole output.
  let recorded = process.new_subject()
  let observed = process.new_subject()
  let line = string.repeat("x", 1023) <> "\n"
  let ctx =
    observing_ctx(
      [
        fake_broker.stdout(string.repeat(line, 3)),
        fake_broker.stdout(string.repeat(line, 3)),
        fake_broker.exited(code: 0, stdout_bytes: 6144),
      ],
      recorded,
      observed,
    )
  let outcome = bash.tool(job.unavailable()).run(ctx, command_args("yes"))
  assert outcome.is_error == False
  let assert Ok(_first) = process.receive(observed, 1000)
  let assert Ok(second) = process.receive(observed, 1000)
  assert second.total_bytes == 6144
  assert string.byte_size(second.tail) == tool.tail_bytes
  assert string.ends_with(second.tail, line)
}

pub fn bash_observer_is_shown_no_text_for_binary_output_test() {
  // Bytes that are not UTF-8 have no text to show; the observation still
  // says the stream is moving, and the collected result carries the bytes.
  let recorded = process.new_subject()
  let observed = process.new_subject()
  let ctx =
    observing_ctx(
      [
        broker.CallOutput(
          stream: framing.Stdout,
          data: <<0xff, 0xfe, 0xfd>>,
          total_bytes: 0,
          truncated: False,
        ),
        fake_broker.exited(code: 0, stdout_bytes: 3),
      ],
      recorded,
      observed,
    )
  let _outcome = bash.tool(job.unavailable()).run(ctx, command_args("cat"))
  let assert Ok(seen) = process.receive(observed, 1000)
  assert seen
    == tool.OutputTail(stream: framing.Stdout, tail: "", total_bytes: 3)
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
  let outcome =
    bash.tool(job.unavailable()).run(ctx, command_args("curl example.com"))
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
  let bash_tool = bash.tool(job.unavailable())
  assert bash_tool.name == "bash"
  assert bash_tool.replay == tool.Never
  assert bash_tool.execution_mode == tool.Exclusive
}

pub fn bash_schema_requires_command_test() {
  let assert json.Object(fields) = bash.tool(job.unavailable()).schema
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
  let _outcome =
    bash.tool(job.unavailable()).run(tool.Ctx(..ctx, base_policy: base), args)
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

pub fn explicit_permissions_wait_before_launch_and_are_call_scoped_test() {
  let filesystem = memory_fs.filesystem(memory_fs.start())
  let recorded = process.new_subject()
  let asked = process.new_subject()
  let original =
    fake_broker.ctx(
      workspace:,
      filesystem:,
      now:,
      script: [fake_broker.exited(code: 0, stdout_bytes: 0)],
      recorded:,
    )
  let ctx =
    tool.Ctx(..original, raise_refusal: fn(request: tool.RaisedRefusal) {
      assert remaining_specs(recorded) == 0
      process.send(asked, request.denial.wanted)
      tool.Resume(request.denial.wanted)
    })
  let arguments =
    json.Object([
      #("command", json.String("write /shared/result; fetch resource")),
      #(
        "permissions",
        json.Object([
          #("writable_roots", json.Array([json.String("/shared")])),
          #("network", json.String("full")),
        ]),
      ),
    ])
  assert bash.tool(job.unavailable()).run(ctx, arguments).is_error == False
  let assert Ok(wanted) = process.receive(asked, 1000)
    as "the precise permissions must be shown before launch"
  assert list.contains(wanted, policy.GrantWritableRoot("/shared"))
  assert list.contains(wanted, policy.GrantNetwork(policy.NetworkFull))
  let spec = recorded_spec(recorded)
  assert spec.grants == wanted
  assert remaining_specs(recorded) == 0
  assert bash.tool(job.unavailable()).run(original, arguments).is_error == True
  assert remaining_specs(recorded) == 0
}

pub fn kernel_denial_after_start_does_not_ask_or_replay_test() {
  let filesystem = memory_fs.filesystem(memory_fs.start())
  let recorded = process.new_subject()
  let asked = process.new_subject()
  let ctx =
    fake_broker.ctx(
      workspace:,
      filesystem:,
      now:,
      script: [
        fake_broker.stderr("Operation not permitted"),
        fake_broker.exited(code: 1, stdout_bytes: 0),
      ],
      recorded:,
    )
  let ctx =
    tool.Ctx(..ctx, raise_refusal: fn(request: tool.RaisedRefusal) {
      process.send(asked, request.denial)
      tool.Resume(request.denial.wanted)
    })
  let outcome =
    bash.tool(job.unavailable()).run(
      ctx,
      command_args("write marker; access denied path"),
    )
  assert outcome.is_error == True
  assert string.contains(first_text(outcome), "permissions.writable_roots")
  assert string.contains(first_text(outcome), "before that call runs")
  let _spec = recorded_spec(recorded)
  assert remaining_specs(recorded) == 0
  assert process.receive(asked, 0) == Error(Nil)
}

pub fn a_successful_command_does_not_get_permission_guidance_test() {
  let #(outcome, _recorded) =
    run_with_script(
      [
        fake_broker.stderr("Operation not permitted"),
        fake_broker.exited(code: 0, stdout_bytes: 0),
      ],
      command_args("echo diagnostic 1>&2"),
    )
  assert !string.contains(first_text(outcome), "permissions.writable_roots")
}

pub fn a_read_only_mount_denial_gets_permission_guidance_test() {
  let #(outcome, _recorded) =
    run_with_script(
      [
        fake_broker.stderr("fatal: cannot lock ref: Read-only file system"),
        fake_broker.exited(code: 128, stdout_bytes: 0),
      ],
      command_args("git worktree add /linked"),
    )
  assert string.contains(first_text(outcome), "permissions.writable_roots")
}

pub fn a_git_lock_denial_names_the_reported_metadata_directory_test() {
  let stderr =
    "fatal: cannot lock ref 'refs/heads/sqlite-update': Unable to create "
    <> "'/repo/.git/refs/heads/sqlite-update.lock': Operation not permitted"
  let #(outcome, _recorded) =
    run_with_script(
      [
        fake_broker.stderr(stderr),
        fake_broker.exited(code: 255, stdout_bytes: 0),
      ],
      command_args("cd /repo && git worktree add /linked"),
    )
  assert string.contains(first_text(outcome), "`/repo/.git`")
  assert string.contains(first_text(outcome), "destination directory")
}

fn remaining_specs(recorded: process.Subject(fake_broker.Recorded)) -> Int {
  case process.receive(recorded, 0) {
    Error(Nil) -> 0
    Ok(fake_broker.Spec(_)) -> 1 + remaining_specs(recorded)
    Ok(fake_broker.Stdin(..)) | Ok(fake_broker.Cancelled) ->
      remaining_specs(recorded)
  }
}

fn session_watch_args() -> json.JsonValue {
  json.Object([
    #("command", json.String("substrate watch")),
    #("mode", json.String("background")),
    #("lifetime", json.String("session")),
  ])
}

pub fn session_lifetime_is_authorized_before_the_job_starts_test() {
  let filesystem = memory_fs.filesystem(memory_fs.start())
  let recorded = process.new_subject()
  let asked = process.new_subject()
  let launched = process.new_subject()
  let original =
    fake_broker.ctx(workspace:, filesystem:, now:, script: [], recorded:)
  let ctx =
    tool.Ctx(..original, raise_refusal: fn(request: tool.RaisedRefusal) {
      assert process.receive(launched, 0) == Error(Nil)
      process.send(asked, request.denial.wanted)
      tool.Resume(request.denial.wanted)
    })
  let plane =
    job.Jobs(
      ..job.unavailable(),
      start: fn(ctx: tool.Ctx, _cwd, command, wall, wake) {
        assert command == "substrate watch"
        assert wall == Some(0)
        assert wake == job.QuietUntilDone
        assert list.contains(
          ctx.grants,
          policy.GrantLimit(policy.WallSeconds, 0),
        )
        process.send(launched, Nil)
        Ok(job.Started(id: "session-watch", deadline_ms: 0, wall_ms: 0))
      },
    )
  let outcome = bash.tool(plane).run(ctx, session_watch_args())
  assert !outcome.is_error
  assert string.contains(first_text(outcome), "until the session closes")
  assert process.receive(asked, 1000)
    == Ok([policy.GrantLimit(policy.WallSeconds, 0)])
  assert process.receive(launched, 1000) == Ok(Nil)

  // The approval is for this invocation. Rejecting the same request on a
  // fresh context must leave the jobs plane untouched.
  assert bash.tool(plane).run(original, session_watch_args()).is_error
  assert process.receive(launched, 0) == Error(Nil)
}

pub fn session_lifetime_cannot_disguise_a_finite_or_foreground_timeout_test() {
  let filesystem = memory_fs.filesystem(memory_fs.start())
  let recorded = process.new_subject()
  let ctx =
    fake_broker.ctx(workspace:, filesystem:, now:, script: [], recorded:)
  let plane =
    job.Jobs(..job.unavailable(), start: fn(_ctx, _cwd, _command, _wall, _wake) {
      panic as "invalid arguments must never launch a job"
    })
  let assert json.Object(fields) = session_watch_args()
    as "watch arguments are an object"
  assert bash.tool(plane).run(
    ctx,
    json.Object([#("timeout_ms", json.Int(0)), ..fields]),
  ).is_error
  assert bash.tool(plane).run(
    ctx,
    json.Object([#("timeout_ms", json.Int(1000)), ..fields]),
  ).is_error
  assert bash.tool(plane).run(
    ctx,
    json.Object([
      #("command", json.String("watch")),
      #("lifetime", json.String("session")),
      #("mode", json.String("foreground")),
    ]),
  ).is_error
}

pub fn session_lifetime_is_refused_to_a_subagent_before_any_approval_test() {
  let filesystem = memory_fs.filesystem(memory_fs.start())
  let recorded = process.new_subject()
  let original =
    fake_broker.ctx(workspace:, filesystem:, now:, script: [], recorded:)

  // Neither the approval seam nor the jobs plane may be reached: the point
  // of the refusal is that no operator prompt is raised for a child.
  let ctx =
    tool.Ctx(
      ..original,
      strand: "sub:main/run-tests-1a2b3c4d5e6f7a8b",
      raise_refusal: fn(_request) { panic as "a subagent must not prompt" },
    )
  let plane =
    job.Jobs(..job.unavailable(), start: fn(_ctx, _cwd, _command, _wall, _wake) {
      panic as "a refused lifetime must never launch a job"
    })
  let outcome = bash.tool(plane).run(ctx, session_watch_args())
  assert outcome.is_error
  assert string.contains(
    first_text(outcome),
    "a subagent's jobs end with it, so use the default finite lifetime "
      <> "(omit lifetime)",
  )
}

pub fn finite_lifetime_is_unaffected_for_a_subagent_test() {
  let filesystem = memory_fs.filesystem(memory_fs.start())
  let recorded = process.new_subject()
  let original =
    fake_broker.ctx(workspace:, filesystem:, now:, script: [], recorded:)
  let ctx = tool.Ctx(..original, strand: "sub:main/run-tests-1a2b3c4d5e6f7a8b")
  let plane =
    job.Jobs(..job.unavailable(), start: fn(_ctx, _cwd, command, wall, _wake) {
      assert command == "go test ./..."
      assert wall == option.None
      Ok(job.Started(id: "finite", deadline_ms: 600_000, wall_ms: 600_000))
    })
  let outcome =
    bash.tool(plane).run(
      ctx,
      json.Object([
        #("command", json.String("go test ./...")),
        #("mode", json.String("background")),
        #("lifetime", json.String("finite")),
      ]),
    )
  assert !outcome.is_error
}

pub fn lifetime_description_steers_finishing_work_to_the_default_test() {
  let schema = json.to_string(bash.tool(job.unavailable()).schema)
  assert string.contains(
    schema,
    "Test runs, builds, and anything expected to finish use the default",
  )
  assert string.contains(schema, "always asks the operator for approval")
}

pub fn cwd_reaches_foreground_and_auto_without_changing_workspace_test() {
  let assert Ok(here) = simplifile.current_directory()
    as "locate test workspace"
  let root = here <> "/build/bash-cwd-test"
  let selected = root <> "/review"
  let assert Ok(Nil) = simplifile.create_directory_all(selected)
    as "create selected directory"
  let recorded = process.new_subject()
  let ctx =
    fake_broker.ctx(
      workspace: root,
      filesystem: fs.real_filesystem(),
      now:,
      script: [fake_broker.exited(code: 0, stdout_bytes: 0)],
      recorded:,
    )
  let directory =
    working_directory.Door(read: fn(_) { Ok(selected) }, write: fn(_, _) {
      Ok(Nil)
    })
  let offered = bash.tool_with_directory(job.unavailable(), directory)
  let foreground =
    offered.run(
      ctx,
      json.Object([
        #("command", json.String("pwd")),
        #("mode", json.String("foreground")),
      ]),
    )
  assert !foreground.is_error
  let spec = recorded_spec(recorded)
  assert spec.cwd == selected
  assert spec.base_policy == ctx.base_policy
  let _stdin = process.receive(recorded, 100)
  let attended = process.new_subject()
  let jobs =
    job.Jobs(
      ..job.unavailable(),
      attend: fn(at: tool.Ctx, cwd, _command, _wake) {
        process.send(attended, #(at.workspace, cwd))
        Error(job.NoJobsPlane)
      },
    )
  let automatic =
    bash.tool_with_directory(jobs, directory).run(
      ctx,
      json.Object([
        #("command", json.String("pwd")),
        #("cwd", json.String("..")),
      ]),
    )
  assert !automatic.is_error
  assert process.receive(attended, 100) == Ok(#(root, root))
  assert recorded_spec(recorded).cwd == root
  let assert Ok(Nil) = simplifile.delete_all([root]) as "remove fixture"
}

pub fn background_captures_cwd_before_start_test() {
  let assert Ok(here) = simplifile.current_directory()
    as "locate test workspace"
  let root = here <> "/build/bash-background-cwd-test"
  let selected = root <> "/review"
  let assert Ok(Nil) = simplifile.create_directory_all(selected)
    as "create selected directory"
  let recorded = process.new_subject()
  let ctx =
    fake_broker.ctx(
      workspace: root,
      filesystem: fs.real_filesystem(),
      now:,
      script: [],
      recorded:,
    )
  let directory =
    working_directory.Door(read: fn(_) { Ok(root) }, write: fn(_, _) { Ok(Nil) })
  let started = process.new_subject()
  let jobs =
    job.Jobs(
      ..job.unavailable(),
      start: fn(at: tool.Ctx, cwd, _command, _wall, _wake) {
        process.send(started, #(at.workspace, cwd))
        Ok(job.Started("fixture", 0, 0))
      },
    )
  let outcome =
    bash.tool_with_directory(jobs, directory).run(
      ctx,
      json.Object([
        #("command", json.String("pwd")),
        #("mode", json.String("background")),
        #("cwd", json.String("review")),
      ]),
    )
  assert !outcome.is_error
  assert process.receive(started, 100) == Ok(#(root, selected))
  let missing =
    bash.tool_with_directory(jobs, directory).run(
      ctx,
      json.Object([
        #("command", json.String("pwd")),
        #("cwd", json.String("missing")),
      ]),
    )
  assert missing.is_error
  assert process.receive(started, 0) == Error(Nil)
  let assert Ok(Nil) = simplifile.delete_all([root]) as "remove fixture"
}
