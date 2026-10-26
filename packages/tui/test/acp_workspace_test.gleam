//// The workspace gate of `loom acp`: a client-supplied `cwd` binds a session
//// only inside a root the operator named, and a registered workspace is a
//// name, never a path.

import gleam/option.{None, Some}
import gleam/string
import tui/acp/schema
import tui/acp/workspace

fn meta(
  name: option.Option(String),
  executor: option.Option(String),
  pool: option.Option(String),
) -> schema.Meta {
  schema.Meta(name, executor, pool, None, None, schema.GuidanceLoaded)
}

fn identity(path: String) -> Result(String, String) {
  Ok(path)
}

pub fn a_path_inside_a_root_is_admitted_as_a_local_workspace_test() {
  assert workspace.choose(
      meta(None, None, None),
      "/work/app",
      ["/work"],
      identity,
    )
    == Ok(workspace.Local("/work/app"))
}

pub fn the_root_itself_is_admitted_test() {
  assert workspace.choose(meta(None, None, None), "/work", ["/work"], identity)
    == Ok(workspace.Local("/work"))
}

pub fn a_path_outside_every_root_is_refused_test() {
  let assert Error(reason) =
    workspace.choose(
      meta(None, None, None),
      "/etc",
      ["/work", "/srv"],
      identity,
    )

  assert string.contains(reason, "outside")
}

pub fn a_sibling_that_shares_a_prefix_is_not_inside_test() {
  assert workspace.within("/work/app", "/work/app-evil") == False
  assert workspace.within("/work/app", "/work/app/src") == True
  assert workspace.within("/", "/anything") == True
  assert workspace.within("/work", "relative") == False
}

pub fn a_relative_cwd_is_refused_before_the_filesystem_is_asked_test() {
  let must_not_run = fn(_) { panic as "canonicalisation must not run" }

  let assert Error(reason) =
    workspace.choose(meta(None, None, None), "app", ["/work"], must_not_run)
  assert string.contains(reason, "absolute")
}

pub fn the_path_is_compared_after_resolution_so_a_link_cannot_escape_test() {
  let resolve = fn(path) {
    case path {
      "/work/link" -> Ok("/etc")
      other -> Ok(other)
    }
  }

  let assert Error(_) =
    workspace.choose(meta(None, None, None), "/work/link", ["/work"], resolve)
}

pub fn a_cwd_that_does_not_exist_is_refused_with_the_reason_test() {
  let missing = fn(_) { Error("no such directory") }

  let assert Error(reason) =
    workspace.choose(meta(None, None, None), "/work/gone", ["/work"], missing)
  assert string.contains(reason, "no such directory")
}

pub fn a_registered_workspace_needs_an_executor_or_a_pool_test() {
  assert workspace.choose(
      meta(Some("repo"), Some("builder"), None),
      "/ignored",
      [],
      identity,
    )
    == Ok(workspace.Registered("repo", "builder", ""))
  assert workspace.choose(
      meta(Some("repo"), None, Some("fleet")),
      "/ignored",
      [],
      identity,
    )
    == Ok(workspace.Registered("repo", "", "fleet"))
  let assert Error(_) =
    workspace.choose(meta(Some("repo"), None, None), "/w", [], identity)
  let assert Error(_) =
    workspace.choose(
      meta(Some("repo"), Some("a"), Some("b")),
      "/w",
      [],
      identity,
    )
  let assert Error(_) =
    workspace.choose(meta(Some("  "), Some("a"), None), "/w", [], identity)
}

pub fn an_executor_without_a_workspace_name_is_refused_test() {
  let assert Error(_) =
    workspace.choose(meta(None, Some("builder"), None), "/w", ["/w"], identity)
}
