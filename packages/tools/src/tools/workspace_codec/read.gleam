//// Read projections preserve the requested text, anchors, binary or line window.
////
//// Image media must agree with the existing byte-signature detector. Native
//// windows retain offset, full line count, remaining-lines and trailing-newline
//// flags. File-read and line-reader refusals remain separate error contracts.

import core/msgpack
import gleam/option.{Some}
import gleam/result
import tools/fs
import tools/workspace
import tools/workspace_codec/edit
import tools/workspace_codec/failures
import tools/workspace_codec/search
import tools/workspace_codec/value as v

/// Converts the closed workspace.ReadView shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn view_value(value: workspace.ReadView) -> msgpack.MsgPackValue {
  case value {
    workspace.Text -> msgpack.ArrayValue([msgpack.IntValue(0)])
    workspace.Native(offset, limit) ->
      msgpack.ArrayValue([
        msgpack.IntValue(1),
        msgpack.IntValue(offset),
        msgpack.IntValue(limit),
      ])
    workspace.Lines(first, last) ->
      msgpack.ArrayValue([
        msgpack.IntValue(2),
        msgpack.IntValue(first),
        msgpack.IntValue(last),
      ])
  }
}

/// Converts the closed workspace.ReadView shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_view(
  value: msgpack.MsgPackValue,
) -> Result(workspace.ReadView, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0)]) -> {
      Ok(workspace.Text)
    }
    msgpack.ArrayValue([msgpack.IntValue(1), offset, limit]) -> {
      use offset <- result.try(v.positive(offset))
      use limit <- result.try(v.positive(limit))
      Ok(workspace.Native(offset, limit))
    }
    msgpack.ArrayValue([msgpack.IntValue(2), first, last]) -> {
      use first <- result.try(v.positive(first))
      use last <- result.try(v.positive(last))
      Ok(workspace.Lines(first, last))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed workspace.ImageMedia shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn media_value(value: workspace.ImageMedia) -> msgpack.MsgPackValue {
  case value {
    workspace.Png -> msgpack.ArrayValue([msgpack.IntValue(0)])
    workspace.Jpeg -> msgpack.ArrayValue([msgpack.IntValue(1)])
    workspace.Gif -> msgpack.ArrayValue([msgpack.IntValue(2)])
    workspace.Webp -> msgpack.ArrayValue([msgpack.IntValue(3)])
  }
}

/// Converts the closed workspace.ImageMedia shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_media(
  value: msgpack.MsgPackValue,
) -> Result(workspace.ImageMedia, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0)]) -> {
      Ok(workspace.Png)
    }
    msgpack.ArrayValue([msgpack.IntValue(1)]) -> {
      Ok(workspace.Jpeg)
    }
    msgpack.ArrayValue([msgpack.IntValue(2)]) -> {
      Ok(workspace.Gif)
    }
    msgpack.ArrayValue([msgpack.IntValue(3)]) -> {
      Ok(workspace.Webp)
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed workspace.ReadResult shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn read_result_value(value: workspace.ReadResult) -> msgpack.MsgPackValue {
  case value {
    workspace.TextRead(content) ->
      msgpack.ArrayValue([msgpack.IntValue(0), msgpack.StringValue(content)])
    workspace.AnchoredRead(digest, window) ->
      msgpack.ArrayValue([
        msgpack.IntValue(1),
        msgpack.StringValue(digest),
        edit.window_value(window),
      ])
    workspace.ImageRead(bytes, media) ->
      msgpack.ArrayValue([
        msgpack.IntValue(2),
        msgpack.BinaryValue(bytes),
        media_value(media),
      ])
    workspace.LinesRead(lines) ->
      msgpack.ArrayValue([msgpack.IntValue(3), search.lines_value(lines)])
  }
}

/// Converts the closed workspace.ReadResult shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_read_result(
  value: msgpack.MsgPackValue,
) -> Result(workspace.ReadResult, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), content]) -> {
      use content <- result.try(v.content(content))
      Ok(workspace.TextRead(content))
    }
    msgpack.ArrayValue([msgpack.IntValue(1), digest, window]) -> {
      use digest <- result.try(v.digest(digest))
      use window <- result.try(edit.parse_window(window))
      Ok(workspace.AnchoredRead(digest, window))
    }
    msgpack.ArrayValue([msgpack.IntValue(2), bytes, media]) -> {
      use bytes <- result.try(v.image(bytes))
      use media <- result.try(parse_media(media))
      let expected = case media {
        workspace.Png -> "image/png"
        workspace.Jpeg -> "image/jpeg"
        workspace.Gif -> "image/gif"
        workspace.Webp -> "image/webp"
      }
      use Nil <- result.try(
        v.check(fn() { fs.image_media_type(bytes) == Some(expected) }),
      )
      Ok(workspace.ImageRead(bytes, media))
    }
    msgpack.ArrayValue([msgpack.IntValue(3), lines]) -> {
      use lines <- result.try(search.parse_lines(lines))
      Ok(workspace.LinesRead(lines))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed workspace.ReadFailure shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn read_failure_value(
  value: workspace.ReadFailure,
) -> msgpack.MsgPackValue {
  case value {
    workspace.FileReadFailed(error) ->
      msgpack.ArrayValue([msgpack.IntValue(0), failures.read_error_value(error)])
    workspace.LinesReadFailed(error) ->
      msgpack.ArrayValue([
        msgpack.IntValue(1),
        failures.search_error_value(error),
      ])
    workspace.InvalidWindow -> msgpack.ArrayValue([msgpack.IntValue(2)])
  }
}

/// Converts the closed workspace.ReadFailure shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_read_failure(
  value: msgpack.MsgPackValue,
) -> Result(workspace.ReadFailure, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), error]) -> {
      use error <- result.try(failures.parse_read_error(error))
      Ok(workspace.FileReadFailed(error))
    }
    msgpack.ArrayValue([msgpack.IntValue(1), error]) -> {
      use error <- result.try(failures.parse_search_error(error))
      Ok(workspace.LinesReadFailed(error))
    }
    msgpack.ArrayValue([msgpack.IntValue(2)]) -> {
      Ok(workspace.InvalidWindow)
    }
    _ -> Error(Nil)
  }
}
