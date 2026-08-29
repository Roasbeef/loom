import etui/keys
import gleeunit
import tui_gleam/command
import tui_gleam/model_selector
import tui_gleam/protocol.{ModelInfo}

pub fn main() {
  gleeunit.main()
}

pub fn prompt_test() {
  assert command.parse("hello") == command.Prompt("hello")
}

pub fn models_test() {
  assert command.parse("/models") == command.Models
  assert command.parse("/model") == command.Models
}

pub fn agents_test() {
  assert command.parse("/agents") == command.Agents
}

pub fn details_test() {
  assert command.parse("/details") == command.Details
}

pub fn model_argument_test() {
  assert command.parse(" /model baseten-kimi-k3 ")
    == command.Model("baseten-kimi-k3")
}

pub fn missing_argument_test() {
  assert command.parse("/fork") == command.MissingArgument("fork")
}

pub fn unknown_command_test() {
  assert command.parse("/dance now") == command.Unknown("dance")
}

pub fn model_selector_accepts_initials_test() {
  let models = [
    ModelInfo("baseten-kimi-k3", "openai", "moonshotai/Kimi-K3", [], ["main"]),
    ModelInfo(
      "baseten-glm-5-3-flash",
      "openai",
      "zai-org/GLM-5.3-Flash",
      [],
      [],
    ),
  ]
  let state = model_selector.State(models:, query: "glm53f", selected: 0)
  assert model_selector.update(keys.Enter, state)
    == model_selector.Choose("baseten-glm-5-3-flash")
  let assert model_selector.Continue(next) =
    model_selector.update(keys.Down, state)
  assert model_selector.update(keys.Enter, next)
    == model_selector.Choose("baseten-glm-5-3-flash")
}
