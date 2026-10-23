//// An explicit live contract separates compatible state migration from the
//// ordinary replacement path. Decoding admits only a bounded pause and a
//// stable message boundary; execution authority still belongs to evolution.

import codemode/vet/migration
import codemode/vet/package
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tom

/// The operator-visible contract compiled together with an immutable candidate.
pub type Contract {
  Contract(
    /// The authored module exporting the state and callback definition.
    entry: String,
    /// The effect-free authored module exporting the state migration.
    migration: String,
    /// The message schema shared by every compatible generation.
    boundary: String,
    /// The state schema this generation produces.
    state_version: String,
    /// Previous state schemas its migration decoder accepts.
    accepts: List(String),
    /// The upper bound on the actor's suspension in milliseconds.
    pause_ms: Int,
    /// The largest serialized state admitted before and after migration.
    max_state_bytes: Int,
  )
}

/// Reads the optional live declaration, refusing unknown or unbounded fields.
///
/// ## Examples
///
/// ```gleam
/// assert live_contract.decode("[extension]\nname = \"plain\"", [])
///   == Ok(None)
/// ```
///
pub fn decode(
  text: String,
  modules: List(String),
) -> Result(Option(Contract), String) {
  use document <- result.try(
    tom.parse(text) |> result.replace_error("invalid extension TOML"),
  )
  case dict.get(document, "live") {
    Error(Nil) -> Ok(None)
    Ok(tom.Table(fields)) | Ok(tom.InlineTable(fields)) -> {
      use contract <- result.try(fields_contract(fields, modules))
      Ok(Some(contract))
    }
    Ok(_) -> Error("[live] must be a table")
  }
}

fn fields_contract(
  fields: Dict(String, tom.Toml),
  modules: List(String),
) -> Result(Contract, String) {
  let allowed = [
    "entry",
    "migration",
    "boundary",
    "state_version",
    "accepts",
    "pause_ms",
    "max_state_bytes",
  ]
  use Nil <- result.try(
    list.try_each(dict.keys(fields), fn(key) {
      case list.contains(allowed, key) {
        True -> Ok(Nil)
        False -> Error("unknown [live] field: " <> key)
      }
    }),
  )
  use entry <- result.try(text_field(fields, "entry"))
  use Nil <- result.try(case list.contains(modules, entry) {
    True -> Ok(Nil)
    False -> Error("[live].entry must name a shipped authored module")
  })
  use migration <- result.try(text_field(fields, "migration"))
  use Nil <- result.try(case list.contains(modules, migration) {
    True -> Ok(Nil)
    False -> Error("[live].migration must name a shipped authored module")
  })
  use boundary <- result.try(text_field(fields, "boundary"))
  use state_version <- result.try(text_field(fields, "state_version"))
  use accepts <- result.try(accepted_versions(fields))
  use pause_ms <- result.try(bounded_int(fields, "pause_ms", 1000))
  use max_state_bytes <- result.try(bounded_int(
    fields,
    "max_state_bytes",
    65_536,
  ))
  Ok(Contract(
    entry:,
    migration:,
    boundary:,
    state_version:,
    accepts:,
    pause_ms:,
    max_state_bytes:,
  ))
}

fn text_field(
  fields: Dict(String, tom.Toml),
  key: String,
) -> Result(String, String) {
  case dict.get(fields, key) {
    Ok(tom.String(text)) if text != "" -> {
      case string.byte_size(text) <= 128 {
        True -> Ok(text)
        False -> Error("[live]." <> key <> " exceeds 128 bytes")
      }
    }
    _ -> Error("[live]." <> key <> " must be a non-empty string")
  }
}

fn accepted_versions(
  fields: Dict(String, tom.Toml),
) -> Result(List(String), String) {
  use values <- result.try(case dict.get(fields, "accepts") {
    Ok(tom.Array(values)) if values != [] -> Ok(values)
    _ -> Error("[live].accepts must contain at least one state version")
  })
  use versions <- result.try(
    list.try_map(values, fn(value) {
      case value {
        tom.String(text) if text != "" -> {
          case string.byte_size(text) <= 128 {
            True -> Ok(text)
            False -> Error("[live].accepts version exceeds 128 bytes")
          }
        }
        _ -> Error("[live].accepts contains a non-string or empty version")
      }
    }),
  )
  case list.length(versions) <= 16 && list.unique(versions) == versions {
    True -> Ok(versions)
    False -> Error("[live].accepts must contain at most 16 distinct versions")
  }
}

fn bounded_int(
  fields: Dict(String, tom.Toml),
  key: String,
  maximum: Int,
) -> Result(Int, String) {
  case dict.get(fields, key) {
    Ok(tom.Int(value)) if value > 0 && value <= maximum -> Ok(value)
    _ -> Error("[live]." <> key <> " is outside its native bound")
  }
}

/// Checks compatibility before a compiler artifact can suspend the actor.
///
/// ## Examples
///
/// ```gleam
/// // live_contract.compatible(current, target, current_state_version)
/// ```
///
pub fn compatible(
  current: Contract,
  target: Contract,
  state_version: String,
) -> Result(Nil, String) {
  use Nil <- result.try(case current.boundary == target.boundary {
    True -> Ok(Nil)
    False -> Error("live message boundary is incompatible")
  })
  case list.contains(target.accepts, state_version) {
    True -> Ok(Nil)
    False -> Error("live migration does not accept the current state version")
  }
}

/// Narrows every migration helper to the effect-free source seam.
///
/// ## Examples
///
/// ```gleam
/// // live_contract.vet(files, vetted)
/// ```
///
pub fn vet(
  files: List(#(String, String)),
  vetted: package.VettedPackage,
) -> Result(Nil, String) {
  use text <- result.try(
    list.key_find(files, "extension.toml")
    |> result.replace_error("extension.toml absent"),
  )
  use contract <- result.try(decode(text, package.module_names(vetted)))
  case contract {
    None -> Ok(Nil)
    Some(contract) -> migration.check(vetted, contract.migration)
  }
}
