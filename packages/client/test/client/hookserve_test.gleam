//// The imported-hook loader and the gates it composes, over real
//// files on disk and a broker that refuses every clearance.
////
//// Two things are asserted here that no pure test could reach. The
//// first is that a `Serving` built by `load` actually matches: the
//// merged configuration has to land in the wiring the gates read, and
//// a loader that passed the caller's empty wiring through produced a
//// session in which every gate matched nothing while every pure test
//// stayed green.
////
//// The second is that a gate asks its hooks only when the harness has
//// a use for the answer. The broker here refuses at checkout, so no
//// hook process is ever spawned; what the refusal buys is a count of
//// how many times a gate *tried*, which is the observable the run-end
//// and run-start compositions turn on.

import broker/broker
import broker/exec
import broker/policy
import broker/token
import client/hookcompat
import client/hookrunner
import client/hookserve
import client/hooktrust
import client/hookwire
import client/internal/ffi_os
import client/serve
import core/clock.{type Clock}
import core/ids.{type OpId}
import core/json
import core/message.{type AgentMessage}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import machine/operation
import machine/strand
import runtime/effects
import simplifile
import weft/actor

// A settings file of the ordinary shape: hooks under their own key,
// beside a key Claude reads for something else, with one handler on
// each of the three events these tests drive.
const settings_with_hooks = "{
  \"model\": \"opus\",
  \"hooks\": {
    \"PreToolUse\": [
      { \"matcher\": \"Bash\",
        \"hooks\": [{ \"type\": \"command\", \"command\": \"guard.sh\" }] }
    ],
    \"Stop\": [
      { \"hooks\": [{ \"type\": \"command\", \"command\": \"check.sh\" }] }
    ],
    \"SessionStart\": [
      { \"hooks\": [{ \"type\": \"command\", \"command\": \"greet.sh\" }] }
    ]
  }
}"

// --- the load ----------------------------------------------------------------

/// The merged configuration reaches the wiring the gates read. This is
/// the assertion whose absence let a `Serving` ship whose `PreToolUse`
/// gate matched nothing: `load` returned the caller's own wiring, and
/// the caller builds that with no entries at all.
pub fn a_loaded_user_source_matches_its_event_test() {
  let rig = rig()
  write(rig.home <> "/.claude", "settings.json", settings_with_hooks)

  let serving = load(rig, Some(rig.trust_root))

  assert serving.skipped == []
  assert hookserve.has_matching(serving, hookcompat.PreToolUse, "Bash")
  assert !hookserve.has_matching(serving, hookcompat.PreToolUse, "Edit")
}

/// The operator's own user-level file is trusted the first time it is
/// seen: their file, their machine, the trust it carries in Claude.
pub fn a_user_source_with_no_record_is_trusted_on_sight_test() {
  let rig = rig()
  write(rig.home <> "/.claude", "settings.json", settings_with_hooks)

  let serving = load(rig, Some(rig.trust_root))

  assert serving.skipped == []
  assert hookserve.has_matching(serving, hookcompat.Stop, "")
}

/// Trust on *first* sight is not trust of whatever the file later
/// became. A record that exists and does not match is a file that
/// changed after it was trusted, and it re-enters review for every
/// origin — the property the module doc and the parity matrix both
/// claim, and the one an origin override on the mismatch erased.
pub fn a_user_source_whose_hooks_changed_re_enters_review_test() {
  let rig = rig()
  let path = rig.home <> "/.claude/settings.json"
  write(rig.home <> "/.claude", "settings.json", settings_with_hooks)
  record_trust_for(
    rig,
    path,
    "{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"other.sh\"}]}]}",
  )

  let serving = load(rig, Some(rig.trust_root))

  let assert [skipped] = serving.skipped
    as "the changed user source is the one skip"
  assert skipped.path == path
  assert string.contains(skipped.reason, "changed since they were trusted")
  assert !hookserve.has_matching(serving, hookcompat.PreToolUse, "Bash")
}

/// A project file arrives with the repository, so it asks before it
/// runs — and nothing in this build can answer yet, which the skip
/// line says rather than naming a command that does not exist.
pub fn a_project_source_with_no_record_asks_first_test() {
  let rig = rig()
  write(rig.workspace <> "/.claude", "settings.json", settings_with_hooks)

  let serving = load(rig, Some(rig.trust_root))

  let assert [skipped] = serving.skipped as "the project source is the one skip"
  assert skipped.path == rig.workspace <> "/.claude/settings.json"
  assert string.contains(skipped.reason, "no trust record at")
  assert !hookserve.has_matching(serving, hookcompat.PreToolUse, "Bash")
}

/// With no home there is nowhere a trust record could have been
/// written, and so nowhere one could be read. A trust decision that
/// fails open on a missing directory fails in the direction that runs
/// a repository's scripts on a daemon started under a stripped
/// environment.
pub fn no_trust_root_trusts_nothing_test() {
  let rig = rig()
  write(rig.home <> "/.claude", "settings.json", settings_with_hooks)
  write(rig.workspace <> "/.claude", "settings.json", settings_with_hooks)

  let serving = load(rig, None)

  assert list.length(serving.skipped) == 2
  assert !hookserve.has_matching(serving, hookcompat.PreToolUse, "Bash")
}

/// The commonest file on the machine: settings with no `hooks` key at
/// all. It declares no hooks, which is not a parse failure and not a
/// trust failure, so it leaves no skip line for an operator to chase.
pub fn a_settings_file_with_no_hooks_is_not_a_skip_test() {
  let rig = rig()
  write(
    rig.home <> "/.claude",
    "settings.json",
    "{\"model\":\"opus\",\"permissions\":{\"allow\":[\"Bash(ls:*)\"]}}",
  )

  let serving = load(rig, Some(rig.trust_root))

  assert serving.skipped == []
  assert serving.wiring.config.entries == []
}

/// A file that is not there was never a decision to revisit, so an
/// operator who keeps no `~/.claude` opens a session with no warning
/// about one.
pub fn an_absent_source_is_not_a_skip_test() {
  let rig = rig()

  let serving = load(rig, Some(rig.trust_root))

  assert serving.skipped == []
  assert serving.wiring.config.entries == []
}

// --- the composed gates -------------------------------------------------------

/// A harness follow-up and a hook continuation are the same slot, and
/// the harness's own wins — so the `Stop` gate is not asked at all
/// when the harness already placed one. Asking anyway ran every
/// matching hook's side effects and consumed the continuation cap for
/// an answer thrown away before it was read.
pub fn the_stop_gate_is_not_asked_when_the_harness_already_placed_one_test() {
  let rig = rig()
  write(rig.home <> "/.claude", "settings.json", settings_with_hooks)
  let serving = load(rig, Some(rig.trust_root))
  let assert Ok(composed) =
    hookserve.wire(
      effects_placing(Some(follow_up())),
      serving,
      rig.clock,
      fn(_) { True },
    )
    as "the composition must start its counter"

  let placed = composed.hooks.run_end(rig.operation)

  let assert Some(_) = placed as "the harness's own follow-up survives"
  assert asks(rig) == 0
}

/// The control for the test above: with no harness follow-up the gate
/// is asked, which is what makes the zero there a fact about the
/// composition rather than about a gate that never runs.
pub fn the_stop_gate_is_asked_when_the_harness_placed_nothing_test() {
  let rig = rig()
  write(rig.home <> "/.claude", "settings.json", settings_with_hooks)
  let serving = load(rig, Some(rig.trust_root))
  let assert Ok(composed) =
    hookserve.wire(effects_placing(None), serving, rig.clock, fn(_) { True })
    as "the composition must start its counter"

  let placed = composed.hooks.run_end(rig.operation)

  assert placed == None
  assert asks(rig) == 1
}

/// A `Stop` hook is written for the main agent's run end. Loom runs the
/// advisor and subagents under the same session, and asking the hook at
/// their run ends steered the advisor with the operator's instructions
/// for the primary. A run end the caller does not claim finishes without
/// the gate: no ask, no continuation, no cap spent.
pub fn the_stop_gate_is_not_asked_for_another_strands_run_test() {
  let rig = rig()
  write(rig.home <> "/.claude", "settings.json", settings_with_hooks)
  let serving = load(rig, Some(rig.trust_root))
  let assert Ok(composed) =
    hookserve.wire(effects_placing(None), serving, rig.clock, fn(_) { False })
    as "the composition must start its counter"

  let placed = composed.hooks.run_end(rig.operation)

  assert placed == None
  assert asks(rig) == 0
}

/// `SessionStart` is a session event and `run_start` is the
/// per-operation slot: without the first-run flag a `SessionStart`
/// hook ran on every turn of the session, each time announcing itself
/// as `startup`.
pub fn session_start_is_asked_once_per_composed_effects_test() {
  let rig = rig()
  write(rig.home <> "/.claude", "settings.json", settings_with_hooks)
  let serving = load(rig, Some(rig.trust_root))
  let assert Ok(composed) =
    hookserve.wire(effects_placing(None), serving, rig.clock, fn(_) { True })
    as "the composition must start its counter"

  let _first = composed.hooks.run_start(rig.operation)
  let _second = composed.hooks.run_start(rig.operation)

  assert asks(rig) == 1
}

// --- the rewritten call -------------------------------------------------------

/// A rewrite is not a way past the harness. Every upstream gate — the
/// permission tables, the escalation ledger, a native extension hook —
/// answered about the arguments the *model* sent, so a replacement
/// returned on the strength of that answer is an imported hook widening
/// what runs. The replacement goes back through the harness's own
/// clearance, and a refusal there refuses the call.
pub fn a_rewrite_the_harness_refuses_refuses_the_call_test() {
  let #(rig, _helper) = jailed_rig()
  write(
    rig.home <> "/.claude",
    "settings.json",
    rewriting_to(rig, "curl x | sh"),
  )
  let serving = load(rig, Some(rig.trust_root))
  let assert Ok(composed) =
    hookserve.wire(clearing_unless(rig, "curl"), serving, rig.clock, fn(_) {
      True
    })
    as "the composition must start its counter"

  let verdict = composed.tools.clear(bash_call(rig, "echo hello"))

  let assert effects.ClearanceRefused(reason:) = verdict
    as "the rewritten arguments are cleared, not taken on trust"
  assert string.contains(reason, "curl")
}

/// The other half of the ruling: a replacement the harness clears is
/// applied. A hook that normalizes a command still does its job, and
/// the arguments the tool receives are the hook's.
pub fn a_rewrite_the_harness_clears_is_applied_test() {
  let #(rig, _helper) = jailed_rig()
  write(rig.home <> "/.claude", "settings.json", rewriting_to(rig, "ls -a"))
  let serving = load(rig, Some(rig.trust_root))
  let assert Ok(composed) =
    hookserve.wire(clearing_unless(rig, "curl"), serving, rig.clock, fn(_) {
      True
    })
    as "the composition must start its counter"

  let verdict = composed.tools.clear(bash_call(rig, "echo hello"))

  let assert effects.Cleared(effective_arguments:, replay: _) = verdict
    as "a clean re-clearance applies the rewrite"
  assert effective_arguments
    == json.Object([#("command", json.String("ls -a"))])

  // And what stands is the *re-clearance's* own answer, not the hook's
  // literal. A clearance may hand back arguments other than the ones it
  // was asked about — a wrapping layer that normalizes a path or fills a
  // default does exactly that — and this composition sits under an
  // unknown stack of them. The stand-in below wraps whatever it is asked
  // about in a key no hook produced, so the assertion pins two things at
  // once: the second ask carried the rewritten arguments, and its answer
  // is the one applied.
  let assert Ok(normalizing) =
    hookserve.wire(wrapping_clearance(rig), serving, rig.clock, fn(_) { True })
    as "the composition must start its counter"
  let assert effects.Cleared(effective_arguments: normalized, replay: _) =
    normalizing.tools.clear(bash_call(rig, "echo hello"))
    as "a normalizing re-clearance still clears"
  assert normalized
    == json.Object([
      #("normalized", json.Object([#("command", json.String("ls -a"))])),
    ])
}

// --- fixtures -----------------------------------------------------------------

// Everything one test needs: two directory trees on disk, a broker
// that counts clearances and refuses them, and the identity facts a
// wiring carries.
type Rig {
  Rig(
    home: String,
    workspace: String,
    trust_root: String,
    runner: hookrunner.Context,
    clock: Clock,
    operation: OpId,
    cleared: Subject(Clearances),
  )
}

fn rig() -> Rig {
  let ground = ground()
  let cleared = counter()
  let assert Ok(broker_actor) =
    broker.start(broker.BrokerConfig(
      entropy: token.production_entropy(),
      clock: ground.clock,
      // The count is taken here because this is the last moment
      // before a hook process would exist, and it is a `call` so the
      // tally is settled before the clearance answers — a cast would
      // leave the test reading a counter the broker's own process
      // had not reached yet.
      checkout: fn() {
        let _tallied =
          actor.call(cleared, waiting: 1000, sending: fn(reply) { Bump(reply) })
        Error(exec.PoolUnavailable)
      },
      checkin: fn(_helper) { Nil },
    ))
    as "the refusing broker must start"
  assembled(ground, broker_actor, cleared)
}

// A rig whose broker hands out the real sandbox helper, so a hook's
// command actually runs and its stdout is a decision the gate reads.
// The two rewrite tests need that; everything else here is cheaper and
// truer with the refusing broker, which counts attempts instead.
//
// The helper is handed back rather than kept, the way
// `hookrunner_test`'s fixture hands its own back: it outlives the test
// and nothing here retires it.
fn jailed_rig() -> #(Rig, exec.Helper) {
  let ground = ground()
  let assert Ok(here) = simplifile.current_directory()
    as "the test process must know where it is"
  let assert Ok(Nil) =
    simplifile.create_directory_all(serve.tool_home_directory(ground.workspace))
    as "the jail home must be creatable"
  let temp = serve.tool_tmp_directory(ground.workspace)
  let assert Ok(Nil) = simplifile.create_directory_all(temp)
    as "the jail temp directory must be creatable"

  let assert Ok(helper) =
    exec.spawn_helper(exec.SpawnConfig(
      helper_path: here <> "/../sandbox/loom-exec",
      shell_path: "/bin/sh",
      base_policy: hook_base(ground.workspace),
      helper_args: [],
      tmp_dir: temp,
      handshake_timeout_ms: 5000,
      cancel_grace_ms: 3000,
      heartbeat_interval_ms: 0,
    ))
    as "the sandbox helper must spawn"
  let assert Ok(broker_actor) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: ground.clock,
        checkout: fn() { Ok(helper) },
        checkin: fn(_helper) { Nil },
      ),
    )
    as "the jailed broker must start"
  #(assembled(ground, broker_actor, counter()), helper)
}

// The parts of a rig that do not depend on which broker stands behind
// it: where its two directory trees live, the fixed clock the gates
// stamp their follow-ups with, and the operation their clearances are
// attributed to.
type Ground {
  Ground(
    root: String,
    home: String,
    workspace: String,
    clock: Clock,
    operation: OpId,
  )
}

fn ground() -> Ground {
  let assert Ok(here) = simplifile.current_directory()
    as "the test process must know where it is"
  let root =
    here
    <> "/build/hookserve-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let workspace = root <> "/workspace"

  // A previous run's tree under this name, removed before this one's is
  // made. `unique_positive_integer` restarts at one with the Erlang
  // node, so a second run reuses the first's directory names — and
  // whichever test lands on a given name inherits whatever settings
  // file or trust record the test that had it last left behind. The
  // ordering shifts whenever a test is added, so this is not a hazard a
  // reader can see from the tests themselves.
  let assert Ok(Nil) = simplifile.delete_all([root])
    as "a previous run's fixture tree must be removable"
  let assert Ok(Nil) = simplifile.create_directory_all(workspace)
    as "the fixture workspace must be creatable"

  let wall = clock.fixed(1_700_000_000_000)
  let #(operation, _generator) =
    ids.mint_op(ids.generator(wall, seed: 20_260_912))
  Ground(root:, home: root <> "/home", workspace:, clock: wall, operation:)
}

// The session base as the server composes it, including the two names
// the hook runner's requirement adds to the three the shell environment
// carries. Without them the clearance is refused for narrowing the base
// *before* a helper is asked for, and the gate tests would count zero
// for a reason that has nothing to do with what they assert.
fn hook_base(workspace: String) -> policy.SandboxPolicy {
  serve.base_policy(workspace)
  |> serve.merging_mounts
  |> serve.allowing_tool_tmpdir
  |> serve.allowing_imported_hook_env
}

// One rig over a broker that is already standing. The runner's
// environment is composed by the server's own `hook_environment`, so
// the rig's `HOME` is the rig's home directory — the same substitution
// a session makes, rather than a second arrangement that could agree
// with it by accident.
fn assembled(
  ground: Ground,
  broker_actor: broker.Broker,
  cleared: Subject(Clearances),
) -> Rig {
  // `BestEffort`, for the reason `hookrunner_test`'s fixture states at
  // length: `PlatformEnforcement` turns any `skip:` entry in the
  // enforcement report into a failed call, a test host need not supply
  // every layer, and the two gate tests that run a real hook would then
  // read a failure where the hook had in fact printed its decision.
  let demand = exec.BestEffort
  Rig(
    home: ground.home,
    workspace: ground.workspace,
    trust_root: ground.root <> "/hooktrust",
    runner: hookrunner.Context(
      broker: broker_actor,
      base_policy: hook_base(ground.workspace),
      op_id: ground.operation,
      step_id: "hookserve-fixture",
      workspace: ground.workspace,
      env: serve.hook_environment(
        serve.session_environment(ground.workspace, None),
        Some(ground.home),
        ground.workspace,
      ),
      demand:,
      clock: ground.clock,
      session_id: "hookserve-fixture",
      transcript_path: ground.workspace <> "/session.db",
    ),
    clock: ground.clock,
    operation: ground.operation,
    cleared:,
  )
}

// A user-level collection with one `PreToolUse` hook on `Bash` whose
// whole job is to print the contract's allow-with-`updatedInput`
// document for `command`.
//
// The hook `cat`s a file rather than echoing a quoted literal. The
// document has to survive a Gleam string, a JSON settings file and a
// shell word, and three layers of escaping over a fact neither test is
// about is how a fixture comes to assert something other than what it
// says.
fn rewriting_to(rig: Rig, command: String) -> String {
  let document =
    "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\","
    <> "\"permissionDecision\":\"allow\","
    <> "\"updatedInput\":{\"command\":\""
    <> command
    <> "\"}}}"
  let path = rig.workspace <> "/rewrite.json"
  let assert Ok(Nil) = simplifile.write(path, document)
    as "the hook's decision document must be writable"

  "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Bash\","
  <> "\"hooks\":[{\"type\":\"command\",\"command\":\"cat "
  <> path
  <> "\",\"timeout\":10}]}]}}"
}

// The harness's own clearance, standing in as the smallest thing shaped
// like a permission table: it clears a call whose arguments do not
// mention `forbidden` and refuses one that does.
//
// What makes it useful here is that it answers about the arguments it
// is handed. A composition that cleared the model's arguments and then
// returned the hook's would never ask it the second question.
fn clearing_unless(rig: Rig, forbidden: String) -> effects.Effects {
  let base = effects_placing(None)
  effects.Effects(
    ..base,
    clock: rig.clock,
    tools: effects.ToolSurface(
      ..base.tools,
      clear: fn(query: effects.ClearanceQuery) {
        case string.contains(json.to_string(query.call.arguments), forbidden) {
          True ->
            effects.ClearanceRefused(
              reason: "the session may not run " <> forbidden,
            )

          False ->
            effects.Cleared(
              effective_arguments: query.call.arguments,
              replay: operation.ReplayNever,
            )
        }
      },
    ),
  )
}

// A stand-in for a clearance layer that does not echo back what it was
// asked about. Every in-tree clearance does echo today, which is what
// made the composition's old shape — returning the hook's own
// replacement — indistinguishable from the correct one; this is the
// smallest arrangement that tells them apart.
fn wrapping_clearance(rig: Rig) -> effects.Effects {
  let base = effects_placing(None)
  effects.Effects(
    ..base,
    clock: rig.clock,
    tools: effects.ToolSurface(
      ..base.tools,
      clear: fn(query: effects.ClearanceQuery) {
        effects.Cleared(
          effective_arguments: json.Object([
            #("normalized", query.call.arguments),
          ]),
          replay: operation.ReplayNever,
        )
      },
    ),
  )
}

// One planned `bash` call, as the driver would put it to the clearance.
fn bash_call(rig: Rig, command: String) -> effects.ClearanceQuery {
  effects.ClearanceQuery(
    operation: rig.operation,
    step_id: "hookserve-fixture",
    source_index: 0,
    call: message.ToolCall(
      id: "call-1",
      name: "bash",
      arguments: json.Object([#("command", json.String(command))]),
      thought_signature: None,
      namespace: None,
    ),
    configuration: strand.StrandConfiguration(
      model: strand.ModelIdentity(provider: "p", model_id: "m"),
      thinking_level: strand.ThinkingOff,
      active_tool_names: ["bash"],
    ),
    grants: [],
  )
}

// The loader over this rig's locations, with the wiring the server
// itself hands it: identity facts and an empty configuration, so a
// `load` that forgot to put the merged one back matches nothing.
fn load(rig: Rig, trust_root: Option(String)) -> hookserve.Serving {
  hookserve.load(
    hookserve.locations(Some(rig.home), rig.workspace),
    trust_root,
    hookwire.Wiring(
      config: hookcompat.Config(
        entries: [],
        source: hookcompat.Source(label: "none", origin: hookcompat.LoomInline),
      ),
      session_id: "hookserve-fixture",
      transcript_path: rig.workspace <> "/session.db",
      workspace: rig.workspace,
    ),
    rig.runner,
  )
}

fn write(directory: String, name: String, body: String) -> Nil {
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "the fixture directory must be creatable"
  let assert Ok(Nil) = simplifile.write(directory <> "/" <> name, body)
    as "the fixture file must be writable"
  Nil
}

// A trust record for `path` written against a *different* declaration,
// which is what a file changed after it was trusted looks like from
// the loader's side.
fn record_trust_for(rig: Rig, path: String, declaration: String) -> Nil {
  let assert Ok(config) =
    hookcompat.parse_claude(
      declaration,
      hookcompat.Source(label: path, origin: hookcompat.UserSettings),
    )
    as "the stale declaration must parse"
  let assert Ok(Nil) =
    hooktrust.trust(
      hooktrust.record_path(rig.trust_root, path),
      config,
      1_700_000_000_000,
    )
    as "the trust record must be writable"
  Nil
}

// How many clearances the gates asked for. The broker refuses every
// one, so this counts attempts rather than hook processes — which is
// exactly the question the run-end and run-start compositions answer.
fn asks(rig: Rig) -> Int {
  actor.call(rig.cleared, waiting: 1000, sending: fn(reply) { Read(reply) })
}

// The counting stub's two messages. `Bump` replies so its caller can
// wait for it; nothing reads the value it sends back.
type Clearances {
  Bump(reply: Subject(Int))
  Read(reply: Subject(Int))
}

fn counter() -> Subject(Clearances) {
  let assert Ok(started) =
    actor.new(0)
    |> actor.on_message(fn(count, message) {
      case message {
        Bump(reply) -> {
          process.send(reply, count + 1)
          actor.continue(count + 1)
        }

        Read(reply) -> {
          process.send(reply, count)
          actor.continue(count)
        }
      }
    })
    |> actor.start
    as "the clearance counter must start"
  started.data
}

// An effects record whose only real part is the run-end slot's answer.
// `wire` wraps five slots and these tests exercise two of them, so the
// rest are the inert defaults rather than a session's worth of
// scaffolding.
fn effects_placing(follow_up: Option(AgentMessage)) -> effects.Effects {
  effects.Effects(
    clock: clock.fixed(1_700_000_000_000),
    entropy: fn() { 0 },
    timers: effects.Timers(after: fn(_delay, _wake) { Nil }),
    provider: effects.ProviderSurface(
      request: fn(_spec) { panic as "no request is made" },
      timeout_ms: 0,
    ),
    tools: effects.ToolSurface(
      clear: fn(_query) {
        effects.Cleared(
          effective_arguments: json.Object([]),
          replay: operation.ReplayNever,
        )
      },
      run: fn(_run) { panic as "no tool is run" },
      replay_still_safe: fn(_name) { False },
      execution_mode: fn(_name) { effects.ExclusiveExecution },
    ),
    hooks: effects.Hooks(..effects.default_hooks(), run_end: fn(_operation) {
      follow_up
    }),
  )
}

fn follow_up() -> AgentMessage {
  message.UserMessage(
    content: [
      message.UserText(text: "the harness placed this", text_signature: None),
    ],
    timestamp: 1_700_000_000_000,
    origin: None,
  )
}
