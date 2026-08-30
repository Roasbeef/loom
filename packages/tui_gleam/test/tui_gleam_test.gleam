import core/json
import etui/keys
import gleam/option.{Some}
import gleam/string
import gleeunit
import tui_gleam
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

pub fn transcript_scroll_clamps_at_the_live_tail_test() {
  assert tui_gleam.scroll_offset(12, True, 3) == 15
  assert tui_gleam.scroll_offset(12, False, 3) == 9
  assert tui_gleam.scroll_offset(2, False, 3) == 0
}

pub fn code_mode_program_renders_as_gleam_test() {
  let arguments =
    json.Object([
      #(
        "program",
        json.String(
          "import cap/report\n\npub fn main() {\n  report.text(\"live\")\n}",
        ),
      ),
    ])

  assert tui_gleam.code_mode_program("code_mode", arguments, False)
    == Some(
      "```gleam\nimport cap/report\n\npub fn main() {\n  report.text(\"live\")\n}\n```",
    )
}

pub fn code_mode_program_preview_is_bounded_test() {
  let arguments =
    json.Object([
      #(
        "program",
        json.String(
          "line-01\nline-02\nline-03\nline-04\nline-05\nline-06\nline-07\nline-08\nline-09\nline-10\nline-11\nline-12\nline-13",
        ),
      ),
    ])
  let assert Some(collapsed) =
    tui_gleam.code_mode_program("code_mode", arguments, False)
  let assert Some(expanded) =
    tui_gleam.code_mode_program("code_mode", arguments, True)

  assert !string.contains(collapsed, "line-13")
  assert string.contains(collapsed, "// …")
  assert string.contains(expanded, "line-13")
}
