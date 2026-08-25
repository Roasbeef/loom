//// The shipped pack, checked as content rather than as syntax.
////
//// These tests hold the two things the design and the adversarial
//// judgment settled: the build-constant sections stay build-constant, so
//// every strand in a session shares one cached prefix; and the sandbox
//// section states posture behaviourally, always says something about
//// enforcement, and tells a degraded host's agent that it is looking at
//// a host failure rather than a policy denial.

import gleam/list
import gleam/option.{None}
import gleam/string
import prompt/default
import prompt/pack.{type Environment, type Pack}

fn shipped() -> Pack {
  let assert Ok(decoded) = pack.decode(default.source)
  decoded
}

fn on(enforcement: pack.Enforcement) -> Environment {
  pack.environment(
    workspace: "/work",
    platform: "linux/x86_64",
    shell: "/bin/bash",
    tools: ["bash", "fs_read"],
    enforcement:,
    network: pack.NetworkBlocked,
    protected_paths: [],
    repository_guidance: None,
  )
}

// The rendered prompt, lowercased and with every run of whitespace
// collapsed to one space, so an assertion about a phrase is not an
// assertion about where the pack happens to wrap its lines.
fn phrases(enforcement: pack.Enforcement) -> String {
  pack.render(shipped(), on(enforcement))
  |> string.lowercase
  |> string.split(on: "\n")
  |> list.map(string.trim)
  |> string.join(" ")
}

// --- the pack is complete and well formed --------------------------------

pub fn shipped_pack_decodes_test() {
  let assert Ok(decoded) = pack.decode(default.source)
  assert decoded.version == "loom-default-1"
}

pub fn shipped_pack_has_no_problems_test() {
  // Every canonical section, every selectable fragment, and no
  // placeholder the renderer cannot bind.
  assert pack.problems(shipped()) == []
}

pub fn shipped_pack_carries_the_six_sections_in_design_order_test() {
  let rendered =
    list.filter(shipped().sections, fn(section) {
      !string.starts_with(section.name, "_")
    })
  assert list.map(rendered, fn(section) { section.name })
    == pack.canonical_sections
}

// --- the build-constant half ---------------------------------------------

pub fn build_constant_sections_carry_no_placeholders_test() {
  // Guarantee 3 of the stability contract: identical for every strand,
  // including model-spawned children. A placeholder in one of these
  // three would make the prompt vary with the host for text that has no
  // reason to.
  list.each(["identity", "tool_discipline", "conduct"], fn(name) {
    let assert Ok(section) =
      list.find(shipped().sections, fn(section) { section.name == name })
    assert pack.placeholders(section.template) == []
  })
}

pub fn host_specific_sections_use_only_environment_bindings_test() {
  list.each(shipped().sections, fn(section) {
    list.each(pack.placeholders(section.template), fn(name) {
      assert list.contains(pack.binding_names, name)
    })
  })
}

// --- the sandbox section, as the judgment rewrote it ---------------------

pub fn sandbox_never_enumerates_kernel_layers_test() {
  // The judgment allows withholding a layer inventory and requires
  // behavioural posture instead. A layer name here would be both an
  // injection payload's map of the holes and a claim the agent cannot
  // act on.
  list.each(
    ["seccomp", "landlock", "bwrap", "cgroup", "namespace", "prctl", "apparmor"],
    fn(layer) {
      list.each(
        [pack.FullyEnforced, pack.DegradedRefusing, pack.BestEffort],
        fn(enforcement) {
          assert !string.contains(phrases(enforcement), layer)
        },
      )
    },
  )
}

pub fn enforcement_is_stated_on_every_host_test() {
  // Open question 4, answered no: the line is never omitted, because the
  // presence of the line on every host is what makes its variation
  // meaningful.
  let enforced = phrases(pack.FullyEnforced)
  let degraded = phrases(pack.DegradedRefusing)
  let best_effort = phrases(pack.BestEffort)
  assert string.contains(enforced, "confinement on this host is complete")
  assert string.contains(degraded, "cannot provide the confinement")
  assert string.contains(best_effort, "best-effort mode")
  assert enforced != degraded
  assert degraded != best_effort
}

pub fn degraded_names_a_host_failure_not_a_policy_denial_test() {
  // The judgment's item 5: on a degraded production host every jailed
  // execution is refused, and the agent must be able to tell that from a
  // policy denial — the two demand different behaviour.
  let degraded = phrases(pack.DegradedRefusing)
  assert string.contains(degraded, "host failure, not a policy denial")
  assert string.contains(degraded, "refused outright")
  assert string.contains(degraded, "no escalation clears it")
}

pub fn only_the_degraded_host_is_told_escalation_will_not_help_test() {
  // The escalation sentence in the shared body is true wherever jailed
  // execution actually runs; the degraded fragment is what withdraws it.
  let enforced = phrases(pack.FullyEnforced)
  assert string.contains(enforced, "widened re-execution")
  assert !string.contains(enforced, "no escalation clears it")
}

pub fn best_effort_warns_that_success_is_not_permission_test() {
  let best_effort = phrases(pack.BestEffort)
  assert string.contains(
    best_effort,
    "succeeding as evidence that it was permitted",
  )
}

pub fn network_posture_is_stated_behaviourally_test() {
  let blocked = phrases(pack.FullyEnforced)
  assert string.contains(blocked, "network egress is blocked")
  assert string.contains(blocked, "enforced below you")
}

// --- the environment section stays frugal --------------------------------

pub fn environment_section_states_only_workspace_platform_and_shell_test() {
  let assert Ok(section) =
    list.find(shipped().sections, fn(section) { section.name == "environment" })
  assert pack.placeholders(section.template)
    == ["workspace", "platform", "shell"]
}
