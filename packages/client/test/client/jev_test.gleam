//// The transport to Jev and the `[jev]` table, with a fake fetch. Nothing here
//// reaches the network.

import client/codex/network
import client/jev as transport
import client/jev_settings
import client/project_settings
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import jevelin
import project/jev
import project/model.{Explicit}
import project/state
import provider/http
import tom

// A response to a request that asks only `clear_alone`.
const clear_body =
  "{\"model\":\"jev-1.14.0\",\"answers\":{\"clear_alone\":{\"type\":\"noul\",\"noul\":0.9}},\"usage\":{\"input_tokens\":10,\"output_tokens\":1}}"

fn request() -> jevelin.Request(jevelin.Evaluation(jev.Answers)) {
  let config =
    state.Config(
      project: model.ProjectId("p1"),
      workspace: "/w",
      max_workers: 1,
      queue_limit: 1,
      attention_limit: 1,
      policy_version: "v1",
    )
  let shape = jev.shape(state.start(config), Explicit, [])
  let message = jev.Message(text: "hello", source: jev.FromOwner)
  let assert Ok(built) = jev.request(shape, message, "jev-1.14.0")
    as "the request builds"
  built
}

fn answering(status: Int, body: String) -> transport.Fetch {
  fn(_, _, _) { Ok(network.Response(status, body)) }
}

fn client(fetch: transport.Fetch) -> transport.Client {
  transport.client_with(Some("sekret"), 3000, fetch)
}

pub fn a_client_with_no_key_sends_nothing_test() {
  let sent = process.new_subject()
  let fetch = fn(_, _, _) {
    process.send(sent, Nil)
    Ok(network.Response(200, clear_body))
  }
  let silent = transport.client_with(None, 3000, fetch)
  assert transport.evaluate(silent, request()) == Error(jev.NoKey)
  assert process.receive(sent, 0) == Error(Nil)
}

pub fn the_key_is_a_bearer_header_and_nowhere_else_test() {
  let seen = process.new_subject()
  let fetch = fn(sent: http.HttpRequest, limit, timeout) {
    process.send(seen, #(sent, limit, timeout))
    Ok(network.Response(200, clear_body))
  }
  let assert Ok(answered) = transport.evaluate(client(fetch), request())
  assert answered.model == "jev-1.14.0"
  let assert Ok(#(sent, limit, timeout)) = process.receive(seen, 0)
  assert list.key_find(sent.headers, "authorization") == Ok("Bearer sekret")
  assert !string.contains(sent.url, "sekret")
  assert !string.contains(sent.body, "sekret")
  assert string.starts_with(sent.url, jevelin.origin)
  assert limit == transport.response_limit_bytes
  assert timeout == 3000
}

pub fn any_status_but_200_or_a_failed_exchange_is_unavailable_test() {
  list.each([401, 422, 429, 500, 529], fn(status) {
    assert transport.evaluate(client(answering(status, "{}")), request())
      == Error(jev.Unavailable)
  })
  let failing = fn(_, _, _) { Error("request_timed_out") }
  assert transport.evaluate(client(failing), request())
    == Error(jev.Unavailable)
}

pub fn a_200_that_is_not_an_answer_to_the_request_is_invalid_test() {
  assert transport.evaluate(client(answering(200, "not json")), request())
    == Error(jev.Invalid)
  let extra =
    "{\"model\":\"m\",\"answers\":{\"clear_alone\":{\"type\":\"noul\",\"noul\":0.9},\"other\":{\"type\":\"noul\",\"noul\":0.1}},\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"
  assert transport.evaluate(client(answering(200, extra)), request())
    == Error(jev.Invalid)
}

pub fn a_pass_stops_asking_at_the_first_unavailable_test() {
  let calls = process.new_subject()
  let fetch = fn(_, _, _) {
    process.send(calls, Nil)
    Error("request_transport_failed")
  }
  let results =
    transport.pass(
      client(fetch),
      [#("a", request()), #("b", request()), #("c", request())],
      fn() { 0 },
      45_000,
    )
  assert results
    == [
      #("a", transport.Failed(jev.Unavailable)),
      #("b", transport.Skipped),
      #("c", transport.Skipped),
    ]
  assert process.receive(calls, 0) == Ok(Nil)
  assert process.receive(calls, 0) == Error(Nil)
}

pub fn an_invalid_answer_does_not_stop_the_pass_test() {
  let results =
    transport.pass(
      client(answering(200, "garbage")),
      [#("a", request()), #("b", request())],
      fn() { 0 },
      45_000,
    )
  assert results
    == [
      #("a", transport.Failed(jev.Invalid)),
      #("b", transport.Failed(jev.Invalid)),
    ]
}

pub fn a_pass_sends_no_request_that_could_not_finish_inside_its_bound_test() {
  // One request may take 3 s, and the pass is bounded to 2 s, so the clock
  // cannot show a moment at which a request would finish in time.
  let calls = process.new_subject()
  let fetch = fn(_, _, _) {
    process.send(calls, Nil)
    Ok(network.Response(200, clear_body))
  }
  let tight =
    transport.pass(
      client(fetch),
      [#("a", request()), #("b", request())],
      fn() { 0 },
      2000,
    )
  assert tight == [#("a", transport.Skipped), #("b", transport.Skipped)]
  assert process.receive(calls, 0) == Error(Nil)

  // The same batch under the real bound is asked in full.
  let roomy =
    transport.pass(
      client(fetch),
      [#("a", request()), #("b", request())],
      fn() { 0 },
      45_000,
    )
  assert list.all(roomy, fn(each) {
    case each.1 {
      transport.Answered(_) -> True
      transport.Failed(_) | transport.Skipped -> False
    }
  })
}

pub fn the_key_comes_from_the_variable_the_settings_name_test() {
  let lookup = fn(name) {
    case name {
      "JEV_API_KEY" -> Ok("  k  ")
      "BLANK" -> Ok("   ")
      _ -> Error(Nil)
    }
  }
  assert transport.key_from(jev_settings.defaults, lookup) == Some("k")
  let blank =
    jev_settings.Settings(..jev_settings.defaults, api_key_env: "BLANK")
  assert transport.key_from(blank, lookup) == None
  let unset =
    jev_settings.Settings(..jev_settings.defaults, api_key_env: "UNSET")
  assert transport.key_from(unset, lookup) == None
}

fn parsed(text: String) -> dict.Dict(String, tom.Toml) {
  let assert Ok(document) = tom.parse(text) as "the document parses"
  document
}

pub fn the_jev_table_defaults_and_bounds_its_keys_test() {
  assert jev_settings.from_document(dict.new()) == Ok(jev_settings.defaults)
  assert jev_settings.from_document(parsed(
      "[jev]\napi_key_env = \"MY_KEY\"\nmodel = \"jev-1.14.0\"\ntimeout_ms = 500\n",
    ))
    == Ok(jev_settings.Settings("MY_KEY", "jev-1.14.0", 500))
  list.each(
    [
      "timeout_ms = 499",
      "timeout_ms = 30001",
      "timeout_ms = \"3000\"",
      "api_key_env = \"1BAD\"",
      "api_key_env = \"has space\"",
      "model = \"two words\"",
      "model = \"\"",
      "origin = \"https://example.test\"",
    ],
    fn(line) {
      let assert Error(_) =
        jev_settings.from_document(parsed("[jev]\n" <> line <> "\n"))
        as line
      Nil
    },
  )
}

pub fn the_router_defaults_to_the_model_and_names_jev_only_by_the_word_test() {
  assert project_settings.defaults.router == project_settings.ModelRouter
  let assert Ok(settings) =
    project_settings.from_document(parsed("[project]\nrouter = \"jev\"\n"))
  assert settings.router == project_settings.JevRouter
  let assert Ok(model_settings) =
    project_settings.from_document(parsed("[project]\nrouter = \"model\"\n"))
  assert model_settings.router == project_settings.ModelRouter
  list.each(["router = \"Jev\"", "router = true", "router = \"\""], fn(line) {
    let assert Error(_) =
      project_settings.from_document(parsed("[project]\n" <> line <> "\n"))
      as line
    Nil
  })
}

pub fn the_attach_bar_is_a_percent_above_one_half_test() {
  assert project_settings.defaults.jev_min_probability == 80
  let assert Ok(settings) =
    project_settings.from_document(parsed(
      "[project]\njev_min_probability = 51\n",
    ))
  assert settings.jev_min_probability == 51
  list.each(["50", "101", "\"80\""], fn(value) {
    let assert Error(_) =
      project_settings.from_document(parsed(
        "[project]\njev_min_probability = " <> value <> "\n",
      ))
      as value
    Nil
  })
}

const catalogue_file =
  "[models.opus]\nprovider = \"x\"\n[profiles.cheap.roles]\nmain = [\"opus\"]\n[[project.agent]]\nname = \"small fixes\"\nuse_for = \"one-file fixes\"\nprofile = \"cheap\"\n[[project.agent]]\nname = \"refactors\"\nuse_for = \"large changes\"\nmodel = \"opus\"\n"

pub fn an_agent_catalogue_names_only_what_the_file_defines_test() {
  let assert Ok(settings) =
    project_settings.from_document(parsed(catalogue_file))
  assert settings.agents
    == [
      project_settings.Agent(
        name: "small fixes",
        use_for: "one-file fixes",
        profile: Some("cheap"),
        model: None,
      ),
      project_settings.Agent(
        name: "refactors",
        use_for: "large changes",
        profile: None,
        model: Some("opus"),
      ),
    ]
  let refused = fn(file: String) {
    let assert Error(_) = project_settings.from_document(parsed(file)) as file
    Nil
  }

  // A profile or a model the file does not define, an entry that names
  // neither, a repeated name and an unknown key are each refused.
  refused(string.replace(
    catalogue_file,
    "profile = \"cheap\"",
    "profile = \"ghost\"",
  ))
  refused(string.replace(
    catalogue_file,
    "model = \"opus\"\n",
    "model = \"ghost\"\n",
  ))
  refused(string.replace(catalogue_file, "profile = \"cheap\"\n", ""))
  refused(string.replace(catalogue_file, "\"refactors\"", "\"small fixes\""))
  refused(string.replace(
    catalogue_file,
    "use_for = \"large changes\"",
    "use_for = \"large changes\"\nextra = 1",
  ))
}

pub fn a_catalogue_holds_at_most_sixteen_agents_test() {
  let one =
    "[[project.agent]]\nname = \"a#\"\nuse_for = \"u\"\nmodel = \"opus\"\n"
  let build = fn(count: Int) {
    "[models.opus]\nprovider = \"x\"\n"
    <> string.concat(
      list.index_map(list.repeat(Nil, count), fn(_, index) {
        string.replace(one, "#", string.inspect(index + 1))
      }),
    )
  }
  let assert Ok(_) = project_settings.from_document(parsed(build(16)))
  let assert Error(_) = project_settings.from_document(parsed(build(17)))
  Nil
}
