//// Invocation payloads have a closed workspace operation vocabulary.
////
//// Paths pass core/workspace's total grammar constructor before they become
//// request authority. Origin retains the source index/digest or a named system
//// caller. validated_view enforces line spans; validated_plan checks aggregate
//// edit material and ranges before this payload can enter the service.

import core/msgpack
import gleam/list
import gleam/result
import gleam/string
import tools/hashline
import tools/workspace
import tools/workspace_codec/edit
import tools/workspace_codec/git
import tools/workspace_codec/read
import tools/workspace_codec/search
import tools/workspace_codec/value as v

/// Converts the closed workspace.SystemCaller shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn system_value(value: workspace.SystemCaller) -> msgpack.MsgPackValue {
  case value {
    workspace.CommandPreparation -> msgpack.ArrayValue([msgpack.IntValue(0)])
    workspace.Compiler -> msgpack.ArrayValue([msgpack.IntValue(1)])
    workspace.SatelliteLaunch -> msgpack.ArrayValue([msgpack.IntValue(2)])
    workspace.LanguageServer -> msgpack.ArrayValue([msgpack.IntValue(3)])
    workspace.WorktreeObservation -> msgpack.ArrayValue([msgpack.IntValue(4)])
    workspace.WorkspaceAdministration ->
      msgpack.ArrayValue([msgpack.IntValue(5)])
  }
}

/// Converts the closed workspace.SystemCaller shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_system(
  value: msgpack.MsgPackValue,
) -> Result(workspace.SystemCaller, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0)]) -> {
      Ok(workspace.CommandPreparation)
    }
    msgpack.ArrayValue([msgpack.IntValue(1)]) -> {
      Ok(workspace.Compiler)
    }
    msgpack.ArrayValue([msgpack.IntValue(2)]) -> {
      Ok(workspace.SatelliteLaunch)
    }
    msgpack.ArrayValue([msgpack.IntValue(3)]) -> {
      Ok(workspace.LanguageServer)
    }
    msgpack.ArrayValue([msgpack.IntValue(4)]) -> {
      Ok(workspace.WorktreeObservation)
    }
    msgpack.ArrayValue([msgpack.IntValue(5)]) -> {
      Ok(workspace.WorkspaceAdministration)
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed workspace.Origin shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn origin_value(value: workspace.Origin) -> msgpack.MsgPackValue {
  case value {
    workspace.Tool(origin) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        v.tool_origin_value(origin),
      ])
    workspace.System(caller) ->
      msgpack.ArrayValue([msgpack.IntValue(1), system_value(caller)])
  }
}

/// Converts the closed workspace.Origin shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_origin(
  value: msgpack.MsgPackValue,
) -> Result(workspace.Origin, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), origin]) -> {
      use origin <- result.try(v.tool_origin(origin))
      Ok(workspace.Tool(origin))
    }
    msgpack.ArrayValue([msgpack.IntValue(1), caller]) -> {
      use caller <- result.try(parse_system(caller))
      Ok(workspace.System(caller))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed workspace.Request shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn request_value(value: workspace.Request) -> msgpack.MsgPackValue {
  case value {
    workspace.Read(path, view) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        v.path_value(path),
        read.view_value(view),
      ])
    workspace.Write(path, content) ->
      msgpack.ArrayValue([
        msgpack.IntValue(1),
        v.path_value(path),
        msgpack.StringValue(content),
      ])
    workspace.AnchoredEdit(path, plan) ->
      msgpack.ArrayValue([
        msgpack.IntValue(2),
        v.path_value(path),
        edit.plan_value(plan),
      ])
    workspace.ListEntries(root, query) ->
      msgpack.ArrayValue([
        msgpack.IntValue(3),
        v.path_value(root),
        search.glob_value(query),
      ])
    workspace.Search(root, query) ->
      msgpack.ArrayValue([
        msgpack.IntValue(4),
        v.path_value(root),
        search.grep_value(query),
      ])
    workspace.Stat(path) ->
      msgpack.ArrayValue([msgpack.IntValue(5), v.path_value(path)])
    workspace.Git(query) ->
      msgpack.ArrayValue([msgpack.IntValue(6), git.query_value(query)])
    workspace.Guidance -> msgpack.ArrayValue([msgpack.IntValue(7)])
    workspace.Initialize -> msgpack.ArrayValue([msgpack.IntValue(8)])
  }
}

/// Converts the closed workspace.Request shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_request(
  value: msgpack.MsgPackValue,
) -> Result(workspace.Request, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), path, view]) -> {
      use path <- result.try(v.path(path))
      use view <- result.try(validated_view(view))
      Ok(workspace.Read(path, view))
    }
    msgpack.ArrayValue([msgpack.IntValue(1), path, content]) -> {
      use path <- result.try(v.path(path))
      use content <- result.try(v.content(content))
      Ok(workspace.Write(path, content))
    }
    msgpack.ArrayValue([msgpack.IntValue(2), path, plan]) -> {
      use path <- result.try(v.path(path))
      use plan <- result.try(validated_plan(plan))
      Ok(workspace.AnchoredEdit(path, plan))
    }
    msgpack.ArrayValue([msgpack.IntValue(3), root, query]) -> {
      use root <- result.try(v.path(root))
      use query <- result.try(search.parse_glob(query))
      Ok(workspace.ListEntries(root, query))
    }
    msgpack.ArrayValue([msgpack.IntValue(4), root, query]) -> {
      use root <- result.try(v.path(root))
      use query <- result.try(search.parse_grep(query))
      Ok(workspace.Search(root, query))
    }
    msgpack.ArrayValue([msgpack.IntValue(5), path]) -> {
      use path <- result.try(v.path(path))
      Ok(workspace.Stat(path))
    }
    msgpack.ArrayValue([msgpack.IntValue(6), query]) -> {
      use query <- result.try(git.parse_query(query))
      Ok(workspace.Git(query))
    }
    msgpack.ArrayValue([msgpack.IntValue(7)]) -> {
      Ok(workspace.Guidance)
    }
    msgpack.ArrayValue([msgpack.IntValue(8)]) -> {
      Ok(workspace.Initialize)
    }
    _ -> Error(Nil)
  }
}

// Read coordinates must satisfy the existing service admission bounds.
fn validated_view(
  value: msgpack.MsgPackValue,
) -> Result(workspace.ReadView, Nil) {
  use view <- result.try(read.parse_view(value))
  use Nil <- result.try(case view {
    workspace.Lines(first, last) ->
      v.check(fn() { last >= first && last - first + 1 <= 2000 })
    workspace.Native(_, _) | workspace.Text -> Ok(Nil)
  })
  Ok(view)
}

// Aggregate replacement material, not only each individual line, has an 8-MiB cap.
fn validated_plan(value: msgpack.MsgPackValue) -> Result(hashline.Plan, Nil) {
  use plan <- result.try(edit.parse_plan(value))
  use Nil <- result.try(
    v.check(fn() {
      list.fold(plan.hunks, string.byte_size(plan.digest), fn(size, hunk) {
        let #(refs, lines) = case hunk {
          hashline.Replace(from, to, lines) -> #([from, to], lines)
          hashline.Delete(from, to) -> #([from, to], [])
          hashline.InsertAfter(at, lines) -> #([at], lines)
          hashline.InsertAtStart(lines) -> #([], lines)
        }
        size
        + list.fold(refs, 0, fn(n, ref) { n + string.byte_size(ref.anchor) + 1 })
        + list.fold(lines, 0, fn(n, line) { n + string.byte_size(line) + 1 })
      })
      <= 8_388_608
    }),
  )
  use Nil <- result.try(
    v.check(fn() {
      list.all(plan.hunks, fn(hunk) {
        case hunk {
          hashline.Replace(from, to, _) | hashline.Delete(from, to) ->
            from.line <= to.line
          hashline.InsertAfter(_, _) | hashline.InsertAtStart(_) -> True
        }
      })
    }),
  )
  Ok(plan)
}
