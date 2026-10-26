//// Renders an arm into the session configuration a trial runs under.
////
//// An arm is data: text components and model-selection knobs. A trial needs
//// two things made from it. The first is a `Settings` whose catalogue roles,
//// thinking levels, routes and withheld tools are the arm's (`to_settings`).
//// The second is the arm's prompt profiles, one per distinct exact model the
//// components name (`profiles`), which the trial installs through the same
//// gateway seam the governed evolution path uses. Splitting them keeps the
//// profile map where the shared trial recipe expects it.
////
//// The rule that matters here is that nothing is applied silently or not at
//// all. Every component or knob this module cannot honour is an `Error` that
//// names it: a role-aimed component (`arm.refuse_unapplied`), a prompt pack
//// that does not decode (see `pack_of`), a model name the catalogue does not hold, a profile
//// aimed at a model the catalogue does not route or at the wrong wire API.
//// An arm that quietly ran as the baseline would make every comparison read
//// as "indistinguishable" for a reason nobody could find.

import client/catalog.{type Catalog, type CatalogModel, Catalog}
import client/mcp
import client/serve.{type Settings, Settings}
import core/corruption
import eval/arm.{
  type Arm, type Target, PromptPack, SystemSuffix, TaskPrefix, ToolDescription,
}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import prompt/pack
import provider/gateway
import provider/model
import provider/profile.{type Profile}

/// Applies the arm's model-selection knobs to `base`.
///
/// Catalogue roles named by the arm replace the base rows for those roles;
/// thinking levels replace the named entries' levels; every role is then
/// routed again from the resulting catalogue, so the gateway the trial uses
/// agrees with the catalogue it was configured from; and the arm's withheld
/// tools join the base's.
///
/// ## Examples
///
/// ```gleam
/// // arm_settings.to_settings(arm, base) -> Ok(Settings(..base, deactivated_tools: ["bash"]))
/// ```
///
pub fn to_settings(arm: Arm, base: Settings) -> Result(Settings, String) {
  use arm <- result.try(arm.refuse_unapplied(arm))
  use pack <- result.try(pack_of(arm))
  use thinking <- result.try(apply_thinking(base.catalog, arm.knobs.thinking))
  use roles <- result.try(apply_roles(thinking, arm.knobs.roles))

  Ok(
    Settings(
      ..base,
      pack: option.or(pack, base.pack),
      catalog: roles,
      gateway: route_all(base.gateway, roles),
      deactivated_tools: list.unique(list.append(
        base.deactivated_tools,
        arm.knobs.disabled_tools,
      )),
    ),
  )
}

/// The arm's prompt profiles: one per distinct exact `(provider, model, api)`
/// its components name, role `Any` only, in sorted target order.
///
/// ## Examples
///
/// ```gleam
/// // arm_settings.profiles(arm_with_a_system_suffix, base) -> Ok([profile])
/// ```
///
pub fn profiles(arm: Arm, base: Settings) -> Result(List(Profile), String) {
  use arm <- result.try(arm.refuse_unapplied(arm))

  let targets =
    arm.components
    |> list.filter_map(fn(component) { target_of(component.0) })
    |> list.map(key_of)
    |> list.unique
    |> list.sort(compare_keys)

  list.try_map(targets, fn(key) { profile_for(arm, base, key) })
}

type Key =
  #(String, String, String)

/// The exact-model key a profile is selected by.
fn key_of(target: Target) -> Key {
  #(target.provider, target.model_id, target.api)
}

/// Orders target keys by their joined text so profile order does not depend on component order.
fn compare_keys(left: Key, right: Key) -> order.Order {
  string.compare(
    left.0 <> "\u{0}" <> left.1 <> "\u{0}" <> left.2,
    right.0 <> "\u{0}" <> right.1 <> "\u{0}" <> right.2,
  )
}

/// The exact target a component is aimed at; the prompt pack has none.
fn target_of(component: arm.Component) -> Result(Target, Nil) {
  case component {
    SystemSuffix(target:) | TaskPrefix(target:) -> Ok(target)
    ToolDescription(target:, ..) -> Ok(target)
    PromptPack -> Error(Nil)
  }
}

/// The prompt pack source the arm carries, if any, after proving it decodes.
///
/// The pack reaches the session as text in `Settings.pack`. Decoding it here,
/// with the pack's own total decoder, refuses a corrupt pack by arm name
/// before any trial opens; left to the session boot it would fail every trial
/// as an infrastructure error and spend attempts finding that out.
fn pack_of(arm: Arm) -> Result(Option(String), String) {
  case list.find(arm.components, fn(component) { component.0 == PromptPack }) {
    Error(Nil) -> Ok(None)
    Ok(#(_, text)) ->
      case pack.decode(text) {
        Ok(_) -> Ok(Some(text))
        Error(report) ->
          Error(
            "the PromptPack component of arm "
            <> arm.id
            <> " is corrupt: "
            <> corruption.describe(report),
          )
      }
  }
}

/// A profile is keyed by the exact model, so a component aimed at a model the
/// catalogue does not hold, or at the wrong wire API for it, would be a profile
/// that never matches a request. That is refused here, where the arm is read.
fn profile_for(arm: Arm, base: Settings, key: Key) -> Result(Profile, String) {
  let #(provider, model_id, api) = key
  let label = provider <> "/" <> model_id <> " (" <> api <> ")"

  use entry <- result.try(
    list.find(base.catalog.models, fn(entry) {
      entry.name == provider && entry.model_id == model_id
    })
    |> result.map_error(fn(_) { "the catalogue holds no model " <> label }),
  )

  // A catalogue entry on the right wire API is the only target a profile can match; every other answer says why it cannot.
  use Nil <- result.try(
    case gateway.api_for(base.gateway, catalog.resolved(entry)) {
      Ok(actual) if actual == api -> Ok(Nil)
      Ok(actual) ->
        Error(label <> " speaks " <> actual <> ", not the component's " <> api)
      Error(Nil) -> Error("no provider is registered for " <> label)
    },
  )

  let aimed =
    list.filter(arm.components, fn(component) {
      case target_of(component.0) {
        Ok(target) -> key_of(target) == key
        Error(Nil) -> False
      }
    })

  profile.new(
    "eval-" <> string.slice(mcp.sha256_hex(arm.id <> "|" <> label), 0, 24),
    provider,
    model_id,
    api,
    text_of(aimed, fn(component) {
      case component {
        SystemSuffix(..) -> True
        TaskPrefix(..) | ToolDescription(..) | PromptPack -> False
      }
    }),
    text_of(aimed, fn(component) {
      case component {
        TaskPrefix(..) -> True
        SystemSuffix(..) | ToolDescription(..) | PromptPack -> False
      }
    }),
    list.filter_map(aimed, fn(component) {
      case component.0 {
        ToolDescription(tool:, ..) -> Ok(#(tool, component.1))
        SystemSuffix(..) | TaskPrefix(..) | PromptPack -> Error(Nil)
      }
    }),
  )
}

/// The one component of a kind for a target, or empty. The arm codec refuses a
/// repeated slot, so at most one matches.
fn text_of(
  aimed: List(#(arm.Component, String)),
  wanted: fn(arm.Component) -> Bool,
) -> String {
  aimed
  |> list.find(fn(component) { wanted(component.0) })
  |> result.map(fn(component) { component.1 })
  |> result.unwrap("")
}

/// Sets the thinking level of each named catalogue entry, refusing a name the catalogue lacks.
fn apply_thinking(
  catalogue: Catalog,
  levels: List(#(String, model.ThinkingLevel)),
) -> Result(Catalog, String) {
  use catalogue, change <- list.try_fold(levels, catalogue)
  let #(name, level) = change

  // A level can only be set on an entry the catalogue holds; an unknown name is the arm's mistake, never a quiet no-op.
  case catalog.find(catalogue, name) {
    Error(Nil) -> Error("thinking names a model the catalogue lacks: " <> name)
    Ok(_) ->
      Ok(
        Catalog(
          ..catalogue,
          models: list.map(catalogue.models, fn(entry: CatalogModel) {
            case entry.name == name {
              True -> catalog.CatalogModel(..entry, thinking: level)
              False -> entry
            }
          }),
        ),
      )
  }
}

/// Replaces the catalogue's rows for the roles the arm names, after checking every model named exists.
fn apply_roles(
  catalogue: Catalog,
  rows: List(#(model.Role, List(String))),
) -> Result(Catalog, String) {
  use Nil <- result.try(
    list.try_each(rows, fn(row) {
      list.try_each(row.1, fn(name) {
        catalog.find(catalogue, name)
        |> result.replace(Nil)
        |> result.map_error(fn(_) {
          "a role names a model the catalogue lacks: " <> name
        })
      })
    }),
  )

  let kept =
    list.filter(catalogue.roles, fn(existing) {
      !list.any(rows, fn(row) { row.0 == existing.0 })
    })

  Ok(Catalog(..catalogue, roles: list.append(kept, rows)))
}

/// Routes every role again from the catalogue, so a thinking change reaches
/// roles the arm did not name and the gateway never disagrees with the catalogue.
fn route_all(base: gateway.Gateway, catalogue: Catalog) -> gateway.Gateway {
  list.fold(catalogue.roles, base, fn(routed, row) {
    let chain =
      list.filter_map(row.1, fn(name) {
        catalog.find(catalogue, name) |> result.map(catalog.resolved)
      })

    gateway.route(routed, row.0, chain)
  })
}
