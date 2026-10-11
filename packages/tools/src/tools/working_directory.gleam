//// Shell directory selection is separate from workspace authority.
////
//// A host stores one default per strand. Every command captures its selected
//// canonical directory before execution; changing the default cannot move a
//// running job or change where native file and LSP paths resolve.

import core/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import tools/fs
import tools/permissions
import tools/tool.{type Ctx}

/// The host-owned per-strand directory store.
pub type Door {
  Door(
    /// Reads this caller's default, with workspace as the missing-state value.
    read: fn(Ctx) -> Result(String, String),
    /// Commits a validated canonical directory for this caller only.
    write: fn(Ctx, String) -> Result(Nil, String),
  )
}

/// A host without persistence still supports explicit per-call directories.
///
/// ## Examples
///
/// ```gleam
/// // working_directory.workspace_only().read(ctx)
/// ```
pub fn workspace_only() -> Door {
  Door(read: fn(ctx) { Ok(ctx.workspace) }, write: fn(_ctx, _path) {
    Error("this host has no directory store")
  })
}

/// Resolves a selection against the strand default without widening authority.
///
/// Absolute selections allow recovery when the previous directory is gone.
/// Native tools continue to resolve paths against `ctx.workspace`.
///
/// ## Examples
///
/// ```gleam
/// // working_directory.select(door, ctx, Some(".worktrees/review"))
/// ```
pub fn select(
  door: Door,
  ctx: Ctx,
  path: Option(String),
) -> Result(String, String) {
  case path {
    None -> door.read(ctx)
    Some(path) -> select_path(door, ctx, path)
  }
}

fn select_path(door: Door, ctx: Ctx, path: String) -> Result(String, String) {
  use chosen <- result.try(case path {
    "" -> Error("cwd must not be empty")
    path ->
      case string.starts_with(path, "/") {
        True -> Ok(path)
        False -> result.map(door.read(ctx), fn(base) { base <> "/" <> path })
      }
  })
  use canonical <- result.try(
    fs.resolve_for_read(ctx, chosen)
    |> result.map_error(fn(error) { "invalid cwd: " <> string.inspect(error) }),
  )
  use exists <- result.try(
    simplifile.is_directory(canonical)
    |> result.map_error(fn(_) { "cwd could not be inspected: " <> canonical }),
  )
  case exists {
    True -> Ok(canonical)
    False -> Error("cwd is not an existing directory: " <> canonical)
  }
}

/// Reads or sets the calling strand's persistent shell directory.
///
/// ## Examples
///
/// ```gleam
/// // working_directory.tool(door).run(ctx, json.Object([]))
/// ```
pub fn tool(door: Door) -> tool.Tool {
  tool.Tool(
    name: "working_directory",
    description: "Read or set your persistent shell working directory. Omit path to inspect it and the actual TMPDIR for cross-call temporary files; set path to change it for subsequent bash and cap/proc calls. Each strand has its own default, initially the workspace. bash.cwd and proc.in_dir override one command. Native file, search and LSP paths remain workspace-relative. Selecting a directory grants no additional access. Use an absolute path to recover from a deleted directory.",
    prompt_snippet: Some(
      "`working_directory` reads or sets your strand's shell directory and reports the actual cross-call TMPDIR; `bash.cwd` overrides one call. File and LSP paths remain workspace-relative.",
    ),
    schema: tool.object_schema(
      [
        #(
          "path",
          tool.string_property(
            "directory to remember; omission reads the current directory",
          ),
        ),
        #("permissions", permissions.schema()),
      ],
      [],
    ),
    replay: tool.Never,
    execution_mode: tool.Exclusive,
    requirements: tool.read_requirements,
    run: fn(ctx, args) { run(door, ctx, args) },
  )
}

fn run(door: Door, ctx: Ctx, args: json.JsonValue) -> tool.ToolOutcome {
  use path <- tool.with_arg(tool.optional_string(args, "path"))
  use ctx <- tool.or_outcome(permissions.authorize(ctx, args), fn(outcome) {
    outcome
  })
  use cwd <- tool.with_arg(select(door, ctx, path))
  use Nil <- tool.with_arg(case path {
    None -> Ok(Nil)
    Some(_) -> door.write(ctx, cwd)
  })
  let tmp = list.key_find(ctx.env, "TMPDIR") |> result.unwrap("")
  tool.success(
    "shell cwd: "
    <> cwd
    <> "\nworkspace: "
    <> ctx.workspace
    <> "\nTMPDIR: "
    <> tmp,
  )
  |> tool.with_details(
    json.Object([
      #("cwd", json.String(cwd)),
      #("workspace", json.String(ctx.workspace)),
      #("tmpdir", json.String(tmp)),
    ]),
  )
}
