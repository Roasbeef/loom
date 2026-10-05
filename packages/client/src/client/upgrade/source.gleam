//// Reviewed core artifacts have a separate authority from authored extensions.
////
//// Only fixed official release URLs are resolved. The native owner supplies an
//// exact manifest digest; TLS establishes source authenticity, while manifest
//// and BEAM digests establish byte equality. No operator JSON supplies a local
//// path, arbitrary URL, raw BEAM bytes or extension candidate identity.

import client/upgrade/download
import client/upgrade/state as abi
import core/json
import gleam/bit_array
import gleam/bool
import gleam/list
import gleam/result
import gleam/string
import host/bootstrap as host

/// Bounded verified HTTPS acquisition, injectable only by trusted harness code.
pub type Fetch =
  fn(String, Int) -> Result(BitArray, String)

/// Artifact identity and bytes verified together before slot ownership admission.
pub opaque type Artifact {
  Artifact(
    identity: abi.Identity,
    bytes: BitArray,
    accepts: List(String),
    release: String,
    manifest_digest: String,
  )
}

/// Exact implementation identity admitted by the release resolver.
/// ## Examples
/// `identity(artifact).boundary` is `"loom.scratch.v1"`.
pub fn identity(artifact: Artifact) -> abi.Identity {
  artifact.identity
}

/// Verified bytes, available only to the trusted slot owner.
/// ## Examples
/// `bytes(artifact)` is bounded to one MiB.
pub fn bytes(artifact: Artifact) -> BitArray {
  artifact.bytes
}

/// Whether this release explicitly supports the current state representation.
/// ## Examples
/// `accepts(artifact, "v1")` checks declared migration compatibility.
pub fn accepts(artifact: Artifact, current: String) -> Bool {
  list.contains(artifact.accepts, current)
}

/// Resolve a manifest and BEAM artifact from the fixed official release origin.
/// ## Examples
/// `resolve("v0.2.1", exact_manifest_digest)` accepts no arbitrary path.
pub fn resolve(
  release: String,
  manifest_digest: String,
) -> Result(Artifact, String) {
  resolve_on(release, manifest_digest, download.fetch)
}

/// Trusted test/transport seam with the same fixed-origin and digest policy.
///
/// This injectable function is never exposed through operator or capability
/// arguments. Production uses `resolve` and verified TLS.
/// ## Examples
/// `resolve_on(tag, digest, fixture_fetch)` still verifies all admitted bytes.
pub fn resolve_on(
  release: String,
  manifest_digest: String,
  fetch: Fetch,
) -> Result(Artifact, String) {
  use <- bool.guard(
    !basename(release),
    Error("reviewed release must be a conservative tag"),
  )
  use <- bool.guard(
    !hexadecimal(manifest_digest, 64),
    Error("an exact reviewed manifest SHA-256 is required"),
  )
  let base = "https://github.com/Roasbeef/loom/releases/download/" <> release
  use manifest_bytes <- result.try(fetch(
    base <> "/harness-scratch.json",
    65_536,
  ))
  use <- bool.guard(
    bit_array.byte_size(manifest_bytes) > 65_536
      || digest(manifest_bytes) != manifest_digest,
    Error("reviewed manifest size or digest differs from admission"),
  )
  use text <- result.try(
    bit_array.to_string(manifest_bytes)
    |> result.replace_error("reviewed manifest is not UTF-8"),
  )
  use document <- result.try(
    json.parse(text) |> result.replace_error("invalid reviewed manifest JSON"),
  )
  use artifact <- result.try(decode_manifest(document, release, manifest_digest))
  let module = case artifact.identity.slot {
    abi.SlotA -> "loom_scratch_a"
    abi.SlotB -> "loom_scratch_b"
    abi.Builtin -> "builtin"
  }
  use bytes <- result.try(fetch(base <> "/" <> module <> ".beam", artifact.size))
  use <- bool.guard(
    bit_array.byte_size(bytes) != artifact.size
      || digest(bytes) != artifact.identity.digest,
    Error("reviewed BEAM size or digest differs from manifest"),
  )
  Ok(Artifact(
    artifact.identity,
    bytes,
    artifact.accepts,
    release,
    manifest_digest,
  ))
}

/// Immutable shipped implementation used for current-state downgrade.
/// ## Examples
/// `builtin()` contains no downloaded code or saved state snapshot.
pub fn builtin() -> Artifact {
  Artifact(abi.builtin(), <<>>, ["v1"], "builtin", "builtin")
}

type Decoded {
  Decoded(identity: abi.Identity, size: Int, accepts: List(String))
}

fn decode_manifest(document, release, _manifest_digest) {
  use fields <- result.try(case document {
    json.Object(fields) -> Ok(fields)
    _ -> Error("reviewed manifest must be an object")
  })
  use <- bool.guard(
    list.any(fields, fn(field) {
      !list.contains(
        [
          "schema",
          "repository",
          "release",
          "component",
          "module",
          "version",
          "state_version",
          "boundary",
          "size",
          "sha256",
          "accepts",
        ],
        field.0,
      )
    }),
    Error("unknown reviewed manifest field"),
  )
  use schema <- result.try(number(fields, "schema"))
  use repository <- result.try(text(fields, "repository"))
  use selected <- result.try(text(fields, "release"))
  use component <- result.try(text(fields, "component"))
  use module <- result.try(text(fields, "module"))
  use version <- result.try(text(fields, "version"))
  use state_version <- result.try(text(fields, "state_version"))
  use boundary <- result.try(text(fields, "boundary"))
  use size <- result.try(number(fields, "size"))
  use sha256 <- result.try(text(fields, "sha256"))
  use declared <- result.try(field(fields, "accepts"))
  use accepts <- result.try(case declared {
    json.Array(items) ->
      list.try_map(items, fn(item) {
        case item {
          json.String(version) -> Ok(version)
          _ -> Error("invalid migration source version")
        }
      })
    _ -> Error("reviewed migration source versions must be an array")
  })
  use <- bool.guard(
    schema != 1
      || repository != "Roasbeef/loom"
      || selected != release
      || component != "scratch",
    Error("reviewed manifest identity differs from source selection"),
  )
  use <- bool.guard(
    !basename(version)
      || state_version != "v1"
      || boundary != "loom.scratch.v1"
      || accepts != ["v1"],
    Error("reviewed scratch ABI or migration compatibility is unsupported"),
  )
  use <- bool.guard(
    size <= 0 || size > 1_048_576 || !hexadecimal(sha256, 64),
    Error("reviewed BEAM bound or digest is invalid"),
  )
  use slot <- result.try(case module {
    "loom_scratch_a" -> Ok(abi.SlotA)
    "loom_scratch_b" -> Ok(abi.SlotB)
    _ -> Error("reviewed module is outside the fixed component allowlist")
  })
  Ok(Decoded(
    abi.Identity(slot, version, sha256, state_version, boundary),
    size,
    accepts,
  ))
}

fn field(fields, key) {
  list.key_find(fields, key)
  |> result.map_error(fn(_) { "reviewed manifest lacks " <> key })
}

fn text(fields, key) {
  use value <- result.try(field(fields, key))
  case value {
    json.String(value) -> Ok(value)
    _ -> Error("reviewed manifest field must be text: " <> key)
  }
}

fn number(fields, key) {
  use value <- result.try(field(fields, key))
  case value {
    json.Int(value) -> Ok(value)
    _ -> Error("reviewed manifest field must be an integer: " <> key)
  }
}

/// SHA-256 of exact artifact bytes, in canonical lowercase hexadecimal.
/// ## Examples
/// `digest(<<"artifact":utf8>>)` returns a 64-character identity.
pub fn digest(bytes: BitArray) -> String {
  host.sha256(bytes) |> bit_array.base16_encode |> string.lowercase
}

/// Conservative release basename, refusing path and shell syntax.
/// ## Examples
/// `basename("../release")` is false.
pub fn basename(value: String) -> Bool {
  string.length(value) > 0
  && string.length(value) <= 200
  && value != "."
  && value != ".."
  && list.all(string.to_utf_codepoints(value), fn(point) {
    let n = string.utf_codepoint_to_int(point)
    n >= 48
    && n <= 57
    || n >= 65
    && n <= 90
    || n >= 97
    && n <= 122
    || n == 45
    || n == 46
    || n == 95
  })
}

/// Canonical fixed-width lowercase hexadecimal identity.
/// ## Examples
/// `hexadecimal("ab", 2)` is true.
pub fn hexadecimal(value: String, width: Int) -> Bool {
  bit_array.byte_size(<<value:utf8>>) == width
  && list.all(string.to_utf_codepoints(value), fn(point) {
    let n = string.utf_codepoint_to_int(point)
    n >= 48 && n <= 57 || n >= 97 && n <= 102
  })
}
