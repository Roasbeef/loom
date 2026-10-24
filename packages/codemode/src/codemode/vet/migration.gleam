//// Migration is computation over a state document, without capabilities.
//// The whole authored import closure is checked: a pure-looking entry cannot
//// conceal an effect in a sibling helper. The existing source vetter owns
//// parser cross-checks and foreign-interface refusal on every visited module.

import codemode/vet
import codemode/vet/package
import codemode/vet/policy
import gleam/list
import gleam/result

/// Proves that a migration entry and every authored helper are effect-free.
///
/// The input is already a vetted package, so module names and source layout
/// have passed the ordinary extension seam. This pass narrows only reachable
/// migration code to the pure standard library and JSON codecs.
///
/// ## Examples
///
/// ```gleam
/// // migration.check(vetted_package, "counter/migrate")
/// ```
///
pub fn check(
  vetted: package.VettedPackage,
  entry: String,
) -> Result(Nil, String) {
  let modules = package.modules(vetted)
  let names = package.module_names(vetted)
  let pure = policy.new(list.append(policy.extension_stdlib_modules(), names))
  visit([entry], [], modules, pure)
}

/// Recursively walks reachable modules verifying none introduce forbidden effects.
fn visit(
  pending: List(String),
  visited: List(String),
  modules: List(#(String, vet.Vetted)),
  pure: policy.VetPolicy,
) -> Result(Nil, String) {
  // Process each pending migration module in depth-first order.
  case pending {
    [] -> Ok(Nil)
    [name, ..rest] -> {
      // Skip modules that have already been vetted.
      case list.contains(visited, name) {
        True -> visit(rest, visited, modules, pure)
        False -> {
          use source <- result.try(
            list.key_find(modules, name)
            |> result.map_error(fn(_) {
              "migration module is missing: " <> name
            }),
          )
          let text = vet.vetted_source(source)

          // Ensure the module obeys the pure migration policy.
          use Nil <- result.try(case vet.vet(text, pure) {
            vet.Passed(_) -> Ok(Nil)
            vet.Rejected(_) ->
              Error(
                "migration reaches a forbidden effect or foreign interface through "
                <> name,
              )
          })

          let authored =
            list.filter(vet.token_imports(text), fn(imported) {
              list.any(modules, fn(module) { module.0 == imported })
            })
          visit(list.append(authored, rest), [name, ..visited], modules, pure)
        }
      }
    }
  }
}
