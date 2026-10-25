//// An arm is one candidate configuration of the agent: a handful of named
//// text components plus the model-selection knobs, addressed by the digest
//// of both.
////
//// The split between the two is the contract with the optimiser that will
//// eventually drive this instrument. Components are text, and a mutation
//// step may rewrite them freely; knobs choose models and withhold tools, and
//// no mutation step touches them. Keeping them in separate fields means that
//// "the optimiser changed a knob" is not a bug a test has to catch but a
//// thing the type cannot say.
////
//// This module is pure. It only describes an arm and its identity; turning
//// one into the settings a session boots with is a later slice, because that
//// needs the client's settings type and this module must stay checkable
//// without it. What it does own is the refusal that keeps the data honest:
//// a component aimed at a role other than `Any` can be written down, but
//// `refuse_unapplied` says plainly that nothing can apply it yet.

import client/mcp
import core/json.{type JsonValue}
import eval/wire
import gleam/list
import gleam/result
import gleam/string
import provider/model

/// One candidate configuration.
pub type Arm {
  Arm(
    /// SHA-256 hex of the canonical components and knobs; the pairing key.
    /// The name is not hashed, so renaming an arm does not make a new one.
    id: String,
    /// A human handle for reports; informational only.
    name: String,
    /// The text components, keyed by `Component`. Encoded sorted by their
    /// canonical form, so the order a caller built the list in is not part
    /// of the arm's identity.
    components: List(#(Component, String)),
    /// The model-selection knobs, which an optimiser never mutates.
    knobs: Knobs,
  )
}

/// A slot of text an arm can replace.
pub type Component {
  /// The profile's system suffix for the exact target.
  SystemSuffix(target: Target)

  /// The profile's task prefix for the exact target.
  TaskPrefix(target: Target)

  /// One tool's appended description for the exact target.
  ToolDescription(target: Target, tool: String)

  /// The whole prompt pack text.
  PromptPack
}

/// The exact model a profile component applies to.
pub type Target {
  Target(
    /// The provider name as the catalogue spells it.
    provider: String,
    /// The model identifier at that provider.
    model_id: String,
    /// The wire API name.
    api: String,
    /// Which role the component is aimed at. Anything but `Any` cannot be
    /// applied today.
    role: Role,
  )
}

/// The role a component is aimed at.
pub type Role {
  /// Every role: the only value that can be applied today.
  Any

  /// The primary strand.
  Main

  /// Child strands spawned by the primary.
  Subagent

  /// The advisor strand.
  Advisor

  /// The summarising route.
  Summarize
}

/// The non-text choices of an arm.
pub type Knobs {
  Knobs(
    /// Role to ordered catalogue model names: the ensemble axis. The model
    /// order within a role is meaningful and is kept.
    roles: List(#(model.Role, List(String))),
    /// Model name to thinking level.
    thinking: List(#(String, model.ThinkingLevel)),
    /// Tool names withheld from the model.
    disabled_tools: List(String),
  )
}

/// The refusal text for a component aimed at a role.
const per_role_refusal = "per-role profiles need protocol-change 101"

/// The encoding version of an arm file.
pub const version = 2

/// The canonical encoding of an arm. The keyed lists are sorted by their own
/// encoding so that building the same arm in a different order mints the
/// same id.
///
/// ## Examples
///
/// ```gleam
/// // json.to_string(arm.to_json(a)) starts with {"components":…
/// ```
///
pub fn to_json(arm: Arm) -> JsonValue {
  json.canonical(
    json.Object([
      #("v", json.Int(version)),
      #("id", json.String(arm.id)),
      #("name", json.String(arm.name)),
      #("components", components_json(arm.components)),
      #("knobs", knobs_json(arm.knobs)),
    ]),
  )
}

/// Returns the arm with `id` set to the digest of its canonical components
/// and knobs. The name and the previous id are left out, so renaming an arm
/// keeps its identity and minting is idempotent.
///
/// ## Examples
///
/// ```gleam
/// // arm.mint(arm.mint(a)) == arm.mint(a)
/// ```
///
pub fn mint(arm: Arm) -> Arm {
  Arm(..arm, id: digest(arm))
}

/// Refuses an arm whose id is not the digest of its content.
///
/// ## Examples
///
/// ```gleam
/// // arm.verify_id(arm.mint(a)) == Ok(arm.mint(a))
/// ```
///
pub fn verify_id(arm: Arm) -> Result(Arm, String) {
  let actual = digest(arm)

  // A mismatch means the arm was edited after it was minted, so the error names both digests.
  case actual == arm.id {
    True -> Ok(arm)
    False ->
      Error(
        "arm content changed: id "
        <> arm.id
        <> " but content digests to "
        <> actual,
      )
  }
}

/// Refuses any component aimed at a role other than `Any`. The axis exists in
/// the data so a later optimiser can emit it, but nothing applies it yet, and
/// an arm that silently ignored the role would measure a configuration the
/// reader did not ask for.
///
/// ## Examples
///
/// ```gleam
/// // arm.refuse_unapplied(a) == Error("per-role profiles need protocol-change 101")
/// // when a component's target role is Main
/// ```
///
pub fn refuse_unapplied(arm: Arm) -> Result(Arm, String) {
  let aimed =
    list.any(arm.components, fn(component) {
      case component.0 {
        SystemSuffix(target:) | TaskPrefix(target:) -> target.role != Any
        ToolDescription(target:, ..) -> target.role != Any
        PromptPack -> False
      }
    })

  // Only a target with a role other than `Any` is refused; the pack has no target.
  case aimed {
    True -> Error(per_role_refusal)
    False -> Ok(arm)
  }
}

/// Decodes an arm. Total. Components must be unique by slot, strings must be
/// nonempty where they name something, and unknown keys are refused. The
/// result's lists are in canonical order, which is the order `to_json`
/// writes.
///
/// ## Examples
///
/// ```gleam
/// // arm.decode(arm.to_json(a)) == Ok(a) for an arm already in canonical order
/// ```
///
pub fn decode(value: JsonValue) -> Result(Arm, String) {
  use fields <- result.try(
    wire.object(value, ["v", "id", "name", "components", "knobs"]),
  )
  use v <- result.try(wire.int(fields, "v"))
  use id <- result.try(wire.text(fields, "id"))
  use name <- result.try(wire.text(fields, "name"))
  use components <- result.try(wire.list_of(
    fields,
    "components",
    decode_component,
  ))
  use knobs <- result.try(
    wire.required(fields, "knobs") |> result.try(decode_knobs),
  )

  // Only the current version is understood; an older file must be migrated, not guessed at.
  use Nil <- result.try(case v == version {
    True -> Ok(Nil)
    False -> Error("unsupported arm version")
  })

  // An id is either blank (not yet minted) or a full digest.
  use Nil <- result.try(case id == "" || wire.is_hex(id, 64) {
    True -> Ok(Nil)
    False -> Error("bad arm id")
  })

  use components <- result.try(distinct_sorted(components, component_key))
  use knobs <- result.try(normalise(knobs))

  Ok(Arm(id:, name:, components:, knobs:))
}

/// The digest an arm's id is: components and knobs only.
fn digest(arm: Arm) -> String {
  json.Object([
    #("components", components_json(arm.components)),
    #("knobs", knobs_json(arm.knobs)),
  ])
  |> json.canonical
  |> json.to_string
  |> mcp.sha256_hex
}

/// Encodes the components in canonical slot order, each as a slot and its text.
fn components_json(components: List(#(Component, String))) -> JsonValue {
  components
  |> sorted_by(component_key)
  |> list.map(fn(component) {
    json.Object([
      #("slot", slot_json(component.0)),
      #("text", json.String(component.1)),
    ])
  })
  |> json.Array
}

/// Sorts entries by a string key: a total, version-stable order that needs
/// no ordering on the Gleam types themselves. `decode` sorts by the same
/// keys, which is what makes a decoded arm re-encode to its own bytes.
fn sorted_by(entries: List(a), key: fn(a) -> String) -> List(a) {
  list.sort(entries, fn(left, right) { string.compare(key(left), key(right)) })
}

/// Encodes a component's slot: its kind tag plus the target and tool that address it. The slot, not the text, is a component's key.
fn slot_json(component: Component) -> JsonValue {
  case component {
    SystemSuffix(target:) ->
      json.Object([
        #("kind", json.String("system_suffix")),
        #("target", target_json(target)),
      ])
    TaskPrefix(target:) ->
      json.Object([
        #("kind", json.String("task_prefix")),
        #("target", target_json(target)),
      ])
    ToolDescription(target:, tool:) ->
      json.Object([
        #("kind", json.String("tool_description")),
        #("target", target_json(target)),
        #("tool", json.String(tool)),
      ])
    PromptPack -> json.Object([#("kind", json.String("prompt_pack"))])
  }
}

/// Encodes the exact-model target a profile component is addressed to.
fn target_json(target: Target) -> JsonValue {
  json.Object([
    #("provider", json.String(target.provider)),
    #("model_id", json.String(target.model_id)),
    #("api", json.String(target.api)),
    #("role", json.String(role_name(target.role))),
  ])
}

/// The wire spelling of a target role.
fn role_name(role: Role) -> String {
  case role {
    Any -> "any"
    Main -> "main"
    Subagent -> "subagent"
    Advisor -> "advisor"
    Summarize -> "summarize"
  }
}

/// Encodes the knobs with every keyed list in key order, so two arms built in different orders write the same bytes.
fn knobs_json(knobs: Knobs) -> JsonValue {
  json.Object([
    #(
      "roles",
      knobs.roles
        |> sorted_by(role_key)
        |> list.map(fn(entry) {
          json.Object([
            #("role", json.String(model.role_to_string(entry.0))),
            #("models", json.Array(list.map(entry.1, json.String))),
          ])
        })
        |> json.Array,
    ),
    #(
      "thinking",
      knobs.thinking
        |> sorted_by(thinking_key)
        |> list.map(fn(entry) {
          json.Object([
            #("model", json.String(entry.0)),
            #("level", json.String(level_name(entry.1))),
          ])
        })
        |> json.Array,
    ),
    #(
      "disabled_tools",
      knobs.disabled_tools
        |> list.sort(string.compare)
        |> list.map(json.String)
        |> json.Array,
    ),
  ])
}

/// The wire spelling of a thinking level.
fn level_name(level: model.ThinkingLevel) -> String {
  case level {
    model.ThinkingOff -> "off"
    model.ThinkingLow -> "low"
    model.ThinkingMedium -> "medium"
    model.ThinkingHigh -> "high"
  }
}

/// Parses a thinking level's wire spelling.
fn decode_level(name: String) -> Result(model.ThinkingLevel, String) {
  case name {
    "off" -> Ok(model.ThinkingOff)
    "low" -> Ok(model.ThinkingLow)
    "medium" -> Ok(model.ThinkingMedium)
    "high" -> Ok(model.ThinkingHigh)
    other -> Error("unknown thinking level \"" <> other <> "\"")
  }
}

/// Parses `model.role_to_string`'s rendering back to a role.
fn decode_model_role(name: String) -> Result(model.Role, String) {
  case name {
    "main" -> Ok(model.Main)
    "subagent" -> Ok(model.Subagent)
    "plan" -> Ok(model.Plan)
    "summarize" -> Ok(model.Summarize)
    "vision" -> Ok(model.Vision)
    other ->
      case string.starts_with(other, "custom:") && string.length(other) > 7 {
        True -> Ok(model.Custom(string.drop_start(other, 7)))
        False -> Error("unknown model role \"" <> other <> "\"")
      }
  }
}

/// Parses a target role's wire spelling.
fn decode_role(name: String) -> Result(Role, String) {
  case name {
    "any" -> Ok(Any)
    "main" -> Ok(Main)
    "subagent" -> Ok(Subagent)
    "advisor" -> Ok(Advisor)
    "summarize" -> Ok(Summarize)
    other -> Error("unknown target role \"" <> other <> "\"")
  }
}

/// Decodes a target, refusing any empty provider, model or api so a component can never be addressed to nothing.
fn decode_target(value: JsonValue) -> Result(Target, String) {
  use fields <- result.try(
    wire.object(value, ["provider", "model_id", "api", "role"]),
  )
  use provider <- result.try(wire.text(fields, "provider"))
  use model_id <- result.try(wire.text(fields, "model_id"))
  use api <- result.try(wire.text(fields, "api"))
  use role <- result.try(wire.text(fields, "role") |> result.try(decode_role))

  // A target that names nothing would match every model.
  case provider != "" && model_id != "" && api != "" {
    True -> Ok(Target(provider:, model_id:, api:, role:))
    False -> Error("a target must name its provider, model and api")
  }
}

/// Decodes a component slot, dispatching on its `kind` tag.
fn decode_slot(value: JsonValue) -> Result(Component, String) {
  use fields <- result.try(wire.object(value, ["kind", "target", "tool"]))
  use kind <- result.try(wire.text(fields, "kind"))

  // The kind tag selects which of the slot's fields are required.
  case kind {
    "prompt_pack" -> Ok(PromptPack)
    "system_suffix" -> {
      use target <- result.map(
        wire.required(fields, "target") |> result.try(decode_target),
      )
      SystemSuffix(target:)
    }
    "task_prefix" -> {
      use target <- result.map(
        wire.required(fields, "target") |> result.try(decode_target),
      )
      TaskPrefix(target:)
    }
    "tool_description" -> {
      use target <- result.try(
        wire.required(fields, "target") |> result.try(decode_target),
      )
      use tool <- result.try(wire.text(fields, "tool"))

      // A tool description with no tool name would address nothing.
      case tool {
        "" -> Error("a tool description must name its tool")
        _ -> Ok(ToolDescription(target:, tool:))
      }
    }
    other -> Error("unknown component kind \"" <> other <> "\"")
  }
}

/// Decodes one component entry: its slot and its text, bounded at 64 KiB.
fn decode_component(value: JsonValue) -> Result(#(Component, String), String) {
  use fields <- result.try(wire.object(value, ["slot", "text"]))
  use slot <- result.try(
    wire.required(fields, "slot") |> result.try(decode_slot),
  )
  use text <- result.try(wire.text(fields, "text"))

  // The text bound keeps one component from dominating the arm file.
  case wire.bytes(text) <= 65_536 {
    True -> Ok(#(slot, text))
    False -> Error("a component's text may hold at most 64 KiB")
  }
}

/// Decodes the knobs object; ordering and uniqueness are enforced afterwards by `normalise`.
fn decode_knobs(value: JsonValue) -> Result(Knobs, String) {
  use fields <- result.try(
    wire.object(value, ["roles", "thinking", "disabled_tools"]),
  )
  use roles <- result.try(wire.list_of(fields, "roles", decode_role_entry))
  use thinking <- result.try(wire.list_of(
    fields,
    "thinking",
    decode_thinking_entry,
  ))
  use disabled_tools <- result.try(wire.strings(fields, "disabled_tools"))

  Ok(Knobs(roles:, thinking:, disabled_tools:))
}

/// Decodes one role's ordered model list. An empty list is refused because a role with no models selects nothing.
fn decode_role_entry(
  value: JsonValue,
) -> Result(#(model.Role, List(String)), String) {
  use fields <- result.try(wire.object(value, ["role", "models"]))
  use role <- result.try(
    wire.text(fields, "role") |> result.try(decode_model_role),
  )
  use models <- result.try(wire.strings(fields, "models"))

  // An empty model list is refused, not read as the default route.
  case models {
    [] -> Error("a role entry needs at least one model")
    [_, ..] -> Ok(#(role, models))
  }
}

/// Decodes one model's thinking level.
fn decode_thinking_entry(
  value: JsonValue,
) -> Result(#(String, model.ThinkingLevel), String) {
  use fields <- result.try(wire.object(value, ["model", "level"]))
  use name <- result.try(wire.text(fields, "model"))
  use level <- result.try(
    wire.text(fields, "level") |> result.try(decode_level),
  )

  Ok(#(name, level))
}

/// The component's slot rendered canonically, for uniqueness and ordering.
fn component_key(component: #(Component, String)) -> String {
  json.to_string(json.canonical(slot_json(component.0)))
}

/// The role of a role entry, its sort and uniqueness key.
fn role_key(entry: #(model.Role, List(String))) -> String {
  model.role_to_string(entry.0)
}

/// The model of a thinking entry, its sort and uniqueness key.
fn thinking_key(entry: #(String, model.ThinkingLevel)) -> String {
  entry.0
}

/// Rejects repeated keys and returns the entries ordered by key, which is the
/// order `to_json` writes them in.
fn distinct_sorted(
  entries: List(a),
  key: fn(a) -> String,
) -> Result(List(a), String) {
  let keys = list.map(entries, key)

  // Two entries with one key would make the arm depend on which was read first.
  case list.length(list.unique(keys)) == list.length(keys) {
    True -> Ok(sorted_by(entries, key))
    False -> Error("repeated entry in an arm")
  }
}

/// Puts the knob lists in canonical order and refuses repeated keys, so a
/// decoded arm re-encodes to the bytes it was minted from.
fn normalise(knobs: Knobs) -> Result(Knobs, String) {
  use roles <- result.try(distinct_sorted(knobs.roles, role_key))
  use thinking <- result.try(distinct_sorted(knobs.thinking, thinking_key))

  Ok(Knobs(
    roles:,
    thinking:,
    disabled_tools: list.sort(knobs.disabled_tools, string.compare),
  ))
}
