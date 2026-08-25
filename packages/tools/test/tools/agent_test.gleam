//// The `agent_*` tool shells: what they decode, what they refuse, and —
//// the load-bearing one — where the caller identity they hand the Agency
//// comes from.
////
//// The Agency here is a fake built out of closures that echo their
//// arguments back through their results, so an assertion on the result
//// is an assertion on what the tool passed. That is deliberate: the
//// thing worth pinning is not that a spawn returns a handle but that the
//// `Caller` reaching the seam is the driver's `Ctx` and never anything
//// in the model's arguments.

import broker/broker.{type CallEvent, type CallSpec, type Refusal}
import broker/exec
import broker/policy
import core/clock
import core/ids.{type OpId}
import core/json
import core/message
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None}
import gleam/string
import tools/agent
import tools/tool.{type Ctx}

// --- fixtures --------------------------------------------------------------

fn an_op(seed: Int) -> OpId {
  let #(op, _generator) = ids.mint_op(ids.generator(clock.fixed(at: 0), seed:))
  op
}

fn ctx_for(strand: String, step: String, index: Int) -> Ctx {
  let workspace = "/nonexistent/loom-agent-test"
  tool.Ctx(
    workspace:,
    strand:,
    op_id: an_op(11),
    step_id: step,
    source_index: index,
    base_policy: policy.workspace_default(workspace),
    grants: [],
    demand: exec.FullEnforcement,
    env: [],
    clock: clock.fixed(at: 1000),
    filesystem: dead_filesystem(),
    blob_root: workspace <> "/.blobs",
    clear_call: dead_broker,
  )
}

fn dead_broker(
  _spec: CallSpec,
  _events: Subject(CallEvent),
) -> Result(tool.RunningCall, Refusal) {
  Error(broker.BrokerUnavailable)
}

fn dead_filesystem() -> tool.FileSystem {
  tool.FileSystem(
    read: fn(path) { Error(tool.FsNotFound(path:)) },
    write: fn(path, _bytes) { Error(tool.FsNotFound(path:)) },
    create_directory_all: fn(path) { Error(tool.FsNotFound(path:)) },
    is_file: fn(_path) { Ok(False) },
    read_link: fn(_path) { Ok(tool.LinkMissing) },
  )
}

// An Agency whose every answer is derived from what it was handed, so a
// result assertion is an argument assertion.
fn echoing_agency() -> agent.Agency {
  agent.Agency(
    spawn: fn(caller, request) {
      Ok(agent.Spawned(
        handle: agent.Handle(
          strand: caller.strand <> "|" <> request.purpose,
          operation: caller.operation,
        ),
        strand: caller.strand
          <> "|"
          <> provenance_text(request.context)
          <> "|"
          <> bool_text(request.detach),
        tools: option.unwrap(request.tools, ["inherited"]),
      ))
    },
    send: fn(caller, to, text) {
      Ok(agent.Started(operation: caller.operation))
      |> echo_send(caller, to, text)
    },
    wait: fn(caller, handles, within_ms) {
      Ok(
        list.map(handles, fn(handle) {
          agent.Ready(
            handle:,
            outcome: agent.Completed,
            report: caller.strand <> "@" <> string.inspect(within_ms),
            notes: [],
          )
        }),
      )
    },
    note: fn(caller, key, _value) {
      case caller.strand == "main" && key != "" {
        True -> Ok(Nil)
        False -> Error(agent.InvalidArgument(reason: key))
      }
    },
    notes: fn(caller, prefix) {
      Ok([
        #(
          "seen/" <> caller.strand,
          json.String(option.unwrap(prefix, "<none>")),
        ),
      ])
    },
    roster: fn(caller) {
      Ok([
        agent.Peer(
          strand: caller.strand,
          relation: agent.ParentOf,
          handle: None,
          outcome: None,
          tools: [],
        ),
      ])
    },
    max_wait_ms: 30_000,
  )
}

// The fake's send arm ignores its echo helper's arguments; it exists so
// the closure keeps the same shape as the real one.
fn echo_send(
  result: Result(agent.Delivery, agent.Refusal),
  _caller: agent.Caller,
  _to: String,
  _text: String,
) -> Result(agent.Delivery, agent.Refusal) {
  result
}

fn provenance_text(context: agent.Provenance) -> String {
  case context {
    agent.Fresh -> "fresh"
    agent.MyConversation -> "mine"
  }
}

fn bool_text(flag: Bool) -> String {
  case flag {
    True -> "detached"
    False -> "attached"
  }
}

fn refusing_agency(refusal: agent.Refusal) -> agent.Agency {
  agent.Agency(
    spawn: fn(_caller, _request) { Error(refusal) },
    send: fn(_caller, _to, _text) { Error(refusal) },
    wait: fn(_caller, _handles, _within) { Error(refusal) },
    note: fn(_caller, _key, _value) { Error(refusal) },
    notes: fn(_caller, _prefix) { Error(refusal) },
    roster: fn(_caller) { Error(refusal) },
    max_wait_ms: 30_000,
  )
}

fn run(name: String, ctx: Ctx, agency: agent.Agency, args: json.JsonValue) {
  let registry = tool.registry(agent.tools(agency))
  tool.dispatch(registry, ctx, name, args)
}

fn text_of(outcome: tool.ToolOutcome) -> String {
  outcome.content
  |> list.filter_map(fn(block) {
    case block {
      message.ToolResultText(text:, ..) -> Ok(text)
      _ -> Error(Nil)
    }
  })
  |> string.join("\n")
}

// --- the family ------------------------------------------------------------

pub fn registry_holds_exactly_the_family_test() {
  let registry = tool.registry(agent.tools(echoing_agency()))
  assert tool.names(registry) == agent.tool_names
}

pub fn every_tool_asks_the_broker_for_nothing_test() {
  // The agent tools touch no filesystem and spawn no process, so their
  // requirements must compose with any session base rather than asking
  // it to widen.
  list.each(agent.tools(echoing_agency()), fn(registered) {
    let wanted = registered.requirements("/work")
    assert wanted.writable_roots == []
    assert wanted.readable_roots == []
    assert wanted.env_allow == []
    assert wanted.network == policy.NetworkOff
  })
}

pub fn replay_and_mode_declarations_test() {
  let registry = tool.registry(agent.tools(echoing_agency()))
  let assert Ok(spawn) = tool.lookup(registry, "agent_spawn")
  let assert Ok(send) = tool.lookup(registry, "agent_send")
  let assert Ok(wait) = tool.lookup(registry, "agent_wait")
  // A send mints a fresh entry id per admission, so a replay would
  // deliver it twice.
  assert send.replay == tool.Never
  // A spawn's name derives from persisted coordinates, so a replay
  // reconciles onto the same child rather than minting a second one.
  assert spawn.replay == tool.Safe
  assert wait.replay == tool.Safe
  assert spawn.execution_mode == tool.Exclusive
  assert wait.execution_mode == tool.Concurrent
}

// --- identity --------------------------------------------------------------

pub fn the_caller_comes_from_the_context_not_the_arguments_test() {
  // A model that names another strand in its arguments must not become
  // that strand: `Caller` is built from `Ctx` alone.
  let ctx = ctx_for("sub:main/worker-1", "turn-4:tools", 2)
  let args =
    json.Object([
      #("purpose", json.String("review")),
      #("brief", json.String("look at auth")),
      #("strand", json.String("main")),
      #("caller", json.String("main")),
    ])
  let outcome = run("agent_spawn", ctx, echoing_agency(), args)
  assert !outcome.is_error
  assert string.contains(text_of(outcome), "sub:main/worker-1|")
  assert !string.contains(text_of(outcome), "|main|")
}

pub fn the_caller_carries_the_replay_coordinates_test() {
  // The child's name derives from `{operation, step, source index}`, so
  // all three must reach the seam or a replayed spawn would mint a
  // second child.
  let ctx = ctx_for("main", "turn-9:tools", 3)
  let caller = agent.caller(ctx)
  assert caller.strand == "main"
  assert caller.operation == ctx.op_id
  assert caller.step_id == "turn-9:tools"
  assert caller.source_index == 3
}

// --- slugs and handles -----------------------------------------------------

pub fn slug_keeps_names_addressable_test() {
  assert agent.slug("Review the auth code") == Ok("review-the-auth-code")
  // `/` and `#` are what a name and a handle are split on; neither may
  // survive into a slug.
  assert agent.slug("main/../#") == Ok("main")
  assert agent.slug("a#b/c") == Ok("a-b-c")
  assert agent.slug("///") == Error(Nil)
  assert agent.slug("") == Error(Nil)
}

pub fn slug_is_capped_test() {
  let assert Ok(slugged) =
    agent.slug(string.repeat("verylongpurpose", times: 20))
  assert string.length(slugged) <= agent.max_slug_length
}

pub fn handles_round_trip_test() {
  let handle = agent.Handle(strand: "sub:main/reviewer-1", operation: an_op(3))
  assert agent.parse_handle(agent.handle_to_string(handle)) == Ok(handle)
}

pub fn mangled_handles_refuse_rather_than_crash_test() {
  list.each(
    ["", "#", "nothing", "sub:main/x#", "#op_nope", "sub:main/x#not-an-op"],
    fn(text) {
      let assert Error(agent.MalformedHandle(..)) = agent.parse_handle(text)
    },
  )
}

pub fn a_mangled_handle_settles_in_band_test() {
  let outcome =
    run(
      "agent_wait",
      ctx_for("main", "turn-1:tools", 0),
      echoing_agency(),
      json.Object([#("handles", json.Array([json.String("garbage")]))]),
    )
  assert outcome.is_error
  assert string.contains(text_of(outcome), "is not a handle")
}

// --- agent_wait ------------------------------------------------------------

pub fn wait_takes_every_handle_in_one_call_test() {
  // The unit of waiting is the call, not the handle: one budget covers
  // the whole set, and the answers come back in argument order.
  let first = agent.Handle(strand: "sub:a", operation: an_op(5))
  let second = agent.Handle(strand: "sub:b", operation: an_op(6))
  let outcome =
    run(
      "agent_wait",
      ctx_for("main", "turn-1:tools", 0),
      echoing_agency(),
      json.Object([
        #(
          "handles",
          json.Array([
            json.String(agent.handle_to_string(first)),
            json.String(agent.handle_to_string(second)),
          ]),
        ),
        #("within_ms", json.Int(1234)),
      ]),
    )
  assert !outcome.is_error
  let rendered = text_of(outcome)
  assert string.contains(rendered, "sub:a")
  assert string.contains(rendered, "sub:b")
  // The budget reaches the seam once, for the set.
  assert string.contains(rendered, "1234")
}

pub fn wait_defaults_its_budget_to_the_published_ceiling_test() {
  let handle = agent.Handle(strand: "sub:a", operation: an_op(5))
  let outcome =
    run(
      "agent_wait",
      ctx_for("main", "turn-1:tools", 0),
      echoing_agency(),
      json.Object([
        #("handles", json.Array([json.String(agent.handle_to_string(handle))])),
      ]),
    )
  assert string.contains(text_of(outcome), "30000")
}

pub fn wait_bounds_the_handle_list_test() {
  let handle =
    json.String(
      agent.handle_to_string(agent.Handle(strand: "sub:a", operation: an_op(5))),
    )
  let too_many =
    json.Object([
      #(
        "handles",
        json.Array(list.repeat(handle, times: agent.max_handles + 1)),
      ),
    ])
  let outcome =
    run("agent_wait", ctx_for("main", "t", 0), echoing_agency(), too_many)
  assert outcome.is_error
  assert string.contains(text_of(outcome), "at most")
}

pub fn wait_refuses_an_empty_set_test() {
  let outcome =
    run(
      "agent_wait",
      ctx_for("main", "t", 0),
      echoing_agency(),
      json.Object([#("handles", json.Array([]))]),
    )
  assert outcome.is_error
}

pub fn a_pending_wait_is_not_an_error_test() {
  // A timeout is an answer, not a failure; marking it as one pushes a
  // model into retry panic.
  let handle = agent.Handle(strand: "sub:a", operation: an_op(5))
  let pending =
    agent.Agency(..echoing_agency(), wait: fn(_caller, handles, _within) {
      Ok(list.map(handles, fn(handle) { agent.Pending(handle:, waited_ms: 9) }))
    })
  let outcome =
    run(
      "agent_wait",
      ctx_for("main", "t", 0),
      pending,
      json.Object([
        #("handles", json.Array([json.String(agent.handle_to_string(handle))])),
      ]),
    )
  assert !outcome.is_error
  assert string.contains(text_of(outcome), "still working")
}

// --- agent_spawn arguments -------------------------------------------------

pub fn spawn_defaults_are_fresh_and_attached_test() {
  let outcome =
    run(
      "agent_spawn",
      ctx_for("main", "t", 0),
      echoing_agency(),
      json.Object([
        #("purpose", json.String("review")),
        #("brief", json.String("read it")),
      ]),
    )
  assert string.contains(text_of(outcome), "fresh")
  assert string.contains(text_of(outcome), "attached")
}

pub fn spawn_refuses_an_unknown_context_test() {
  let outcome =
    run(
      "agent_spawn",
      ctx_for("main", "t", 0),
      echoing_agency(),
      json.Object([
        #("purpose", json.String("review")),
        #("brief", json.String("read it")),
        #("context", json.String("everything")),
      ]),
    )
  assert outcome.is_error
  assert string.contains(text_of(outcome), "fresh or my_conversation")
}

pub fn spawn_requires_a_brief_test() {
  let outcome =
    run(
      "agent_spawn",
      ctx_for("main", "t", 0),
      echoing_agency(),
      json.Object([#("purpose", json.String("review"))]),
    )
  assert outcome.is_error
}

// --- refusals --------------------------------------------------------------

pub fn every_refusal_settles_in_band_test() {
  // Nothing here crashes the strand: a refused Agency call is a
  // structured `is_error` result the model can read.
  let agency = refusing_agency(agent.AgencyUnavailable)
  let ctx = ctx_for("main", "t", 0)
  let calls = [
    #(
      "agent_spawn",
      json.Object([
        #("purpose", json.String("p")),
        #("brief", json.String("b")),
      ]),
    ),
    #(
      "agent_send",
      json.Object([
        #("to", json.String("main")),
        #("message", json.String("hi")),
      ]),
    ),
    #(
      "agent_wait",
      json.Object([
        #(
          "handles",
          json.Array([
            json.String(
              agent.handle_to_string(agent.Handle(
                strand: "sub:a",
                operation: an_op(1),
              )),
            ),
          ]),
        ),
      ]),
    ),
    #(
      "agent_note",
      json.Object([#("key", json.String("k")), #("value", json.Int(1))]),
    ),
    #("agent_notes", json.Object([])),
    #("agent_roster", json.Object([])),
  ]
  list.each(calls, fn(call) {
    let outcome = run(call.0, ctx, agency, call.1)
    assert outcome.is_error
    assert string.contains(text_of(outcome), "no messaging plane")
  })
}

pub fn refusals_describe_themselves_test() {
  assert string.contains(
    agent.describe(agent.NotADescendant(strand: "sub:x")),
    "only on your own descendants",
  )
  assert string.contains(
    agent.describe(agent.ParentRunEnded(strand: "main")),
    "was not delivered",
  )
  assert string.contains(
    agent.describe(agent.UnknownTool(name: "bash")),
    "do not hold yourself",
  )
  assert agent.refusal_outcome(agent.AgencyUnavailable).is_error
}

// --- the blackboard shells -------------------------------------------------

pub fn note_reports_the_full_key_it_wrote_test() {
  let outcome =
    run(
      "agent_note",
      ctx_for("main", "t", 0),
      echoing_agency(),
      json.Object([
        #("key", json.String("findings/auth")),
        #("value", json.String("looks fine")),
      ]),
    )
  assert !outcome.is_error
  assert string.contains(text_of(outcome), "agent/main/findings/auth")
}

pub fn note_requires_a_value_test() {
  let outcome =
    run(
      "agent_note",
      ctx_for("main", "t", 0),
      echoing_agency(),
      json.Object([#("key", json.String("k"))]),
    )
  assert outcome.is_error
}

pub fn notes_passes_an_absent_prefix_through_as_absent_test() {
  // The clamping to `agent/` is the Agency's job, not the shell's: the
  // shell must not invent a prefix the Agency would then prepend twice.
  let outcome =
    run(
      "agent_notes",
      ctx_for("main", "t", 0),
      echoing_agency(),
      json.Object([]),
    )
  assert string.contains(text_of(outcome), "<none>")
}

pub fn roster_takes_no_arguments_test() {
  let outcome =
    run(
      "agent_roster",
      ctx_for("sub:main/x", "t", 0),
      echoing_agency(),
      json.Object([#("ignored", json.Bool(True))]),
    )
  assert !outcome.is_error
  assert string.contains(text_of(outcome), "parent sub:main/x")
}
