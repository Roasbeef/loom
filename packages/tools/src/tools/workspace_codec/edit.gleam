//// Hashline plans and edit evidence retain complete preimage/postimage text.
////
//// The reference, hunk and plan decoders admit bounded coordinates and exact
//// anchor/digest spelling; request validates aggregate edit material and ranges.
//// LandRejected retains both the typed rejection and the exact current file.
//// Fresh anchor inventories keep their positions, without re-anchoring text or
//// dropping the stale-reference diagnostics a caller needs to replan.

import core/msgpack
import gleam/list
import gleam/result
import tools/fs
import tools/hashline
import tools/workspace_codec/preflight
import tools/workspace_codec/value as v

/// Converts the closed hashline.Ref shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn reference_value(value: hashline.Ref) -> msgpack.MsgPackValue {
  case value {
    hashline.Ref(line, anchor) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        msgpack.IntValue(line),
        msgpack.StringValue(anchor),
      ])
  }
}

/// Converts the closed hashline.Ref shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_reference(
  value: msgpack.MsgPackValue,
) -> Result(hashline.Ref, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), line, anchor]) -> {
      use line <- result.try(v.positive(line))
      use anchor <- result.try(v.anchor(anchor))
      Ok(hashline.Ref(line, anchor))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed hashline.AnchoredLine shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn anchored_line_value(
  value: hashline.AnchoredLine,
) -> msgpack.MsgPackValue {
  case value {
    hashline.AnchoredLine(line, anchor, text) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        msgpack.IntValue(line),
        msgpack.StringValue(anchor),
        msgpack.StringValue(text),
      ])
  }
}

/// Converts the closed hashline.AnchoredLine shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_anchored_line(
  value: msgpack.MsgPackValue,
) -> Result(hashline.AnchoredLine, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), line, anchor, text]) -> {
      use line <- result.try(v.positive(line))
      use anchor <- result.try(v.anchor(anchor))
      use text <- result.try(v.line_text(text))
      Ok(hashline.AnchoredLine(line, anchor, text))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed hashline.Hunk shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn hunk_value(value: hashline.Hunk) -> msgpack.MsgPackValue {
  case value {
    hashline.Replace(from, to, lines) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        reference_value(from),
        reference_value(to),
        fn(xs) { v.array(xs, msgpack.StringValue) }(lines),
      ])
    hashline.Delete(from, to) ->
      msgpack.ArrayValue([
        msgpack.IntValue(1),
        reference_value(from),
        reference_value(to),
      ])
    hashline.InsertAfter(at, lines) ->
      msgpack.ArrayValue([
        msgpack.IntValue(2),
        reference_value(at),
        fn(xs) { v.array(xs, msgpack.StringValue) }(lines),
      ])
    hashline.InsertAtStart(lines) ->
      msgpack.ArrayValue([
        msgpack.IntValue(3),
        fn(xs) { v.array(xs, msgpack.StringValue) }(lines),
      ])
  }
}

/// Converts the closed hashline.Hunk shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_hunk(value: msgpack.MsgPackValue) -> Result(hashline.Hunk, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), from, to, lines]) -> {
      use from <- result.try(parse_reference(from))
      use to <- result.try(parse_reference(to))
      use lines <- result.try(fn(x) { v.items(x, 8192, v.line_text) }(lines))
      Ok(hashline.Replace(from, to, lines))
    }
    msgpack.ArrayValue([msgpack.IntValue(1), from, to]) -> {
      use from <- result.try(parse_reference(from))
      use to <- result.try(parse_reference(to))
      Ok(hashline.Delete(from, to))
    }
    msgpack.ArrayValue([msgpack.IntValue(2), at, lines]) -> {
      use at <- result.try(parse_reference(at))
      use lines <- result.try(fn(x) { v.items(x, 8192, v.line_text) }(lines))
      Ok(hashline.InsertAfter(at, lines))
    }
    msgpack.ArrayValue([msgpack.IntValue(3), lines]) -> {
      use lines <- result.try(fn(x) { v.items(x, 8192, v.line_text) }(lines))
      Ok(hashline.InsertAtStart(lines))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed hashline.Plan shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn plan_value(value: hashline.Plan) -> msgpack.MsgPackValue {
  case value {
    hashline.Plan(digest, hunks) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        msgpack.StringValue(digest),
        fn(xs) { v.array(xs, hunk_value) }(hunks),
      ])
  }
}

/// Converts the closed hashline.Plan shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_plan(value: msgpack.MsgPackValue) -> Result(hashline.Plan, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), digest, hunks]) -> {
      use digest <- result.try(v.digest(digest))
      use hunks <- result.try(fn(x) { v.items(x, 256, parse_hunk) }(hunks))
      Ok(hashline.Plan(digest, hunks))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed hashline.Stale shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn stale_value(value: hashline.Stale) -> msgpack.MsgPackValue {
  case value {
    hashline.Stale(line, expected, fresh) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        msgpack.IntValue(line),
        msgpack.StringValue(expected),
        fn(xs) { v.array(xs, anchored_line_value) }(fresh),
      ])
  }
}

/// Converts the closed hashline.Stale shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_stale(value: msgpack.MsgPackValue) -> Result(hashline.Stale, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), line, expected, fresh]) -> {
      use line <- result.try(v.positive(line))
      use expected <- result.try(v.anchor(expected))
      use fresh <- result.try(fn(x) { v.inventory(x, 5, parse_anchored_line) }(
        fresh,
      ))
      Ok(hashline.Stale(line, expected, fresh))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed hashline.ApplyError shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn apply_error_value(value: hashline.ApplyError) -> msgpack.MsgPackValue {
  case value {
    hashline.MalformedPlan(reason) ->
      msgpack.ArrayValue([msgpack.IntValue(0), msgpack.StringValue(reason)])
    hashline.OverlappingHunks(line) ->
      msgpack.ArrayValue([msgpack.IntValue(1), msgpack.IntValue(line)])
    hashline.StaleAnchors(stale) ->
      msgpack.ArrayValue([
        msgpack.IntValue(2),
        fn(xs) { v.array(xs, stale_value) }(stale),
      ])
    hashline.StaleContent(digest, fresh) ->
      msgpack.ArrayValue([
        msgpack.IntValue(3),
        msgpack.StringValue(digest),
        fn(xs) { v.array(xs, anchored_line_value) }(fresh),
      ])
  }
}

/// Decodes hashline refusals under the producer's coordinate and list contracts.
/// Overlap includes coordinate zero for file-start insertions. Stale references
/// retain hunk order and duplicates, with at most two references per admitted
/// hunk. Fresh touched lines share the allocation scanner's container ceiling.
///
/// ## Examples
///
/// Two `InsertAtStart` hunks produce `OverlappingHunks(0)`. Repeated stale
/// references remain repeated rather than losing per-hunk evidence.
@internal
pub fn parse_apply_error(
  value: msgpack.MsgPackValue,
) -> Result(hashline.ApplyError, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), reason]) -> {
      use reason <- result.try(v.diagnostic(reason))
      Ok(hashline.MalformedPlan(reason))
    }
    msgpack.ArrayValue([msgpack.IntValue(1), line]) -> {
      use line <- result.try(v.natural(line))
      Ok(hashline.OverlappingHunks(line))
    }
    msgpack.ArrayValue([msgpack.IntValue(2), stale]) -> {
      use stale <- result.try(v.items(stale, 512, parse_stale))
      Ok(hashline.StaleAnchors(stale))
    }
    msgpack.ArrayValue([msgpack.IntValue(3), digest, fresh]) -> {
      use digest <- result.try(v.digest(digest))
      use fresh <- result.try(v.inventory(
        fresh,
        preflight.max_container,
        parse_anchored_line,
      ))
      Ok(hashline.StaleContent(digest, fresh))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed fs.Landed shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn landed_value(value: fs.Landed) -> msgpack.MsgPackValue {
  case value {
    fs.Landed(before, edited) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        msgpack.StringValue(before),
        msgpack.StringValue(edited),
      ])
  }
}

/// Converts the closed fs.Landed shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_landed(value: msgpack.MsgPackValue) -> Result(fs.Landed, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), before, edited]) -> {
      use before <- result.try(v.content(before))
      use edited <- result.try(v.postimage(edited))
      Ok(fs.Landed(before, edited))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed hashline.Window shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn window_value(value: hashline.Window) -> msgpack.MsgPackValue {
  case value {
    hashline.Window(lines, total_lines, offset, has_more, trailing_newline) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        fn(xs) { v.array(xs, anchored_line_value) }(lines),
        msgpack.IntValue(total_lines),
        msgpack.IntValue(offset),
        msgpack.BoolValue(has_more),
        msgpack.BoolValue(trailing_newline),
      ])
  }
}

/// Decodes native windows with unique in-file line positions and positive offset.
/// The native producer bounds rendered bytes, so short-line windows can exceed
/// the structured line reader's 2,000-line span. Anchor count remains bounded by
/// the shared allocation scanner, independently of file length.
///
/// ## Examples
///
/// A native window of 2,001 empty lines retains every anchor within the shared
/// container limit; the separate `Lines` request still rejects that span.
@internal
pub fn parse_window(
  value: msgpack.MsgPackValue,
) -> Result(hashline.Window, Nil) {
  case value {
    msgpack.ArrayValue([
      msgpack.IntValue(0),
      lines,
      total_lines,
      offset,
      has_more,
      trailing_newline,
    ]) -> {
      use lines <- result.try(v.inventory(
        lines,
        preflight.max_container,
        parse_anchored_line,
      ))
      use total_lines <- result.try(v.natural(total_lines))
      use offset <- result.try(v.positive(offset))
      use Nil <- result.try(v.unique_keys(lines, fn(line) { line.line }))
      use Nil <- result.try(
        v.check(fn() {
          list.all(lines, fn(line) {
            line.line >= offset && line.line <= total_lines
          })
        }),
      )
      use has_more <- result.try(v.flag(has_more))
      use trailing_newline <- result.try(v.flag(trailing_newline))
      Ok(hashline.Window(lines, total_lines, offset, has_more, trailing_newline))
    }
    _ -> Error(Nil)
  }
}
