//// Every built-in tool is placed on exactly one side of the workspace
//// boundary, and on the side its builder says.
////
//// The placement table is two lists of names. These tests build each half of
//// the registry with every plane enabled, from the code that builds it, and
//// hold the table to what was built: a tool added to a builder with no line in
//// the table, a tool placed on the wrong side, a name on both sides and a name
//// in the table that nothing builds all fail here.

import client/contributions
import client/owner_services
import client/peer_mail
import client/peers
import client/skill_tool
import client/tool_placement
import client/working_directory
import core/json
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import host/skill
import simplifile
import tools/advise
import tools/agent
import tools/codemode as codemode_tool
import tools/context as context_tool
import tools/history as history_tool
import tools/job
import tools/remember
import tools/schedule as schedule_tool
import tools/tool
import tools/working_directory as directory_tool

// --- every plane enabled, with seams which answer nothing -------------------

fn an_agency() -> agent.Agency {
  agent.Agency(
    spawn: fn(_caller, _request) { Error(agent.AgencyUnavailable) },
    wait: fn(_caller, _handles, _within) { Error(agent.AgencyUnavailable) },
    send: fn(_caller, _to, _text, _within_ms) { Error(agent.AgencyUnavailable) },
    note: fn(_caller, _key, _value) { Error(agent.AgencyUnavailable) },
    notes: fn(_caller, _prefix) { Error(agent.AgencyUnavailable) },
    todos: fn(_caller, _step) { Error(agent.AgencyUnavailable) },
    roster: fn(_caller) { Error(agent.AgencyUnavailable) },
    max_wait_ms: 30_000,
    model_names: [],
    holds: fn(_caller, _tool) { Ok(Nil) },
  )
}

fn a_code_mode() -> codemode_tool.CodeMode {
  codemode_tool.CodeMode(
    execute: fn(_request) { panic as "this test does not run a program" },
    background: None,
    seams: codemode_tool.one_seam(
      codemode_tool.SeamOffer(
        seam: codemode_tool.WorkspaceSeam,
        allowed_imports: [],
        serviced_caps: [],
        extra_surfaces: [],
      ),
    ),
    default_within_ms: 1000,
    max_within_ms: 1000,
  )
}

fn a_directory() -> directory_tool.Door {
  working_directory.door(
    owner_services.local_facts(handle: fn() { Error(Nil) }, runtime: fn() {
      Error(Nil)
    }),
  )
}

// What the workspace builds, with a language server door too so the two write
// tools are built the way a configured host builds them.
fn workspace_built() -> List(tool.Tool) {
  let jobs = job.unavailable()
  contributions.workspace_tools(Some(a_code_mode()), Some(jobs), None, [])
  |> contributions.directory_tools(jobs, a_directory())
}

fn owner_built() -> List(tool.Tool) {
  let built =
    contributions.owner_tools(
      Some(an_agency()),
      Some(
        history_tool.History(
          search: fn(_query, _limit, _scope) { Ok([]) },
          recent: fn(_limit) { Ok([]) },
          read: fn(_session, _entry) {
            Error(history_tool.IndexUnavailable("a fixture"))
          },
        ),
      ),
      Some(remember.Memory(remember: fn(_note) { Ok(Nil) })),
      Some(
        schedule_tool.Schedules(
          create: fn(_ctx, _request) {
            Error(schedule_tool.Invalid("a fixture"))
          },
          list: fn(_ctx) { Ok([]) },
          cancel: fn(_ctx, _name, _target) { Ok(Nil) },
        ),
      ),
      Some(context_tool.Context(report: fn(_strand) { Error("a fixture") })),
    )
  list.flatten([
    built.agent,
    built.session,
    skill_tool.tools(a_skill_catalogue()),
    peers.tools(a_peer_wiring()),
    [
      advise.tool(
        advise.Advice(judge: fn(_strand, _verdict) { Error("a fixture") }),
      ),
    ],
  ])
}

fn a_skill_catalogue() -> skill.Catalogue {
  let assert Ok(here) = simplifile.current_directory()
    as "the test workspace must be known"
  let root =
    here
    <> "/build/tool-placement-skills-"
    <> int.to_string(bootstrap.system_time_ms())
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/sample")
    as "the skill directory must exist"
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/sample/SKILL.md",
      "---\nname: sample\ndescription: a sample\n---\nInstructions.\n",
    )
    as "the skill file must be written"
  skill.discover([root])
}

fn a_peer_wiring() -> peers.Wiring {
  peers.Wiring(
    own: peer_mail.Endpoint("placement", fn(_command) {
      Error(peer_mail.Refused("a fixture"))
    }),
    metadata: json.Object([]),
    directory: None,
  )
}

fn names(tools: List(tool.Tool)) -> List(String) {
  list.map(tools, fn(each) { each.name })
}

// --- the properties ----------------------------------------------------------

/// Everything the workspace builds is placed on the workspace.
pub fn every_tool_the_workspace_builds_is_placed_there_test() {
  let built = names(workspace_built())
  assert built != []
  list.each(built, fn(name) {
    assert tool_placement.placement(name) == Ok(tool_placement.WorkspaceSide)
      as {
        "`" <> name <> "` is built by the workspace and must be placed there"
      }
  })
}

/// Everything the owner builds, including skills, peers and the advisor's
/// tool, is placed on the owner.
pub fn every_tool_the_owner_builds_is_placed_there_test() {
  let built = names(owner_built())
  assert built != []
  list.each(built, fn(name) {
    assert tool_placement.placement(name) == Ok(tool_placement.OwnerSide)
      as { "`" <> name <> "` is built by the owner and must be placed there" }
  })
}

/// The lists name what is built and nothing else: a name left in the table
/// after its tool is gone would place a name some extension could then claim.
pub fn the_table_names_exactly_what_is_built_test() {
  assert list.sort(tool_placement.workspace_names, by: string.compare)
    == list.sort(names(workspace_built()), by: string.compare)
  assert list.sort(tool_placement.owner_names(), by: string.compare)
    == list.sort(names(owner_built()), by: string.compare)
}

/// No name is on both sides.
pub fn no_name_is_placed_on_both_sides_test() {
  list.each(tool_placement.workspace_names, fn(name) {
    assert !list.contains(tool_placement.owner_names(), name)
  })
}

/// The whole registry, as `serve` composes it, places every name exactly once.
pub fn every_registered_name_is_placed_exactly_once_test() {
  let assert Ok(registry) =
    contributions.registry([
      contributions.Contribution(
        contributions.BuiltIn,
        list.append(workspace_built(), owner_built()),
      ),
    ])
    as "the built-in halves never claim one name twice"
  let registered = tool.names(registry)
  assert list.length(registered) == 28
    as "ten workspace tools and eighteen owner tools"
  list.each(registered, fn(name) {
    assert result.is_ok(tool_placement.placement(name))
      as { "`" <> name <> "` is registered and placed on no side" }
  })
}

/// An extension's tool is placed nowhere, which is what keeps it from being
/// sent to a workspace.
pub fn an_extension_tool_is_not_placed_test() {
  assert tool_placement.placement("websearch") == Error(Nil)
  assert tool_placement.placement("") == Error(Nil)
}

/// Placement is by exact name: a name which only starts like a built-in is not
/// one.
pub fn placement_is_by_exact_name_test() {
  assert tool_placement.placement("bash_extra") == Error(Nil)
  assert tool_placement.placement("agent") == Error(Nil)
}

/// The core tools lead the workspace's list, because `compose` cuts there.
pub fn the_core_tools_head_the_workspace_list_test() {
  assert list.take(tool_placement.workspace_names, 5)
    == tool_placement.core_names
}
