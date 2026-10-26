import core/json
import eval/arm.{type Arm}
import gleam/list
import gleam/string
import provider/model

fn target(role: arm.Role) -> arm.Target {
  arm.Target(provider: "anthropic", model_id: "m1", api: "messages", role:)
}

fn raw() -> Arm {
  arm.Arm(
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
      thinking: [#("m1", model.ThinkingHigh), #("m0", model.ThinkingLow)],
      disabled_tools: ["web", "mcp"],
    ),
  )
}

fn minted(candidate: Arm) -> Arm {
  let assert Ok(done) = arm.mint(candidate)
  done
}

fn sample() -> Arm {
  minted(raw())
}

pub fn arm_round_trips_test() {
  let assert Ok(decoded) = arm.decode(arm.to_json(sample()))
  let assert Ok(again) = arm.decode(arm.to_json(decoded))

  assert decoded == sample()
  assert again == decoded
  assert arm.to_json(again) == arm.to_json(sample())
  assert arm.verify_id(decoded) == Ok(decoded)
  assert arm.mint(sample()) == Ok(sample())
}

pub fn arm_id_ignores_order_and_name_test() {
  let shuffled =
    arm.Arm(..raw(), name: "renamed", components: [
      #(arm.ToolDescription(target(arm.Any), "bash"), "careful"),
      #(arm.PromptPack, "pack text"),
      #(arm.SystemSuffix(target(arm.Any)), "be terse"),
    ])

  assert minted(shuffled).id == sample().id
}

// The same configuration written another way must be the same arm: every
// keyed list in a different order, and a tool listed twice.
pub fn arm_id_ignores_build_order_test() {
  let base = raw()
  let rebuilt =
    arm.Arm(
      ..base,
      components: list.reverse(base.components),
      knobs: arm.Knobs(
        roles: list.reverse(base.knobs.roles),
        thinking: list.reverse(base.knobs.thinking),
        disabled_tools: ["mcp", "web", "mcp", "web"],
      ),
    )

  assert minted(rebuilt).id == sample().id
  assert minted(rebuilt) == sample()
  assert arm.verify_id(arm.Arm(..rebuilt, id: sample().id))
    == Ok(arm.Arm(..rebuilt, id: sample().id))
}

pub fn arm_duplicate_entries_are_refused_alike_test() {
  let repeated_slot =
    arm.Arm(..raw(), components: [
      #(arm.PromptPack, "a"),
      #(arm.PromptPack, "b"),
    ])
  let repeated_role =
    arm.Arm(
      ..raw(),
      knobs: arm.Knobs(..raw().knobs, roles: [
        #(model.Main, ["m1"]),
        #(model.Main, ["m2"]),
      ]),
    )
  let message = Error("repeated entry in an arm")

  assert arm.mint(repeated_slot) == message
  assert arm.decode(arm.to_json(repeated_slot)) == message
  assert arm.mint(repeated_role) == message
  assert arm.decode(arm.to_json(repeated_role)) == message
}

pub fn arm_id_changes_with_content_test() {
  let base = sample()
  let text = arm.Arm(..raw(), components: [#(arm.PromptPack, "other")])
  let knob =
    arm.Arm(..raw(), knobs: arm.Knobs(..raw().knobs, disabled_tools: ["web"]))

  assert minted(text).id != base.id
  assert minted(knob).id != base.id
}

pub fn arm_role_not_any_refused_test() {
  let roles = [arm.Main, arm.Subagent, arm.Advisor, arm.Summarize]
  let slots = fn(role) {
    [
      arm.SystemSuffix(target(role)),
      arm.TaskPrefix(target(role)),
      arm.ToolDescription(target(role), "bash"),
    ]
  }

  list.each(roles, fn(role) {
    list.each(slots(role), fn(slot) {
      let aimed = arm.Arm(..raw(), components: [#(slot, "x")])

      assert arm.refuse_unapplied(aimed)
        == Error("per-role profiles need protocol-change 101")
    })
  })
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
}
