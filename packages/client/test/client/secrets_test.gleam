//// The `[secrets]` table: what the catalogue accepts, what resolution
//// makes of a host command, and that a resolved value reaches all three
//// readers of a credential name.
////
//// The decode half uses no processes and no commands. The resolution
//// half runs `/bin/sh` on purpose: the point of the feature is that a
//// real host command produces the value, and a scripted runner alone
//// would prove only that this module's own arithmetic is consistent.
//// The two integration cases go through the seams a session actually
//// uses — the provider gateway's own dispatch, and the environment
//// builder a jailed tool's shell inherits — rather than re-asserting the
//// store.

import client/catalog
import client/secrets
import client/serve
import core/clock
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import provider/gateway
import provider/http
import provider/model
import provider/secret
import support/provider as provider_test

import core/message

// --- the [secrets] table ---------------------------------------------------

pub fn absent_table_names_no_entries_test() {
  assert secrets.parse("[models.a]\n") == Ok([])
}

pub fn command_entry_parses_test() {
  let text =
    "[secrets]\nGH_TOKEN = { command = [\"gh\", \"auth\", \"token\"] }\n"
  assert secrets.parse(text)
    == Ok([
      secrets.Entry(
        name: "GH_TOKEN",
        source: secrets.Command(argv: ["gh", "auth", "token"]),
      ),
    ])
}

pub fn entries_come_back_in_name_order_test() {
  let text =
    "[secrets]\nZED = { command = [\"z\"] }\nALPHA = { command = [\"a\"] }\n"
  let assert Ok(entries) = secrets.parse(text)
  assert list.map(entries, fn(entry) { entry.name }) == ["ALPHA", "ZED"]
}

pub fn a_command_that_is_not_an_array_is_refused_test() {
  let assert Error(reason) =
    secrets.parse("[secrets]\nGH_TOKEN = { command = \"gh auth token\" }\n")

  // The entry is named, because an operator with several of them needs
  // to know which line to open.
  assert string.contains(reason, "secrets.GH_TOKEN.command")
}

pub fn an_empty_command_is_refused_test() {
  let assert Error(reason) =
    secrets.parse("[secrets]\nGH_TOKEN = { command = [] }\n")
  assert string.contains(reason, "secrets.GH_TOKEN.command")
}

pub fn an_unknown_source_key_is_refused_test() {
  let assert Error(reason) =
    secrets.parse("[secrets]\nGH_TOKEN = { commnad = [\"gh\"] }\n")
  assert string.contains(reason, "commnad")
  assert string.contains(reason, "secrets.GH_TOKEN")
}

pub fn an_entry_that_is_not_a_table_is_refused_test() {
  let assert Error(reason) = secrets.parse("[secrets]\nGH_TOKEN = \"gho_x\"\n")
  assert string.contains(reason, "secrets.GH_TOKEN")
}

pub fn the_catalogue_accepts_the_table_test() {
  // `client/catalog` is the one place top-level table names are checked,
  // so a `[secrets]` table it does not know about would be refused by
  // the catalogue however well `secrets.parse` understood it.
  let text =
    "[models.acme]\ndialect = \"anthropic\"\napi_key_env = \"GH_TOKEN\"\n"
    <> "model_id = \"m\"\ncontext_window = 1000\nmax_output_tokens = 100\n"
    <> "[roles]\nmain = [\"acme\"]\n"
    <> "[secrets]\nGH_TOKEN = { command = [\"gh\"] }\n"
  let assert Ok(_catalogue) = catalog.parse(text)
}

// --- resolution ------------------------------------------------------------

fn entry(name: String, argv: List(String)) -> secrets.Entry {
  secrets.Entry(name:, source: secrets.Command(argv:))
}

pub fn a_host_command_supplies_the_value_test() {
  let #(resolved, failures) =
    secrets.resolve(
      [entry("K", ["/bin/sh", "-c", "printf 'secret\n'"])],
      running: secrets.host_runner(),
      within: secrets.default_timeout_ms,
    )

  // Exactly one trailing newline comes off; the value is otherwise the
  // bytes the command wrote.
  assert resolved == [#("K", "secret")]
  assert failures == []
}

pub fn interior_whitespace_survives_test() {
  let #(resolved, _failures) =
    secrets.resolve(
      [entry("K", ["/bin/sh", "-c", "printf 'a b \n'"])],
      running: secrets.host_runner(),
      within: secrets.default_timeout_ms,
    )

  // Only the newline is a framing artefact. A trailing space inside the
  // value is the vault's, and trimming it would hand a different
  // credential to the wire than the one the operator stored.
  assert resolved == [#("K", "a b ")]
}

pub fn a_failing_command_yields_a_warning_and_no_value_test() {
  let #(resolved, failures) =
    secrets.resolve(
      [entry("K", ["/bin/sh", "-c", "exit 3"])],
      running: secrets.host_runner(),
      within: secrets.default_timeout_ms,
    )
  assert resolved == []
  let assert [secrets.Failure(name: "K", reason:)] = failures
  assert string.contains(reason, "3")
}

pub fn an_empty_success_yields_a_failure_and_no_value_test() {
  // A scripted runner, because the case being pinned is the resolution
  // rule rather than any host command's behaviour: exit 0 with nothing
  // on stdout.
  let runner = fn(_argv, _timeout_ms) { Ok(secrets.Capture(0, "")) }
  let #(resolved, failures) =
    secrets.resolve(
      [entry("K", ["helper"])],
      running: runner,
      within: secrets.default_timeout_ms,
    )
  assert resolved == []
  let assert [secrets.Failure(name: "K", reason:)] = failures
  assert string.contains(reason, "no output")
}

pub fn a_newline_only_success_yields_a_failure_test() {
  // The newline is framing, so a helper that writes only one has still
  // written nothing. It has to land on the failure side too, or the name
  // would be bound to "" and stop falling through.
  let runner = fn(_argv, _timeout_ms) { Ok(secrets.Capture(0, "\n")) }
  let #(resolved, failures) =
    secrets.resolve(
      [entry("K", ["helper"])],
      running: runner,
      within: secrets.default_timeout_ms,
    )
  assert resolved == []
  assert list.length(failures) == 1
}

pub fn an_empty_result_leaves_the_environment_in_charge_test() {
  // The consequence the rule exists for. An operator who exported the
  // variable *and* wrote an entry for it keeps the exported value when
  // the helper says nothing, instead of an empty header.
  let runner = fn(_argv, _timeout_ms) { Ok(secrets.Capture(0, "")) }
  let #(resolved, _failures) =
    secrets.resolve(
      [entry("K", ["helper"])],
      running: runner,
      within: secrets.default_timeout_ms,
    )
  let base = secret.from_list([#("K", "from the environment")])
  assert secret.lookup(secrets.store(resolved, beneath: base), "K")
    == Ok("from the environment")
}

pub fn a_command_that_is_not_on_path_yields_a_failure_test() {
  let #(resolved, failures) =
    secrets.resolve(
      [entry("K", ["loom-no-such-credential-helper"])],
      running: secrets.host_runner(),
      within: secrets.default_timeout_ms,
    )
  assert resolved == []
  let assert [secrets.Failure(name: "K", reason:)] = failures
  assert string.contains(reason, "PATH")
}

pub fn a_slow_command_times_out_test() {
  let #(resolved, failures) =
    secrets.resolve(
      [entry("K", ["/bin/sh", "-c", "sleep 30"])],
      running: secrets.host_runner(),
      within: 250,
    )
  assert resolved == []
  let assert [secrets.Failure(name: "K", reason:)] = failures
  assert string.contains(reason, "in time")
}

pub fn a_resolved_value_beats_the_environment_test() {
  let base = secret.from_list([#("K", "from the environment")])
  let store = secrets.store([#("K", "from the table")], beneath: base)
  assert secret.lookup(store, "K") == Ok("from the table")
}

pub fn an_unresolved_name_falls_back_to_the_environment_test() {
  let base = secret.from_list([#("OTHER", "from the environment")])
  let store = secrets.store([#("K", "from the table")], beneath: base)
  assert secret.lookup(store, "OTHER") == Ok("from the environment")
  assert secret.lookup(store, "MISSING") == Error(Nil)
}

// --- the three readers -----------------------------------------------------

pub fn a_resolved_value_reaches_the_provider_wire_test() {
  // The whole point of layering the table over the environment store is
  // that `api_key_env` needs no notion of where its value came from.
  // This asserts the header, not the store: the request is dispatched
  // through the real gateway and the transport reports what it was
  // handed.
  let headers = process.new_subject()
  let transport =
    provider_test.transport(fn(request, events) {
      process.send(headers, request.headers)
      process.send(events, http.RequestFailed(reason: "fixture stops here"))
    })

  let store =
    secrets.store(
      [#("GH_TOKEN", "resolved-value")],
      beneath: secret.from_list([]),
    )
  let gw =
    gateway.new(transport:, secrets: store, clock: clock.fixed(at: 1))
    |> gateway.add_provider(gateway.AnthropicProvider(
      name: "acme",
      base_url: "https://acme.test",
      api_key_secret: "GH_TOKEN",
    ))
    |> gateway.route(model.Main, [
      model.ResolvedModel(
        provider: "acme",
        model_id: "m",
        thinking: model.ThinkingOff,
        context_window: 1000,
        max_output_tokens: 100,
      ),
    ])
    |> gateway.with_attempt_timeout(2000)

  let _handle = gateway.request(gw, one_request())
  let assert Ok(sent) = process.receive(headers, within: 2000)
  assert list.key_find(sent, "x-api-key") == Ok("resolved-value")
}

pub fn a_resolved_value_reaches_a_jailed_tool_environment_test() {
  // `[tools] env` is the second reader, and it reads through the same
  // seam `boot` hands `tool_environment`. A name the table resolved is a
  // pair in the child's environment rather than an `env_unset` warning.
  let store =
    secrets.store(
      [#("GH_TOKEN", "resolved-value")],
      beneath: secret.from_list([]),
    )
  let tools =
    catalog.ToolsConfig(..catalog.default_tools(), env: ["GH_TOKEN", "ABSENT"])

  let #(environment, unset) =
    serve.tool_environment("/work", None, tools, reading: fn(name) {
      secret.lookup(store, name)
    })
  assert list.key_find(environment, "GH_TOKEN") == Ok("resolved-value")
  assert unset == ["ABSENT"]
}

fn one_request() -> model.ProviderRequest {
  model.ProviderRequest(
    target: model.ForRole(model.Main, None),
    system: Some("Be terse."),
    messages: [
      message.UserMessage(
        content: [message.UserText(text: "hi", text_signature: None)],
        timestamp: 1,
        origin: None,
      ),
    ],
    tools: [],
    max_output_tokens: None,
  )
}
