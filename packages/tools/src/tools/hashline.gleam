//// The pure hashline core: content-hash line anchors, windowed views,
//// and anchor-checked multi-hunk edit plans (design §5.4, WP-I).
////
//// Reads render every line with an **anchor** — a short hash of the
//// line's content. Edits reference lines as `{line, anchor}` pairs;
//// `apply` verifies every referenced anchor against the *current*
//// content before touching anything, so an edit planned against a file
//// that has since changed is rejected before corruption — a TOCTOU
//// defense between read and write. The rejection is structured and
//// carries fresh anchors for the stale regions, so a caller can replan
//// without another full read.
////
//// ## The anchor algorithm (version 1, package-internal)
////
//// An anchor is the first 8 lowercase hex characters of a 64-bit
//// FNV-1a hash of the line's UTF-8 bytes. The implementation spec
//// names `xxh3(content)[:8]`; that names the intent — a fast 64-bit
//// content hash truncated to 8 hex characters — not a wire contract:
//// anchors never leave a single read/edit round trip, are never stored
//// durably, and are versioned by `anchor_version` so the algorithm can
//// change without protocol impact. FNV-1a is used because it is a few
//// integer operations per byte in pure Gleam; xxh3 would need native
//// code for no observable benefit at 8-hex truncation. Recorded as a
//// spec gap.
////
//// Anchors depend only on line *content*: unrelated edits elsewhere in
//// the file never change a line's anchor (though they may change its
//// line number, which is why references carry both and both are
//// checked). Two identical lines share an anchor; the line number
//// disambiguates.
////
//// Everything in this module is pure and total.

import gleam/int
import gleam/list
import gleam/string

/// The anchor algorithm version. Bump when the hash or rendering
/// changes; `fs_read` reports it in details so an edit planned against
/// one version is never checked against another.
pub const anchor_version = 1

/// How many context lines are reported around each stale anchor in a
/// rejection.
pub const fresh_context_lines = 2

// FNV-1a 64-bit parameters (Fowler–Noll–Vo, the 1a byte order).
const fnv_offset_basis = 0xCBF29CE484222325

const fnv_prime = 0x100000001B3

const mask_64 = 0xFFFFFFFFFFFFFFFF

/// One line with its position and anchor. `line` is 1-based.
pub type AnchoredLine {
  AnchoredLine(line: Int, anchor: String, text: String)
}

/// A reference to one line by position and content anchor. Both are
/// checked on apply: the anchor proves the content, the line number
/// disambiguates identical lines.
pub type Ref {
  Ref(line: Int, anchor: String)
}

/// Content split into lines plus whether the original ended with a
/// newline, so `join_lines` is byte-exact. Lines never contain `\n`; a
/// CRLF file keeps each `\r` at the end of its line content.
pub type Split {
  Split(lines: List(String), trailing_newline: Bool)
}

/// One edit hunk. Ranges are inclusive; `lines` are replacement lines
/// without newlines.
pub type Hunk {
  /// Replaces the inclusive range `[from, to]` with `lines`.
  Replace(from: Ref, to: Ref, lines: List(String))
  /// Deletes the inclusive range `[from, to]`.
  Delete(from: Ref, to: Ref)
  /// Inserts `lines` immediately after the anchored line.
  InsertAfter(at: Ref, lines: List(String))
  /// Inserts `lines` before the first line of the file.
  InsertAtStart(lines: List(String))
}

/// A multi-hunk edit plan. Hunks may be given in any order; `apply`
/// sorts them and rejects overlaps.
pub type Plan {
  Plan(hunks: List(Hunk))
}

/// One stale reference in a rejection: where the plan pointed, what it
/// expected, and fresh anchors for the surrounding region of the
/// *current* content.
pub type Stale {
  Stale(line: Int, expected: String, fresh: List(AnchoredLine))
}

/// Why a plan was rejected. Rejections are data for the model; nothing
/// here crashes.
pub type ApplyError {
  /// A hunk is structurally invalid independent of content: an inverted
  /// range, a line number below 1, or a replacement line containing a
  /// newline.
  MalformedPlan(reason: String)
  /// Two hunks touch the same lines (or an insertion point inside
  /// another hunk's range); the edit is ambiguous.
  OverlappingHunks(line: Int)
  /// At least one referenced anchor does not match the current content
  /// — the file changed since it was read (or the reference is beyond
  /// the end of the file). Every stale reference is listed, each with
  /// fresh anchors for its region.
  StaleAnchors(stale: List(Stale))
}

/// The anchor of one line's content.
///
/// ## Examples
///
/// ```gleam
/// assert hashline.anchor("") == "cbf29ce4"
/// ```
///
pub fn anchor(line: String) -> String {
  hash_64(line)
  |> int.to_base16
  |> string.lowercase
  |> string.pad_start(to: 16, with: "0")
  |> string.slice(at_index: 0, length: 8)
}

// FNV-1a over the UTF-8 bytes of the line.
fn hash_64(line: String) -> Int {
  hash_loop(<<line:utf8>>, fnv_offset_basis)
}

fn hash_loop(bytes: BitArray, accumulator: Int) -> Int {
  case bytes {
    <<byte, rest:bytes>> ->
      hash_loop(
        rest,
        int.bitwise_and(
          int.bitwise_exclusive_or(accumulator, byte) * fnv_prime,
          mask_64,
        ),
      )
    // UTF-8 encoding is always byte-aligned, so the only other shape is
    // the empty array.
    _ -> accumulator
  }
}

/// Splits content into lines on `\n`, remembering whether a trailing
/// newline was present.
///
/// ## Examples
///
/// ```gleam
/// assert hashline.split_lines("a\nb\n")
///   == hashline.Split(lines: ["a", "b"], trailing_newline: True)
/// ```
///
/// ```gleam
/// assert hashline.split_lines("")
///   == hashline.Split(lines: [], trailing_newline: False)
/// ```
///
pub fn split_lines(content: String) -> Split {
  case content {
    "" -> Split(lines: [], trailing_newline: False)
    _ -> {
      let segments = string.split(content, on: "\n")
      case list.reverse(segments) {
        ["", ..rest] -> Split(lines: list.reverse(rest), trailing_newline: True)
        _ -> Split(lines: segments, trailing_newline: False)
      }
    }
  }
}

/// Rejoins a split byte-exactly: `join_lines(split_lines(c)) == c`.
///
/// ## Examples
///
/// ```gleam
/// assert hashline.join_lines(hashline.split_lines("a\r\nb")) == "a\r\nb"
/// ```
///
pub fn join_lines(split: Split) -> String {
  let joined = string.join(split.lines, with: "\n")
  case split.trailing_newline {
    True -> joined <> "\n"
    False -> joined
  }
}

/// Every line of `content` with its 1-based number and anchor.
///
/// ## Examples
///
/// ```gleam
/// let [first] = hashline.annotate("hi")
/// assert first.line == 1 && first.text == "hi"
/// ```
///
pub fn annotate(content: String) -> List(AnchoredLine) {
  split_lines(content).lines
  |> list.index_map(fn(text, index) {
    AnchoredLine(line: index + 1, anchor: anchor(text), text:)
  })
}

/// A windowed view over content: the anchored lines of the window plus
/// enough shape information to page through the whole file.
pub type Window {
  Window(
    /// The window's anchored lines, in order.
    lines: List(AnchoredLine),
    /// Total lines in the content.
    total_lines: Int,
    /// The 1-based line number the window starts at (clamped).
    offset: Int,
    /// Whether lines exist beyond the end of this window.
    has_more: Bool,
    /// Whether the content ends with a newline.
    trailing_newline: Bool,
  )
}

/// A window of at most `limit` anchored lines starting at 1-based line
/// `offset`. Offsets below 1 clamp to 1; offsets past the end yield an
/// empty window; a non-positive limit yields an empty window at the
/// clamped offset.
///
/// ## Examples
///
/// ```gleam
/// let window = hashline.window("a\nb\nc", offset: 2, limit: 1)
/// assert window.total_lines == 3 && window.has_more == True
/// ```
///
pub fn window(content: String, offset offset: Int, limit limit: Int) -> Window {
  let split = split_lines(content)
  let total_lines = list.length(split.lines)
  let offset = int.max(offset, 1)
  let limit = int.max(limit, 0)
  let lines =
    annotate(content)
    |> list.drop(offset - 1)
    |> list.take(limit)
  Window(
    lines:,
    total_lines:,
    offset:,
    has_more: offset - 1 + limit < total_lines,
    trailing_newline: split.trailing_newline,
  )
}

/// Renders a window as `line:anchor|text` lines — the read
/// representation edits reference.
///
/// ## Examples
///
/// ```gleam
/// assert hashline.render(hashline.window("hi", offset: 1, limit: 10))
///   == "1:" <> hashline.anchor("hi") <> "|hi"
/// ```
///
pub fn render(window_value: Window) -> String {
  window_value.lines
  |> list.map(render_line)
  |> string.join(with: "\n")
}

/// Renders one anchored line as `line:anchor|text`.
pub fn render_line(anchored: AnchoredLine) -> String {
  int.to_string(anchored.line) <> ":" <> anchored.anchor <> "|" <> anchored.text
}

// --- applying edit plans -------------------------------------------------

// A hunk normalized for validation and splicing. For replaces/deletes
// `start..end` is the inclusive removed range and `insert` is False;
// for insertions `start == end` names the line the insertion follows
// (0 for the start of the file) and `insert` is True.
type Placed {
  Placed(start: Int, end: Int, insert: Bool, replacement: List(String))
}

/// Applies a plan to content. Verification comes first and is total:
/// every referenced anchor is checked against the current content, and
/// *any* stale reference rejects the whole edit with fresh anchors for
/// each stale region — partial application never happens. On success
/// the result is byte-exact: untouched lines, line endings, and the
/// trailing-newline state are preserved.
///
/// Applying is deterministic: equal content and plan always produce the
/// same result. Re-applying a plan to its own output rejects (the
/// replaced lines' anchors are gone), which is what makes `fs_edit`
/// safe to replay after a crash: a re-execution cannot double-apply.
///
/// ## Examples
///
/// ```gleam
/// let ref = hashline.Ref(line: 1, anchor: hashline.anchor("old"))
/// let plan = hashline.Plan([hashline.Replace(ref, ref, ["new"])])
/// assert hashline.apply("old\n", plan) == Ok("new\n")
/// ```
///
pub fn apply(content: String, plan: Plan) -> Result(String, ApplyError) {
  let split = split_lines(content)
  let total_lines = list.length(split.lines)
  case malformed_reason(plan) {
    [reason, ..] -> Error(MalformedPlan(reason:))
    [] -> {
      let annotated = annotate(content)
      case stale_references(plan, annotated, total_lines) {
        [_, ..] as stale -> Error(StaleAnchors(stale:))
        [] -> {
          let placed = list.map(plan.hunks, place)
          case overlap(placed) {
            Ok(line) -> Error(OverlappingHunks(line:))
            Error(Nil) -> Ok(apply_placed(split, placed))
          }
        }
      }
    }
  }
}

// Structural problems, checked before any content comparison.
fn malformed_reason(plan: Plan) -> List(String) {
  list.flat_map(plan.hunks, fn(hunk) {
    let range_problems = case hunk {
      Replace(from:, to:, lines: _) | Delete(from:, to:) ->
        case from.line < 1, from.line > to.line {
          True, _ -> ["line numbers start at 1"]
          False, True -> [
            "range "
            <> int.to_string(from.line)
            <> ".."
            <> int.to_string(to.line)
            <> " is inverted",
          ]
          False, False -> []
        }
      InsertAfter(at:, lines: _) ->
        case at.line < 1 {
          True -> ["line numbers start at 1"]
          False -> []
        }
      InsertAtStart(lines: _) -> []
    }
    let newline_problems = case hunk {
      Replace(from: _, to: _, lines:)
      | InsertAfter(at: _, lines:)
      | InsertAtStart(lines:) ->
        case list.any(lines, string.contains(_, "\n")) {
          True -> ["replacement lines must not contain newlines"]
          False -> []
        }
      Delete(from: _, to: _) -> []
    }
    list.append(range_problems, newline_problems)
  })
}

// Every reference whose anchor does not match the current content,
// including references past the end of the file (a shrink is also a
// concurrent modification).
fn stale_references(
  plan: Plan,
  annotated: List(AnchoredLine),
  total_lines: Int,
) -> List(Stale) {
  plan.hunks
  |> list.flat_map(refs)
  |> list.filter_map(fn(ref) {
    let current =
      list.find(annotated, fn(anchored) { anchored.line == ref.line })
    let matches = case current {
      Ok(anchored) -> anchored.anchor == ref.anchor
      Error(Nil) -> False
    }
    case matches {
      True -> Error(Nil)
      False ->
        Ok(Stale(
          line: ref.line,
          expected: ref.anchor,
          fresh: fresh_region(annotated, ref.line, total_lines),
        ))
    }
  })
}

fn refs(hunk: Hunk) -> List(Ref) {
  case hunk {
    Replace(from:, to:, lines: _) | Delete(from:, to:) ->
      case from == to {
        True -> [from]
        False -> [from, to]
      }
    InsertAfter(at:, lines: _) -> [at]
    InsertAtStart(lines: _) -> []
  }
}

// Fresh anchors around a stale line, clamped to the file.
fn fresh_region(
  annotated: List(AnchoredLine),
  line: Int,
  total_lines: Int,
) -> List(AnchoredLine) {
  let first = int.max(int.min(line, total_lines) - fresh_context_lines, 1)
  let last = int.min(line + fresh_context_lines, total_lines)
  list.filter(annotated, fn(anchored) {
    anchored.line >= first && anchored.line <= last
  })
}

fn place(hunk: Hunk) -> Placed {
  case hunk {
    Replace(from:, to:, lines:) ->
      Placed(start: from.line, end: to.line, insert: False, replacement: lines)
    Delete(from:, to:) ->
      Placed(start: from.line, end: to.line, insert: False, replacement: [])
    InsertAfter(at:, lines:) ->
      Placed(start: at.line, end: at.line, insert: True, replacement: lines)
    InsertAtStart(lines:) ->
      Placed(start: 0, end: 0, insert: True, replacement: lines)
  }
}

// First overlapping line between any two hunks, if any. Two removal
// ranges conflict when they intersect; an insertion conflicts when its
// anchor line sits inside another hunk's removal range, or when two
// insertions share the same point. Strict by design: an ambiguous plan
// is rejected rather than guessed at — a single Replace hunk can always
// express the intent unambiguously.
fn overlap(placed: List(Placed)) -> Result(Int, Nil) {
  let pairs = distinct_pairs(placed)
  list.find_map(pairs, fn(pair) {
    let #(a, b) = pair
    case a.insert, b.insert {
      False, False ->
        case a.start <= b.end && b.start <= a.end {
          True -> Ok(int.max(a.start, b.start))
          False -> Error(Nil)
        }
      True, True ->
        case a.start == b.start {
          True -> Ok(a.start)
          False -> Error(Nil)
        }
      True, False ->
        case b.start <= a.start && a.start <= b.end {
          True -> Ok(a.start)
          False -> Error(Nil)
        }
      False, True ->
        case a.start <= b.start && b.start <= a.end {
          True -> Ok(b.start)
          False -> Error(Nil)
        }
    }
  })
}

fn distinct_pairs(placed: List(Placed)) -> List(#(Placed, Placed)) {
  case placed {
    [] -> []
    [first, ..rest] ->
      list.append(
        list.map(rest, fn(other) { #(first, other) }),
        distinct_pairs(rest),
      )
  }
}

// Splices bottom-up so earlier hunks' line numbers stay valid. The
// overlap rules guarantee all start positions are distinct, so the
// descending order is unambiguous.
fn apply_placed(split: Split, placed: List(Placed)) -> String {
  let descending = list.sort(placed, fn(a, b) { int.compare(b.start, a.start) })
  let lines =
    list.fold(descending, split.lines, fn(lines, hunk) {
      case hunk.insert {
        True ->
          splice(lines, at: hunk.start, remove: 0, insert: hunk.replacement)
        False ->
          splice(
            lines,
            at: hunk.start - 1,
            remove: hunk.end - hunk.start + 1,
            insert: hunk.replacement,
          )
      }
    })
  // An edit that grows an empty file produces a trailing newline; any
  // other edit preserves the original ending byte-exactly.
  let trailing_newline = case split.lines, lines {
    [], [_, ..] -> True
    _, _ -> split.trailing_newline
  }
  join_lines(Split(lines:, trailing_newline:))
}

// Replaces `remove` lines at 0-based index `at` with `insert`.
fn splice(
  lines: List(String),
  at index: Int,
  remove count: Int,
  insert replacement: List(String),
) -> List(String) {
  let #(before, rest) = list.split(lines, index)
  let after = list.drop(rest, count)
  list.flatten([before, replacement, after])
}
