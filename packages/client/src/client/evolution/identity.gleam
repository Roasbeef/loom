//// Approval freshness binds native build metadata, toolchain and seam contents.
////
//// Release launchers supply the exact build commit. Development VMs lack that
//// claim, so their evidence is deliberately scoped to this VM's native birth
//// identity and cannot authorize a later restart. The offline seed's manifest
//// and vendored preludes are hashed from trusted host paths, never author paths.
//// Evaluator semantic changes also advance the explicit format version below.

import client/codemode
import client/evolution/record
import client/extension/archive
import client/extension/install
import client/internal/ffi_os
import client/mcp
import codemode/vet/policy as vet_policy
import core/json
import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string
import host/bootstrap
import host/build_identity

/// Computes the identity native catalogue admission captures in every envelope.
/// No candidate may supply or replace these fields.
///
/// ## Examples
///
/// ```gleam
/// // identity.current(native_code_mode_host)
/// ```
pub fn current(host: codemode.Config) -> Result(record.Identity, String) {
  use #(status, compiler) <- result.try(ffi_os.run_capture(
    host.gleam_path,
    ["--version"],
    5000,
  ))
  use Nil <- result.try(case status == 0 {
    True -> Ok(Nil)
    False -> Error("the native compiler version could not be observed")
  })
  use manifest <- result.try(text(host.seed_root <> "/manifest.toml"))
  use preludes <- result.try(
    list.try_map(["cap", "core", "ext"], fn(name) {
      use tree <- result.try(
        archive.from_directory(
          host.seed_root <> "/vendor/" <> name <> "/src",
          archive.Caps(256, 262_144, 1_048_576),
        )
        |> result.map_error(archive.describe),
      )
      Ok(#(name, json.String(archive.digest(tree))))
    }),
  )
  use build <- result.try(native_build())
  let build =
    mcp.sha256_hex(
      json.to_string(
        json.Object([
          #("native", json.String(build)),
          #("compiler", json.String(compiler)),
          #("erts", json.String(ffi_os.erts_version())),
          #("manifest", json.String(manifest)),
          #("preludes", json.Object(preludes)),
        ]),
      ),
    )
  let seam =
    mcp.sha256_hex(
      json.to_string(
        json.Object([
          #("extension", imports(install.allowlist())),
          #(
            "workspace",
            imports(
              vet_policy.allowed_imports(codemode.seam_allowlist(
                host,
                vet_policy.WorkspaceSeam,
              )),
            ),
          ),
        ]),
      ),
    )
  Ok(record.Identity(
    build:,
    seam:,
    evaluator: mcp.sha256_hex(build <> ":author-tests-and-live-rollout-1"),
  ))
}

fn imports(names: List(String)) -> json.JsonValue {
  json.Array(list.map(list.sort(names, string.compare), json.String))
}

fn native_build() -> Result(String, String) {
  let identity = build_identity.current()
  case identity.commit == build_identity.unknown_commit {
    False -> Ok(build_identity.describe(identity))
    True -> {
      let pid = bootstrap.current_process_id()
      use birth <- result.try(bootstrap.process_identity(pid))
      case birth {
        bootstrap.ProcessAbsent -> Error("development VM birth is unavailable")
        bootstrap.ProcessPresent(..) -> Ok(string.inspect(#(pid, birth)))
      }
    }
  }
}

fn text(path: String) -> Result(String, String) {
  use bytes <- result.try(bootstrap.read_bounded(path, 262_144))
  bit_array.to_string(bytes)
  |> result.replace_error("the native build manifest is not UTF-8")
}
