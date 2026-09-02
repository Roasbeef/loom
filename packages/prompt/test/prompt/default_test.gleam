//// The shipped pack, checked as content rather than as syntax.
////
//// These tests hold what the design and the adversarial judgment
//// settled: the build-constant sections stay build-constant, so every
//// strand in a session shares one cached prefix; the sandbox section
//// states posture behaviourally, always says something about
//// enforcement, and tells a degraded host's agent that it is looking at
//// a host failure rather than a policy denial; and the delegation
//// section states the facts about the `agent_*` tools that their
//// schemas cannot carry.

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
    available_tools: [],
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
  assert decoded.version == "loom-default-4"
}

pub fn shipped_pack_has_no_problems_test() {
  // Every canonical section, every selectable fragment, and no
  // placeholder the renderer cannot bind.
  assert pack.problems(shipped()) == []
}

pub fn shipped_pack_carries_the_canonical_sections_in_design_order_test() {
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
  // including model-spawned children. A placeholder in any of these
  // would make the prompt vary with the host for text that has no reason
  // to.
  list.each(["identity", "tool_discipline", "delegation", "conduct"], fn(name) {
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

// --- the delegation section ----------------------------------------------
//
// The six `agent_*` schemas are on the wire, so the model already knows
// these tools exist. What the pack owes it is the policy a schema cannot
// carry, and each test below pins one fact that is true of the code in
// `tools/agent` and `client/agency` and false of a plausible guess.

pub fn delegation_is_rendered_on_every_host_test() {
  // Placeholder-free, so it is the same bytes for every strand of every
  // session on this build — and never dropped as an empty section.
  let assert Ok(section) =
    list.find(shipped().sections, fn(section) { section.name == "delegation" })
  assert pack.placeholders(section.template) == []
  list.each(
    [pack.FullyEnforced, pack.DegradedRefusing, pack.BestEffort],
    fn(enforcement) {
      assert string.contains(
        phrases(enforcement),
        "a subagent is a strand of this session",
      )
    },
  )
}

pub fn delegation_says_a_wait_holds_the_operation_open_test() {
  // `agent_wait` blocks between the intent and settle commits, and a
  // steer committed in that window drains only at the next checkpoint.
  // An agent that does not know this cannot trade it off.
  let rendered = phrases(pack.FullyEnforced)
  assert string.contains(
    rendered,
    "waiting blocks the operation you are inside and holds it open",
  )
  assert string.contains(rendered, "queued rather than dropped")
  assert string.contains(rendered, "reaches you only at your next checkpoint")
}

pub fn delegation_says_to_wait_on_the_batch_test() {
  // `agent_wait` takes an array against one deadline whatever
  // `tool_execution` says: a session can set it back to sequential, and
  // one `Exclusive` sibling fences a parallel batch, either of which
  // turns eight one-handle waits into eight serial windows.
  let rendered = phrases(pack.FullyEnforced)
  assert string.contains(rendered, "spawn the batch, then wait on the batch")
  assert string.contains(
    rendered,
    "one wait takes a list of handles and joins them all against one deadline",
  )
  assert string.contains(rendered, "comes back pending")
}

pub fn delegation_states_the_descendant_only_addressing_rule_test() {
  // The rule the Agency enforces: wait only downward, address a parent
  // or a descendant. A refusal is cheaper if it is never attempted.
  let rendered = phrases(pack.FullyEnforced)
  assert string.contains(rendered, "wait only on what you spawned")
  assert string.contains(
    rendered,
    "address only your parent or something below you",
  )
  assert string.contains(rendered, "refused rather than queued")
}

pub fn delegation_says_a_childs_answer_is_its_last_message_test() {
  // `LastResult` carries `final_assistant: Option(EntryId)` and no
  // payload, so the report is the child's last assistant text and there
  // is no structured result format to write a brief against.
  let rendered = phrases(pack.FullyEnforced)
  assert string.contains(
    rendered,
    "its last assistant message, not a structured report",
  )
  assert string.contains(rendered, "a final answer that stands on its own")
  // `Ready` carries the child's blackboard cells beside its report, so
  // notes are the one way a child can hand back something with shape.
  assert string.contains(rendered, "a child's notes come back with its result")
}

pub fn delegation_distinguishes_a_note_from_a_message_test() {
  // `agent_note` writes a durable cell and notifies nobody; `agent_send`
  // lands in a run, and a send to a finished parent is refused outright.
  let rendered = phrases(pack.FullyEnforced)
  assert string.contains(rendered, "writing one notifies nobody")
  assert string.contains(rendered, "read once")
  assert string.contains(rendered, "parent whose run has ended is refused")
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

// --- the available-tools index -------------------------------------------

fn with_snippets(snippets: List(String)) -> String {
  pack.render(
    shipped(),
    pack.environment(
      workspace: "/work",
      platform: "linux/x86_64",
      shell: "/bin/bash",
      tools: ["bash", "fs_read"],
      available_tools: snippets,
      enforcement: pack.FullyEnforced,
      network: pack.NetworkBlocked,
      protected_paths: [],
      repository_guidance: None,
    ),
  )
}

pub fn the_index_renders_in_the_order_it_was_given_test() {
  // Registration order, not sorted order: the host's own tools follow
  // the core ones, which is how an operator reads the list.
  let rendered =
    with_snippets(["`grep` searches.", "`bash` runs.", "`fs_read` reads."])
  assert string.contains(
    rendered,
    "- `grep` searches.\n- `bash` runs.\n- `fs_read` reads.",
  )
}

pub fn the_index_is_absent_when_nothing_carries_a_snippet_test() {
  // A section that renders to nothing is dropped along with its blank
  // line, so a host with no snippets pays no bytes and reads no dangling
  // heading.
  let rendered = with_snippets([])
  assert !string.contains(string.lowercase(rendered), "one line each")
}

pub fn the_index_says_the_schema_is_what_binds_test() {
  // The snippet is an index entry; the wire tool array is the contract.
  // A model that read the line as the specification would call tools
  // wrong, so the fragment says which of the two is authoritative.
  let rendered = string.lowercase(with_snippets(["`bash` runs."]))
  assert string.contains(rendered, "not a specification")
  assert string.contains(rendered, "callable all the same")
}

pub fn rendering_the_same_index_twice_gives_the_same_bytes_test() {
  // The prompt sits behind a one-hour cache breakpoint whose economics
  // rest on the head not moving.
  let snippets = ["`bash` runs.", "`grep` searches."]
  assert with_snippets(snippets) == with_snippets(snippets)
}
