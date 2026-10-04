//// Filesystem and search failures remain distinct completion evidence.
////
//// Physical error paths are bounded observations, never RelativePath authority.
//// Edit refusal retains unreadability, rejection with current text or failure
//// to write as three separate states. Fixed codec errors never copy these
//// rejected peer values into another diagnostic.

import core/msgpack
import gleam/result
import tools/fs
import tools/search
import tools/tool
import tools/workspace_codec/edit
import tools/workspace_codec/value as v

/// Converts the closed tool.FsError shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn fs_error_value(value: tool.FsError) -> msgpack.MsgPackValue {
  case value {
    tool.FsNotFound(path) ->
      msgpack.ArrayValue([msgpack.IntValue(0), msgpack.StringValue(path)])
    tool.FsPermissionDenied(path) ->
      msgpack.ArrayValue([msgpack.IntValue(1), msgpack.StringValue(path)])
    tool.FsFailure(path, reason) ->
      msgpack.ArrayValue([
        msgpack.IntValue(2),
        msgpack.StringValue(path),
        msgpack.StringValue(reason),
      ])
  }
}

/// Converts the closed tool.FsError shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_fs_error(
  value: msgpack.MsgPackValue,
) -> Result(tool.FsError, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), path]) -> {
      use path <- result.try(v.text(path))
      Ok(tool.FsNotFound(path))
    }
    msgpack.ArrayValue([msgpack.IntValue(1), path]) -> {
      use path <- result.try(v.text(path))
      Ok(tool.FsPermissionDenied(path))
    }
    msgpack.ArrayValue([msgpack.IntValue(2), path, reason]) -> {
      use path <- result.try(v.text(path))
      use reason <- result.try(v.diagnostic(reason))
      Ok(tool.FsFailure(path, reason))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed fs.PathError shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn path_error_value(value: fs.PathError) -> msgpack.MsgPackValue {
  case value {
    fs.EmptyPath -> msgpack.ArrayValue([msgpack.IntValue(0)])
    fs.EscapesWorkspace(path) ->
      msgpack.ArrayValue([msgpack.IntValue(1), msgpack.StringValue(path)])
    fs.Unresolvable(path, reason) ->
      msgpack.ArrayValue([
        msgpack.IntValue(2),
        msgpack.StringValue(path),
        msgpack.StringValue(reason),
      ])
    fs.ProtectedPath(path, protected) ->
      msgpack.ArrayValue([
        msgpack.IntValue(3),
        msgpack.StringValue(path),
        msgpack.StringValue(protected),
      ])
    fs.ProtectionMisconfigured(path, protected) ->
      msgpack.ArrayValue([
        msgpack.IntValue(4),
        msgpack.StringValue(path),
        msgpack.StringValue(protected),
      ])
  }
}

/// Converts the closed fs.PathError shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_path_error(
  value: msgpack.MsgPackValue,
) -> Result(fs.PathError, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0)]) -> {
      Ok(fs.EmptyPath)
    }
    msgpack.ArrayValue([msgpack.IntValue(1), path]) -> {
      use path <- result.try(v.text(path))
      Ok(fs.EscapesWorkspace(path))
    }
    msgpack.ArrayValue([msgpack.IntValue(2), path, reason]) -> {
      use path <- result.try(v.text(path))
      use reason <- result.try(v.diagnostic(reason))
      Ok(fs.Unresolvable(path, reason))
    }
    msgpack.ArrayValue([msgpack.IntValue(3), path, protected]) -> {
      use path <- result.try(v.text(path))
      use protected <- result.try(v.text(protected))
      Ok(fs.ProtectedPath(path, protected))
    }
    msgpack.ArrayValue([msgpack.IntValue(4), path, protected]) -> {
      use path <- result.try(v.text(path))
      use protected <- result.try(v.text(protected))
      Ok(fs.ProtectionMisconfigured(path, protected))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed fs.ReadError shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn read_error_value(value: fs.ReadError) -> msgpack.MsgPackValue {
  case value {
    fs.ReadFailed(error) ->
      msgpack.ArrayValue([msgpack.IntValue(0), fs_error_value(error)])
    fs.TooLarge(size, limit) ->
      msgpack.ArrayValue([
        msgpack.IntValue(1),
        msgpack.IntValue(size),
        msgpack.IntValue(limit),
      ])
    fs.NotText -> msgpack.ArrayValue([msgpack.IntValue(2)])
  }
}

/// Converts the closed fs.ReadError shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_read_error(
  value: msgpack.MsgPackValue,
) -> Result(fs.ReadError, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), error]) -> {
      use error <- result.try(parse_fs_error(error))
      Ok(fs.ReadFailed(error))
    }
    msgpack.ArrayValue([msgpack.IntValue(1), size, limit]) -> {
      use size <- result.try(v.natural(size))
      use limit <- result.try(v.natural(limit))
      Ok(fs.TooLarge(size, limit))
    }
    msgpack.ArrayValue([msgpack.IntValue(2)]) -> {
      Ok(fs.NotText)
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed search.SearchError shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn search_error_value(value: search.SearchError) -> msgpack.MsgPackValue {
  case value {
    search.InvalidQuery(message) ->
      msgpack.ArrayValue([msgpack.IntValue(0), msgpack.StringValue(message)])
    search.NotADirectory(path) ->
      msgpack.ArrayValue([msgpack.IntValue(1), msgpack.StringValue(path)])
    search.NotAFile(path) ->
      msgpack.ArrayValue([msgpack.IntValue(2), msgpack.StringValue(path)])
    search.TooLarge(path, size) ->
      msgpack.ArrayValue([
        msgpack.IntValue(3),
        msgpack.StringValue(path),
        msgpack.IntValue(size),
      ])
    search.NotText(path) ->
      msgpack.ArrayValue([msgpack.IntValue(4), msgpack.StringValue(path)])
    search.Missing(path) ->
      msgpack.ArrayValue([msgpack.IntValue(5), msgpack.StringValue(path)])
    search.Backend(error) ->
      msgpack.ArrayValue([msgpack.IntValue(6), fs_error_value(error)])
  }
}

/// Converts the closed search.SearchError shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_search_error(
  value: msgpack.MsgPackValue,
) -> Result(search.SearchError, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), message]) -> {
      use message <- result.try(v.diagnostic(message))
      Ok(search.InvalidQuery(message))
    }
    msgpack.ArrayValue([msgpack.IntValue(1), path]) -> {
      use path <- result.try(v.text(path))
      Ok(search.NotADirectory(path))
    }
    msgpack.ArrayValue([msgpack.IntValue(2), path]) -> {
      use path <- result.try(v.text(path))
      Ok(search.NotAFile(path))
    }
    msgpack.ArrayValue([msgpack.IntValue(3), path, size]) -> {
      use path <- result.try(v.text(path))
      use size <- result.try(v.natural(size))
      Ok(search.TooLarge(path, size))
    }
    msgpack.ArrayValue([msgpack.IntValue(4), path]) -> {
      use path <- result.try(v.text(path))
      Ok(search.NotText(path))
    }
    msgpack.ArrayValue([msgpack.IntValue(5), path]) -> {
      use path <- result.try(v.text(path))
      Ok(search.Missing(path))
    }
    msgpack.ArrayValue([msgpack.IntValue(6), error]) -> {
      use error <- result.try(parse_fs_error(error))
      Ok(search.Backend(error))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed fs.LandError shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn land_error_value(value: fs.LandError) -> msgpack.MsgPackValue {
  case value {
    fs.LandUnreadable(error) ->
      msgpack.ArrayValue([msgpack.IntValue(0), read_error_value(error)])
    fs.LandRejected(error, current) ->
      msgpack.ArrayValue([
        msgpack.IntValue(1),
        edit.apply_error_value(error),
        msgpack.StringValue(current),
      ])
    fs.LandUnwritten(error) ->
      msgpack.ArrayValue([msgpack.IntValue(2), fs_error_value(error)])
  }
}

/// Converts the closed fs.LandError shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_land_error(
  value: msgpack.MsgPackValue,
) -> Result(fs.LandError, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), error]) -> {
      use error <- result.try(parse_read_error(error))
      Ok(fs.LandUnreadable(error))
    }
    msgpack.ArrayValue([msgpack.IntValue(1), error, current]) -> {
      use error <- result.try(edit.parse_apply_error(error))
      use current <- result.try(v.content(current))
      Ok(fs.LandRejected(error, current))
    }
    msgpack.ArrayValue([msgpack.IntValue(2), error]) -> {
      use error <- result.try(parse_fs_error(error))
      Ok(fs.LandUnwritten(error))
    }
    _ -> Error(Nil)
  }
}
