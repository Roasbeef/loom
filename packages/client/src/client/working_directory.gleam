//// Per-strand shell defaults live in reserved facts rather than process cwd.
////
//// A restart reads the same canonical spelling. Each use revalidates it;
//// symlink replacement cannot redirect a remembered directory. The module
//// reaches the session's store only through `owner_services.FactAccess`,
//// which serves this module's own prefix and nothing else, and updates
//// compare the cell sequence so a stale setter cannot overwrite a concurrent
//// decision.

import broker/policy
import client/codemode
import client/owner_services.{type FactAccess, type FactFault}
import codemode/satellite
import core/json
import core/msgpack as m
import gleam/bool
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import runtime/api
import simplifile
import tools/codemode as code_tool
import tools/directory_access
import tools/fs
import tools/working_directory as directory

type ProcessScope {
  ProcessScope(
    workspace: String,
    access: directory_access.Access,
    grants: List(policy.Grant),
  )
}

/// Builds the native tool store, binding the strand from each tool context.
///
/// ## Examples
///
/// ```gleam
/// // working_directory.door(facts)
/// ```
pub fn door(facts: FactAccess) -> directory.Door {
  directory.Door(
    read: fn(ctx) {
      use path <- result.try(read(facts, ctx.strand, ctx.workspace))
      use canonical <- result.try(directory.select(
        directory.workspace_only(),
        ctx,
        Some(path),
      ))
      case canonical == path {
        True -> Ok(path)
        False ->
          Error(
            "remembered cwd changed its canonical target; set an absolute path",
          )
      }
    },
    write: fn(ctx, path) { write(facts, ctx.strand, path) },
  )
}

fn key(strand: String) -> String {
  owner_services.working_directory_prefix <> strand
}

// An absent store is told apart from a failed read because the first means
// the session is starting up or going away, and the second that a cell exists
// which could not be read.
fn read_failed(fault: FactFault) -> String {
  case fault {
    owner_services.StoreAbsent -> "working directory store is unavailable"

    owner_services.Conflict
    | owner_services.LeaseStolen(..)
    | owner_services.Failed(..)
    | owner_services.NotServed(..) -> "working directory could not be read"
  }
}

fn read(
  facts: FactAccess,
  strand: String,
  workspace: String,
) -> Result(String, String) {
  use cell <- result.try(
    facts.cell(key(strand)) |> result.map_error(read_failed),
  )
  case cell {
    None ->
      fs.resolve_readable(fs.real_filesystem(), workspace, [], workspace)
      |> result.map_error(fn(_) { "workspace directory could not be resolved" })
    Some(api.FactCell(json.String(path), _seq)) ->
      case string.starts_with(path, "/") {
        True -> Ok(path)
        False -> Error("remembered cwd is not absolute; set an absolute path")
      }
    Some(_) ->
      Error("remembered working directory is malformed; set an absolute path")
  }
}

fn write(
  facts: FactAccess,
  strand: String,
  path: String,
) -> Result(Nil, String) {
  let key = key(strand)
  use cell <- result.try(facts.cell(key) |> result.map_error(read_failed))
  let expected = option.map(cell, fn(cell) { cell.seq })
  facts.put(key, json.String(path), expected)
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(_) {
    "working directory changed concurrently or could not be saved; inspect it again"
  })
}

/// Applies the same default to process capabilities without moving file paths.
///
/// The default is captured once per program. Each explicit `proc.in_dir` is
/// resolved against it, then checked under the invocation's existing roots.
///
/// ## Examples
///
/// ```gleam
/// // working_directory.over_code_mode(config, facts)
/// ```
pub fn over_code_mode(
  config: codemode.Config,
  facts: FactAccess,
) -> codemode.Config {
  let wrap = config.wrap_router
  codemode.Config(..config, wrap_router: fn(request: code_tool.Request, router) {
    let default = read(facts, request.strand, request.workspace)
    let scope =
      ProcessScope(request.workspace, request.directory_access, request.grants)
    let inner = wrap(request, router)
    fn(call: satellite.CapRequest) {
      case call.cap {
        "proc.run" -> {
          use cwd <- result.try(process_directory(scope, default, call.args))
          let args = case call.args {
            m.MapValue(fields) ->
              m.MapValue(
                list.map(fields, fn(pair) {
                  case pair.0 {
                    m.StringValue("cwd") -> #(pair.0, m.NilValue)
                    _ -> pair
                  }
                }),
              )
            _ -> call.args
          }
          inner(satellite.CapRequest(..call, cwd:, args:))
        }
        _ -> inner(call)
      }
    }
  })
}

fn process_directory(
  scope: ProcessScope,
  default: Result(String, String),
  args: m.MsgPackValue,
) -> Result(String, satellite.CapDenial) {
  let selected = case args {
    m.MapValue(fields) ->
      list.key_find(fields, m.StringValue("cwd")) |> result.unwrap(m.NilValue)
    _ -> m.NilValue
  }
  let answer = case selected {
    m.NilValue -> remembered_directory(scope, default)
    m.StringValue("") -> Error("proc.run cwd must not be empty")
    m.StringValue(path) ->
      case string.starts_with(path, "/") {
        True -> checked_directory(scope, path)
        False -> {
          // The saved base is validated before a relative override can follow it.
          use base <- result.try(remembered_directory(scope, default))
          checked_directory(scope, base <> "/" <> path)
        }
      }
    _ -> Error("proc.run cwd must be a directory string")
  }
  answer
  |> result.map_error(fn(message) {
    satellite.CapDenial("invalid_cwd", message)
  })
}

fn remembered_directory(
  scope: ProcessScope,
  default: Result(String, String),
) -> Result(String, String) {
  use path <- result.try(default)
  use canonical <- result.try(checked_directory(scope, path))
  use <- bool.guard(
    canonical != path,
    Error("remembered cwd changed its canonical target"),
  )
  Ok(canonical)
}

fn checked_directory(
  scope: ProcessScope,
  path: String,
) -> Result(String, String) {
  let access = directory_access.approved(scope.access, scope.grants)
  use canonical <- result.try(
    fs.resolve_readable(
      fs.real_filesystem(),
      scope.workspace,
      access.readable,
      path,
    )
    |> result.map_error(fn(error) { "invalid cwd: " <> string.inspect(error) }),
  )
  use exists <- result.try(
    simplifile.is_directory(canonical)
    |> result.map_error(fn(_) { "cwd could not be inspected" }),
  )
  use <- bool.lazy_guard(!exists, fn() {
    Error("cwd is not an existing directory: " <> canonical)
  })
  Ok(canonical)
}
