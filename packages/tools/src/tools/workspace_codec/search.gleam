//// Search requests and observations retain bounded traversal semantics.
////
//// Queries use the existing glob/regex compilers and their admitted ceilings.
//// Listings reject repeated paths even when metadata differs. Match context,
//// skipped/scanned counts, coverage and completeness remain explicit fields;
//// an empty inventory cannot conceal a truncated scan.

import core/msgpack
import gleam/result
import tools/search
import tools/workspace_codec/value as v

/// Converts the closed search.Hidden shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn hidden_value(value: search.Hidden) -> msgpack.MsgPackValue {
  case value {
    search.SkipHidden -> msgpack.ArrayValue([msgpack.IntValue(0)])
    search.IncludeHidden -> msgpack.ArrayValue([msgpack.IntValue(1)])
  }
}

/// Converts the closed search.Hidden shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_hidden(value: msgpack.MsgPackValue) -> Result(search.Hidden, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0)]) -> {
      Ok(search.SkipHidden)
    }
    msgpack.ArrayValue([msgpack.IntValue(1)]) -> {
      Ok(search.IncludeHidden)
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed search.Kind shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn kind_value(value: search.Kind) -> msgpack.MsgPackValue {
  case value {
    search.File -> msgpack.ArrayValue([msgpack.IntValue(0)])
    search.Directory -> msgpack.ArrayValue([msgpack.IntValue(1)])
    search.Symlink(target) ->
      msgpack.ArrayValue([msgpack.IntValue(2), msgpack.StringValue(target)])
    search.Other -> msgpack.ArrayValue([msgpack.IntValue(3)])
  }
}

/// Converts the closed search.Kind shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_kind(value: msgpack.MsgPackValue) -> Result(search.Kind, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0)]) -> {
      Ok(search.File)
    }
    msgpack.ArrayValue([msgpack.IntValue(1)]) -> {
      Ok(search.Directory)
    }
    msgpack.ArrayValue([msgpack.IntValue(2), target]) -> {
      use target <- result.try(v.text(target))
      Ok(search.Symlink(target))
    }
    msgpack.ArrayValue([msgpack.IntValue(3)]) -> {
      Ok(search.Other)
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed search.Completeness shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn completeness_value(value: search.Completeness) -> msgpack.MsgPackValue {
  case value {
    search.Complete -> msgpack.ArrayValue([msgpack.IntValue(0)])
    search.Truncated -> msgpack.ArrayValue([msgpack.IntValue(1)])
  }
}

/// Converts the closed search.Completeness shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_completeness(
  value: msgpack.MsgPackValue,
) -> Result(search.Completeness, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0)]) -> {
      Ok(search.Complete)
    }
    msgpack.ArrayValue([msgpack.IntValue(1)]) -> {
      Ok(search.Truncated)
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed search.Coverage shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn coverage_value(value: search.Coverage) -> msgpack.MsgPackValue {
  case value {
    search.Exhaustive -> msgpack.ArrayValue([msgpack.IntValue(0)])
    search.MatchesCapped -> msgpack.ArrayValue([msgpack.IntValue(1)])
    search.ScanTruncated -> msgpack.ArrayValue([msgpack.IntValue(2)])
  }
}

/// Converts the closed search.Coverage shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_coverage(
  value: msgpack.MsgPackValue,
) -> Result(search.Coverage, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0)]) -> {
      Ok(search.Exhaustive)
    }
    msgpack.ArrayValue([msgpack.IntValue(1)]) -> {
      Ok(search.MatchesCapped)
    }
    msgpack.ArrayValue([msgpack.IntValue(2)]) -> {
      Ok(search.ScanTruncated)
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed search.GlobQuery shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn glob_value(value: search.GlobQuery) -> msgpack.MsgPackValue {
  case value {
    search.GlobQuery(pattern, max_entries, hidden, prune) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        msgpack.StringValue(pattern),
        msgpack.IntValue(max_entries),
        hidden_value(hidden),
        fn(xs) { v.array(xs, msgpack.StringValue) }(prune),
      ])
  }
}

/// Converts the closed search.GlobQuery shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_glob(
  value: msgpack.MsgPackValue,
) -> Result(search.GlobQuery, Nil) {
  case value {
    msgpack.ArrayValue([
      msgpack.IntValue(0),
      pattern,
      max_entries,
      hidden,
      prune,
    ]) -> {
      use pattern <- result.try(v.glob(pattern))
      use max_entries <- result.try(fn(x) { v.range(x, 1, 4096) }(max_entries))
      use hidden <- result.try(parse_hidden(hidden))
      use prune <- result.try(fn(x) { v.inventory(x, 8192, v.prune) }(prune))
      Ok(search.GlobQuery(pattern, max_entries, hidden, prune))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed search.GrepQuery shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn grep_value(value: search.GrepQuery) -> msgpack.MsgPackValue {
  case value {
    search.GrepQuery(pattern, globs, context, max_matches, hidden, prune) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        msgpack.StringValue(pattern),
        fn(xs) { v.array(xs, msgpack.StringValue) }(globs),
        msgpack.IntValue(context),
        msgpack.IntValue(max_matches),
        hidden_value(hidden),
        fn(xs) { v.array(xs, msgpack.StringValue) }(prune),
      ])
  }
}

/// Converts the closed search.GrepQuery shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_grep(
  value: msgpack.MsgPackValue,
) -> Result(search.GrepQuery, Nil) {
  case value {
    msgpack.ArrayValue([
      msgpack.IntValue(0),
      pattern,
      globs,
      context,
      max_matches,
      hidden,
      prune,
    ]) -> {
      use pattern <- result.try(v.regex(pattern))
      use globs <- result.try(fn(x) { v.inventory(x, 8192, v.glob) }(globs))
      use context <- result.try(fn(x) { v.range(x, 0, 10) }(context))
      use max_matches <- result.try(fn(x) { v.range(x, 1, 1000) }(max_matches))
      use hidden <- result.try(parse_hidden(hidden))
      use prune <- result.try(fn(x) { v.inventory(x, 8192, v.prune) }(prune))
      Ok(search.GrepQuery(pattern, globs, context, max_matches, hidden, prune))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed search.Entry shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn entry_value(value: search.Entry) -> msgpack.MsgPackValue {
  case value {
    search.Entry(path, kind, size, mtime_seconds) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        msgpack.StringValue(path),
        kind_value(kind),
        msgpack.IntValue(size),
        msgpack.IntValue(mtime_seconds),
      ])
  }
}

/// Converts the closed search.Entry shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_entry(value: msgpack.MsgPackValue) -> Result(search.Entry, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), path, kind, size, mtime_seconds]) -> {
      use path <- result.try(v.observed_path(path))
      use kind <- result.try(parse_kind(kind))
      use size <- result.try(v.natural(size))
      use mtime_seconds <- result.try(v.integer(mtime_seconds))
      Ok(search.Entry(path, kind, size, mtime_seconds))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed search.Listing shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn listing_value(value: search.Listing) -> msgpack.MsgPackValue {
  case value {
    search.Listing(entries, completeness) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        fn(xs) { v.array(xs, entry_value) }(entries),
        completeness_value(completeness),
      ])
  }
}

/// Converts the closed search.Listing shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_listing(
  value: msgpack.MsgPackValue,
) -> Result(search.Listing, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), entries, completeness]) -> {
      use entries <- result.try(fn(x) { v.inventory(x, 4096, parse_entry) }(
        entries,
      ))
      use Nil <- result.try(v.unique_keys(entries, fn(entry) { entry.path }))
      use completeness <- result.try(parse_completeness(completeness))
      Ok(search.Listing(entries, completeness))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed search.Match shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn match_value(value: search.Match) -> msgpack.MsgPackValue {
  case value {
    search.Match(path, line, column, text, before, after) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        msgpack.StringValue(path),
        msgpack.IntValue(line),
        msgpack.IntValue(column),
        msgpack.StringValue(text),
        fn(xs) { v.array(xs, msgpack.StringValue) }(before),
        fn(xs) { v.array(xs, msgpack.StringValue) }(after),
      ])
  }
}

/// Converts the closed search.Match shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_match(value: msgpack.MsgPackValue) -> Result(search.Match, Nil) {
  case value {
    msgpack.ArrayValue([
      msgpack.IntValue(0),
      path,
      line,
      column,
      text,
      before,
      after,
    ]) -> {
      use path <- result.try(v.observed_path(path))
      use line <- result.try(v.positive(line))
      use column <- result.try(v.positive(column))
      use text <- result.try(v.line_text(text))
      use before <- result.try(fn(x) { v.items(x, 10, v.line_text) }(before))
      use after <- result.try(fn(x) { v.items(x, 10, v.line_text) }(after))
      Ok(search.Match(path, line, column, text, before, after))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed search.Found shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn found_value(value: search.Found) -> msgpack.MsgPackValue {
  case value {
    search.Found(matches, files_scanned, files_skipped, coverage) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        fn(xs) { v.array(xs, match_value) }(matches),
        msgpack.IntValue(files_scanned),
        msgpack.IntValue(files_skipped),
        coverage_value(coverage),
      ])
  }
}

/// Converts the closed search.Found shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_found(value: msgpack.MsgPackValue) -> Result(search.Found, Nil) {
  case value {
    msgpack.ArrayValue([
      msgpack.IntValue(0),
      matches,
      files_scanned,
      files_skipped,
      coverage,
    ]) -> {
      use matches <- result.try(fn(x) { v.inventory(x, 1000, parse_match) }(
        matches,
      ))
      use Nil <- result.try(
        v.unique_keys(matches, fn(match) { #(match.path, match.line) }),
      )
      use files_scanned <- result.try(fn(x) { v.range(x, 0, 20_000) }(
        files_scanned,
      ))
      use files_skipped <- result.try(fn(x) { v.range(x, 0, 20_000) }(
        files_skipped,
      ))
      use coverage <- result.try(parse_coverage(coverage))
      Ok(search.Found(matches, files_scanned, files_skipped, coverage))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed search.Lines shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn lines_value(value: search.Lines) -> msgpack.MsgPackValue {
  case value {
    search.Lines(text, first, last, total) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        msgpack.StringValue(text),
        msgpack.IntValue(first),
        msgpack.IntValue(last),
        msgpack.IntValue(total),
      ])
  }
}

/// Converts the closed search.Lines shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_lines(value: msgpack.MsgPackValue) -> Result(search.Lines, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), text, first, last, total]) -> {
      use text <- result.try(v.content(text))
      use first <- result.try(v.positive(first))
      use last <- result.try(v.natural(last))
      use total <- result.try(v.natural(total))
      use Nil <- result.try(
        v.check(fn() {
          last <= total
          && last <= first + 1999
          && {
            case first > total {
              True -> text == "" && last == total
              False -> last >= first
            }
          }
        }),
      )
      Ok(search.Lines(text, first, last, total))
    }
    _ -> Error(Nil)
  }
}
