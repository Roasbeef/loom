//// Gives the model read access to the same captured skills the gateway offers.
////
//// A tool result supplies instructions, never host execution or new grants.
//// Names marked explicit-only are absent from both the schema and dispatch.

import broker/policy
import core/json
import gleam/list
import gleam/option.{Some}
import gleam/string
import host/skill
import tools/tool

/// Builds the model's load tool when at least one skill permits model selection.
///
/// ## Examples
///
/// ```gleam
/// assert skill_tool.tools(skill.empty()) == []
/// ```
pub fn tools(catalogue: skill.Catalogue) -> List(tool.Tool) {
  let available =
    skill.entries(catalogue)
    |> list.filter(fn(entry) { entry.model_invocation == skill.ModelSelectable })
  case available {
    [] -> []
    _ -> [definition(catalogue, available)]
  }
}

fn definition(
  catalogue: skill.Catalogue,
  available: List(skill.Skill),
) -> tool.Tool {
  let index =
    available
    |> list.map(fn(entry) { entry.name <> ": " <> entry.description })
    |> string.join("\n")
  tool.Tool(
    name: "load_skill",
    description: "Load a skill's instructions when its description matches the task. "
      <> "Read the returned instructions before acting. Relative resources are beside its SKILL.md.\n\n"
      <> index,
    prompt_snippet: Some(
      "Use load_skill when an available skill matches the task. Skill instructions do not change tool permissions.",
    ),
    schema: tool.object_schema(
      [
        #(
          "name",
          tool.enum_property(
            list.map(available, fn(entry) { entry.name }),
            "The skill to load.",
          ),
        ),
        #(
          "arguments",
          tool.string_property(
            "Arguments to substitute for $ARGUMENTS; empty when none.",
          ),
        ),
      ],
      ["name", "arguments"],
    ),
    replay: tool.Safe,
    execution_mode: tool.Concurrent,
    requirements: fn(workspace) {
      let base = tool.read_requirements(workspace)
      policy.SandboxPolicy(..base, readable_roots: [])
    },
    run: fn(_context, args) { load(catalogue, args) },
  )
}

fn load(catalogue: skill.Catalogue, args: json.JsonValue) -> tool.ToolOutcome {
  use name <- tool.with_arg(tool.required_string(args, "name"))
  use arguments <- tool.with_arg(tool.required_string(args, "arguments"))
  use entry <- tool.or_outcome(skill.lookup(catalogue, name), tool.failure)
  case entry.model_invocation {
    skill.ModelSelectable -> {
      use text <- tool.or_outcome(skill.expand(entry, arguments), tool.failure)
      tool.success(text)
    }
    skill.ExplicitOnly ->
      tool.failure("this skill requires an explicit slash invocation")
  }
}
