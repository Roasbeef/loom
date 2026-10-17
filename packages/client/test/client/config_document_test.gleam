//// One document per configuration load preserves table values and refusal
//// order. The real saved-session resolver must still reread both the file and
//// secret commands on every open; no daemon or provider request is needed.

import broker/policy
import client/catalog
import client/jobs
import client/memory_config
import client/owned_assembly_test
import client/retryconf
import client/rules
import client/schedule
import client/secrets
import client/serve
import filepath
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/operation
import provider/secret
import simplifile
import storage/catalogue
import storage/domain

const models =
  "
[models.base]
dialect = \"anthropic\"
api_key_env = \"CONFIG_TEST_KEY\"
model_id = \"base-model\"
context_window = 1000
max_output_tokens = 100
[models.alt]
dialect = \"openai\"
api_key_env = \"CONFIG_TEST_KEY\"
model_id = \"alt-model\"
context_window = 2000
max_output_tokens = 200
[roles]
main = [\"base\"]
advisor = [\"alt\"]
[profiles.alt.roles]
main = [\"alt\"]
"

const tables =
  "
[[rule]]
name = \"first\"
triggers = [\"migration\"]
body = \"Check schema.\"
[[rule]]
name = \"second\"
triggers = [\"tests\"]
body = \"Run focused checks.\"
[[schedule]]
name = \"watch\"
every = \"120s\"
body = \"Check background work.\"
[schedules]
model_created = \"wake\"
[jobs]
max_wall = 7200
heartbeat_s = 7
[retry]
attempts = 3
base_delay_ms = 50
max_delay_ms = 500
[memory]
inject = \"off\"
[tools]
network = \"off\"
env = [\"CONFIG_TEST_KEY\"]
[tools.set]
CONFIG_LITERAL = \"kept\"
[secrets]
CONFIG_TEST_KEY = { command = [\"/bin/sh\", \"-c\", \"printf fixture-secret\"] }
[workspace]
read_scope = \"workspace\"
go_cache_limit_mib = 123
mounts = [{ path = \"/fixture-read-only\", access = \"ro\" }]
[advisor]
tools = [\"grep\"]
feed_every_steps = 3
block_cooldown_reviews = 4
"

pub fn shared_document_readers_preserve_populated_values_test() {
  let text = models <> tables
  let assert Ok(#(parsed, document)) = catalog.parse_with_document(text)
    as "a populated mixed configuration validates"
  assert catalog.parse(text) == Ok(parsed)
  let assert Ok(main) = catalog.main_model(parsed) as "main is routed"
  assert main.name == "base"

  assert rules.from_document(document) == rules.parse(text)
  assert schedule.from_document(document) == schedule.parse(text)
  assert schedule.policy_from_document(document) == schedule.parse_policy(text)
  assert jobs.policy_from_document(document) == jobs.parse_policy(text)
  assert retryconf.policy_from_document(document)
    == retryconf.parse_policy(text)
  assert memory_config.from_document(document) == memory_config.parse(text)
  assert catalog.tools_from_document(document) == catalog.parse_tools(text)
  assert secrets.from_document(document) == secrets.parse(text)
  assert catalog.workspace_from_document(document)
    == catalog.parse_workspace(text)
  assert catalog.advisor_from_document(document) == catalog.parse_advisor(text)

  let assert Ok([first, second]) = rules.from_document(document)
    as "rules retain their file order"
  assert [first.name, second.name] == ["first", "second"]
  assert jobs.policy_from_document(document)
    == Ok(jobs.JobsPolicy(max_wall_ms: 7_200_000, heartbeat_ms: 7000))
  assert retryconf.policy_from_document(document)
    == Ok(operation.NormalizedRetryPolicy(operation.Bounded(3), 50, 500))
  let assert Ok(workspace) = catalog.workspace_from_document(document)
    as "workspace settings survive the shared parse"
  assert workspace.read_scope == catalog.WorkspaceReads
  assert workspace.go_cache_limit_mib == 123
  assert workspace.mounts
    == [catalog.WorkspaceMount("/fixture-read-only", policy.MountReadOnly)]
}

pub fn shared_document_reaches_real_session_settings_test() {
  let #(record, selected, state) = fixture(models <> tables)
  let assert Ok(settings) = resolve(record, selected, state)
    as "the session resolver reads every populated table"
  assert list.map(settings.rules, fn(rule) { rule.name }) == ["first", "second"]
  assert list.map(settings.schedules, fn(item) { item.name }) == ["watch"]
  assert settings.schedule_policy == schedule.ModelSchedulesWake
  assert settings.jobs_policy == jobs.JobsPolicy(7_200_000, 7000)
  assert settings.retry_policy
    == operation.NormalizedRetryPolicy(operation.Bounded(3), 50, 500)
  assert settings.memory.inject == memory_config.InjectsNothing
  assert settings.tools.network == catalog.ToolNetworkOff
  assert settings.tools.env == ["CONFIG_TEST_KEY"]
  assert settings.tools.set == [#("CONFIG_LITERAL", "kept")]
  assert secret.lookup(settings.secrets, "CONFIG_TEST_KEY")
    == Ok("fixture-secret")
  let assert Some(advisor) = settings.advisor
    as "the configured advisor resolves"
  assert advisor.model.provider == "alt"
  assert advisor.tools == ["grep"]
  assert advisor.feed_every_steps == 3
  assert advisor.block_cooldown_reviews == 4
}

pub fn standalone_parsers_keep_exact_syntax_error_wording_test() {
  let malformed = "duplicate = 1\nduplicate = 2\n"
  let short = "not valid toml: the key duplicate appears twice"
  let verbose =
    "the configuration is not valid TOML: KeyAlreadyInUse([\"duplicate\"])"
  assert catalog.parse(malformed) == Error(short)
  assert catalog.parse_with_document(malformed) == Error(short)
  assert rules.parse(malformed) == Error(short)
  assert schedule.parse(malformed) == Error(short)
  assert schedule.parse_policy(malformed) == Error(short)
  assert catalog.parse_tools(malformed) == Error(short)
  assert catalog.parse_workspace(malformed) == Error(short)
  assert catalog.parse_advisor(malformed) == Error(short)
  assert jobs.parse_policy(malformed) == Error(verbose)
  assert retryconf.parse_policy(malformed) == Error(verbose)
  assert memory_config.parse(malformed) == Error(verbose)
  assert secrets.parse(malformed) == Error(verbose)
}

pub fn catalogue_then_choice_precedes_other_table_errors_test() {
  let bad_rule = "rule = 0\n"
  let #(record, selected, state) = fixture(bad_rule <> models)
  let both_missing =
    catalogue.Registration(..record, profile: Some("gone"), model: Some("gone"))
  let assert Ok(parsed) = catalog.parse(models) as "catalogue is valid"
  let assert Error(profile_error) = catalog.select_profile(parsed, "gone")
    as "profile is absent"
  assert resolve(both_missing, selected, state)
    == Error(record.configuration <> ": " <> profile_error)

  let assert Error(model_error) = catalog.select_model(parsed, "gone")
    as "model is absent"
  assert resolve(
      catalogue.Registration(..both_missing, profile: Some("alt")),
      selected,
      state,
    )
    == Error(record.configuration <> ": " <> model_error)

  let strict = "typo = 0\n" <> bad_rule <> models
  let assert Ok(Nil) = simplifile.write(record.configuration, strict)
    as "top-level typo is written"
  let assert Error(catalog_error) = catalog.parse(strict)
    as "catalogue is strict"
  assert resolve(both_missing, selected, state)
    == Error(record.configuration <> ": " <> catalog_error)
}

pub fn remaining_table_errors_keep_their_original_order_test() {
  assert_error_ladder([
    #(
      "rule = 0",
      "rule must be an array of [[rule]] tables, each with name, triggers and body",
    ),
    #(
      "schedule = 0",
      "schedule must be an array of [[schedule]] tables, each with name, a timing (every, cron or at), and body",
    ),
    #("schedules = 0", "[schedules] must be a table"),
    #("jobs = 0", "[jobs] must be a table"),
    #("retry = 0", "[retry] must be a table"),
    #("memory = 0", "[memory] must be a table"),
    #("tools = 0", "tools must be a [tools] table"),
    #(
      "secrets = 0",
      "secrets must be a [secrets] table naming one variable per entry",
    ),
    #("workspace = 0", "workspace must be a [workspace] table"),
    #("advisor = 0", "advisor must be an [advisor] table"),
  ])
}

fn assert_error_ladder(errors: List(#(String, String))) {
  case errors {
    [] -> Nil
    [#(_bad, expected), ..rest] -> {
      let text =
        string.join(list.map(errors, fn(item) { item.0 }), "\n") <> models
      let #(record, selected, state) = fixture(text)
      assert resolve(record, selected, state)
        == Error(record.configuration <> ": " <> expected)
      assert_error_ladder(rest)
    }
  }
}

pub fn another_open_rereads_configuration_and_resolves_secrets_again_test() {
  let #(record, selected, state) = fixture(models)
  let token = state <> "/synthetic-token"
  let text =
    models
    <> "\n[secrets]\nCONFIG_TEST_KEY = { command = [\"/bin/cat\", \""
    <> token
    <> "\"] }\n"
  let assert Ok(Nil) = simplifile.write(record.configuration, text)
    as "the file names a changing synthetic credential"
  let assert Ok(Nil) = simplifile.write(token, "before\n")
    as "initial credential exists"
  let assert Ok(first) = resolve(record, selected, state)
    as "first open resolves"
  assert secret.lookup(first.secrets, "CONFIG_TEST_KEY") == Ok("before")

  // The configuration bytes are unchanged: a cache keyed by those bytes must
  // not keep a credential command's old output.
  let assert Ok(Nil) = simplifile.write(token, "after\n")
    as "credential rotates"
  let assert Ok(second) = resolve(record, selected, state)
    as "next open resolves"
  assert secret.lookup(second.secrets, "CONFIG_TEST_KEY") == Ok("after")
  assert secret.lookup(first.secrets, "CONFIG_TEST_KEY") == Ok("before")

  let changed =
    string.replace(text, "base-model", "rewritten-model")
    <> "\n[jobs]\nmax_wall = 9000\n"
  let assert Ok(Nil) = simplifile.write(record.configuration, changed)
    as "the same config path is rewritten"
  let assert Ok(third) = resolve(record, selected, state)
    as "rewritten config resolves"
  assert third.model.model_id == "rewritten-model"
  assert third.jobs_policy.max_wall_ms == 9_000_000

  let invalid = "typo = 0\n" <> changed
  let assert Ok(Nil) = simplifile.write(record.configuration, invalid)
    as "the file becomes invalid"
  let assert Error(reason) = catalog.parse(invalid) as "the rewrite is refused"
  assert resolve(record, selected, state)
    == Error(record.configuration <> ": " <> reason)
}

// A registered workspace avoids local toolchain/cache discovery. Resolution
// still uses the production load and secret paths and writes private domain
// directories; the fixture never starts a helper, a daemon or inference.
fn fixture(text: String) -> #(catalogue.Registration, domain.Domain, String) {
  let settings = owned_assembly_test.settings()
  let state = filepath.directory_name(settings.session_path)
  let assert Ok(Nil) = simplifile.create_directory_all(state)
    as "fixture directory exists"
  let config = state <> "/loom.toml"
  let assert Ok(Nil) = simplifile.write(config, text) as "fixture config exists"
  let record =
    catalogue.Registration(
      id: "configuration-document",
      path: settings.session_path,
      workspace: settings.workspace,
      name: "Configuration document",
      configuration: config,
      created_at: 1,
      request_key: "configuration-document",
      state: catalogue.Saved,
      profile: None,
      model: None,
      executor: "fixture-executor",
      pool: "",
      subtitle: None,
    )
  let selected =
    domain.Domain(
      domain.key(domain.SessionOnly, record.workspace, record.id),
      domain.SessionOnly,
      record.workspace,
      config,
      state <> "/domain/memory.sqlite",
      state <> "/domain/index.sqlite",
    )
  #(record, selected, state)
}

fn resolve(
  record: catalogue.Registration,
  selected: domain.Domain,
  state: String,
) -> Result(serve.Settings, String) {
  serve.resolve_managed([], record, selected, state)
}
