//// Completion responses connect each operation to its original typed result.
////
//// Every success/error field remains present, including stale edit content,
//// Git refusal detail, guidance completeness and initialization status. Fresh
//// write anchors are either complete under fs's rendering cap or explicitly
//// require a windowed read. The enclosing decoder checks response_matches
//// against the retained Request before releasing any of these projections.

import core/msgpack
import gleam/int
import gleam/result
import gleam/string
import tools/fs
import tools/hashline
import tools/workspace
import tools/workspace_codec/edit
import tools/workspace_codec/failures
import tools/workspace_codec/git
import tools/workspace_codec/read
import tools/workspace_codec/search
import tools/workspace_codec/value as v

/// Converts the closed workspace.FreshAnchors shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn anchors_value(value: workspace.FreshAnchors) -> msgpack.MsgPackValue {
  case value {
    workspace.Included(lines) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        fn(xs) { v.array(xs, edit.anchored_line_value) }(lines),
      ])
    workspace.RequiresWindowedRead -> msgpack.ArrayValue([msgpack.IntValue(1)])
  }
}

/// Converts the closed workspace.FreshAnchors shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_anchors(
  value: msgpack.MsgPackValue,
) -> Result(workspace.FreshAnchors, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), lines]) -> {
      use lines <- result.try(fn(x) {
        v.inventory(x, 8192, edit.parse_anchored_line)
      }(lines))
      use Nil <- result.try(v.unique_keys(lines, fn(line) { line.line }))
      use Nil <- result.try(
        v.check(fn() {
          string.byte_size(hashline.render_lines(lines))
          <= fs.max_fresh_anchor_bytes
        }),
      )
      Ok(workspace.Included(lines))
    }
    msgpack.ArrayValue([msgpack.IntValue(1)]) -> {
      Ok(workspace.RequiresWindowedRead)
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed workspace.WriteResult shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn written_value(value: workspace.WriteResult) -> msgpack.MsgPackValue {
  case value {
    workspace.Written(bytes, digest, anchors) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        msgpack.IntValue(bytes),
        msgpack.StringValue(digest),
        anchors_value(anchors),
      ])
  }
}

/// Converts the closed workspace.WriteResult shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_written(
  value: msgpack.MsgPackValue,
) -> Result(workspace.WriteResult, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), bytes, digest, anchors]) -> {
      use bytes <- result.try(fn(x) { v.range(x, 0, 8_388_608) }(bytes))
      use digest <- result.try(v.digest(digest))
      use anchors <- result.try(parse_anchors(anchors))
      use Nil <- result.try(
        v.check(fn() { string.ends_with(digest, "-" <> int.to_string(bytes)) }),
      )
      Ok(workspace.Written(bytes, digest, anchors))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed workspace.GuidanceFile shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn guidance_file_value(
  value: workspace.GuidanceFile,
) -> msgpack.MsgPackValue {
  case value {
    workspace.GuidanceFile(path, content) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        v.path_value(path),
        msgpack.StringValue(content),
      ])
  }
}

/// Converts the closed workspace.GuidanceFile shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_guidance_file(
  value: msgpack.MsgPackValue,
) -> Result(workspace.GuidanceFile, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), path, content]) -> {
      use path <- result.try(v.path(path))
      use content <- result.try(v.content(content))
      Ok(workspace.GuidanceFile(path, content))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed workspace.GuidanceResult shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn guidance_value(value: workspace.GuidanceResult) -> msgpack.MsgPackValue {
  case value {
    workspace.GuidanceLoaded(files, completeness) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        fn(xs) { v.array(xs, guidance_file_value) }(files),
        search.completeness_value(completeness),
      ])
  }
}

/// Converts the closed workspace.GuidanceResult shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_guidance(
  value: msgpack.MsgPackValue,
) -> Result(workspace.GuidanceResult, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), files, completeness]) -> {
      use files <- result.try(fn(x) {
        v.inventory(x, 8192, parse_guidance_file)
      }(files))
      use completeness <- result.try(search.parse_completeness(completeness))
      use Nil <- result.try(v.unique_keys(files, fn(file) { file.path }))
      Ok(workspace.GuidanceLoaded(files, completeness))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed workspace.Initialization shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn initialization_value(
  value: workspace.Initialization,
) -> msgpack.MsgPackValue {
  case value {
    workspace.Initialized -> msgpack.ArrayValue([msgpack.IntValue(0)])
    workspace.AlreadyInitialized -> msgpack.ArrayValue([msgpack.IntValue(1)])
  }
}

/// Converts the closed workspace.Initialization shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_initialization(
  value: msgpack.MsgPackValue,
) -> Result(workspace.Initialization, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0)]) -> {
      Ok(workspace.Initialized)
    }
    msgpack.ArrayValue([msgpack.IntValue(1)]) -> {
      Ok(workspace.AlreadyInitialized)
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed workspace.ServiceError shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn service_error_value(
  value: workspace.ServiceError,
) -> msgpack.MsgPackValue {
  case value {
    workspace.Unavailable -> msgpack.ArrayValue([msgpack.IntValue(0)])
    workspace.StaleScope -> msgpack.ArrayValue([msgpack.IntValue(1)])
    workspace.PermissionRefused -> msgpack.ArrayValue([msgpack.IntValue(2)])
    workspace.PathRefused(error) ->
      msgpack.ArrayValue([msgpack.IntValue(3), failures.path_error_value(error)])
    workspace.InvalidRequest -> msgpack.ArrayValue([msgpack.IntValue(4)])
    workspace.CapacityRefused -> msgpack.ArrayValue([msgpack.IntValue(5)])
    workspace.IdentityConflict -> msgpack.ArrayValue([msgpack.IntValue(6)])
    workspace.OutcomeUnknown -> msgpack.ArrayValue([msgpack.IntValue(7)])
  }
}

/// Converts the closed workspace.ServiceError shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_service_error(
  value: msgpack.MsgPackValue,
) -> Result(workspace.ServiceError, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0)]) -> {
      Ok(workspace.Unavailable)
    }
    msgpack.ArrayValue([msgpack.IntValue(1)]) -> {
      Ok(workspace.StaleScope)
    }
    msgpack.ArrayValue([msgpack.IntValue(2)]) -> {
      Ok(workspace.PermissionRefused)
    }
    msgpack.ArrayValue([msgpack.IntValue(3), error]) -> {
      use error <- result.try(failures.parse_path_error(error))
      Ok(workspace.PathRefused(error))
    }
    msgpack.ArrayValue([msgpack.IntValue(4)]) -> {
      Ok(workspace.InvalidRequest)
    }
    msgpack.ArrayValue([msgpack.IntValue(5)]) -> {
      Ok(workspace.CapacityRefused)
    }
    msgpack.ArrayValue([msgpack.IntValue(6)]) -> {
      Ok(workspace.IdentityConflict)
    }
    msgpack.ArrayValue([msgpack.IntValue(7)]) -> {
      Ok(workspace.OutcomeUnknown)
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed workspace.Response shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn response_value(value: workspace.Response) -> msgpack.MsgPackValue {
  case value {
    workspace.ReadCompleted(result) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        fn(x) {
          v.result_value(x, read.read_result_value, read.read_failure_value)
        }(result),
      ])
    workspace.WriteCompleted(result) ->
      msgpack.ArrayValue([
        msgpack.IntValue(1),
        fn(x) { v.result_value(x, written_value, failures.fs_error_value) }(
          result,
        ),
      ])
    workspace.EditCompleted(result) ->
      msgpack.ArrayValue([
        msgpack.IntValue(2),
        fn(x) {
          v.result_value(x, edit.landed_value, failures.land_error_value)
        }(result),
      ])
    workspace.ListingCompleted(result) ->
      msgpack.ArrayValue([
        msgpack.IntValue(3),
        fn(x) {
          v.result_value(x, search.listing_value, failures.search_error_value)
        }(result),
      ])
    workspace.SearchCompleted(result) ->
      msgpack.ArrayValue([
        msgpack.IntValue(4),
        fn(x) {
          v.result_value(x, search.found_value, failures.search_error_value)
        }(result),
      ])
    workspace.StatCompleted(result) ->
      msgpack.ArrayValue([
        msgpack.IntValue(5),
        fn(x) {
          v.result_value(x, search.entry_value, failures.search_error_value)
        }(result),
      ])
    workspace.GitCompleted(result) ->
      msgpack.ArrayValue([
        msgpack.IntValue(6),
        fn(x) { v.result_value(x, git.git_result_value, git.git_error_value) }(
          result,
        ),
      ])
    workspace.GuidanceCompleted(result) ->
      msgpack.ArrayValue([
        msgpack.IntValue(7),
        fn(x) { v.result_value(x, guidance_value, failures.fs_error_value) }(
          result,
        ),
      ])
    workspace.InitializationCompleted(result) ->
      msgpack.ArrayValue([
        msgpack.IntValue(8),
        fn(x) {
          v.result_value(x, initialization_value, failures.fs_error_value)
        }(result),
      ])
  }
}

/// Converts the closed workspace.Response shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_response(
  value: msgpack.MsgPackValue,
) -> Result(workspace.Response, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), result]) -> {
      use result <- result.try(fn(x) {
        v.result_field(x, read.parse_read_result, read.parse_read_failure)
      }(result))
      Ok(workspace.ReadCompleted(result))
    }
    msgpack.ArrayValue([msgpack.IntValue(1), result]) -> {
      use result <- result.try(fn(x) {
        v.result_field(x, parse_written, failures.parse_fs_error)
      }(result))
      Ok(workspace.WriteCompleted(result))
    }
    msgpack.ArrayValue([msgpack.IntValue(2), result]) -> {
      use result <- result.try(fn(x) {
        v.result_field(x, edit.parse_landed, failures.parse_land_error)
      }(result))
      Ok(workspace.EditCompleted(result))
    }
    msgpack.ArrayValue([msgpack.IntValue(3), result]) -> {
      use result <- result.try(fn(x) {
        v.result_field(x, search.parse_listing, failures.parse_search_error)
      }(result))
      Ok(workspace.ListingCompleted(result))
    }
    msgpack.ArrayValue([msgpack.IntValue(4), result]) -> {
      use result <- result.try(fn(x) {
        v.result_field(x, search.parse_found, failures.parse_search_error)
      }(result))
      Ok(workspace.SearchCompleted(result))
    }
    msgpack.ArrayValue([msgpack.IntValue(5), result]) -> {
      use result <- result.try(fn(x) {
        v.result_field(x, search.parse_entry, failures.parse_search_error)
      }(result))
      Ok(workspace.StatCompleted(result))
    }
    msgpack.ArrayValue([msgpack.IntValue(6), result]) -> {
      use result <- result.try(fn(x) {
        v.result_field(x, git.parse_git_result, git.parse_git_error)
      }(result))
      Ok(workspace.GitCompleted(result))
    }
    msgpack.ArrayValue([msgpack.IntValue(7), result]) -> {
      use result <- result.try(fn(x) {
        v.result_field(x, parse_guidance, failures.parse_fs_error)
      }(result))
      Ok(workspace.GuidanceCompleted(result))
    }
    msgpack.ArrayValue([msgpack.IntValue(8), result]) -> {
      use result <- result.try(fn(x) {
        v.result_field(x, parse_initialization, failures.parse_fs_error)
      }(result))
      Ok(workspace.InitializationCompleted(result))
    }
    _ -> Error(Nil)
  }
}
