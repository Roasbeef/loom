//// The catalogue name of a strand's model, read from a capture's
//// configurations.

import core/message
import gleam/dict
import gleam/option.{None, Some}
import machine/strand
import session_view/agent_view
import session_view/snapshot_view

fn configuration(provider: String) -> snapshot_view.Configuration {
  snapshot_view.Configuration(
    strand.StrandConfiguration(
      model: strand.ModelIdentity(provider:, model_id: "zai-org/GLM-5.3"),
      thinking_level: strand.ThinkingOff,
      active_tool_names: [],
    ),
    None,
  )
}

fn view(
  configurations: List(#(String, snapshot_view.Configuration)),
) -> snapshot_view.View {
  snapshot_view.View(
    strands: [],
    leaves: dict.new(),
    configurations: dict.from_list(configurations),
    operations: dict.new(),
    usage: message.Usage(
      0,
      0,
      0,
      0,
      None,
      None,
      0,
      message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
    ),
    settings: snapshot_view.RunSettings("one_at_a_time", "parallel", None),
    peers: [],
    cells: [],
    preview: None,
    pending_inputs: Some([]),
    tools: None,
  )
}

// The name is the catalogue entry that chose the model, which the owner wrote,
// and not the upstream identifier the entry maps to.
pub fn the_catalogue_name_is_the_entry_and_not_the_upstream_id_test() {
  let held = view([#("main", configuration("baseten-glm-5-3"))])
  assert agent_view.catalogue_name(held, "main") == Some("baseten-glm-5-3")
}

// A strand the capture holds no configuration for has no name, and an entry
// whose name is empty is no name either, so a host draws nothing for it.
pub fn a_strand_with_no_configuration_has_no_name_test() {
  let held = view([#("main", configuration("")), #("a", configuration("glm"))])
  assert agent_view.catalogue_name(held, "main") == None
  assert agent_view.catalogue_name(held, "missing") == None
  assert agent_view.catalogue_name(held, "a") == Some("glm")
}

// The name is one line of text: a break in it does not reach a host as one.
pub fn the_name_is_one_line_test() {
  let held = view([#("main", configuration("two\nlines"))])
  assert agent_view.catalogue_name(held, "main") == Some("two lines")
}
