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
//// ## Whole-file binding: why a plan carries a digest
////
//// Per-line anchors alone cannot make "apply at most once" true. After
//// a `Delete`/`Replace` removes a line, an *identical* sibling line
//// (a blank line, a `}`, an `end`) can shift into the removed line's
//// number; its anchor still matches, so re-applying the same plan
//// would succeed and eat another line. No per-line scheme can
//// distinguish "identical sibling shifted into place" from "unchanged
//// line" — the two states are indistinguishable at every referenced
//// position. The only sound guarantee is a whole-file one: a `Plan`
//// carries the `digest` of the exact content it was computed against,
//// and `apply` rejects any content whose digest differs (after the
//// more precise per-line anchor check has had its say). This makes the
//// at-most-once guarantee total rather than heuristic: a plan applies
//// only to the one content it was planned against, so a replayed plan
//// — and a concurrent edit *anywhere* in the file, including strictly
//// inside a range hunk whose endpoints still match — is rejected
//// in-band with fresh anchors for replanning. The trade-off is
//// deliberate: a concurrent edit far from every hunk also rejects,
//// which costs one replan round trip and buys the impossibility of
//// silent double-application.
////
//// The digest is the full 16-hex FNV-1a 64 hash of the content bytes
//// plus the byte length (`hash-length`). Like anchors it is a
//// same-round-trip token, never stored durably, and versioned by
//// `anchor_version`. FNV is not collision resistant against an
//// adversary, but forging a digest collision here yields no authority:
//// the caller supplying the plan already holds unrestricted write
//// access to the same file, so the digest defends against *accidental*
//// double-apply (crash replay), where the appended length makes a
//// pre-image/post-image collision require equal FNV-64 *and* equal
//// byte length — and every deletion or size-changing edit differs in
//// length by construction.
////
//// Everything in this module is pure and total.

import gleam/bit_array
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

/// A multi-hunk edit plan bound to one exact file content.
///
/// Constructor invariants: `digest` is the `digest` of the content the
/// hunks were planned against — `apply` rejects any other content, so
/// a plan can apply at most once (see the module doc). Hunks may be
/// given in any order; `apply` sorts them and rejects overlaps.
pub type Plan {
  Plan(digest: String, hunks: List(Hunk))
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

  /// Every referenced anchor matches, but the whole-file digest does
  /// not: the content is not the exact content the plan was computed
  /// against. This is what a replayed plan looks like (an identical
  /// sibling line shifted into a referenced position), and what a
  /// concurrent edit strictly inside a range hunk looks like. Carries
  /// the current content's digest and fresh anchors for every region
  /// the plan touches, so a caller can replan without another read.
  StaleContent(digest: String, fresh: List(AnchoredLine))
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

/// The whole-file digest a `Plan` is bound to: the full 16-hex FNV-1a
/// 64 hash of the content's UTF-8 bytes, a `-`, and the byte length in
/// decimal. A same-round-trip token like anchors — opaque to callers,
/// never stored durably, versioned by `anchor_version`. The appended
/// length means a collision requires equal hash *and* equal byte
/// length (see the module doc for why this suffices).
///
/// ## Examples
///
/// ```gleam
/// assert hashline.digest("") == "cbf29ce484222325-0"
/// ```
///
pub fn digest(content: String) -> String {
  let bytes = <<content:utf8>>
  let hex =
    hash_loop(bytes, fnv_offset_basis)
    |> int.to_base16
    |> string.lowercase
    |> string.pad_start(to: 16, with: "0")
  hex <> "-" <> int.to_string(bit_array.byte_size(bytes))
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
/// every referenced anchor is checked against the current content, then
/// the whole-file digest is checked against the plan's `digest` — *any*
/// stale reference (or a digest mismatch) rejects the whole edit with
/// fresh anchors for replanning; partial application never happens. On
/// success the result is byte-exact: untouched lines, line endings, and
/// the trailing-newline state are preserved.
///
/// Applying is deterministic: equal content and plan always produce the
/// same result. And the digest binding makes application *at most
/// once*: a plan applies only to the exact content it was planned
/// against, so re-applying a plan to its own output rejects — even
/// when the edited lines have identical siblings that shifted into the
/// referenced positions — which is what makes `fs_edit` safe to replay
/// after a crash. (A hunk whose replacement equals the removed lines
/// re-applies, but such an application is the identity and cannot
/// corrupt.) The digest also verifies range interiors: a concurrent
/// edit strictly inside a `Replace`/`Delete` range, invisible to the
/// endpoint anchors, still rejects.
///
/// ## Examples
///
/// ```gleam
/// let ref = hashline.Ref(line: 1, anchor: hashline.anchor("old"))
/// let plan =
///   hashline.Plan(hashline.digest("old\n"), [hashline.Replace(ref, ref, ["new"])])
/// assert hashline.apply("old\n", plan) == Ok("new\n")
/// ```
///
pub fn apply(content: String, plan: Plan) -> Result(String, ApplyError) {
  let split = split_lines(content)
  let total_lines = list.length(split.lines)
  case malformed_reason(plan) {
    [reason, ..] -> Error(MalformedPlan(reason:))
    [] -> apply_checked(content, plan, split, total_lines)
  }
}

// Structural checks passed; verify the anchors the plan referenced are
// still current before comparing against the whole-file digest.
fn apply_checked(
  content: String,
  plan: Plan,
  split: Split,
  total_lines: Int,
) -> Result(String, ApplyError) {
  let annotated = annotate(content)
  case stale_references(plan, annotated, total_lines) {
    [_, ..] as stale -> Error(StaleAnchors(stale:))
    [] -> apply_if_current(content, plan, split, annotated, total_lines)
  }
}

// Anchors matched; the digest is the coarser check that also catches
// changes an anchored reference cannot see (a shift outside every
// hunk's context, for instance).
fn apply_if_current(
  content: String,
  plan: Plan,
  split: Split,
  annotated: List(AnchoredLine),
  total_lines: Int,
) -> Result(String, ApplyError) {
  case digest(content) == plan.digest {
    False ->
      Error(StaleContent(
        digest: digest(content),
        fresh: touched_regions(plan, annotated, total_lines),
      ))
    True -> apply_hunks(split, plan)
  }
}

// Content is exactly the pre-image the plan was computed against; the
// last possible rejection is two hunks touching the same line.
fn apply_hunks(split: Split, plan: Plan) -> Result(String, ApplyError) {
  let placed = list.map(plan.hunks, place)
  case overlap(placed) {
    Ok(line) -> Error(OverlappingHunks(line:))
    Error(Nil) -> Ok(apply_placed(split, placed))
  }
}

// The current content's anchored lines for every region a plan
// touches (each hunk's full range plus context), in line order.
fn touched_regions(
  plan: Plan,
  annotated: List(AnchoredLine),
  total_lines: Int,
) -> List(AnchoredLine) {
  let ranges =
    list.map(plan.hunks, fn(hunk) {
      let placed = place(hunk)
      #(
        int.max(placed.start - fresh_context_lines, 1),
        int.min(placed.end + fresh_context_lines, total_lines),
      )
    })
  list.filter(annotated, fn(anchored) {
    list.any(ranges, fn(range) {
      anchored.line >= range.0 && anchored.line <= range.1
    })
  })
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

// The references a hunk carries. Range hunks reference their
// endpoints only — interior lines have no caller-supplied anchors and
// are verified by the whole-file digest check instead.
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

/// Renders a plan's hunks against the content they were applied to as
/// a unified diff — one `@@` section per hunk, each with up to three
/// lines of context, `-` for the lines a hunk removed and `+` for the
/// lines it added — so a transcript can show what an edit did rather
/// than how many hunks it had. Hunks render in file order whatever order
/// the plan gave them; the new-side line numbers account for the hunks
/// above. Callers hand this the *pre-image* (the content `apply` was
/// given), since that is the side the hunks' references name.
///
/// ## Examples
///
/// ```gleam
/// hashline.render_diff("a\nb\nc\n", [
///   hashline.Replace(
///     from: hashline.Ref(2, "..."),
///     to: hashline.Ref(2, "..."),
///     lines: ["B"],
///   ),
/// ])
/// // -> "@@ -1,3 +1,3 @@\n a\n-b\n+B\n c"
/// ```
///
pub fn render_diff(content: String, hunks: List(Hunk)) -> String {
  let lines = split_lines(content).lines
  let total = list.length(lines)
  let ascending =
    hunks
    |> list.map(place)
    |> list.sort(fn(a, b) { int.compare(a.start, b.start) })
  let #(sections, _offset) =
    list.fold(ascending, #([], 0), fn(folded, placed) {
      let #(sections, offset) = folded
      let section = diff_section(lines, total, placed, offset)
      let grown = list.length(placed.replacement) - removed_count(placed)
      #([section, ..sections], offset + grown)
    })
  sections |> list.reverse |> string.join("\n")
}

/// How many lines of unchanged context a rendered hunk shows on each side.
pub const diff_context_lines = 3

fn removed_count(placed: Placed) -> Int {
  case placed.insert {
    True -> 0
    False -> placed.end - placed.start + 1
  }
}

// One `@@` section. An insertion sits after `start` (or before line 1
// when `start` is 0) and removes nothing; a replacement or deletion
// removes `[start, end]`. Context is clipped to the file.
fn diff_section(
  lines: List(String),
  total: Int,
  placed: Placed,
  offset: Int,
) -> String {
  // Where the change begins on the old side: the first removed line, or
  // for an insertion the line the new text lands in front of.
  let removed = removed_count(placed)
  let first_removed = case placed.insert {
    True -> placed.start + 1
    False -> placed.start
  }

  // Three slices of the pre-image: the context above, the lines the hunk
  // took out, the context below; each clipped to the file's edges.
  let before_from = int.max(first_removed - diff_context_lines, 1)
  let after_to =
    int.min(first_removed + removed - 1 + diff_context_lines, total)
  let before = slice_lines(lines, before_from, first_removed - 1)
  let gone = slice_lines(lines, first_removed, first_removed + removed - 1)
  let after = slice_lines(lines, first_removed + removed, after_to)

  // The header counts each side's lines; the new side starts where the
  // old did plus whatever the hunks above this one grew the file by.
  let old_count = list.length(before) + removed + list.length(after)
  let new_count =
    list.length(before) + list.length(placed.replacement) + list.length(after)
  let header =
    "@@ -"
    <> int.to_string(before_from)
    <> ","
    <> int.to_string(old_count)
    <> " +"
    <> int.to_string(before_from + offset)
    <> ","
    <> int.to_string(new_count)
    <> " @@"
  [
    [header],
    list.map(before, fn(line) { " " <> line }),
    list.map(gone, fn(line) { "-" <> line }),
    list.map(placed.replacement, fn(line) { "+" <> line }),
    list.map(after, fn(line) { " " <> line }),
  ]
  |> list.flatten
  |> string.join("\n")
}

// The 1-based inclusive range `[from, to]` of `lines`; empty when the
// range is.
fn slice_lines(lines: List(String), from: Int, to: Int) -> List(String) {
  case to < from {
    True -> []
    False -> lines |> list.drop(from - 1) |> list.take(to - from + 1)
  }
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
