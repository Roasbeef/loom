//// Rendering: substitution, fragment selection, the repository-guidance
//// frame, and the byte-stability contract the caching work depends on.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import prompt/default
import prompt/pack.{type Environment, type Pack}

// --- fixtures ------------------------------------------------------------

fn decoded(body: String) -> Pack {
  let assert Ok(decoded) =
    pack.decode("%% loom-prompt-pack 1\n%% version test-1\n" <> body)
  decoded
}

fn shipped() -> Pack {
  let assert Ok(decoded) = pack.decode(default.source)
  decoded
}

// A plain host: full enforcement, no network, nothing protected, no
// repository guidance. Tests vary one field from this at a time.
fn host() -> Environment {
  pack.environment(
    workspace: "/work",
    platform: "linux/x86_64",
    shell: "/bin/bash",
    tools: ["bash", "fs_read"],
    enforcement: pack.FullyEnforced,
    network: pack.NetworkBlocked,
    protected_paths: [],
    repository_guidance: None,
  )
}

// --- substitution --------------------------------------------------------

pub fn render_substitutes_environment_fields_test() {
  let rendered =
    pack.render(
      decoded("%% section environment\n{workspace} {platform} {shell}"),
      host(),
    )
  assert rendered == "/work linux/x86_64 /bin/bash"
}

pub fn render_joins_list_fields_test() {
  assert pack.render(decoded("%% section environment\n{tools}"), host())
    == "bash, fs_read"
}

pub fn render_leaves_an_unknown_placeholder_empty_test() {
  // Total by the design's rule: a pack naming a binding that does not
  // exist renders nothing rather than crashing a session at open.
  assert pack.render(decoded("%% section environment\n[{today}]"), host())
    == "[]"
}

pub fn render_leaves_an_unclosed_brace_alone_test() {
  assert pack.render(decoded("%% section environment\n{workspace"), host())
    == "{workspace"
}

pub fn render_leaves_non_placeholder_braces_alone_test() {
  // Prompt prose carries JSON examples; those braces are content.
  let template = "%% section environment\n{ \"tool\": {} } {A} {a-b}"
  assert pack.render(decoded(template), host()) == "{ \"tool\": {} } {A} {a-b}"
}

pub fn render_drops_fragments_from_the_output_test() {
  let text = "%% section identity\nkept\n%% section _hidden\nnever"
  assert pack.render(decoded(text), host()) == "kept"
}

pub fn render_drops_a_section_that_renders_to_nothing_test() {
  // An absent fragment must not leave a hole with blank lines around it.
  let text =
    "%% section identity\na\n%% section environment\n{protected}\n%% section conduct\nb"
  assert pack.render(decoded(text), host()) == "a\n\nb"
}

pub fn render_separates_sections_with_one_blank_line_test() {
  let text = "%% section identity\na\n%% section conduct\nb"
  assert pack.render(decoded(text), host()) == "a\n\nb"
}

pub fn render_collapses_blank_runs_and_trailing_space_test() {
  let text = "%% section identity\na   \n\n\n\nb"
  assert pack.render(decoded(text), host()) == "a\n\nb"
}

// --- fragment selection --------------------------------------------------

fn enforcement_line(enforcement: pack.Enforcement) -> String {
  let text =
    "%% section sandbox\n{enforcement}\n"
    <> "%% section _enforcement_enforced\nenforced\n"
    <> "%% section _enforcement_degraded\ndegraded\n"
    <> "%% section _enforcement_best_effort\nbest effort"
  pack.render(
    decoded(text),
    pack.environment(
      workspace: "/work",
      platform: "p",
      shell: "s",
      tools: [],
      enforcement:,
      network: pack.NetworkBlocked,
      protected_paths: [],
      repository_guidance: None,
    ),
  )
}

pub fn render_selects_the_enforcement_fragment_test() {
  assert enforcement_line(pack.FullyEnforced) == "enforced"
  assert enforcement_line(pack.DegradedRefusing) == "degraded"
  assert enforcement_line(pack.BestEffort) == "best effort"
}

fn network_line(network: pack.NetworkPosture) -> String {
  let text =
    "%% section sandbox\n{network}\n"
    <> "%% section _network_blocked\nblocked\n"
    <> "%% section _network_proxied\nvia proxy: {network_allow}\n"
    <> "%% section _network_open\nopen"
  pack.render(
    decoded(text),
    pack.environment(
      workspace: "/work",
      platform: "p",
      shell: "s",
      tools: [],
      enforcement: pack.FullyEnforced,
      network:,
      protected_paths: [],
      repository_guidance: None,
    ),
  )
}

pub fn render_selects_the_network_fragment_test() {
  assert network_line(pack.NetworkBlocked) == "blocked"
  assert network_line(pack.NetworkOpen) == "open"
  assert network_line(pack.NetworkProxied(["b.example", "a.example"]))
    == "via proxy: a.example, b.example"
}

pub fn render_omits_the_protected_fragment_when_nothing_is_protected_test() {
  let text =
    "%% section sandbox\n[{protected}]\n%% section _protected_paths\nkept out: {protected_paths}"
  assert pack.render(decoded(text), host()) == "[]"
}

pub fn render_includes_the_protected_fragment_when_paths_exist_test() {
  let text =
    "%% section sandbox\n{protected}\n%% section _protected_paths\nkept out: {protected_paths}"
  let environment =
    pack.environment(
      workspace: "/work",
      platform: "p",
      shell: "s",
      tools: [],
      enforcement: pack.FullyEnforced,
      network: pack.NetworkBlocked,
      protected_paths: ["/work/.git", "/home/u/.ssh"],
      repository_guidance: None,
    )
  assert pack.render(decoded(text), environment)
    == "kept out: /home/u/.ssh, /work/.git"
}

pub fn render_leaves_a_missing_fragment_empty_test() {
  // A pack that dropped a fragment still renders; `problems` is what
  // says it is incomplete.
  let text = "%% section sandbox\n[{enforcement}]"
  assert pack.render(decoded(text), host()) == "[]"
}

// --- repository guidance -------------------------------------------------

fn with_guidance(text: String) -> Environment {
  pack.environment(
    workspace: "/work",
    platform: "p",
    shell: "s",
    tools: [],
    enforcement: pack.FullyEnforced,
    network: pack.NetworkBlocked,
    protected_paths: [],
    repository_guidance: Some(text),
  )
}

const guidance_pack = "%% section repository_guidance\n{repository_guidance}\n%% section _repository_guidance\nproject data follows\n<g>\n{repository_guidance_text}\n</g>\n%% section _repository_guidance_truncated\n[cut]"

pub fn render_frames_repository_guidance_test() {
  assert pack.render(decoded(guidance_pack), with_guidance("Use tabs."))
    == "project data follows\n<g>\nUse tabs.\n</g>"
}

pub fn render_omits_the_whole_section_without_guidance_test() {
  assert pack.render(decoded(guidance_pack), host()) == ""
}

pub fn render_treats_blank_guidance_as_absent_test() {
  assert pack.render(decoded(guidance_pack), with_guidance("  \n\n ")) == ""
}

pub fn render_never_expands_placeholders_inside_guidance_test() {
  // Injected project text is emitted verbatim and never re-scanned, so a
  // hostile CLAUDE.md cannot read the environment back out of the
  // renderer or drive expansion in a loop.
  let rendered =
    pack.render(
      decoded(guidance_pack),
      with_guidance("shell is {shell} and {repository_guidance_text}"),
    )
  assert string.contains(
    rendered,
    "shell is {shell} and {repository_guidance_text}",
  )
  assert !string.contains(rendered, "/bin/bash")
}

pub fn render_caps_guidance_at_a_line_boundary_test() {
  let line = string.repeat("x", 99)
  let huge = string.join(list.repeat(line, 400), "\n")
  let rendered = pack.render(decoded(guidance_pack), with_guidance(huge))
  // Cut announced, never silent.
  assert string.contains(rendered, "[cut]")
  // Cut on a line boundary: no partial line survives.
  assert list.all(
    string.split(rendered, on: "\n")
      |> list.filter(string.starts_with(_, "x")),
    fn(kept) { kept == line },
  )
  assert string.length(rendered) < 100 + pack.max_repository_guidance_bytes
}

pub fn render_does_not_announce_a_cut_that_did_not_happen_test() {
  let rendered = pack.render(decoded(guidance_pack), with_guidance("short"))
  assert !string.contains(rendered, "[cut]")
}

// --- byte stability ------------------------------------------------------

pub fn render_is_byte_identical_across_calls_test() {
  // Guarantee 1 of the stability contract: one string per session, and
  // re-rendering the same inputs may never differ by a byte.
  let shipped_pack = shipped()
  let environment = host()
  assert pack.render(shipped_pack, environment)
    == pack.render(shipped_pack, environment)
}

pub fn render_ignores_the_order_of_list_fields_test() {
  // The caller's discovery order must not reach the bytes: `tool_specs`
  // and the config it reads from carry no ordering guarantee.
  let permuted =
    pack.environment(
      workspace: "/work",
      platform: "linux/x86_64",
      shell: "/bin/bash",
      tools: ["fs_read", "bash"],
      enforcement: pack.FullyEnforced,
      network: pack.NetworkProxied(["b.example", "a.example", "b.example"]),
      protected_paths: ["/b", "/a", "/a"],
      repository_guidance: None,
    )
  let sorted =
    pack.environment(
      workspace: "/work",
      platform: "linux/x86_64",
      shell: "/bin/bash",
      tools: ["bash", "fs_read"],
      enforcement: pack.FullyEnforced,
      network: pack.NetworkProxied(["a.example", "b.example"]),
      protected_paths: ["/a", "/b"],
      repository_guidance: None,
    )
  let text = "%% section environment\n{tools}|{protected_paths}|{network_allow}"
  assert pack.render(decoded(text), permuted)
    == pack.render(decoded(text), sorted)
  assert pack.render(shipped(), permuted) == pack.render(shipped(), sorted)
}

pub fn render_ignores_whitespace_noise_in_list_fields_test() {
  let padded =
    pack.environment(
      workspace: "/work",
      platform: "p",
      shell: "s",
      tools: [" bash ", "", "fs_read"],
      enforcement: pack.FullyEnforced,
      network: pack.NetworkBlocked,
      protected_paths: [],
      repository_guidance: None,
    )
  assert pack.render(decoded("%% section environment\n{tools}"), padded)
    == "bash, fs_read"
}

pub fn render_ignores_pack_whitespace_edits_test() {
  // Reformatting the pack file — a trailing space, an extra blank line —
  // must not cost a one-hour cache write.
  let tidy = decoded("%% section identity\na\n%% section conduct\nb")
  let noisy =
    decoded("%% section identity\n\na   \n\n\n%% section conduct\nb\n\n")
  assert pack.render(tidy, host()) == pack.render(noisy, host())
}

pub fn render_of_the_shipped_pack_has_no_digits_of_its_own_test() {
  // A date, a clock reading, a token count and a cost all arrive as
  // digits. Rendered against an environment that carries none, the
  // shipped prompt must carry none either — the pack's own text may not
  // smuggle in a year or a version number that will later be edited.
  let plain =
    pack.environment(
      workspace: "/work",
      platform: "linux",
      shell: "/bin/sh",
      tools: ["bash"],
      enforcement: pack.FullyEnforced,
      network: pack.NetworkBlocked,
      protected_paths: [],
      repository_guidance: None,
    )
  let rendered = pack.render(shipped(), plain)
  assert !list.any(string.to_graphemes(rendered), string.contains(
    "0123456789",
    _,
  ))
}

pub fn render_varies_only_with_the_environment_test() {
  let shipped_pack = shipped()
  let degraded =
    pack.environment(
      workspace: "/work",
      platform: "linux/x86_64",
      shell: "/bin/bash",
      tools: ["bash", "fs_read"],
      enforcement: pack.DegradedRefusing,
      network: pack.NetworkBlocked,
      protected_paths: [],
      repository_guidance: None,
    )
  assert pack.render(shipped_pack, host())
    != pack.render(shipped_pack, degraded)
  assert pack.render(shipped_pack, degraded)
    == pack.render(shipped_pack, degraded)
}
