import codemode/live_slots
import gleeunit/should

pub fn rewrites_authored_imports_only_test() {
  let source =
    "import counter/tool as tool\nimport gleam/string\nconst text = \"import counter/tool\"\n// import counter/tool\n"
  live_slots.rewrite(source, ["counter/tool"], live_slots.First)
  |> should.equal(
    "import loom_live_a/counter/tool as tool\nimport gleam/string\nconst text = \"import counter/tool\"\n// import counter/tool\n",
  )
}

pub fn second_slot_is_reused_test() {
  live_slots.rewrite(
    "import counter/tool.{type Item}",
    ["counter/tool"],
    live_slots.Second,
  )
  |> should.equal("import loom_live_b/counter/tool.{type Item}")
}
