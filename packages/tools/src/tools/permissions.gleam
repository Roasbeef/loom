//// Declared authority is approved before a command or satellite can start.
////
//// A kernel error can follow earlier effects in the same program, so stderr
//// never triggers replay. A model that requires additional access declares it
//// in the next invocation; the action digest binds those arguments to consent.

import broker/policy
import core/json
import gleam/bool
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import tools/directory_access
import tools/fs
import tools/tool

/// The optional permissions object shared by shell and code-mode tools.
///
/// ## Examples
///
/// ```gleam
/// // #("permissions", permissions.schema())
/// ```
pub fn schema() -> json.JsonValue {
  tool.object_schema(
    [
      #(
        "readable_roots",
        tool.string_array_property(
          "Additional paths needed for this call; approval is requested before execution.",
        ),
      ),
      #(
        "writable_roots",
        tool.string_array_property(
          "Additional writable paths needed for this call; protected paths remain denied.",
        ),
      ),
      #(
        "wall_s",
        tool.integer_property(
          "Requested wall in seconds for this invocation. Zero explicitly requests session-lifetime background jobs; approval is required when the base policy has a finite wall.",
        ),
      ),
      #(
        "network",
        tool.enum_property(
          ["full"],
          "Request full network access for this call. This is not a host-specific grant.",
        ),
      ),
    ],
    [],
  )
}

/// Requests missing authority once, before any external program is launched.
///
/// ## Examples
///
/// ```gleam
/// // permissions.authorize(ctx, args)
/// ```
pub fn authorize(
  ctx: tool.Ctx,
  args: json.JsonValue,
) -> Result(tool.Ctx, tool.ToolOutcome) {
  authorize_against(ctx, args, ctx.base_policy)
}

/// Checks declared capability paths against native workspace authority.
///
/// ## Examples
///
/// ```gleam
/// // permissions.authorize_native(ctx, args)
/// ```
pub fn authorize_native(
  ctx: tool.Ctx,
  args: json.JsonValue,
) -> Result(tool.Ctx, tool.ToolOutcome) {
  use local <- result.try(tool.require_local_workspace(ctx))

  use workspace <- result.try(
    fs.resolve_real(local.filesystem, local.root, ".")
    |> result.map_error(fn(_) {
      tool.failure("workspace could not be resolved")
    }),
  )
  let access = directory_access.approved(ctx.directory_access, ctx.grants)
  let base =
    policy.SandboxPolicy(
      ..ctx.base_policy,
      readable_roots: [workspace, ..access.readable],
      writable_roots: [workspace, ..access.writable],
    )
  authorize_against(ctx, args, base)
}

fn authorize_against(
  ctx: tool.Ctx,
  args: json.JsonValue,
  base: policy.SandboxPolicy,
) -> Result(tool.Ctx, tool.ToolOutcome) {
  use Nil <- result.try(local_path_authority(ctx, args))

  use requested <- result.try(
    decode(tool.Ctx(..ctx, base_policy: base), args)
    |> result.map_error(tool.failure),
  )
  tool.authorize_policy(ctx, base, requested)
}

// Only physical path declarations need workspace access. Owner network/wall
// policy and calls without path declarations remain independent of placement.
fn local_path_authority(
  ctx: tool.Ctx,
  args: json.JsonValue,
) -> Result(Nil, tool.ToolOutcome) {
  use value <- result.try(
    tool.optional_value(args, "permissions") |> result.map_error(tool.failure),
  )
  case value {
    None -> Ok(Nil)
    Some(value) -> {
      use read <- result.try(
        tool.optional_string_list(value, "readable_roots")
        |> result.map_error(tool.failure),
      )
      use write <- result.try(
        tool.optional_string_list(value, "writable_roots")
        |> result.map_error(tool.failure),
      )
      case option.unwrap(read, []) == [] && option.unwrap(write, []) == [] {
        True -> Ok(Nil)
        False -> tool.require_local_workspace(ctx) |> result.map(fn(_) { Nil })
      }
    }
  }
}

fn decode(
  ctx: tool.Ctx,
  args: json.JsonValue,
) -> Result(policy.SandboxPolicy, String) {
  use value <- result.try(tool.optional_value(args, "permissions"))
  case value {
    None -> Ok(ctx.base_policy)
    Some(value) -> {
      use read <- result.try(tool.optional_string_list(value, "readable_roots"))
      use write <- result.try(tool.optional_string_list(value, "writable_roots"))
      use network <- result.try(tool.optional_string(value, "network"))
      use wall <- result.try(tool.optional_int(value, "wall_s"))
      use <- bool.guard(
        when: option.unwrap(wall, 0) < 0,
        return: Error(
          "permissions.wall_s must be zero or a positive number of seconds",
        ),
      )
      let read = option.unwrap(read, [])
      let write = option.unwrap(write, [])
      use <- bool.guard(
        list.length(read) + list.length(write) > 32,
        Error("permissions allow at most 32 paths"),
      )
      use readable <- result.try(
        list.try_map(read, fn(path) { canonical(ctx, path) }),
      )
      use writable <- result.try(
        list.try_map(write, fn(path) {
          use local <- result.try(
            tool.require_local_workspace(ctx)
            |> result.map_error(fn(_) { "local workspace required" }),
          )
          fs.resolve_writable_roots(
            local.filesystem,
            "/",
            [],
            ctx.base_policy.protected,
            absolute(local.root, path),
          )
          |> result.map_error(fn(_) {
            "requested writable path cannot be resolved or is protected"
          })
        }),
      )
      use network <- result.try(case network {
        None -> Ok(ctx.base_policy.network)
        Some("full") -> Ok(policy.NetworkFull)
        Some(_) -> Error("permissions.network must be full")
      })
      Ok(
        policy.SandboxPolicy(
          ..ctx.base_policy,
          readable_roots: list.unique(
            list.flatten([ctx.base_policy.readable_roots, readable, writable]),
          ),
          writable_roots: list.unique(list.append(
            ctx.base_policy.writable_roots,
            writable,
          )),
          network:,
          limits: policy.Limits(
            ..ctx.base_policy.limits,
            wall_s: option.unwrap(wall, ctx.base_policy.limits.wall_s),
          ),
        ),
      )
    }
  }
}

fn absolute(workspace_root: String, path: String) -> String {
  case path {
    "/" <> _ -> path
    "" -> ""
    _ -> workspace_root <> "/" <> path
  }
}

fn canonical(ctx: tool.Ctx, path: String) -> Result(String, String) {
  use local <- result.try(
    tool.require_local_workspace(ctx)
    |> result.map_error(fn(_) { "local workspace required" }),
  )

  fs.resolve_real(local.filesystem, "/", absolute(local.root, path))
  |> result.map_error(fn(_) { "requested readable path cannot be resolved" })
}
