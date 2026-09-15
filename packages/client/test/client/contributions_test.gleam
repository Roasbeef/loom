//// The tool registry as a list of contributions.
////
//// Two things are under test and they pull in opposite directions. The
//// built-in half must register exactly what it always did, plane by
//// plane, because the wire tool array is the provider cache's byte
//// prefix and a tool that quietly appeared or vanished would reprice
//// every session. The extension half must be refused the moment it
//// claims a name someone else holds, because a shadowed `bash` is a
//// sandbox argument about the wrong function.

import broker/broker
import broker/exec
import broker/policy
import client/catalog
import client/contributions
import core/clock
import core/ids
import core/json
import core/message
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tools/agent
import tools/codemode
import tools/context
import tools/history
import tools/job
import tools/remember
import tools/schedule
import tools/tool

// A tool an extension might contribute, under whatever name the test
// needs. Nothing about its behaviour matters here: registration is
// decided from the name alone.
fn contributed(name: String) -> tool.Tool {
  tool.Tool(
    name:,
    description: "A tool from outside the harness.",
    prompt_snippet: Some("`" <> name <> "` does something out of tree."),
    schema: tool.object_schema([], []),
    replay: tool.Safe,
    execution_mode: tool.Concurrent,
    requirements: fn(_workspace) { policy.workspace_default("/nonexistent") },
    run: fn(_ctx, _args) { tool.success("done") },
  )
}

fn extension(
  name: String,
  tools: List(tool.Tool),
) -> contributions.Contribution {
  contributions.Contribution(origin: contributions.Extension(name:), tools:)
}

fn built(
  contribution_list: List(contributions.Contribution),
) -> Result(List(String), contributions.Collision) {
  contributions.registry(contribution_list)
  |> result.map(tool.names)
}

// --- the built-in contributions -------------------------------------------

pub fn an_unwired_host_contributes_the_five_core_tools_test() {
  // Gating registration on the seam existing is arithmetic rather than
  // tidiness: a permanently-refusing definition would be paid for on
  // every request of every strand for the life of the session.
  let assert Ok(registry) =
    contributions.registry(contributions.built_in(
      None,
      None,
      None,
      None,
      None,
      None,
      None,
    ))
    as "the built-in contributions never collide"
  assert tool.names(registry)
    == ["bash", "fs_edit", "fs_read", "fs_write", "grep"]
}

pub fn the_host_makes_exactly_one_contribution_test() {
  // Every plane the harness compiles in is one origin, `code_mode`
  // included: gating on a plane is what `history_search`, `remember` and
  // the `schedule_*` tools already do, and none of them is a separate
  // origin either. An absent plane contributes nothing at all.
  let assert [contributions.Contribution(origin:, tools:)] =
    contributions.built_in(None, None, None, None, None, None, None)
    as "a host makes exactly one built-in contribution"
  assert origin == contributions.BuiltIn
  assert list.length(tools) == 5
}

pub fn the_core_tools_lead_the_registration_order_test() {
  // The order is what the system prompt's index reads, and the core
  // tools come first there because that is how an operator reads a list.
  let assert Ok(registry) =
    contributions.registry(contributions.built_in(
      None,
      None,
      None,
      None,
      None,
      None,
      None,
    ))
    as "the built-in contributions never collide"
  assert list.map(tool.registered(registry), fn(each) { each.name })
    == ["bash", "grep", "fs_read", "fs_write", "fs_edit"]
}

// --- collisions -----------------------------------------------------------

pub fn an_extension_may_not_shadow_a_built_in_test() {
  // The security argument for the whole seam: if an extension could
  // register `bash`, installing one would silently redefine what the
  // model's `bash` call does.
  let attempt =
    list.append(
      contributions.built_in(None, None, None, None, None, None, None),
      [
        extension("hostile", [contributed("bash")]),
      ],
    )
  assert built(attempt)
    == Error(contributions.Collision(
      name: "bash",
      first: contributions.BuiltIn,
      second: contributions.Extension(name: "hostile"),
    ))
}

// --- deactivating a built-in ----------------------------------------------
//
// The ruling in two directions. An extension never overrides a built-in;
// an operator who wants an extension's tool to stand in for one
// deactivates the built-in first, and the name is then simply free.

pub fn a_deactivated_built_in_yields_its_name_test() {
  let attempt =
    list.append(
      contributions.built_in(None, None, None, None, None, None, None),
      [
        extension("hashline", [contributed("fs_edit")]),
      ],
    )

  // Active, the built-in still wins the argument by refusing the boot.
  assert built(attempt)
    == Error(contributions.Collision(
      name: "fs_edit",
      first: contributions.BuiltIn,
      second: contributions.Extension(name: "hashline"),
    ))

  // Deactivated, the name is unclaimed and the extension's tool is the
  // only `fs_edit` the model can reach.
  let assert Ok(names) = built(contributions.deactivate(attempt, ["fs_edit"]))
    as "a deactivated built-in does not collide"
  assert list.contains(names, "fs_edit")
  assert list.length(list.filter(names, fn(name) { name == "fs_edit" })) == 1

  // And the rest of the built-ins are untouched by it.
  assert list.contains(names, "bash")
}

pub fn deactivation_reaches_built_ins_only_test() {
  // Deactivating an extension's tool would be a way to hand one
  // extension's name to another by configuration, which is the peer
  // shadowing this module refuses. The way to stop an extension's tool
  // is to uninstall the extension.
  let attempt = [
    extension("first", [contributed("web_search")]),
    extension("second", [contributed("web_search")]),
  ]
  assert built(contributions.deactivate(attempt, ["web_search"]))
    == Error(contributions.Collision(
      name: "web_search",
      first: contributions.Extension(name: "first"),
      second: contributions.Extension(name: "second"),
    ))
}

pub fn deactivating_a_tool_this_host_never_built_is_not_an_error_test() {
  // A shared configuration is used across hosts whose planes differ, so
  // naming a tool that is not here states a posture rather than a
  // mistake.
  let host = contributions.built_in(None, None, None, None, None, None, None)
  assert built(contributions.deactivate(host, ["code_mode", "no_such_tool"]))
    == built(host)
}

pub fn an_extension_may_not_shadow_a_peer_test() {
  // At one remove, the same argument: with last-wins between peers, the
  // install order would decide which of two tools the model reached.
  let attempt = [
    extension("first", [contributed("web_search")]),
    extension("second", [contributed("web_search")]),
  ]
  assert built(attempt)
    == Error(contributions.Collision(
      name: "web_search",
      first: contributions.Extension(name: "first"),
      second: contributions.Extension(name: "second"),
    ))
}

pub fn the_first_claim_is_the_one_that_holds_test() {
  // A collision names the earlier origin as `first` so that the refusal
  // can point at the newcomer as the thing to remove.
  let assert Error(collision) =
    contributions.registry([
      extension("early", [contributed("shared")]),
      extension("late", [contributed("shared")]),
    ])
    as "two extensions claiming one name must be refused"
  assert collision.first == contributions.Extension(name: "early")
  let message = contributions.collision_message(collision)
  assert string.contains(message, "`shared`")
  assert string.contains(message, "`early`")
  assert string.contains(message, "`late`")
}

pub fn a_contribution_may_still_override_itself_test() {
  // Within one contribution, last registration wins, exactly as
  // `tool.registry` has always behaved: a single author restating a name
  // is that author overriding themselves, not a shadowing.
  let quiet = tool.Tool(..contributed("web_search"), description: "quiet")
  let loud = tool.Tool(..contributed("web_search"), description: "loud")
  let assert Ok(registry) =
    contributions.registry([extension("only", [quiet, loud])])
    as "a repeat inside one contribution is an override, not a collision"
  let assert Ok(found) = tool.lookup(registry, "web_search")
    as "the overridden tool stays registered"
  assert found.description == "loud"
}

pub fn an_extension_adds_to_the_built_ins_test() {
  let with_extension =
    list.append(
      contributions.built_in(None, None, None, None, None, None, None),
      [
        extension("websearch", [contributed("web_search")]),
      ],
    )
  assert built(with_extension)
    == Ok(["bash", "fs_edit", "fs_read", "fs_write", "grep", "web_search"])
}

pub fn a_contributed_tool_dispatches_like_any_other_test() {
  // The registry is a name table and has no memory of origins; dispatch
  // must not be able to tell a contributed tool from a built-in one.
  let assert Ok(registry) =
    contributions.registry([extension("only", [contributed("web_search")])])
    as "one extension alone cannot collide"
  let outcome = tool.dispatch(registry, a_ctx(), "web_search", json.Object([]))
  assert outcome.is_error == False
  assert outcome.terminate == tool.ContinueRun
}

// A context nothing under test reads: the contributed tool's `run`
// ignores it, and dispatch is decided from the name alone.
fn a_ctx() -> tool.Ctx {
  let workspace = "/nonexistent/loom-contributions-test"
  let #(op_id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 3))
  tool.Ctx(
    workspace:,
    strand: "main",
    op_id:,
    step_id: "step-1",
    source_index: 0,
    base_policy: policy.workspace_default(workspace),
    grants: [],
    demand: exec.BestEffort,
    env: [],
    clock: clock.fixed(at: 0),
    filesystem: dead_filesystem(),
    blob_root: workspace <> "/.blobs",
    clear_call: fn(_spec, _events) { Error(broker.BrokerUnavailable) },
    raise_refusal: tool.no_raise(),
    observe_output: tool.ignore_output(),
  )
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

// --- the wire tool roster --------------------------------------------------
//
// Plane gating answers whether this host *has* a thing. The roster
// answers whether this deployment wants to *pay* for it, and the price is
// the provider's cached prefix — every definition, on every request of
// every strand, called or not. The two questions are independent, which
// is why `Minimal` must ignore a plane that is genuinely present.

// Every plane this host could open, all at once. No seam here is ever
// called: registration is decided when a tool is constructed.
fn every_plane() -> #(
  Option(agent.Agency),
  Option(codemode.CodeMode),
  Option(history.History),
  Option(remember.Memory),
  Option(schedule.Schedules),
  Option(context.Context),
  Option(job.Jobs),
) {
  #(
    Some(unused_agency()),
    Some(unused_code_mode()),
    Some(unused_history()),
    Some(unused_memory()),
    Some(unused_schedules()),
    Some(unused_context()),
    Some(job.unavailable()),
  )
}

fn roster_names(roster: catalog.Roster) -> List(String) {
  let #(agency, code_mode, history, memory, schedules, context, jobs) =
    every_plane()
  let assert Ok(registry) =
    contributions.registry(contributions.built_in_for(
      roster,
      agency,
      code_mode,
      history,
      memory,
      schedules,
      context,
      jobs,
    ))
    as "the built-in contributions never collide"
  list.map(tool.registered(registry), fn(each) { each.name })
}

pub fn the_minimal_roster_registers_six_tools_test() {
  // Every plane is open and only two of them reach the wire. The order is
  // the order the system prompt's index reads, and `code_mode` is last
  // because it is the door that stands in for everything dropped.
  assert roster_names(catalog.Minimal)
    == ["bash", "grep", "fs_read", "fs_write", "fs_edit", "code_mode"]
}

pub fn the_roster_chooses_how_bash_reads_a_job_back_test() {
  // The same roster value that decides whether job_poll is on the wire
  // decides which readback bash names, so swapping the two arms cannot
  // leave the description pointing at an absent tool.
  let bash_of = fn(roster) {
    let #(agency, code_mode, history, memory, schedules, context, jobs) =
      every_plane()
    let assert Ok(registry) =
      contributions.registry(contributions.built_in_for(
        roster,
        agency,
        code_mode,
        history,
        memory,
        schedules,
        context,
        jobs,
      ))
    let assert Ok(bash) = tool.lookup(registry, "bash")
    bash.description
  }
  assert string.contains(bash_of(catalog.Minimal), "job://<id>")
  assert !string.contains(bash_of(catalog.Minimal), "`job_poll`")
  assert string.contains(bash_of(catalog.Full), "`job_poll`")
  assert !string.contains(bash_of(catalog.Full), "job://<id>")
}

pub fn the_minimal_roster_ignores_a_present_plane_test() {
  // The point of the roster, stated as an absence: the agency, jobs,
  // schedules, history and memory planes are all wired here, and none of
  // them is on the wire. Nothing was taken from the session — each is
  // reachable from a code-mode program — only from the cached prefix.
  let names = roster_names(catalog.Minimal)
  let dropped = [
    "agent_spawn", "agent_send", "agent_wait", "agent_note", "agent_notes",
    "agent_roster", "job_poll", "job_kill", "job_send", "schedule_create",
    "schedule_list", "schedule_cancel", "history_search", "remember",
    "context_remaining",
  ]
  assert list.filter(dropped, list.contains(names, _)) == []
}

pub fn a_minimal_host_without_code_mode_registers_the_five_test() {
  // Code mode is gated on its plane under `Minimal` exactly as it is
  // under `Full`: a host that opened no pipeline has no `code_mode` to
  // register, and pays for no definition that could only refuse.
  let #(agency, _code_mode, history, memory, schedules, context, jobs) =
    every_plane()
  let assert Ok(registry) =
    contributions.registry(contributions.built_in_for(
      catalog.Minimal,
      agency,
      None,
      history,
      memory,
      schedules,
      context,
      jobs,
    ))
    as "the built-in contributions never collide"
  assert list.map(tool.registered(registry), fn(each) { each.name })
    == ["bash", "grep", "fs_read", "fs_write", "fs_edit"]
}

pub fn the_full_roster_is_what_built_in_has_always_registered_test() {
  // `built_in` is `built_in_for(Full, ..)` under its historical name, and
  // the assertion is on the registration order rather than on the set:
  // the tool array is the byte prefix of the provider's cached region, so
  // a definition that moved would reprice every strand.
  let #(agency, code_mode, history, memory, schedules, context, jobs) =
    every_plane()
  let assert Ok(historical) =
    contributions.registry(contributions.built_in(
      agency,
      code_mode,
      history,
      memory,
      schedules,
      context,
      jobs,
    ))
    as "the built-in contributions never collide"
  assert roster_names(catalog.Full)
    == list.map(tool.registered(historical), fn(each) { each.name })
  assert list.length(roster_names(catalog.Full)) == 21
}

pub fn bash_keeps_the_jobs_door_under_the_minimal_roster_test() {
  // The door is not one of the dropped tools. `job_*` leaves the wire;
  // `mode: "background"` does not leave `bash`'s schema, because taking
  // it away would change what a core tool *does* rather than how many
  // definitions the prefix carries.
  let #(agency, code_mode, history, memory, schedules, context, jobs) =
    every_plane()
  let assert Ok(registry) =
    contributions.registry(contributions.built_in_for(
      catalog.Minimal,
      agency,
      code_mode,
      history,
      memory,
      schedules,
      context,
      jobs,
    ))
    as "the built-in contributions never collide"
  let assert Ok(shell) = tool.lookup(registry, "bash")
    as "every roster registers bash"

  // The schema still offers the background mode, which is the half of
  // the door the model can see.
  assert string.contains(json.to_string(shell.schema), "background")

  // And the seam behind it is reached rather than absent: a background
  // call on this fixture's `job.unavailable()` door refuses in band,
  // which only the door can produce.
  let outcome =
    tool.dispatch(
      registry,
      a_ctx(),
      "bash",
      json.Object([
        #("command", json.String("true")),
        #("mode", json.String("background")),
      ]),
    )
  assert outcome.is_error
  assert string.contains(
    outcome_text(outcome),
    "this session runs no background jobs",
  )
}

// The text a dispatched outcome carries, for a test that is about the
// words the seam produced rather than about the block structure.
fn outcome_text(outcome: tool.ToolOutcome) -> String {
  list.filter_map(outcome.content, fn(block) {
    case block {
      message.ToolResultText(text:, ..) -> Ok(text)
      message.ToolResultImage(..) -> Error(Nil)
    }
  })
  |> string.join("\n")
}

// --- seams the roster census needs -----------------------------------------
//
// None of these is ever called: a registration is decided from the tool's
// name, and the one dispatch above goes through the jobs door rather than
// through any of them.

fn unused_refusal() -> String {
  "this seam is never called"
}

fn unused_agency() -> agent.Agency {
  agent.Agency(
    spawn: fn(_caller, _request) { Error(agent.AgencyUnavailable) },
    send: fn(_caller, _to, _text) { Error(agent.AgencyUnavailable) },
    wait: fn(_caller, _handles, _within) { Error(agent.AgencyUnavailable) },
    note: fn(_caller, _key, _value) { Error(agent.AgencyUnavailable) },
    notes: fn(_caller, _prefix) { Error(agent.AgencyUnavailable) },
    roster: fn(_caller) { Error(agent.AgencyUnavailable) },
    max_wait_ms: 1000,
    model_names: [],
  )
}

fn unused_code_mode() -> codemode.CodeMode {
  codemode.CodeMode(
    execute: fn(_request) { panic as "the roster census never runs a program" },
    seams: codemode.one_seam(
      codemode.SeamOffer(
        seam: codemode.WorkspaceSeam,
        allowed_imports: ["cap/report"],
        serviced_caps: ["proc.run"],
        extra_surfaces: [],
      ),
    ),
    default_within_ms: 300_000,
    max_within_ms: 900_000,
  )
}

fn unused_history() -> history.History {
  history.History(
    read: fn(_session, _entry) {
      Error(history.IndexUnavailable(reason: unused_refusal()))
    },
    search: fn(_text, _limit, _scope) {
      Error(history.IndexUnavailable(reason: unused_refusal()))
    },
  )
}

fn unused_memory() -> remember.Memory {
  remember.Memory(remember: fn(_note) {
    Error(remember.MemoryUnavailable(reason: unused_refusal()))
  })
}

fn unused_schedules() -> schedule.Schedules {
  schedule.Schedules(
    create: fn(_ctx, _request) {
      Error(schedule.Unavailable(reason: unused_refusal()))
    },
    list: fn(_ctx) { Error(schedule.Unavailable(reason: unused_refusal())) },
    cancel: fn(_ctx, _name, _target) {
      Error(schedule.Unavailable(reason: unused_refusal()))
    },
  )
}

fn unused_context() -> context.Context {
  context.Context(report: fn(_strand) { Error(unused_refusal()) })
}
