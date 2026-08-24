import provider/model

pub fn role_to_string_test() {
  assert model.role_to_string(model.Main) == "main"
  assert model.role_to_string(model.Subagent) == "subagent"
  assert model.role_to_string(model.Plan) == "plan"
  assert model.role_to_string(model.Summarize) == "summarize"
  assert model.role_to_string(model.Vision) == "vision"
  assert model.role_to_string(model.Custom("critic")) == "custom:critic"
}
