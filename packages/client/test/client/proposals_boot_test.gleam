//// The proposal queue as the real boot wires it: the `propose` tool is in
//// the pinned prompt's tool index, the approved-rules file beside the session
//// reaches the prompt in its own fence and after the project's files, and a
//// session with no such file carries no fence at all.

import broker/exec
import client/catalog
import client/codemode
import client/jobs
import client/memory_config
import client/proposals
import client/retryconf
import client/schedule
import client/serve
import client/workspace_policy
import core/clock
import gleam/option.{None, Some}
import gleam/string
import machine/operation
import machine/strand as machine_strand
import provider/adapter/anthropic
import provider/gateway as provider_gateway
import provider/model
import provider/secret
import simplifile
import support/provider as provider_test

pub fn the_propose_tool_is_registered_and_no_rules_means_no_fence_test() {
  let root = fresh_root("none")
  let assert Ok(booted) = serve.boot(settings(root, "a.db"))
    as "the server must boot"
  assert string.contains(booted.instance.prompt.text, "propose")
  assert !string.contains(booted.instance.prompt.text, "approved-proposal path")
  serve.shutdown(booted)
}

pub fn an_approved_rules_file_reaches_the_pinned_prompt_after_project_files_test() {
  let root = fresh_root("rules")
  let assert Ok(Nil) =
    simplifile.write(root <> "/work/AGENTS.md", "project text")
  let assert Ok(Nil) =
    proposals.write_rules(
      root <> "/loom-rules.md",
      "### Rule prop-0000000001 (approved 2026-10-11, from session s)\n\nPrefer tabs.\n",
    )
  let assert Ok(booted) = serve.boot(settings(root, "a.db"))
    as "the server must boot"
  let text = booted.instance.prompt.text
  let assert Ok(#(before, after)) =
    string.split_once(
      text,
      "<instructions origin=approved-proposal path=loom-rules.md>",
    )
    as "the approved fence is in the prompt"
  assert string.contains(before, "origin=workspace path=")
  assert string.contains(before, "project text")
  assert string.contains(after, "Prefer tabs.")
  serve.shutdown(booted)
}

// --- the rig ----------------------------------------------------------------

fn settings(root: String, file: String) -> serve.Settings {
  let assert Ok(here) = simplifile.current_directory()
    as "the fixture locates its protocol-speaking helper"
  serve.Settings(
    peer_directory: None,
    peer_defaults: None,
    remote_reach: None,
    deadline_tick_ms: None,
    depth_cap: None,
    metering: None,
    spawner: None,
    laptop: None,
    first_prompt: None,
    profile_desk: None,
    evolution_role: serve.Source,
    codemode_sockets: None,
    secrets: secret.env(),
    secret_failures: [],
    session_path: root <> "/" <> file,
    domain_paths: None,
    bind_host: "127.0.0.1",
    bind_port: 0,
    token_path: root <> "/" <> file <> ".token",
    workspace: root <> "/work",
    base_policy: workspace_policy.base_policy(root <> "/work"),
    helper_path: here <> "/../sandbox/loom-exec",
    helper_pool_size: 2,
    session_id: file,
    demand: exec.BestEffort,
    gateway: dead_gateway(),
    catalog: scripted_catalog(),
    system: None,
    home: Some("build/no-operator-home"),
    model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
    context_window: 100_000,
    max_output_tokens: 4096,
    api: anthropic.api_name,
    compaction: operation.CompactionSettings(
      enabled: True,
      reserve_tokens: 16_384,
      keep_recent_tokens: 20_000,
    ),
    codemode_seed: root <> "/no-such-seed",
    codemode_seams: codemode.WorkspaceOnly,
    rules: [],
    schedules: [],
    schedule_policy: schedule.ModelSchedulesOff,
    jobs_policy: jobs.default_policy,
    retry_policy: retryconf.default_policy,
    deactivated_tools: [],
    memory: memory_config.default_options(),
    tools: catalog.default_tools(),
    advisor: None,
    go_caches: None,
  )
}

fn scripted_catalog() -> catalog.Catalog {
  catalog.Catalog(
    models: [
      catalog.CatalogModel(
        name: "acme",
        dialect: catalog.Anthropic,
        base_url: "https://acme.test",
        api_key_env: "ACME_KEY",
        model_id: "loom-1",
        context_window: 100_000,
        max_output_tokens: 4096,
        thinking: model.ThinkingOff,
        pricing: None,
        vision: catalog.TextOnly,
        max_images: 8,
        cyber_access: None,
        service_tier: None,
      ),
    ],
    roles: [#(model.Main, ["acme"])],
    profiles: [],
    mcp_servers: [],
    lsp_servers: [],
  )
}

fn dead_gateway() -> provider_gateway.Gateway {
  catalog.gateway(
    scripted_catalog(),
    transport: provider_test.silent(),
    secrets: secret.from_list([#("ACME_KEY", "test-key")]),
    clock: clock.fixed(at: 0),
  )
}

// Absolute, because the workspace root becomes the base policy's writable
// root and the boot refuses a policy whose paths the jail could not accept.
fn fresh_root(lane: String) -> String {
  let relative = "build/test_db/proposals-boot-" <> lane
  let _stale = simplifile.delete(relative)
  let assert Ok(Nil) = simplifile.create_directory_all(relative <> "/work")
    as "the test root must be creatable"
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner must have a working directory"
  here <> "/" <> relative
}
