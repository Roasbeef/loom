//// The private Go caches: where they live, what the jail sees of them,
//// how the mirror is judged, and how a retired build cache is replaced.

import broker/policy
import client/catalog
import client/gocache
import client/internal/ffi_os
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile

fn caches_at(root: String, limit_mib: Int) -> gocache.GoCaches {
  gocache.GoCaches(root:, mirror: None, limit_kib: limit_mib * 1024)
}

fn scratch(name: String) -> String {
  let assert Ok(cwd) = simplifile.current_directory()
  let path =
    cwd
    <> "/build/gocache-test-"
    <> name
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let _stale = simplifile.delete(path)
  let assert Ok(Nil) = simplifile.create_directory_all(path)
  path
}

pub fn the_caches_live_outside_the_workspace_and_differ_per_workspace_test() {
  let assert Some(first) =
    gocache.locate(Some("/home/o/.cache/"), "/work/a", None, 10_240)
  let assert Some(second) =
    gocache.locate(Some("/home/o/.cache"), "/work/b", None, 10_240)
  assert first.root != second.root
  assert string.starts_with(first.root, "/home/o/.cache/loom/workspace/")
  assert !string.starts_with(first.root, "/work/a")

  // Sessions of one workspace resolve one directory.
  let assert Some(again) =
    gocache.locate(Some("/home/o/.cache"), "/work/a", None, 10_240)
  assert again == first
  assert first.limit_kib == 10_240 * 1024
}

pub fn no_cache_place_means_no_private_caches_test() {
  assert gocache.locate(None, "/work", None, 10_240) == None
}

pub fn the_environment_names_the_private_directories_test() {
  let caches = gocache.GoCaches(root: "/c/r", mirror: None, limit_kib: 1)
  assert gocache.environment(caches)
    == [
      #("GOCACHE", "/c/r/go-build"),
      #("GOMODCACHE", "/c/r/gomod"),
      #("GOLANGCI_LINT_CACHE", "/c/r/golangci-lint"),
    ]
}

pub fn a_mirror_adds_a_file_proxy_ahead_of_the_public_one_test() {
  let caches =
    gocache.GoCaches(root: "/c/r", mirror: Some("/m/mod"), limit_kib: 1)
  assert list.key_find(gocache.environment(caches), "GOPROXY")
    == Ok("file:///m/mod/cache/download,https://proxy.golang.org,direct")
}

pub fn the_base_grants_the_root_writable_and_the_mirror_read_only_test() {
  let caches =
    gocache.GoCaches(root: "/c/r", mirror: Some("/m/mod"), limit_kib: 1)
  let base = gocache.admitting(policy.workspace_default("/work"), Some(caches))
  assert list.contains(base.writable_roots, "/c/r")
  assert list.contains(base.writable_roots, "/work")
  assert list.contains(base.env_allow, "GOCACHE")
  assert list.contains(base.env_allow, "GOPROXY")
  assert base.mounts
    == [
      policy.Mount(
        path: "/m/mod/cache/download",
        access: policy.MountReadOnly,
        requirement: policy.MountOptional,
      ),
    ]

  // The host module cache itself is never a writable root.
  assert !list.contains(base.writable_roots, "/m/mod")
  assert gocache.admitting(policy.workspace_default("/work"), None)
    == policy.workspace_default("/work")
}

pub fn the_mirror_key_decodes_strictly_test() {
  let parse = fn(body) { catalog.parse_workspace("[workspace]\n" <> body) }
  let assert Ok(absent) = parse("")
  assert absent.go_module_mirror == None
  assert absent.go_cache_limit_mib == catalog.default_go_cache_limit_mib

  let assert Ok(valid) =
    parse(
      "go_module_mirror = \"/home/o/go/pkg/mod/\"\ngo_cache_limit_mib = 512\n",
    )
  assert valid.go_module_mirror == Some("/home/o/go/pkg/mod")
  assert valid.go_cache_limit_mib == 512

  assert result.is_error(parse("go_module_mirror = \"relative/mod\"\n"))
  assert result.is_error(parse("go_module_mirror = \"/has space/mod\"\n"))
  assert result.is_error(parse("go_module_mirror = \"/a,b\"\n"))
  assert result.is_error(parse("go_module_mirror = \"/\"\n"))
  assert result.is_error(parse("go_module_mirror = 3\n"))
  assert result.is_error(parse("go_cache_limit_mib = 0\n"))
  assert result.is_error(parse("go_cache_limit_mib = \"big\"\n"))
  assert result.is_error(parse("go_module_mirrr = \"/m\"\n"))
}

pub fn a_mirror_must_exist_and_hold_a_download_directory_test() {
  let root = scratch("mirror")
  let caches =
    gocache.GoCaches(
      root: root <> "/private",
      mirror: Some(root <> "/mod"),
      limit_kib: 1,
    )

  let assert Error(missing) =
    gocache.fault(caches, "/work", [], tools_naming: [])
  assert string.contains(missing, "[workspace] go_module_mirror")
  assert string.contains(missing, "does not exist")

  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/mod")
  let assert Error(bare) = gocache.fault(caches, "/work", [], tools_naming: [])
  assert string.contains(bare, "cache/download")

  let assert Ok(Nil) =
    simplifile.create_directory_all(root <> "/mod/cache/download")
  assert gocache.fault(caches, "/work", [], tools_naming: []) == Ok(Nil)
  let _cleanup = simplifile.delete(root)
}

pub fn a_mirror_may_not_overlap_the_workspace_or_a_masked_path_test() {
  let root = scratch("overlap")
  let assert Ok(Nil) =
    simplifile.create_directory_all(root <> "/mod/cache/download")
  let caches =
    gocache.GoCaches(
      root: root <> "/private",
      mirror: Some(root <> "/mod"),
      limit_kib: 1,
    )

  // The workspace inside the mirror, and the mirror inside the workspace,
  // are both an overlap.
  let assert Error(inside) =
    gocache.fault(caches, root <> "/mod/project", [], tools_naming: [])
  assert string.contains(inside, "the workspace")
  let assert Error(above) = gocache.fault(caches, root, [], tools_naming: [])
  assert string.contains(above, "the workspace")

  let assert Error(masked) =
    gocache.fault(caches, "/work", [root <> "/mod/cache"], tools_naming: [])
  assert string.contains(masked, "protected")
  let _cleanup = simplifile.delete(root)
}

pub fn tools_may_not_set_names_the_server_owns_test() {
  let caches = gocache.GoCaches(root: "/c/r", mirror: None, limit_kib: 1)
  let assert Error(refused) =
    gocache.fault(caches, "/work", [], tools_naming: ["GOCACHE"])
  assert string.contains(refused, "[tools]")

  // GOPROXY is the operator's until a mirror takes it over.
  assert gocache.fault(caches, "/work", [], tools_naming: ["GOPROXY"])
    == Ok(Nil)
  let mirrored = gocache.GoCaches(..caches, mirror: Some("/nowhere"))
  let assert Error(_) =
    gocache.fault(mirrored, "/work", [], tools_naming: ["GOPROXY"])
}

pub fn a_cache_over_the_limit_is_renamed_and_replaced_test() {
  let root = scratch("trim")
  let caches = caches_at(root, 1)
  let build = gocache.build_cache(caches)
  let assert Ok(Nil) = simplifile.create_directory_all(build <> "/ab")
  let assert Ok(Nil) = simplifile.write(build <> "/ab/entry", "object")

  let assert Ok(gocache.Retired(size_kib: 5000, trash:)) =
    gocache.trim(caches, measuring: fn(_) { Ok(5000) }, unique: "t1")
  assert trash == root <> "/trash-t1"

  // The old tree moved whole, and the replacement is empty but has Go's
  // fan-out directories so a build that already opened it can write.
  assert simplifile.read(trash <> "/ab/entry") == Ok("object")
  assert simplifile.is_file(build <> "/ab/entry") == Ok(False)
  assert simplifile.is_directory(build <> "/ab") == Ok(True)
  assert simplifile.is_directory(build <> "/ff") == Ok(True)

  // Deletion is the sweep's job, and it leaves the live cache alone.
  assert gocache.sweep(caches) == Ok(1)
  assert simplifile.is_directory(trash) == Ok(False)
  assert simplifile.is_directory(build) == Ok(True)
  let _cleanup = simplifile.delete(root)
}

pub fn a_cache_within_the_limit_is_left_alone_test() {
  let root = scratch("within")
  let caches = caches_at(root, 1)
  let build = gocache.build_cache(caches)
  let assert Ok(Nil) = simplifile.create_directory_all(build)
  let assert Ok(Nil) = simplifile.write(build <> "/entry", "object")
  assert gocache.trim(caches, measuring: fn(_) { Ok(1024) }, unique: "t1")
    == Ok(gocache.Within(size_kib: 1024))
  assert simplifile.read(build <> "/entry") == Ok("object")
  let _cleanup = simplifile.delete(root)
}

pub fn a_failed_measurement_trims_nothing_test() {
  let root = scratch("unmeasured")
  let caches = caches_at(root, 1)
  let assert Ok(Nil) =
    simplifile.create_directory_all(gocache.build_cache(caches))
  assert gocache.trim(caches, measuring: fn(_) { Error("no du") }, unique: "t")
    == Error("no du")
  assert simplifile.is_directory(gocache.build_cache(caches)) == Ok(True)
  let _cleanup = simplifile.delete(root)
}

pub fn the_sweep_removes_a_planted_link_without_following_it_test() {
  let root = scratch("link")
  let caches = caches_at(root, 1)
  let victim = root <> "/victim"
  let assert Ok(Nil) = simplifile.create_directory_all(victim)
  let assert Ok(Nil) = simplifile.write(victim <> "/keep", "precious")
  let assert Ok(Nil) =
    simplifile.create_symlink(victim, root <> "/trash-planted")
  assert gocache.sweep(caches) == Ok(1)
  assert simplifile.read(victim <> "/keep") == Ok("precious")
  let _cleanup = simplifile.delete(root)
}

pub fn du_output_is_read_as_kibibytes_test() {
  assert gocache.parse_du("2048\t/x\n") == Ok(2048)
  assert result.is_error(gocache.parse_du("garbage"))
}

pub fn the_real_du_measures_a_directory_test() {
  let root = scratch("du")
  let assert Ok(Nil) = simplifile.write(root <> "/f", string.repeat("x", 8192))
  let assert Ok(size) = gocache.du_kib(root)
  assert size >= 8
  let _cleanup = simplifile.delete(root)
}
