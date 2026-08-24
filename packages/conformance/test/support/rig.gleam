//// Shared wiring fixtures for the e2e suite: the strand configuration,
//// the full tool registry, a gateway over the scripted transport, and
//// the production wiring config assembled from a live jail.

import broker/exec
import conformance/wiring
import core/clock
import gleam/option.{Some}
import machine/strand.{
  type StrandConfiguration, ModelIdentity, StrandConfiguration, ThinkingOff,
}
import provider/gateway.{type Gateway}
import provider/model.{ResolvedModel}
import provider/secret
import support/internal/ffi_shell
import support/jail.{type Jail}
import support/script.{type Turn}
import tools/bash
import tools/fs
import tools/grep
import tools/tool.{type Registry}

/// The strand configuration the e2e sessions run under. The identity
/// matches the scripted gateway's `Main` route, so dispatch resolves to
/// the full model facts.
pub fn configuration() -> StrandConfiguration {
  StrandConfiguration(
    model: ModelIdentity(provider: "acme", model_id: "loom-1"),
    thinking_level: ThinkingOff,
    active_tool_names: ["bash", "fs_read", "fs_edit", "fs_write", "grep"],
  )
}

/// The full core tool registry.
pub fn registry() -> Registry {
  tool.registry([
    bash.tool(),
    grep.tool(),
    fs.read_tool(),
    fs.write_tool(),
    fs.edit_tool(),
  ])
}

/// A real gateway whose only provider replays the scripted turns.
pub fn scripted_gateway(turns: List(Turn)) -> Gateway {
  gateway.new(
    transport: script.transport(turns),
    secrets: secret.from_list([#("ACME_KEY", "scripted-test-key")]),
    clock: clock.stepping(from: 1_700_000_000_000, by: 3),
  )
  |> gateway.add_provider(gateway.AnthropicProvider(
    name: "acme",
    base_url: "https://acme.test",
    api_key_secret: "ACME_KEY",
  ))
  |> gateway.route(model.Main, [
    ResolvedModel(
      provider: "acme",
      model_id: "loom-1",
      thinking: model.ThinkingOff,
      context_window: 200_000,
      max_output_tokens: 8192,
    ),
  ])
}

/// The production wiring config over a live jail and a scripted
/// gateway.
pub fn config(jail_rig: Jail, gw: Gateway) -> wiring.Config {
  wiring.Config(
    gateway: gw,
    role: model.Main,
    system: Some("Drive the workspace tools exactly as instructed."),
    fallback_context_window: 200_000,
    fallback_max_output_tokens: 8192,
    provider_timeout_ms: 30_000,
    broker: jail_rig.broker,
    broker_timeout_ms: 15_000,
    registry: registry(),
    workspace: jail_rig.workspace,
    blob_root: jail_rig.blob_root,
    base_policy: jail_rig.base_policy,
    grants: [],
    // This container's helper runs degraded (no bwrap/Landlock/cgroup
    // in the dev image), so the demand must accept degraded enforcement
    // and the tests assert on the helper's honest per-exec report
    // instead. Production sessions demand `exec.FullEnforcement`, which
    // refuses degraded helpers at dispatch and degraded exec_exit
    // reports at settlement (spec-gaps WP-G item 6).
    demand: exec.BestEffort,
    env: jail_rig.env,
    // Deliberately a little ahead of the jail's broker clock: budget
    // deadlines are computed from this clock and checked against the
    // broker's, so the tool-side era must not lag the broker-side one.
    clock: clock.stepping(from: 1_700_000_010_000, by: 25),
    entropy: ffi_shell.unique_integer,
  )
}
