//// Stable model doors for immutable self-extension candidates.
////
//// Authoring and testing never grant activation authority. Discovery returns
//// exact candidate and generation tokens; invocation requires both, so an old
//// schema cannot silently execute a replacement implementation.

import broker/policy
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{Some}
import tools/tool.{type Ctx, type Tool, type ToolOutcome}

/// The host-owned lifecycle doors. No operator authority crosses this seam.
pub type Door {
  Door(
    /// Captures authorized source into an immutable proposal.
    propose: fn(Ctx, JsonValue) -> ToolOutcome,
    /// Runs candidate-owned tests and persists their evidence.
    test_candidate: fn(Ctx, JsonValue) -> ToolOutcome,
    /// Reads visible immutable bytes and evidence.
    inspect: fn(Ctx, JsonValue) -> ToolOutcome,
    /// Discovers selected versions and their precise callable contracts.
    catalogue: fn(Ctx, JsonValue) -> ToolOutcome,
    /// Calls an exact discovered candidate under the current caller's policy.
    invoke: fn(Ctx, JsonValue) -> ToolOutcome,
  )
}

/// The generic invocation name. The wrapper that leases a generation learns
/// which tools bypass it from `names`, never from this constant.
pub const invoke_name = "evolution_invoke"

/// Registers the five stable lifecycle tools.
///
/// ## Examples
///
/// ```gleam
/// // evolution.tools(door) |> tool.registry
/// ```
///
pub fn tools(door: Door) -> List(Tool) {
  [
    declared(
      "evolution_propose",
      "Capture a candidate from authorized source. "
        <> "This creates no approval or activation. Requests needing a new "
        <> "trusted capability return CoreChangeRequired.",
      [
        #(
          "directory",
          tool.string_property("Source directory in your workspace."),
        ),
        #("name", tool.string_property("Stable candidate name.")),
        #(
          "kind",
          tool.enum_property(
            ["extension", "program", "prompt"],
            "Artifact kind.",
          ),
        ),
        #(
          "test_entry",
          tool.string_property("Candidate-owned test entry module."),
        ),
        #("description", tool.string_property("Purpose and input contract.")),
        #("input_schema", tool.string_property("JSON input schema.")),
      ],
      ["directory", "name", "kind"],
      door.propose,
    ),
    declared(
      "evolution_test",
      "Test an immutable candidate and retain durable evidence. Extensions and "
        <> "Programs run author tests in the jail. Prompt candidates require "
        <> "taskset_id for an independently admitted paired coding comparison; "
        <> "limits may only lower native ceilings. Neither successful author "
        <> "tests nor a comparison grant approval or selection.",
      test_properties(),
      ["candidate_id"],
      door.test_candidate,
    ),
    declared(
      "evolution_inspect",
      "Inspect immutable candidate bytes or retained evidence before approval. "
        <> "Supply candidate_id or evidence_id; offset_bytes continues a bounded "
        <> "base64 page of the same verified envelope.",
      [
        #("candidate_id", tool.string_property("Immutable candidate identity.")),
        #(
          "evidence_id",
          tool.string_property("Retained immutable evidence identity."),
        ),
        #(
          "offset_bytes",
          tool.integer_property("Exact next_offset_bytes from inspection."),
        ),
      ],
      [],
      door.inspect,
    ),
    declared(
      "evolution_catalogue",
      "Discover selected executable candidates. "
        <> "Keep the exact candidate_id and generation with the advertised "
        <> "schema; both are required for invocation.",
      [
        #("offset", json.Object([#("type", json.String("integer"))])),
        #("count", json.Object([#("type", json.String("integer"))])),
        #("candidate_offset", json.Object([#("type", json.String("integer"))])),
      ],
      [],
      door.catalogue,
    ),
    declared(
      invoke_name,
      "Invoke a discovered immutable version with fresh "
        <> "inputs under your current authority. A stale candidate_id or "
        <> "generation refuses instead of choosing another version.",
      [
        #(
          "candidate_id",
          tool.string_property("Exact discovered candidate identity."),
        ),
        #(
          "generation",
          tool.integer_property("Exact discovered selection generation."),
        ),
        #("tool", tool.string_property("Declared callable name.")),
        #(
          "arguments",
          tool.any_property("Fresh inputs satisfying its discovered schema."),
        ),
      ],
      ["candidate_id", "generation", "tool", "arguments"],
      door.invoke,
    ),
  ]
}

fn test_properties() -> List(#(String, JsonValue)) {
  [
    #("candidate_id", tool.string_property("Immutable candidate identity.")),
    #(
      "taskset_id",
      tool.string_property(
        "Required for Prompt: independently admitted immutable task-set identity.",
      ),
    ),
    #(
      "limits",
      tool.object_schema(
        [
          #(
            "trials",
            tool.integer_property("Paired trial arms, 1..20; default 20."),
          ),
          #(
            "turns",
            tool.integer_property("Aggregate turns, 1..20; default 20."),
          ),
          #(
            "tokens",
            tool.integer_property(
              "Aggregate tokens, 1..1000000; default 1000000.",
            ),
          ),
          #(
            "dollars",
            json.Object([
              #("type", json.String("number")),
              #(
                "description",
                json.String(
                  "Aggregate dollars, above zero through 2; default 2.",
                ),
              ),
            ]),
          ),
          #(
            "output_bytes",
            tool.integer_property(
              "Retained output bytes, 1..65536; default 65536.",
            ),
          ),
          #(
            "wall_ms",
            tool.integer_property(
              "Comparison wall milliseconds, 1..120000; default 120000.",
            ),
          ),
        ],
        ["trials", "turns", "tokens", "dollars", "output_bytes", "wall_ms"],
      ),
    ),
  ]
}

/// The registered door names, derived from the declarations themselves.
///
/// The generation hook wrapper skips these tools because each is a door into
/// the owner or the catalogue and needs no generation of its own. Deriving the list from `tools` means a door added there is skipped
/// without a second edit.
///
/// ## Examples
///
/// ```gleam
/// // evolution.names() == ["evolution_propose", ..., "evolution_invoke"]
/// ```
///
pub fn names() -> List(String) {
  let unreachable = fn(_ctx, _args) {
    tool.failure("names declares doors and never runs them")
  }
  tools(Door(
    propose: unreachable,
    test_candidate: unreachable,
    inspect: unreachable,
    catalogue: unreachable,
    invoke: unreachable,
  ))
  |> list.map(fn(declared) { declared.name })
}

fn declared(
  name: String,
  description: String,
  properties: List(#(String, JsonValue)),
  required: List(String),
  run: fn(Ctx, JsonValue) -> ToolOutcome,
) -> Tool {
  tool.Tool(
    name:,
    description:,
    prompt_snippet: Some(description),
    schema: tool.object_schema(properties, required),
    replay: tool.Never,
    execution_mode: tool.Exclusive,
    requirements: fn(workspace) {
      let base = tool.read_requirements(workspace)
      policy.SandboxPolicy(..base, readable_roots: [])
    },
    run:,
  )
}
