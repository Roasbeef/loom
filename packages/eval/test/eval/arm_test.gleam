import core/json
import eval/arm.{type Arm}
import gleam/string
import provider/model

fn target(role: arm.Role) -> arm.Target {
  arm.Target(provider: "anthropic", model_id: "m1", api: "messages", role:)
}

fn sample() -> Arm {
  arm.mint(arm.Arm(
    id: "",
    name: "baseline",
    components: [
      #(arm.PromptPack, "pack text"),
      #(arm.SystemSuffix(target(arm.Any)), "be terse"),
      #(arm.ToolDescription(target(arm.Any), "bash"), "careful"),
    ],
    knobs: arm.Knobs(
      roles: [
        #(model.Main, ["m1", "m2"]),
        #(model.Custom("critic"), ["m3"]),
      ],
      thinking: [#("m1", model.ThinkingHigh)],
      disabled_tools: ["web", "mcp"],
    ),
  ))
}

pub fn arm_round_trips_test() {
  let assert Ok(decoded) = arm.decode(arm.to_json(sample()))
  let assert Ok(again) = arm.decode(arm.to_json(decoded))

  assert again == decoded
  assert arm.to_json(again) == arm.to_json(sample())
  assert arm.verify_id(decoded) == Ok(decoded)
}

pub fn arm_id_ignores_order_and_name_test() {
  let shuffled =
    arm.Arm(..sample(), name: "renamed", components: [
      #(arm.ToolDescription(target(arm.Any), "bash"), "careful"),
      #(arm.PromptPack, "pack text"),
      #(arm.SystemSuffix(target(arm.Any)), "be terse"),
    ])

  assert arm.mint(shuffled).id == sample().id
}

pub fn arm_id_changes_with_content_test() {
  let base = sample()
  let text = arm.Arm(..base, components: [#(arm.PromptPack, "other")])
  let knob =
    arm.Arm(..base, knobs: arm.Knobs(..base.knobs, disabled_tools: ["web"]))

  assert arm.mint(text).id != base.id
  assert arm.mint(knob).id != base.id
}

pub fn arm_role_not_any_refused_test() {
  let aimed =
    arm.Arm(..sample(), components: [
      #(arm.TaskPrefix(target(arm.Subagent)), "x"),
    ])

  assert arm.refuse_unapplied(aimed)
    == Error("per-role profiles need protocol-change 101")
  assert arm.refuse_unapplied(sample()) == Ok(sample())
}

pub fn arm_decode_refuses_bad_input_test() {
  let assert Ok(json.Object(fields)) =
    json.parse(json.to_string(arm.to_json(sample())))

  assert arm.decode(json.Object([#("zzz", json.Null), ..fields]))
    == Error("unknown key \"zzz\"")
  assert arm.decode(json.Null) == Error("expected an object")

  let assert Error(reason) =
    arm.decode(json.Object([#("v", json.Int(1)), ..fields]))
  assert string.contains(reason, "repeated key")

  let twice =
    arm.Arm(..sample(), components: [
      #(arm.PromptPack, "a"),
      #(arm.PromptPack, "b"),
    ])
  assert arm.decode(arm.to_json(twice)) == Error("repeated entry in an arm")
}
