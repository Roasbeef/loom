//// The typed project standing, the router's fixed tool list, the packs and the
//// `[project]` table.

import client/project_packs
import client/project_settings
import client/project_standing
import gleam/dict
import gleam/list
import prompt/pack
import storage/catalogue
import tom
import tools/project as tools

pub fn the_catalogue_answer_lifts_to_the_standing_test() {
  assert project_standing.from_catalogue(catalogue.NotProject)
    == project_standing.Ordinary
  assert project_standing.from_catalogue(catalogue.RouterOf("p"))
    == project_standing.Router("p")
  assert project_standing.from_catalogue(catalogue.WorkerOf("p", "t", 2))
    == project_standing.Worker("p", "t", 2)
}

pub fn only_an_ordinary_session_may_move_test() {
  assert project_standing.mobility(project_standing.Ordinary)
    == project_standing.Free
  let assert project_standing.Held(_) =
    project_standing.mobility(project_standing.Router("p"))
  let assert project_standing.Held(_) =
    project_standing.mobility(project_standing.Worker("p", "t", 1))
}

pub fn the_router_ceiling_is_exactly_its_three_tools_test() {
  assert project_standing.tool_ceiling(project_standing.Router("p"))
    == Ok(["route", "project_read", "reply"])

  // No bash and no code_mode, so no program can start from a router.
  let assert Ok(ceiling) =
    project_standing.tool_ceiling(project_standing.Router("p"))
  assert !list.contains(ceiling, "bash")
  assert !list.contains(ceiling, "code_mode")

  // An ordinary session has no ceiling.
  assert project_standing.tool_ceiling(project_standing.Ordinary) == Error(Nil)
  assert tools.router_tool_names == ceiling
}

pub fn a_worker_loses_peer_and_agent_tools_test() {
  assert project_standing.worker_excludes("agent_spawn")
  assert project_standing.worker_excludes("peer_send")
  assert !project_standing.worker_excludes("bash")
  assert !project_standing.worker_excludes("project_report")
}

pub fn the_packs_decode_without_problems_test() {
  let assert Ok(router) = pack.decode(project_packs.router())
  assert pack.problems(router) == []
  let assert Ok(worker) = pack.decode(project_packs.worker())
  assert pack.problems(worker) == []
}

pub fn the_project_table_defaults_and_refuses_unknown_keys_test() {
  assert project_settings.from_document(dict.new())
    == Ok(project_settings.defaults)
  let assert Ok(document) = tom.parse("[project]\nmax_workers = 2\n")
  assert project_settings.from_document(document)
    == Ok(project_settings.Settings(2, 5_000_000))
  let assert Ok(unknown) = tom.parse("[project]\ncheck = \"make check\"\n")
  let assert Error(_) = project_settings.from_document(unknown)
  let assert Ok(too_many) = tom.parse("[project]\nmax_workers = 99\n")
  let assert Error(_) = project_settings.from_document(too_many)
}

pub fn route_takes_one_to_twenty_typed_items_test() {
  assert tools.parse_resource("board:2") == Ok(tools.Board(2))
  let assert Error(_) = tools.parse_resource("/etc/passwd")
  let assert Error(_) = tools.parse_resource("ticket:")
}
