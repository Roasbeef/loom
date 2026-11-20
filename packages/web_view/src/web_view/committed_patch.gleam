//// Reads the patch stream of a session's committed work into files and their
//// lines (protocol-change/123, the addendum on committed work).
////
//// The worktree observation carries the commits made since the session began as
//// one string: for each commit a `commit <hash>` line and a subject line, then
//// the commit's unified patch, one `diff --git` section for each file it touched
//// (`client/worktree_diff.committed_patch` runs `git log -p` with renames and
//// textconv off, so every section names one path). The stream is bounded to 4096
//// bytes by the observation and may end in the middle of a hunk. A review needs
//// it as files, so this module splits it into the files, merges the sections
//// that name one path across commits, and reads each file's hunks into the same
//// `diff_view` lines a working-tree patch is read into. It performs no I/O and
//// draws nothing.
////
//// ## What is trusted
////
//// The stream is repository text, and a commit's subject is whatever the model
//// wrote, so a subject could read like a patch line. Two rules keep text that is
//// not a patch from becoming one. A `commit` line and the subject after it are
//// dropped as a pair, and a hunk is read by the line counts its header gives, so
//// a line inside a hunk is a hunk line whatever it says. Nothing outside a
//// header, a hunk or that pair is read. A section whose path cannot be read,
//// such as a quoted name, is counted as skipped and not guessed at.
////
//// ## Flow
////
//// `parse` → `scan` → `section` → `hunks` → `merge`
////
//// 1. `scan` walks the stream line by line, dropping each commit header pair and
////    starting a section at each `diff --git` line.
//// 2. `section` reads one file's header lines and calls `hunks`.
//// 3. `hunks` reads each hunk by its counts into the lines the diff reader produces.
//// 4. `merge` joins the sections of one path, oldest commit first.

import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/diff_view

/// What the commits did to a file, over the whole stream.
pub type Status {
  /// The oldest commit that touched the file created it.
  Created

  /// The newest commit that touched the file removed it.
  Removed

  /// Anything else.
  Changed
}

/// What a file's sections could say of its content.
pub type Body {
  /// Text; its lines are in `Entry.lines`.
  TextBody

  /// Git said the file is binary and gave no lines.
  BinaryBody

  /// Only the file's mode changed.
  ModeBody
}

/// One file the commits touched.
pub type Entry {
  Entry(
    /// The path, as Git named it relative to the workspace.
    path: String,
    /// What the commits did to the file.
    status: Status,
    /// What the file's content is.
    body: Body,
    /// The lines of every section that named this path, oldest commit first,
    /// each hunk headed by its `Hunk` line.
    lines: List(diff_view.Line),
  )
}

/// A stream read.
pub type Parsed {
  Parsed(
    /// The files, one entry for each path, in the order of the oldest section
    /// that named each.
    entries: List(Entry),
    /// How many sections were skipped because their path could not be read.
    skipped: Int,
    /// The path of the last section in the stream, which a cut stream ended in.
    last: Option(String),
  )
}

/// One file's section before merging.
type Section {
  Section(path: String, status: Status, body: Body, lines: List(diff_view.Line))
}

/// Reads a patch stream.
///
/// ## Examples
///
/// ```gleam
/// assert committed_patch.parse("").entries == []
/// ```
pub fn parse(patch: String) -> Parsed {
  let #(sections, skipped) = scan(string.split(patch, "\n"), [], 0)

  // The files are in the order Git wrote them, newest commit first, and `merge`
  // puts the lines of each file's sections oldest commit first.
  Parsed(entries: merge(list.reverse(sections)), skipped:, last: case sections {
    [last_read, ..] -> Some(last_read.path)
    [] -> None
  })
}

/// Walks the stream, keeping each section at the head of the list as it is read
/// and counting the skipped. The list comes back reversed, with the section the
/// stream ended in at its head.
fn scan(
  lines: List(String),
  found: List(Section),
  skipped: Int,
) -> #(List(Section), Int) {
  case lines {
    [] -> #(found, skipped)

    // A commit's header and its subject are one pair; the subject is text the
    // committer wrote and is never read as a patch line.
    ["commit " <> hash, subject, ..rest] ->
      case is_hash(hash) {
        True -> scan(rest, found, skipped)
        False -> scan([subject, ..rest], found, skipped)
      }
    ["diff --git " <> names, ..rest] ->
      case path_of(names) {
        Ok(path) -> {
          let #(read, after) = section(path, rest)
          scan(after, [read, ..found], skipped)
        }
        Error(Nil) -> scan(rest, found, skipped + 1)
      }
    [_, ..rest] -> scan(rest, found, skipped)
  }
}

/// Whether a word is the abbreviated hash Git puts after `commit `: lower-case
/// hexadecimal digits, at least four and at most forty.
fn is_hash(word: String) -> Bool {
  let size = string.length(word)

  size >= 4
  && size <= 40
  && list.all(string.to_graphemes(word), fn(digit) {
    string.contains("0123456789abcdef", digit)
  })
}

/// The path both sides of a `diff --git a/X b/X` line name. With renames off the
/// two sides are equal, so the line is `a/` and `b/` around one path and a
/// space, and its length says where the path ends even when the path holds a
/// space. A quoted name, and any line whose sides differ, has no path.
fn path_of(names: String) -> Result(String, Nil) {
  let size = string.length(names)
  let half = { size - 5 } / 2
  let path = string.slice(names, 2, half)

  // Both sides name one path: `a/`, the path, ` b/`, the path again.
  use <- bool.guard(
    !string.starts_with(names, "a/") || { size - 5 } % 2 != 0 || half <= 0,
    Error(Nil),
  )
  use <- bool.guard(
    string.slice(names, 2 + half, 3) != " b/"
      || string.slice(names, 5 + half, half) != path,
    Error(Nil),
  )
  Ok(path)
}

/// Reads one file's header lines and hunks, and returns the lines after them.
fn section(path: String, lines: List(String)) -> #(Section, List(String)) {
  let #(header, after) = list.split_while(lines, is_header_line)
  let #(hunk_lines, rest) = hunks(after, [])
  let says = fn(prefix) { list.any(header, string.starts_with(_, prefix)) }

  #(
    Section(
      path:,
      status: case says("deleted file mode"), says("new file mode") {
        True, _ -> Removed
        False, True -> Created
        False, False -> Changed
      },
      body: case says("Binary files "), says("new mode"), hunk_lines {
        True, _, _ -> BinaryBody
        False, True, [] -> ModeBody
        False, _, _ -> TextBody
      },
      lines: diff_view.of_lines(hunk_lines),
    ),
    rest,
  )
}

/// Whether a line is one of those Git puts between `diff --git` and the first
/// hunk.
fn is_header_line(line: String) -> Bool {
  list.any(
    [
      "index ", "--- ", "+++ ", "new file mode", "deleted file mode", "old mode",
      "new mode", "Binary files ",
    ],
    string.starts_with(line, _),
  )
}

/// Reads the hunks that follow a header: each `@@` line and as many lines after
/// it as its counts say, with the `\ No newline` note that may follow. The lines
/// come back in order with each hunk's header first, and the rest of the stream
/// after them.
fn hunks(
  lines: List(String),
  read: List(List(String)),
) -> #(List(String), List(String)) {
  // A hunk header starts a hunk to read; anything else ends the section.
  case lines {
    ["@@ " <> _ as header, ..rest] -> {
      let #(old, new) = counts(header)
      let #(body, after) = hunk_body(rest, old, new, [])

      hunks(after, [[header, ..body], ..read])
    }
    _ -> #(list.flatten(list.reverse(read)), lines)
  }
}

/// The lines of one hunk: those that make up the old and new counts, then a
/// `\ No newline` note if the next line is one. A line that is none of a
/// context, removed, added or note line ends the hunk even if the counts say
/// more, which is how a stream cut inside a hunk ends.
fn hunk_body(
  lines: List(String),
  old: Int,
  new: Int,
  read: List(String),
) -> #(List(String), List(String)) {
  case lines {
    ["\\" <> _ as note, ..rest] -> hunk_body(rest, old, new, [note, ..read])
    _ if old <= 0 && new <= 0 -> #(list.reverse(read), lines)
    [" " <> _ as line, ..rest] if old > 0 && new > 0 ->
      hunk_body(rest, old - 1, new - 1, [line, ..read])
    ["" as line, ..rest] if old > 0 && new > 0 ->
      hunk_body(rest, old - 1, new - 1, [line, ..read])
    ["-" <> _ as line, ..rest] if old > 0 ->
      hunk_body(rest, old - 1, new, [line, ..read])
    ["+" <> _ as line, ..rest] if new > 0 ->
      hunk_body(rest, old, new - 1, [line, ..read])
    _ -> #(list.reverse(read), lines)
  }
}

/// The old and new line counts a hunk header gives, `@@ -9,6 +9,12 @@`. A side
/// with no comma counts one line, and a side that is not a number counts none, so
/// a damaged header reads no body.
fn counts(header: String) -> #(Int, Int) {
  let words = string.split(header, " ")

  #(count_after(words, "-"), count_after(words, "+"))
}

/// The count of the first word that starts with `sign`: the number after its
/// comma, or one when there is none.
fn count_after(words: List(String), sign: String) -> Int {
  list.find_map(words, fn(word) {
    // Only a word that is the sign and a number can be a side's range.
    case string.starts_with(word, sign) && string.length(word) > 1 {
      True -> {
        let number = string.drop_start(word, 1)

        // `-9,6` counts six lines and `-9` one.
        case string.split_once(number, ",") {
          Ok(#(first, size)) ->
            result.try(int.parse(first), fn(_) { int.parse(size) })
          Error(Nil) -> result.map(int.parse(number), fn(_) { 1 })
        }
      }
      False -> Error(Nil)
    }
  })
  |> result.unwrap(0)
}

/// Joins the sections of each path. The sections are in the stream's order,
/// newest commit first, and each path appears once, where its newest section
/// does. A path's lines are its sections' with the oldest commit first; it is created if its oldest section created it, removed
/// if its newest removed it, binary if any section said so, and a mode change
/// only if every section was one. The cost is the square of the number of
/// sections, and the stream's 4096 bytes bound that at a few dozen.
fn merge(sections: List(Section)) -> List(Entry) {
  let paths =
    list.fold(sections, [], fn(seen, each) {
      case list.contains(seen, each.path) {
        True -> seen
        False -> [each.path, ..seen]
      }
    })
    |> list.reverse

  list.map(paths, fn(path) {
    let group = list.filter(sections, fn(each) { each.path == path })
    join(path, group)
  })
}

/// One path's sections, in the stream's order, as an entry.
fn join(path: String, stream: List(Section)) -> Entry {
  let group = list.reverse(stream)
  let oldest = list.first(group)
  let newest = list.last(group)

  Entry(
    path:,
    status: case oldest, newest {
      _, Ok(Section(status: Removed, ..)) -> Removed
      Ok(Section(status: Created, ..)), _ -> Created
      _, _ -> Changed
    },
    body: case
      list.any(group, fn(each) { each.body == BinaryBody }),
      list.all(group, fn(each) { each.body == ModeBody })
    {
      True, _ -> BinaryBody
      False, True -> ModeBody
      False, False -> TextBody
    },
    lines: list.flat_map(group, fn(each) { each.lines }),
  )
}
