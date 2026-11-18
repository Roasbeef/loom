//// What a person reads to review a finished session's work: the files its
//// workspace changed, each file's hunks, and a diff stat (protocol-change/123).
////
//// The daemon already observes a session's Git working tree for the Changes
//// tab (`session_view/worktree_view.Board`). That observation is the repository's
//// own text, read inside the session's sandbox and bounded in files and bytes,
//// and it carries each file's patch as one string. A review pane needs more
//// shape than that: hunks it can open one at a time, a count of what changed,
//// the files in the order a reviewer reads them, and a promise about how large
//// the whole thing can be. This module turns a board into that, and holds the
//// one total decoder that the page and a control client share. It draws
//// nothing and performs no I/O.
////
//// ## Flow
////
//// `of_board` → `of_file` → `hunks_of` → `bounded_hunk` → `fit` → `encode`
////
//// 1. `of_board` keeps the files whose path is workspace-relative, reads each
////    with `of_file`, orders them with `order`, and totals the stat.
//// 2. `of_file` reads the patch into lines (`session_view/diff_view`), counts
////    what was added and removed, and splits the lines into hunks with
////    `hunks_of`.
//// 3. `bounded_hunk` cuts a hunk to the line and byte bounds below, and says
////    how many it cut.
//// 4. `fit` drops files from the end until the encoded review is within the
////    byte bound, and counts them as omitted.
//// 5. `decode` reads an encoded review back, one damaged file at a time, and
////    holds the same bounds, so a review that reaches a page is as bounded as
////    one the daemon made.
////
//// ## What is bounded, and how a cut is said
////
//// Every cut is counted and carried, never silent. A review holds at most
//// `max_files` files, a file at most `max_hunks` hunks, a hunk at most
//// `max_hunk_lines` lines, a line at most `max_line_bytes` bytes, and the
//// encoded whole at most `max_bytes`, which leaves the control socket's
//// 60,000-byte reply room for its envelope. `Review.omitted` is files left
//// out, `File.hunks_omitted` hunks, `Hunk.omitted` lines and `Hunk.shortened`
//// lines that were cut short. A file's `extent` is `Cut` when any of its own
//// bounds, or the observation's, cut it, and the review's is `Cut` when
//// anything anywhere was. The stat counts every file the observation read,
//// including ones left out of the review, and a cut file's counts are lower
//// bounds.
////
//// A binary file is named and carries no hunks. A path that is absolute or
//// climbs out of the workspace is not a workspace path, so its file is left
//// out and counted as omitted.
////
//// Every string here, a path and a line, is the repository's text, and is
//// drawn only as a text node.

import core/json.{type JsonValue}
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import session_view/diff_view
import session_view/worktree_view
import web_view/utf8_window

/// The most files a review holds. It is the observation's own bound, so the
/// review never has to choose among files the observation kept.
pub const max_files = 24

/// The most hunks a review holds for one file.
pub const max_hunks = 12

/// The most lines a review holds for one hunk, its context lines included.
pub const max_hunk_lines = 80

/// The most bytes one line's text keeps. A longer line is cut at a character
/// boundary and counted in `Hunk.shortened`.
pub const max_line_bytes = 400

/// The most bytes a review encodes to, which leaves the 60,000-byte control
/// reply room for its envelope.
pub const max_bytes = 48_000

/// The longest path a review accepts, in bytes.
pub const max_path_bytes = 1024

/// Whether a repository was there to observe.
pub type Repository {
  /// A checkout with a HEAD commit.
  Head

  /// A checkout with no commit yet; every present file is an addition.
  Unborn

  /// A workspace that is not a Git checkout. There is nothing to review.
  NotRepository
}

/// Which pile a file is read in: the order is source, then tests, then docs.
pub type Section {
  /// Any file that is not a test or a document.
  Source

  /// A file under a test directory, or one whose name marks it a test.
  Tests

  /// A document: a file under `docs/`, or a prose file by its extension.
  Docs
}

/// What happened to a file.
pub type Change {
  /// The file is new: added to the index, or untracked.
  Added

  /// The file existed and its content changed.
  Modified

  /// The file was removed. A renamed file is a removal and an addition, because
  /// the observation does not detect renames.
  Deleted
}

/// What the observation could say about a file's content.
pub type Content {
  /// A text file; its hunks are in `File.hunks`.
  Text

  /// A binary file. It is named, and carries no hunks.
  Binary

  /// A file that is touched but whose content is the same.
  NoNetChange

  /// A file whose mode or other metadata changed, with no text to show.
  MetadataOnly
}

/// Whether anything was cut from what it describes.
pub type Extent {
  /// Nothing was cut.
  Whole

  /// A bound cut something, and the counts beside it say how much.
  Cut
}

/// How much changed, over every file the observation read.
pub type Stat {
  Stat(
    /// The files the observation read, those left out of the review included.
    files: Int,
    /// Lines added, across the files the observation showed.
    added: Int,
    /// Lines removed, across the files the observation showed.
    removed: Int,
  )
}

/// One hunk of a file's patch.
pub type Hunk {
  Hunk(
    /// The hunk header, `@@ -9,6 +9,12 @@` and any text git put after it.
    header: String,
    /// The hunk's lines, at most `max_hunk_lines`, none of them a header. A
    /// line's numbers are those the header gave.
    lines: List(diff_view.Line),
    /// How many lines past `max_hunk_lines` were left out.
    omitted: Int,
    /// How many of `lines` were cut to `max_line_bytes`.
    shortened: Int,
  )
}

/// One file of the review.
pub type File {
  File(
    /// The path, relative to the session's workspace.
    path: String,
    /// What happened to the file.
    change: Change,
    /// The pile the file is read in.
    section: Section,
    /// What the observation could say of its content.
    content: Content,
    /// Lines the file's patch added, as far as the patch was read.
    added: Int,
    /// Lines the file's patch removed, as far as the patch was read.
    removed: Int,
    /// The hunks, at most `max_hunks`.
    hunks: List(Hunk),
    /// How many hunks past `max_hunks` were left out.
    hunks_omitted: Int,
    /// `Cut` when this file's patch, hunks, lines or the observation were cut.
    extent: Extent,
  )
}

/// A session's review: the whole of what the daemon says about its worktree.
pub type Review {
  Review(
    /// When the daemon read the tree, in Unix milliseconds.
    observed_at_ms: Int,
    /// Whether a checkout was there.
    repository: Repository,
    /// What changed, in numbers.
    stat: Stat,
    /// The files, ordered source, then tests, then docs, and by path within each.
    files: List(File),
    /// Files read and not carried: past the observation's bound, past
    /// `max_bytes`, or at a path that is not workspace-relative.
    omitted: Int,
    /// `Cut` when anything was left out or cut short.
    extent: Extent,
  )
}

/// A review of a board: its files read into hunks, ordered, counted and fitted
/// to `max_bytes`.
///
/// ## Examples
///
/// ```gleam
/// // review_feed.of_board(board).stat
/// ```
pub fn of_board(board: worktree_view.Board) -> Review {
  let #(kept, foreign) =
    list.partition(board.files, fn(file) { workspace_relative(file.path) })
  let files = list.map(kept, of_file) |> order
  let stat =
    Stat(
      files: board.total,
      added: list.fold(files, 0, fn(sum, file) { sum + file.added }),
      removed: list.fold(files, 0, fn(sum, file) { sum + file.removed }),
    )

  // The observation's own omissions and the foreign paths are files read and
  // not carried.
  let omitted = board.omitted + list.length(foreign)
  fit(Review(
    observed_at_ms: board.observed_at_ms,
    repository: repository_of(board.repository),
    stat:,
    files:,
    omitted:,
    extent: board_extent(board.extent, omitted),
  ))
}

/// The review's extent: cut when the observation says it was, or when any file
/// was read and not carried.
fn board_extent(observed: String, omitted: Int) -> Extent {
  // The observation's word is `limited` or `complete`; either way a file left
  // out is a cut.
  case observed == "limited", omitted {
    True, _ -> Cut
    False, 0 -> Whole
    False, _ -> Cut
  }
}

/// Whether a path is one a review may name: not empty, not too long, not
/// absolute, and with no `..` segment. The observation asks Git for paths
/// relative to the workspace, so this is a check that a damaged or hostile
/// answer cannot widen the page's idea of where a file is.
///
/// ## Examples
///
/// ```gleam
/// assert review_feed.workspace_relative("src/a.gleam")
/// assert !review_feed.workspace_relative("../outside")
/// ```
pub fn workspace_relative(path: String) -> Bool {
  let segments = string.split(path, "/")
  path != ""
  && string.byte_size(path) <= max_path_bytes
  && !string.starts_with(path, "/")
  && !list.contains(segments, "..")
  && !string.contains(path, "\u{0}")
}

/// The pile a path is read in. A document is decided first, so a `README.md`
/// under `tests/` is a document, and a file under `docs/` is a document
/// whatever its extension.
///
/// ## Examples
///
/// ```gleam
/// assert review_feed.section_of("src/retry_test.gleam") == review_feed.Tests
/// assert review_feed.section_of("docs/next.md") == review_feed.Docs
/// assert review_feed.section_of("src/retry.gleam") == review_feed.Source
/// ```
pub fn section_of(path: String) -> Section {
  let segments = string.split(path, "/")
  let name = list.last(segments) |> result.unwrap(path)
  let directories = list.take(segments, list.length(segments) - 1)

  // A document by where it lives or what it is called wins over a test.
  case is_doc(directories, name), is_test(directories, name) {
    True, _ -> Docs
    False, True -> Tests
    False, False -> Source
  }
}

/// Orders files for reading: source, then tests, then docs, and by path inside
/// each. The order is total and stable, so a review of the same tree is the
/// same review.
///
/// ## Examples
///
/// ```gleam
/// // review_feed.order(files) puts every Source file before every Tests file
/// ```
pub fn order(files: List(File)) -> List(File) {
  list.sort(files, fn(left, right) {
    int.compare(rank(left.section), rank(right.section))
    |> order.break_tie(string.compare(left.path, right.path))
  })
}

/// The review as it travels: the shape `decode` reads.
///
/// ## Examples
///
/// ```gleam
/// // review_feed.encode(review)
/// ```
pub fn encode(review: Review) -> JsonValue {
  json.Object([
    #("observed_at_ms", json.Int(review.observed_at_ms)),
    #("repository", json.String(repository_word(review.repository))),
    #(
      "stat",
      json.Object([
        #("files", json.Int(review.stat.files)),
        #("added", json.Int(review.stat.added)),
        #("removed", json.Int(review.stat.removed)),
      ]),
    ),
    #("omitted", json.Int(review.omitted)),
    #("extent", json.String(extent_word(review.extent))),
    #("files", json.Array(list.map(review.files, encode_file))),
  ])
}

/// A review read from its encoding, or nothing for a value that is not one.
///
/// It is total. The stat, the counts, the repository and the extent must be
/// well formed, or there is no review. A file that is damaged, or whose path is
/// not workspace-relative, is dropped alone and counted in `omitted`, and the
/// bounds of this module hold on what is kept, so a value from any source is as
/// bounded as one `of_board` made.
///
/// ## Examples
///
/// ```gleam
/// assert review_feed.decode(review_feed.encode(review)) == Ok(review)
/// ```
pub fn decode(value: JsonValue) -> Result(Review, Nil) {
  use fields <- result.try(object(value))
  use observed_at_ms <- result.try(natural(fields, "observed_at_ms"))
  use repository <- result.try(
    text(fields, "repository") |> result.try(parse_repository),
  )
  use stat <- result.try(
    list.key_find(fields, "stat") |> result.try(decode_stat),
  )
  use omitted <- result.try(natural(fields, "omitted"))
  use extent <- result.try(text(fields, "extent") |> result.try(parse_extent))
  use raw <- result.try(array(fields, "files"))

  // Each file decodes alone; one that does not is a file left out.
  let files = list.filter_map(list.take(raw, max_files), decode_file)
  let dropped = list.length(raw) - list.length(files)
  Ok(
    Review(
      observed_at_ms:,
      repository:,
      stat:,
      files:,
      omitted: omitted + dropped,
      extent: case dropped {
        0 -> extent
        _ -> Cut
      },
    ),
  )
}

// --- reading a board ----------------------------------------------------------

/// One observed file, read into a reviewable one. The patch is read whole,
/// because the observation already bounded it, and cut afterwards by this
/// module's own bounds.
fn of_file(file: worktree_view.File) -> File {
  let lines = diff_view.of_lines(string.split(file.patch, "\n"))
  let content = content_of(file.kind)

  // A text file shows its hunks; every other kind is named and shows none.
  let #(hunks, hunks_omitted) = shown_hunks(content, hunks_of(lines))
  File(
    path: file.path,
    change: change_of(file.index_status, file.worktree_status),
    section: section_of(file.path),
    content:,
    added: count_kind(lines, diff_view.Added),
    removed: count_kind(lines, diff_view.Removed),
    hunks:,
    hunks_omitted:,
    extent: file_extent(file.extent, hunks, hunks_omitted),
  )
}

/// The hunks a file shows and how many it left out: for a text file the first
/// `max_hunks`, each bounded, and for any other kind none.
fn shown_hunks(content: Content, all: List(Hunk)) -> #(List(Hunk), Int) {
  // Only text has hunks to show.
  case content {
    Text -> #(
      list.take(all, max_hunks) |> list.map(bounded_hunk),
      int.max(0, list.length(all) - max_hunks),
    )
    Binary | NoNetChange | MetadataOnly -> #([], 0)
  }
}

/// A file's extent: cut when the observation cut its patch, when hunks were
/// left out, or when any kept hunk lost lines.
fn file_extent(observed: String, hunks: List(Hunk), omitted: Int) -> Extent {
  let lossy =
    list.any(hunks, fn(hunk) { hunk.omitted > 0 || hunk.shortened > 0 })

  // Any one of the three cuts is enough to call the file cut.
  case observed == "limited" || omitted > 0 || lossy {
    True -> Cut
    False -> Whole
  }
}

/// A patch's lines split into hunks. Lines before the first hunk header, which
/// are the file's own header, belong to no hunk and are dropped.
fn hunks_of(lines: List(diff_view.Line)) -> List(Hunk) {
  // Skip to the next hunk header; none left means no more hunks.
  case list.drop_while(lines, fn(line) { line.kind != diff_view.Hunk }) {
    [] -> []
    [header, ..rest] -> {
      let #(body, after) =
        list.split_while(rest, fn(line) { line.kind != diff_view.Hunk })
      [Hunk(header.text, body, 0, 0), ..hunks_of(after)]
    }
  }
}

/// A hunk cut to `max_hunk_lines` lines, each of at most `max_line_bytes`
/// bytes, with the cuts counted.
fn bounded_hunk(hunk: Hunk) -> Hunk {
  let kept = list.take(hunk.lines, max_hunk_lines)
  let shortened = list.count(kept, fn(line) { too_long(line.text) })
  Hunk(
    header: utf8_window.prefix(hunk.header, max_line_bytes),
    lines: list.map(kept, shorten),
    omitted: int.max(0, list.length(hunk.lines) - max_hunk_lines),
    shortened:,
  )
}

/// Whether a line's text is past `max_line_bytes`.
fn too_long(text: String) -> Bool {
  string.byte_size(text) > max_line_bytes
}

/// A line with its text cut to `max_line_bytes` at a character boundary.
fn shorten(line: diff_view.Line) -> diff_view.Line {
  diff_view.Line(..line, text: utf8_window.prefix(line.text, max_line_bytes))
}

/// How many lines of a kind a patch holds.
fn count_kind(lines: List(diff_view.Line), kind: diff_view.Kind) -> Int {
  list.count(lines, fn(line) { line.kind == kind })
}

/// Fits a review to `max_bytes` by keeping files from the front until the next
/// one would not fit, and counting the rest in `omitted`. What goes is the
/// last files, which are the docs, then the tests. The stat is not touched: it
/// says what the observation read.
///
/// Each file is encoded once and sized, rather than the whole review again for
/// each file dropped, so the cost is one encoding however much is cut.
fn fit(review: Review) -> Review {
  let envelope = encoded_size(encode(Review(..review, files: [])))
  let kept = take_fitting(review.files, max_bytes - envelope)
  let dropped = list.length(review.files) - list.length(kept)

  // Nothing dropped is the review as it came.
  case dropped {
    0 -> review
    _ ->
      Review(
        ..review,
        files: kept,
        omitted: review.omitted + dropped,
        extent: Cut,
      )
  }
}

/// The files from the front whose encodings fit in `room` bytes together, with
/// a byte for the comma between them. The first file that does not fit ends the
/// list, so a small later file never jumps a large earlier one.
fn take_fitting(files: List(File), room: Int) -> List(File) {
  // No files left is the end of the list; otherwise the next file either fits
  // in what room remains, or ends it.
  case files {
    [] -> []
    [file, ..rest] -> {
      let size = encoded_size(encode_file(file)) + 1

      // A file that fits is kept and the rest are fitted into what is left.
      case size <= room {
        True -> [file, ..take_fitting(rest, room - size)]
        False -> []
      }
    }
  }
}

/// The bytes a value encodes to.
fn encoded_size(value: JsonValue) -> Int {
  json.to_string(value) |> string.byte_size
}

/// The change a pair of porcelain status letters makes. A removal outranks an
/// addition, so a file added and then removed reads as removed.
fn change_of(index: String, worktree: String) -> Change {
  // The two letters are the index's and the working tree's.
  case index, worktree {
    "D", _ | _, "D" -> Deleted
    "A", _ | "?", _ | _, "?" -> Added
    _, _ -> Modified
  }
}

/// A content word the observation sent, as the type. A word it does not know
/// cannot occur, because `worktree_view` validates it.
fn content_of(kind: String) -> Content {
  case kind {
    "binary" -> Binary
    "no_net_change" -> NoNetChange
    "metadata_only" -> MetadataOnly
    _ -> Text
  }
}

/// The repository word the observation sent, as the type.
fn repository_of(word: String) -> Repository {
  case word {
    "unborn" -> Unborn
    "not_repository" -> NotRepository
    _ -> Head
  }
}

/// Where a section sorts: source first.
fn rank(section: Section) -> Int {
  case section {
    Source -> 0
    Tests -> 1
    Docs -> 2
  }
}

/// Whether a file is a document, by its directory or its name.
fn is_doc(directories: List(String), name: String) -> Bool {
  let top_is_docs =
    list.first(directories)
    |> result.map(list.contains(["docs", "doc"], _))
    |> result.unwrap(False)
  let lowered = string.lowercase(name)
  let prose =
    list.any([".md", ".mdx", ".rst", ".adoc", ".txt"], string.ends_with(
      lowered,
      _,
    ))
  let known =
    list.contains(
      ["readme", "changelog", "license", "notice", "authors"],
      lowered,
    )
  top_is_docs || prose || known
}

/// Whether a file is a test, by a directory it sits in or the shape of its name.
fn is_test(directories: List(String), name: String) -> Bool {
  let test_directories = [
    "test", "tests", "spec", "specs", "__tests__", "testdata", "fixtures",
  ]
  let in_directory =
    list.any(directories, fn(directory) {
      list.contains(test_directories, string.lowercase(directory))
    })
  let lowered = string.lowercase(name)
  let by_name =
    list.any(["_test.", ".test.", "_spec.", ".spec."], string.contains(
      lowered,
      _,
    ))
    || string.starts_with(lowered, "test_")
  in_directory || by_name
}

// --- the wire ------------------------------------------------------------------

/// A file as it travels.
fn encode_file(file: File) -> JsonValue {
  json.Object([
    #("path", json.String(file.path)),
    #("change", json.String(change_word(file.change))),
    #("section", json.String(section_word(file.section))),
    #("content", json.String(content_word(file.content))),
    #("added", json.Int(file.added)),
    #("removed", json.Int(file.removed)),
    #("hunks_omitted", json.Int(file.hunks_omitted)),
    #("extent", json.String(extent_word(file.extent))),
    #("hunks", json.Array(list.map(file.hunks, encode_hunk))),
  ])
}

/// A hunk as it travels.
fn encode_hunk(hunk: Hunk) -> JsonValue {
  json.Object([
    #("header", json.String(hunk.header)),
    #("omitted", json.Int(hunk.omitted)),
    #("shortened", json.Int(hunk.shortened)),
    #("lines", json.Array(list.map(hunk.lines, encode_line))),
  ])
}

/// A line as it travels: a kind letter, its two numbers when it has them, and
/// its text.
fn encode_line(line: diff_view.Line) -> JsonValue {
  json.Object(
    list.flatten([
      [#("k", json.String(kind_letter(line.kind)))],
      number_field("o", line.old),
      number_field("n", line.new),
      [#("t", json.String(line.text))],
    ]),
  )
}

/// A field that is present only when the number is.
fn number_field(
  name: String,
  value: Option(Int),
) -> List(#(String, JsonValue)) {
  case value {
    Some(number) -> [#(name, json.Int(number))]
    None -> []
  }
}

/// A stat read from its object.
fn decode_stat(value: JsonValue) -> Result(Stat, Nil) {
  use fields <- result.try(object(value))
  use files <- result.try(natural(fields, "files"))
  use added <- result.try(natural(fields, "added"))
  use removed <- result.map(natural(fields, "removed"))
  Stat(files:, added:, removed:)
}

/// A file read from its object, or nothing for one that is damaged or whose
/// path is not workspace-relative. Its hunks are cut to the bounds.
fn decode_file(value: JsonValue) -> Result(File, Nil) {
  use fields <- result.try(object(value))
  use path <- result.try(text(fields, "path"))
  use Nil <- result.try(
    bool.guard(!workspace_relative(path), Error(Nil), fn() { Ok(Nil) }),
  )
  use change <- result.try(text(fields, "change") |> result.try(parse_change))
  use section <- result.try(
    text(fields, "section") |> result.try(parse_section),
  )
  use content <- result.try(
    text(fields, "content") |> result.try(parse_content),
  )
  use added <- result.try(natural(fields, "added"))
  use removed <- result.try(natural(fields, "removed"))
  use hunks_omitted <- result.try(natural(fields, "hunks_omitted"))
  use extent <- result.try(text(fields, "extent") |> result.try(parse_extent))
  use raw <- result.try(array(fields, "hunks"))
  use hunks <- result.map(list.try_map(list.take(raw, max_hunks), decode_hunk))
  File(
    path:,
    change:,
    section:,
    content:,
    added:,
    removed:,
    hunks:,
    hunks_omitted:,
    extent:,
  )
}

/// A hunk read from its object. Its lines are cut to the bounds.
fn decode_hunk(value: JsonValue) -> Result(Hunk, Nil) {
  use fields <- result.try(object(value))
  use header <- result.try(text(fields, "header"))
  use omitted <- result.try(natural(fields, "omitted"))
  use shortened <- result.try(natural(fields, "shortened"))
  use raw <- result.try(array(fields, "lines"))
  use lines <- result.map(list.try_map(
    list.take(raw, max_hunk_lines),
    decode_line,
  ))
  Hunk(
    header: utf8_window.prefix(header, max_line_bytes),
    lines:,
    omitted:,
    shortened:,
  )
}

/// A line read from its object. Its text is cut to `max_line_bytes`.
fn decode_line(value: JsonValue) -> Result(diff_view.Line, Nil) {
  use fields <- result.try(object(value))
  use kind <- result.try(text(fields, "k") |> result.try(parse_kind))
  use body <- result.map(text(fields, "t"))
  diff_view.Line(
    kind:,
    old: option.from_result(natural(fields, "o")),
    new: option.from_result(natural(fields, "n")),
    text: utf8_window.prefix(body, max_line_bytes),
  )
}

/// The words each closed type travels as, and the readers that refuse a word
/// that is not one of them.
fn repository_word(repository: Repository) -> String {
  case repository {
    Head -> "head"
    Unborn -> "unborn"
    NotRepository -> "not_repository"
  }
}

/// The repository a wire word names, or nothing for any other word.
fn parse_repository(word: String) -> Result(Repository, Nil) {
  case word {
    "head" -> Ok(Head)
    "unborn" -> Ok(Unborn)
    "not_repository" -> Ok(NotRepository)
    _ -> Error(Nil)
  }
}

/// The wire word of a section.
fn section_word(section: Section) -> String {
  case section {
    Source -> "source"
    Tests -> "tests"
    Docs -> "docs"
  }
}

/// The section a wire word names, or nothing.
fn parse_section(word: String) -> Result(Section, Nil) {
  case word {
    "source" -> Ok(Source)
    "tests" -> Ok(Tests)
    "docs" -> Ok(Docs)
    _ -> Error(Nil)
  }
}

/// The wire word of a change.
fn change_word(change: Change) -> String {
  case change {
    Added -> "added"
    Modified -> "modified"
    Deleted -> "deleted"
  }
}

/// The change a wire word names, or nothing.
fn parse_change(word: String) -> Result(Change, Nil) {
  case word {
    "added" -> Ok(Added)
    "modified" -> Ok(Modified)
    "deleted" -> Ok(Deleted)
    _ -> Error(Nil)
  }
}

/// The wire word of a content kind.
fn content_word(content: Content) -> String {
  case content {
    Text -> "text"
    Binary -> "binary"
    NoNetChange -> "no_net_change"
    MetadataOnly -> "metadata_only"
  }
}

/// The content kind a wire word names, or nothing.
fn parse_content(word: String) -> Result(Content, Nil) {
  case word {
    "text" -> Ok(Text)
    "binary" -> Ok(Binary)
    "no_net_change" -> Ok(NoNetChange)
    "metadata_only" -> Ok(MetadataOnly)
    _ -> Error(Nil)
  }
}

fn extent_word(extent: Extent) -> String {
  case extent {
    Whole -> "whole"
    Cut -> "cut"
  }
}

/// The extent a wire word names, or nothing.
fn parse_extent(word: String) -> Result(Extent, Nil) {
  case word {
    "whole" -> Ok(Whole)
    "cut" -> Ok(Cut)
    _ -> Error(Nil)
  }
}

/// A line kind's letter. A hunk header and a file header are never carried as
/// lines, so they have none; a header that reached a line is written as
/// context, which `decode` reads back as context.
fn kind_letter(kind: diff_view.Kind) -> String {
  case kind {
    diff_view.Added -> "+"
    diff_view.Removed -> "-"
    diff_view.NoNewline -> "\\"
    diff_view.Context | diff_view.Hunk | diff_view.FileHeader -> " "
  }
}

/// The line kind a wire letter names, or nothing.
fn parse_kind(letter: String) -> Result(diff_view.Kind, Nil) {
  case letter {
    "+" -> Ok(diff_view.Added)
    "-" -> Ok(diff_view.Removed)
    "\\" -> Ok(diff_view.NoNewline)
    " " -> Ok(diff_view.Context)
    _ -> Error(Nil)
  }
}

/// The fields of an object.
fn object(value: JsonValue) -> Result(List(#(String, JsonValue)), Nil) {
  case value {
    json.Object(fields) -> Ok(fields)
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error(Nil)
  }
}

/// A string field.
fn text(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(String, Nil) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> Ok(value)
    Ok(_) | Error(Nil) -> Error(Nil)
  }
}

/// An array field.
fn array(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(List(JsonValue), Nil) {
  case list.key_find(fields, name) {
    Ok(json.Array(items)) -> Ok(items)
    Ok(_) | Error(Nil) -> Error(Nil)
  }
}

/// A nonnegative integer field.
fn natural(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(Int, Nil) {
  case list.key_find(fields, name) {
    Ok(json.Int(value)) if value >= 0 -> Ok(value)
    Ok(_) | Error(Nil) -> Error(Nil)
  }
}
