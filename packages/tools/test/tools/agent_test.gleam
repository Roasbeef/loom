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
import gleam/int
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
    raise_refusal: tool.no_raise(),
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
    rename: fn(from, _to) { Error(tool.FsNotFound(path: from)) },
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
            result: agent.NoResultAsked,
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

// The running example: `{files: [string] (required), count: integer}`.
fn a_schema() -> agent.ResultSchema {
  let assert Ok(schema) =
    agent.parse_result_schema(
      json.Object([
        #("type", json.String("object")),
        #(
          "properties",
          json.Object([
            #(
              "files",
              json.Object([
                #("type", json.String("array")),
                #("items", json.Object([#("type", json.String("string"))])),
              ]),
            ),
            #("count", json.Object([#("type", json.String("integer"))])),
          ]),
        ),
        #("required", json.Array([json.String("files")])),
      ]),
    )
    as "the running example must parse"
  schema
}

// An Agency whose join answers one handle with a fixed terminal result,
// so the rendering of each `TerminalResult` variant can be pinned
// without a runtime.
fn joining_agency(result: agent.TerminalResult) -> agent.Agency {
  agent.Agency(..echoing_agency(), wait: fn(_caller, handles, _within) {
    Ok(
      list.map(handles, fn(handle) {
        agent.Ready(
          handle:,
          outcome: agent.Completed,
          report: "looked at three files",
          result:,
          notes: [],
        )
      }),
    )
  })
}

// A spawn closure that reports the schema it was handed. Written out
// rather than inlined because a record update does not carry its field
// types into an anonymous function's arguments.
fn watching_spawn(
  seen: Subject(option.Option(agent.ResultSchema)),
) -> fn(agent.Caller, agent.SpawnRequest) ->
  Result(agent.Spawned, agent.Refusal) {
  fn(caller: agent.Caller, request: agent.SpawnRequest) {
    process.send(seen, request.result_schema)
    Ok(
      agent.Spawned(
        handle: agent.Handle(strand: "sub:x", operation: caller.operation),
        strand: "sub:x",
        tools: [],
      ),
    )
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

// --- the result contract ---------------------------------------------------

pub fn a_schema_is_stated_in_the_dialect_the_tools_already_speak_test() {
  // No JSON Schema dependency: the subset the harness enforces is the
  // one `tool.object_schema` already emits for every tool definition the
  // model reads, so the parent states a shape in a notation it is fluent
  // in and the harness decodes only what it can hold a child to.
  let fields = agent.result_fields(a_schema())
  assert list.map(fields, fn(field) { field.name }) == ["files", "count"]
  let assert [files, count] = fields
  assert files.expects == agent.ArrayField(items: agent.StringField)
  assert files.required
  assert count.expects == agent.IntegerField
  assert !count.required
}

pub fn a_schema_round_trips_through_its_rendered_form_test() {
  // The rendered form is what the brief quotes and what the Agency
  // stores durably, so a schema read back out of a fact cell has to
  // parse to the value that was written.
  let rendered = agent.render_result_schema(a_schema())
  assert agent.parse_result_schema(rendered) == Ok(a_schema())
  // `additionalProperties` is absent, which is JSON Schema's "extras
  // allowed" default and exactly what validation does.
  assert !string.contains(json.to_string(rendered), "additionalProperties")
}

pub fn a_schema_asking_for_what_this_harness_cannot_enforce_is_refused_test() {
  // A constraint that is accepted and then ignored is worse than no
  // constraint: the parent would read it back in the brief and never
  // learn nothing was checking it.
  let with_pattern =
    json.Object([
      #("type", json.String("object")),
      #(
        "properties",
        json.Object([
          #(
            "name",
            json.Object([
              #("type", json.String("string")),
              #("pattern", json.String("^a")),
            ]),
          ),
        ]),
      ),
    ])
  let assert Error(reason) = agent.parse_result_schema(with_pattern)
  assert string.contains(reason, "pattern")
}

pub fn a_schema_that_is_not_an_object_of_properties_is_refused_test() {
  let assert Error(_not_object) =
    agent.parse_result_schema(json.Array([json.String("files")]))
  let assert Error(_wrong_type) =
    agent.parse_result_schema(
      json.Object([
        #("type", json.String("array")),
        #("properties", json.Object([])),
      ]),
    )
  let assert Error(_empty) =
    agent.parse_result_schema(
      json.Object([
        #("type", json.String("object")),
        #("properties", json.Object([])),
      ]),
    )
  let assert Error(undeclared) =
    agent.parse_result_schema(
      json.Object([
        #("type", json.String("object")),
        #(
          "properties",
          json.Object([#("a", json.Object([#("type", json.String("string"))]))]),
        ),
        #("required", json.Array([json.String("b")])),
      ]),
    )
  assert string.contains(undeclared, "`b`")
}

pub fn the_field_bound_is_checked_before_the_properties_are_walked_test() {
  // The bound sits above `parse_property`, and the ordering is the whole
  // of its protection: an over-limit list is refused for its length
  // without the excess ever being parsed. That is observable — the
  // entries past the bound here are outright malformed, and the refusal
  // still names the bound rather than them, which it could not do if the
  // walk ran first.
  let well_formed = fn(index: Int) {
    #(
      "field" <> int.to_string(index),
      json.Object([#("type", json.String("string"))]),
    )
  }
  let schema = fn(properties) {
    json.Object([
      #("type", json.String("object")),
      #("properties", json.Object(properties)),
    ])
  }
  let inside =
    list.index_map(list.repeat(Nil, agent.max_result_fields), fn(_nil, index) {
      well_formed(index)
    })
  let excess = [
    #("!! not a usable name !!", json.String("not even a type object")),
    #("also bad", json.Array([])),
  ]
  // Exactly at the bound, everything parses.
  let assert Ok(_at_the_bound) = agent.parse_result_schema(schema(inside))
  let assert Error(reason) =
    agent.parse_result_schema(schema(list.append(inside, excess)))
  assert string.contains(reason, "at most")
  assert string.contains(reason, int.to_string(agent.max_result_fields))
  // The excess was never handed to `parse_property`, so none of its own
  // vocabulary can appear in the refusal.
  assert !string.contains(reason, "unusable")
}

pub fn a_malformed_schema_is_refused_at_spawn_not_at_join_test() {
  // The parent learns about its own mistake in the turn it made it. The
  // Agency is never reached, so nothing was minted and nothing has to be
  // joined before the news arrives.
  let unreachable =
    agent.Agency(..echoing_agency(), spawn: fn(_caller, _request) {
      panic as "a malformed schema must never reach the seam"
    })
  let outcome =
    run(
      "agent_spawn",
      ctx_for("main", "t", 0),
      unreachable,
      json.Object([
        #("purpose", json.String("review")),
        #("brief", json.String("read it")),
        #("result_schema", json.String("give me the files")),
      ]),
    )
  assert outcome.is_error
  assert string.contains(text_of(outcome), "`result_schema`")
  assert string.contains(text_of(outcome), "must be a JSON object")
}

pub fn a_spawn_carries_its_schema_to_the_seam_test() {
  let seen = process.new_subject()
  let watching = agent.Agency(..echoing_agency(), spawn: watching_spawn(seen))
  let with_schema =
    json.Object([
      #("purpose", json.String("review")),
      #("brief", json.String("read it")),
      #("result_schema", agent.render_result_schema(a_schema())),
    ])
  let outcome =
    run("agent_spawn", ctx_for("main", "t", 0), watching, with_schema)
  assert !outcome.is_error
  let assert Ok(option.Some(carried)) = process.receive(seen, within: 100)
  assert carried == a_schema()
  // And a spawn that named none hands the seam an absent one rather than
  // an invented empty contract.
  let without =
    json.Object([
      #("purpose", json.String("review")),
      #("brief", json.String("read it")),
    ])
  let _plain = run("agent_spawn", ctx_for("main", "t", 0), watching, without)
  assert process.receive(seen, within: 100) == Ok(None)
}

// --- validation ------------------------------------------------------------

pub fn a_matching_result_validates_test() {
  assert agent.validate_result(
      a_schema(),
      json.Object([
        #("files", json.Array([json.String("auth.gleam")])),
        #("count", json.Int(1)),
      ]),
    )
    == Ok(Nil)
}

pub fn a_missing_required_field_names_itself_and_its_type_test() {
  let assert Error(mismatch) =
    agent.validate_result(a_schema(), json.Object([#("count", json.Int(0))]))
  assert mismatch
    == agent.FieldMissing(
      name: "files",
      expects: agent.ArrayField(items: agent.StringField),
    )
  let said = agent.describe_mismatch(mismatch)
  assert string.contains(said, "`files`")
  assert string.contains(said, "array of string")
}

pub fn a_wrong_type_names_both_sides_test() {
  let assert Error(mismatch) =
    agent.validate_result(a_schema(), json.Object([#("files", json.Int(3))]))
  let said = agent.describe_mismatch(mismatch)
  assert string.contains(said, "must be `array of string`")
  assert string.contains(said, "not `integer`")
}

pub fn an_array_mismatch_names_the_offending_element_test() {
  // "array" is not the news when an array is what was asked for.
  let assert Error(mismatch) =
    agent.validate_result(
      a_schema(),
      json.Object([#("files", json.Array([json.String("a"), json.Int(2)]))]),
    )
  assert string.contains(
    agent.describe_mismatch(mismatch),
    "array containing integer",
  )
}

pub fn a_result_that_is_not_an_object_is_refused_test() {
  let assert Error(agent.NotAnObject(received: "array")) =
    agent.validate_result(a_schema(), json.Array([]))
}

pub fn an_optional_field_may_be_absent_but_never_wrong_test() {
  let only_required = json.Object([#("files", json.Array([]))])
  assert agent.validate_result(a_schema(), only_required) == Ok(Nil)
  let assert Error(agent.FieldWrongType(name: "count", ..)) =
    agent.validate_result(
      a_schema(),
      json.Object([
        #("files", json.Array([])),
        #("count", json.String("three")),
      ]),
    )
}

pub fn a_surplus_field_is_not_a_failure_test() {
  // The contract is a lower bound on the shape: a child that reported
  // more than it owed still reported what it owed.
  assert agent.validate_result(
      a_schema(),
      json.Object([
        #("files", json.Array([])),
        #("notes", json.String("nothing interesting")),
      ]),
    )
    == Ok(Nil)
}

pub fn a_number_field_takes_either_kind_of_number_test() {
  let assert Ok(schema) =
    agent.parse_result_schema(
      json.Object([
        #("type", json.String("object")),
        #(
          "properties",
          json.Object([
            #("ratio", json.Object([#("type", json.String("number"))])),
            #("anything", json.Object([])),
          ]),
        ),
      ]),
    )
  assert agent.validate_result(schema, json.Object([#("ratio", json.Int(1))]))
    == Ok(Nil)
  assert agent.validate_result(
      schema,
      json.Object([#("ratio", json.Float(0.5))]),
    )
    == Ok(Nil)
  // A property with no `type` is the shape `tool.any_property` emits, and
  // takes anything, `null` included.
  assert agent.validate_result(schema, json.Object([#("anything", json.Null)]))
    == Ok(Nil)
}

// --- what the child is told ------------------------------------------------

pub fn a_refused_result_names_the_schema_and_what_it_got_test() {
  // The anonymous-refusal pattern is what this says: a failure that says
  // "did not match" without saying what was wanted costs the reader a
  // round trip to learn what it could have been told.
  let assert Error(mismatch) =
    agent.validate_result(a_schema(), json.Object([#("files", json.Int(3))]))
  let said =
    agent.describe(agent.ResultSchemaUnmet(
      schema: a_schema(),
      received: json.Object([#("files", json.Int(3))]),
      mismatch:,
    ))
  // What was wanted, in full.
  assert string.contains(
    said,
    json.to_string(agent.render_result_schema(a_schema())),
  )
  // What arrived.
  assert string.contains(said, "{\"files\":3}")
  // And that nothing was written, so the child knows to write again.
  assert string.contains(said, "write the note again")
  assert agent.refusal_outcome(agent.ResultSchemaUnmet(
    schema: a_schema(),
    received: json.Null,
    mismatch:,
  )).is_error
}

// --- what the parent sees --------------------------------------------------

pub fn a_join_hands_back_a_matching_result_as_json_test() {
  let handle = agent.Handle(strand: "sub:a", operation: an_op(5))
  let value =
    json.Object([
      #("files", json.Array([json.String("auth.gleam")])),
      #("count", json.Int(1)),
    ])
  let outcome =
    run(
      "agent_wait",
      ctx_for("main", "t", 0),
      joining_agency(agent.ResultGiven(value:)),
      json.Object([
        #("handles", json.Array([json.String(agent.handle_to_string(handle))])),
      ]),
    )
  assert !outcome.is_error
  // Typed, in the details a program reads — not prose to be regexed.
  let assert option.Some(json.Object(fields: details)) = outcome.details
  let assert Ok(json.Array(items: [json.Object(fields: first)])) =
    list.key_find(details, "results")
  assert list.key_find(first, "result")
    == Ok(json.Object([#("state", json.String("given")), #("value", value)]))
  // The prose report survives beside it: it is what a human reads.
  assert string.contains(text_of(outcome), "looked at three files")
  assert string.contains(text_of(outcome), "[result] ")
}

pub fn a_join_names_the_schema_when_the_result_is_unusable_test() {
  let handle = agent.Handle(strand: "sub:a", operation: an_op(5))
  let received = json.Object([#("files", json.Int(3))])
  let assert Error(mismatch) = agent.validate_result(a_schema(), received)
  let outcome =
    run(
      "agent_wait",
      ctx_for("main", "t", 0),
      joining_agency(agent.ResultUnusable(
        schema: a_schema(),
        received:,
        mismatch:,
      )),
      json.Object([
        #("handles", json.Array([json.String(agent.handle_to_string(handle))])),
      ]),
    )
  let said = text_of(outcome)
  assert string.contains(said, "unusable result")
  assert string.contains(said, "must be `array of string`")
  assert string.contains(
    said,
    json.to_string(agent.render_result_schema(a_schema())),
  )
  assert string.contains(said, "{\"files\":3}")
}

pub fn a_join_says_so_when_a_child_owed_a_result_and_recorded_none_test() {
  let handle = agent.Handle(strand: "sub:a", operation: an_op(5))
  let outcome =
    run(
      "agent_wait",
      ctx_for("main", "t", 0),
      joining_agency(agent.ResultAbsent(schema: a_schema())),
      json.Object([
        #("handles", json.Array([json.String(agent.handle_to_string(handle))])),
      ]),
    )
  assert string.contains(text_of(outcome), "owed a result matching")
  let assert option.Some(details) = outcome.details
  assert string.contains(json.to_string(details), "\"state\":\"absent\"")
}

pub fn a_join_without_a_schema_renders_exactly_what_it_did_before_test() {
  // The compatibility floor, pinned byte for byte: a spawn that named no
  // schema must produce the outcome it produced before result contracts
  // existed — no extra field, no invented sentinel.
  let handle = agent.Handle(strand: "sub:a", operation: an_op(5))
  let outcome =
    run(
      "agent_wait",
      ctx_for("main", "t", 0),
      echoing_agency(),
      json.Object([
        #("handles", json.Array([json.String(agent.handle_to_string(handle))])),
      ]),
    )
  assert text_of(outcome) == "[sub:a completed]\nmain@30000"
  assert outcome.details
    == option.Some(
      json.Object([
        #(
          "results",
          json.Array([
            json.Object([
              #("handle", json.String(agent.handle_to_string(handle))),
              #("strand", json.String("sub:a")),
              #("state", json.String("ready")),
              #("outcome", json.String("completed")),
              #("report", json.String("main@30000")),
              #("notes", json.Object([])),
            ]),
          ]),
        ),
        #("pending", json.Bool(False)),
      ]),
    )
}
