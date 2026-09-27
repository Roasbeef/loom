//// The rows of a live answer, built from what changed since the last frame.
////
//// A streaming answer is one transcript line whose text grows with every
//// delta, and `render.render_line` turns it into rows by sanitizing the
//// whole text, parsing it as Markdown and word-wrapping every paragraph. Doing
//// that on every frame made a frame cost the length of the answer so far: at
//// four thousand deltas a frame cost nine times what it did at the start.
////
//// This module keeps what an earlier frame already decided and redoes only
//// the part the new text can still change:
////
//// - **Settled blocks.** Markdown blocks separated by a blank line do not
////   see each other, so the rows of a block that is closed are final. Once a
////   blank line is followed by a line starting with a letter, the text before
////   the blank line is rendered on its own, its rows are finished and kept,
////   and later frames never parse it again.
//// - **Sanitizing.** `text_hygiene.unchanged_prefix` says how much of the
////   text the hygiene pass leaves as it is. That part is checked once, as it
////   arrives, and is then used as it stands.
//// - **The tail.** The text after the settled blocks is parsed on every
////   frame, because a later delta can still change how it parses. Its lines
////   are wrapped against the previous frame's: an unchanged line keeps its
////   rows, and a paragraph that only grew is re-wrapped from its last row
////   (`markdown.rewrap`).
//// - **A paragraph's checkpoint.** An answer written as one long paragraph
////   never settles, so the tail's opening paragraph keeps a checkpoint: the
////   line its plain leading lines parse into. Only the text after the
////   checkpoint is parsed, and its first line is joined to the checkpoint's
////   (`markdown.join_soft_break`). The conditions that make the join exact
////   are on `Head`.
////
//// The sanitizing shortcut, and every shortcut after it, stops at the first
//// byte the hygiene pass rewrites. From there on `unchanged_to` never
//// advances, so for the rest of that stream the tail is sanitized, parsed and
//// wrapped from the last settled block on every frame, as before this cache
//// existed. A tab is enough to trigger it, so a fenced Go block or Makefile
//// in an answer turns the shortcuts off for everything after it.
////
//// The result must be byte for byte the rows `render_line` would give, since
//// replay goldens compare frames exactly. Each part has its reason for being
//// exact written where the part is built, and `test/live_tail_test.gleam`
//// checks the whole against a full render over generated streams. What is
//// not provably safe falls back to the full render: a stream that stopped
//// being an extension of the last one, a changed width, and text holding a
//// reference definition or a footnote, whose meaning reaches across blocks.
////
//// The cache holds no copy of the answer's text. The stream is recognised
//// by its fragment list, which the model keeps anyway; the settled rows are
//// the rows the projection draws; and positions in the text are byte
//// offsets. What it does keep beside the drawn rows is the tail's lines from
//// the last frame, which a paragraph's re-wrap is checked against.

import etui/span
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import session_view/text_hygiene
import session_view/transcript_line.{type Speaker}
import tui/markdown

/// Whether a run of finished rows opens its transcript line or continues
/// one: the first row of a line carries the speaker's mark and every other
/// row the gutter, so the settled rows and the tail are finished apart.
pub type RowRun {
  /// The run's first row is the line's first row.
  OpensLine

  /// Rows of the same line precede the run.
  ContinuesLine
}

/// How one speaker's Markdown becomes rows, as `render` defines it: the
/// width its body is wrapped to, and the step that adds marks and shading
/// to wrapped rows.
pub type Layout {
  Layout(
    /// The cells the body is wrapped to (`render.markdown_room`).
    room: Int,
    /// Marks and shades wrapped rows (`render.finish_markdown_rows`).
    finish: fn(List(span.Line), RowRun) -> List(span.Line),
  )
}

/// What the live tail kept from the last projection, one slot per speaker
/// whose line was live then.
pub opaque type Cache {
  Cache(slots: List(Slot))
}

// One live line's state, as the last frame left it. Offsets are bytes of
// the raw answer, and every one of them falls on a character boundary.
type Slot {
  Slot(
    speaker: Speaker,
    // The wrap width the rows were built for. A resize changes it and
    // starts the slot over, since every row depends on it.
    room: Int,
    // The stream's fragments, newest first, as the last frame read them.
    // The model prepends a delta to this very list, so an answer that only
    // grew still holds it as its tail.
    fragments: List(String),
    count: Int,
    // Where the tail starts: the bytes before it are settled.
    tail_from: Int,
    // Where the text the hygiene pass leaves unchanged ends. Every byte
    // from `tail_from` to here has been checked and needs no sanitizing.
    unchanged_to: Int,
    // Where the search for a settle point resumes.
    scanned: Int,
    // The finished rows of the settled blocks, in order.
    settled: List(span.Line),
    // Each line of the last tail render with the rows it wrapped into.
    memo: List(#(span.Line, List(span.Line))),
    // The open paragraph's checkpoint, if the tail has one.
    head: Head,
    // How far past the checkpoint the text has been read for the
    // conditions a checkpoint needs, and whether they still hold there.
    plain_to: Int,
    plain: Plain,
    // How many frames in a row have continued this slot rather than
    // starting it over. Nothing reads it but `shortcuts`.
    carried: Int,
  )
}

// A checkpoint in the paragraph the tail opens with: the text from
// `tail_from` to `at` is whole lines of that paragraph, and `line` is the
// line they parse into. The rest of the paragraph is parsed on each frame
// and joined to `line` (`markdown.join_soft_break`) instead of the whole
// paragraph being parsed again.
//
// The join is exact because nothing on either side can reach the other:
//
// - The text before `at` holds no character that opens or closes inline
//   Markdown (`*`, `_`, a backtick, `~`, `=`, a bracket, `<`, `>`, `|` or a
//   backslash), no `&`, no hard break and no blank line, so no later
//   delimiter can pair with anything in it and it is one run of paragraph
//   lines.
// - The line at `at` starts with an ASCII letter, so parsed on its own it
//   opens a paragraph, as it continues one in the whole; and no emphasis
//   rule reads the character before it, which is a line feed either way.
// - No line after `at` is a setext underline, which would turn the whole
//   paragraph into a heading, or holds a `|`, which could turn a line into
//   a table header. Those are checked on every frame; the first time either
//   appears the checkpoint is dropped and the tail is parsed whole.
//
// A reference definition or footnote anywhere makes the tail unsplittable
// before any of this is reached.
type Head {
  NoHead
  Head(at: Int, line: span.Line)
}

// Whether the text past `plain_to` may still become checkpoint text. Once a
// character or line that bars it is read, the checkpoint stays where it is
// until the tail moves on.
type Plain {
  Readable
  Barred
}

/// A cache holding nothing, which renders the next frame in full.
///
/// ## Examples
///
/// ```gleam
/// let cache = live_tail.new()
/// ```
pub fn new() -> Cache {
  Cache([])
}

/// One projection's live lines, rendered and remembered for the next.
///
/// A projection draws its live lines between `begin` and `finish`: `begin`
/// hands over what the last projection kept, `rows` renders each live line
/// against it, and `finish` keeps only the slots this projection used, so an
/// answer that has ended releases its rows at the next projection.
pub opaque type Pass {
  Pass(previous: List(Slot), used: List(Slot))
}

/// Starts a projection's pass over its live lines.
///
/// ## Examples
///
/// ```gleam
/// let pass = live_tail.begin(model.live_tail)
/// ```
pub fn begin(cache: Cache) -> Pass {
  Pass(previous: cache.slots, used: [])
}

/// What the cache is holding, for tests that must show a shortcut was
/// taken: the settled rows across its slots, the furthest paragraph
/// checkpoint as a byte offset (zero when no slot has one), and the most
/// frames in a row any slot was continued rather than started over.
///
/// ## Examples
///
/// ```gleam
/// let #(settled, checkpoint, carried) = live_tail.shortcuts(cache)
/// ```
@internal
pub fn shortcuts(cache: Cache) -> #(Int, Int, Int) {
  list.fold(cache.slots, #(0, 0, 0), fn(acc, slot) {
    let at = case slot.head {
      Head(at:, ..) -> at
      NoHead -> 0
    }
    #(
      acc.0 + list.length(slot.settled),
      int.max(acc.1, at),
      int.max(acc.2, slot.carried),
    )
  })
}

/// Ends a pass, keeping the slots it used.
///
/// ## Examples
///
/// ```gleam
/// let cache = live_tail.finish(pass)
/// ```
pub fn finish(pass: Pass) -> Cache {
  Cache(pass.used)
}

/// The rows `render.render_line(Line(speaker, text), width)` gives, for a
/// live line whose text is its stream's `fragments` joined oldest first.
///
/// `fragments` is the stream's list as the model holds it, newest first.
/// The caller builds `text` from it and must pass both, because the list is
/// what proves the text only grew since the last frame and the text is what
/// is drawn.
///
/// ## Examples
///
/// ```gleam
/// let #(rows, pass) =
///   live_tail.rows(pass, Assistant, text, stream.fragments, layout)
/// ```
pub fn rows(
  pass: Pass,
  speaker: Speaker,
  text: String,
  fragments: List(String),
  layout: Layout,
) -> #(List(span.Line), Pass) {
  let count = list.length(fragments)
  let slot =
    list.find(pass.previous, fn(slot) { slot.speaker == speaker })
    |> result.try(fn(slot) {
      case slot.room == layout.room && extends(fragments, count, slot) {
        True -> Ok(Slot(..slot, fragments:, count:, carried: slot.carried + 1))
        False -> Error(Nil)
      }
    })
    |> result.lazy_unwrap(fn() { fresh(speaker, fragments, count, layout) })
  let #(drawn, kept) =
    render_slot(slot, text, layout)
    |> result.lazy_unwrap(fn() {
      #(full_rows(text, layout), fresh(speaker, fragments, count, layout))
    })
  #(drawn, Pass(..pass, used: [kept, ..pass.used]))
}

// A stream only grew if the fragments the slot saw are still the oldest ones:
// dropping the new ones leaves the very list the slot kept. The comparison is
// physical identity in the common case, so it costs the number of new
// fragments. A replaced operation, a collapse to the newest bytes or a
// different stream all fail it.
fn extends(fragments: List(String), count: Int, slot: Slot) -> Bool {
  count >= slot.count
  && list.drop(fragments, count - slot.count) == slot.fragments
}

fn fresh(
  speaker: Speaker,
  fragments: List(String),
  count: Int,
  layout: Layout,
) -> Slot {
  Slot(
    speaker:,
    room: layout.room,
    fragments:,
    count:,
    tail_from: 0,
    unchanged_to: 0,
    scanned: 0,
    settled: [],
    memo: [],
    head: NoHead,
    plain_to: 0,
    plain: Readable,
    carried: 0,
  )
}

// The whole line rendered from scratch: what `render.render_line` does for
// a Markdown speaker, and what every fallback here draws.
fn full_rows(text: String, layout: Layout) -> List(span.Line) {
  [
    span.line_plain(""),
    ..markdown.render(text, layout.room)
    |> markdown.wrap_lines(layout.room)
    |> layout.finish(OpensLine)
  ]
}

// One frame of a slot. An error means the text cannot be split safely and
// the caller draws it in full.
fn render_slot(
  slot: Slot,
  text: String,
  layout: Layout,
) -> Result(#(List(span.Line), Slot), Nil) {
  let bits = bit_array.from_string(text)
  let size = bit_array.byte_size(bits)
  use unread <- result.try(text_from(text, bits, slot.unchanged_to))
  let slot =
    Slot(
      ..slot,
      unchanged_to: slot.unchanged_to + text_hygiene.unchanged_prefix(unread),
    )
  use raw_tail <- result.try(text_from(text, bits, slot.tail_from))

  // The checked prefix is kept as it stands, so a tail the hygiene pass
  // leaves unchanged is used without being rebuilt; otherwise the pass runs
  // over the tail, which `unchanged_prefix` says gives the same text.
  let tail = case slot.unchanged_to == size {
    True -> raw_tail
    False -> text_hygiene.multiline(raw_tail)
  }
  use Nil <- result.try(splittable(tail))

  // The tail is the only part parsed on this frame, and of its opening
  // paragraph only what follows the checkpoint. Its lines are wrapped
  // against the last frame's, which is where a growing paragraph saves its
  // re-wrap.
  let #(lines, slot) = tail_lines(slot, text, bits, tail, layout)
  let memo = wrapped(lines, slot.memo, layout.room)
  let tail_rows =
    memo
    |> list.flat_map(fn(pair) { pair.1 })
    |> layout.finish(run(slot))
  let drawn = [span.line_plain(""), ..list.append(slot.settled, tail_rows)]
  let settled = settle(Slot(..slot, memo:), bits, layout)

  // A checkpoint is placed against this frame's parse of the tail, which a
  // settle has just shortened; the next frame parses the new tail.
  let settled = case settled.tail_from == slot.tail_from {
    True -> checkpoint(settled, text, bits, lines, layout)
    False -> settled
  }
  Ok(#(drawn, settled))
}

// The tail's Markdown lines. With a checkpoint only the text after it is
// parsed, and its first line is joined to the checkpoint's; a line after
// the checkpoint that could reach back into the paragraph drops it, and
// the tail is parsed whole.
fn tail_lines(
  slot: Slot,
  text: String,
  bits: BitArray,
  tail: String,
  layout: Layout,
) -> #(List(span.Line), Slot) {
  let room = layout.room
  let whole = fn() {
    #(
      markdown.render_sanitized(tail, room),
      Slot(..slot, head: NoHead, plain: Barred),
    )
  }
  case slot.head {
    NoHead -> #(markdown.render_sanitized(tail, room), slot)
    Head(at:, line:) ->
      case open_text(slot, text, bits, at) {
        Ok(rest) ->
          case keeps_paragraph(rest) {
            True -> #(joined(line, markdown.render_sanitized(rest, room)), slot)
            False -> whole()
          }
        Error(Nil) -> whole()
      }
  }
}

// The sanitized text from `at` to the end. `at` is inside the text the
// hygiene pass leaves unchanged, so the pass over the rest is the pass over
// the tail from there.
fn open_text(
  slot: Slot,
  text: String,
  bits: BitArray,
  at: Int,
) -> Result(String, Nil) {
  use rest <- result.try(text_from(text, bits, at))
  case slot.unchanged_to == bit_array.byte_size(bits) {
    True -> Ok(rest)
    False -> Ok(text_hygiene.multiline(rest))
  }
}

// The checkpoint's line joined to the first line of the text after it.
fn joined(line: span.Line, rest: List(span.Line)) -> List(span.Line) {
  case rest {
    [first, ..more] -> [markdown.join_soft_break(line, first), ..more]
    [] -> [line]
  }
}

// Whether the text after a checkpoint leaves the paragraph before it as it
// was: no line of it is a setext underline and none holds a `|`. The test
// is broader than the grammar — any line of only `=` or only `-` counts,
// however indented — which costs only a checkpoint.
fn keeps_paragraph(rest: String) -> Bool {
  !string.contains(rest, "|")
  && !list.any(string.split(rest, "\n"), fn(row) {
    let trimmed = string.trim(row)
    trimmed != ""
    && {
      string.replace(trimmed, "=", "") == ""
      || string.replace(trimmed, "-", "") == ""
    }
  })
}

// Whether the tail's rows open the line: only when nothing has settled.
fn run(slot: Slot) -> RowRun {
  case slot.settled {
    [] -> OpensLine
    [_, ..] -> ContinuesLine
  }
}

// `text` from byte `from` to the end, where `bits` is `text`. Every offset
// kept in a slot is on a character boundary, so the slice is whole
// characters; the text itself is returned whole rather than checked again.
fn text_from(text: String, bits: BitArray, from: Int) -> Result(String, Nil) {
  case from {
    0 -> Ok(text)
    _ -> text_between(bits, from, bit_array.byte_size(bits))
  }
}

fn text_between(bits: BitArray, from: Int, to: Int) -> Result(String, Nil) {
  bit_array.slice(bits, from, to - from)
  |> result.try(bit_array.to_string)
}

// A reference definition, a footnote reference or an inline footnote gives
// text in one block a meaning that depends on another: a link resolves
// against a definition anywhere in the document, and footnotes are numbered
// across it. Split rendering cannot reproduce that, so text holding any of
// them is rendered whole. The tail is checked on every frame and every
// settled block was part of a checked tail when it settled.
fn splittable(tail: String) -> Result(Nil, Nil) {
  case
    string.contains(tail, "]:")
    || string.contains(tail, "[^")
    || string.contains(tail, "^[")
  {
    True -> Error(Nil)
    False -> Ok(Nil)
  }
}

// Each tail line with its rows, reusing the last frame's rows for a line
// that is unchanged and re-wrapping from them for one that is not. The
// pairing is by position, and every pair is a line with the rows
// `markdown.wrap_line` gives it, so a pairing that no longer lines up costs
// a full wrap of that line and nothing else.
fn wrapped(
  lines: List(span.Line),
  memo: List(#(span.Line, List(span.Line))),
  room: Int,
) -> List(#(span.Line, List(span.Line))) {
  case lines, memo {
    [], _ -> []
    [line, ..rest], [] -> [
      #(line, markdown.wrap_line(line, room)),
      ..wrapped(rest, [], room)
    ]
    [line, ..rest], [previous, ..older] -> {
      let rows = case line == previous.0 {
        True -> previous.1
        False -> markdown.rewrap(previous, line, room)
      }
      [#(line, rows), ..wrapped(rest, older, room)]
    }
  }
}

// Moves the tail's closed blocks into the settled rows, when the text shows
// a place to cut.
//
// The cut is after a blank line whose next line starts with an ASCII
// letter. A letter at the margin cannot continue anything a blank line left
// open: it is not indented enough to continue a list item or an indented
// code block, and it is not a list marker, a quote marker, a fence or a
// table row. What it can still land inside is a fenced code block or an
// HTML block that was open before the blank line, and those are caught by
// rendering the text before the cut, the first line after it, and both
// together: if the two halves do not give the lines the whole gives, the cut
// is inside something and is not taken. The first line after the cut is
// where that is decided, so later text cannot undo it.
//
// The text on both sides must be text the hygiene pass leaves unchanged,
// which makes the raw bytes the sanitized ones, and the pass splits there.
//
// Cuts are tried oldest first, each checked against the text since the last
// one taken, so the check costs that block once. A cut that fails, inside a
// long fence say, leaves its block to the next one, which then checks both;
// the attempts a frame may make are bounded so that such a run cannot turn
// one frame into many renders of the same text.
fn settle(slot: Slot, bits: BitArray, layout: Layout) -> Slot {
  settle_from(slot, bits, layout, settle_attempts)
}

// Cuts one frame may check. A frame after a resize starts from nothing and
// may find every cut in the answer at once; the rest wait for later frames.
const settle_attempts = 4

// `scanned` always names the first offset not yet looked at, so a frame
// whose attempts run out leaves the remaining cuts to the next one. A cut is
// only looked for where its first line is complete, up to the last line
// feed in the checked text; the partial line after it is searched once it
// ends. That line feed is looked for backwards from the end of the checked
// text only as far as the search starts, so a long unbroken line is not
// read again on every frame.
fn settle_from(
  slot: Slot,
  bits: BitArray,
  layout: Layout,
  attempts: Int,
) -> Slot {
  case attempts {
    0 -> slot
    _ -> {
      let from = int.max(slot.scanned, slot.tail_from + 2)
      let complete = last_line_feed(bits, slot.unchanged_to - 1, from)
      case cut_point(bits, from, complete) {
        Error(Nil) -> Slot(..slot, scanned: int.max(slot.scanned, complete))
        Ok(at) -> settle_at(slot, bits, at, layout, attempts)
      }
    }
  }
}

// One cut's attempt, and the search for the next from just after it.
fn settle_at(
  slot: Slot,
  bits: BitArray,
  at: Int,
  layout: Layout,
  attempts: Int,
) -> Slot {
  let slot = case checked_cut(bits, slot.tail_from, at, layout) {
    Ok(parts) -> take(slot, parts, at, layout)
    Error(Nil) -> slot
  }
  settle_from(Slot(..slot, scanned: at + 1), bits, layout, attempts - 1)
}

// The Markdown lines of the tail before the cut at `at`, if the tail up to
// the end of the cut's first line renders the same split there as whole.
fn checked_cut(
  bits: BitArray,
  from: Int,
  at: Int,
  layout: Layout,
) -> Result(List(span.Line), Nil) {
  use line_end <- result.try(next_line_end(bits, at))
  use before <- result.try(text_between(bits, from, at))
  use first <- result.try(text_between(bits, at, line_end))
  use whole <- result.try(text_between(bits, from, line_end))
  let parts = markdown.render_sanitized(before, layout.room)
  let separate =
    list.append(parts, markdown.render_sanitized(first, layout.room))
  case markdown.render_sanitized(whole, layout.room) == separate {
    True -> Ok(parts)
    False -> Error(Nil)
  }
}

// Settles `parts`, the lines of the tail before a checked cut at `at`. Their
// rows come from the tail's memo where a line is unchanged, which it usually
// is: the block was on screen as part of the tail a frame ago.
fn take(slot: Slot, parts: List(span.Line), at: Int, layout: Layout) -> Slot {
  let rows =
    wrapped(parts, slot.memo, layout.room)
    |> list.flat_map(fn(pair) { pair.1 })
    |> layout.finish(run(slot))
  Slot(
    ..slot,
    tail_from: at,
    settled: list.append(slot.settled, rows),
    memo: list.drop(slot.memo, list.length(parts)),
    head: NoHead,
    plain_to: at,
    plain: Readable,
  )
}

// The first byte offset from `index` up to `limit` that starts a line
// beginning with an ASCII letter and preceded by a blank line: the two bytes
// before it are line feeds.
fn cut_point(bits: BitArray, index: Int, limit: Int) -> Result(Int, Nil) {
  case index >= limit {
    True -> Error(Nil)
    False ->
      case bit_array.slice(bits, index - 2, 3) {
        Ok(<<10, 10, letter>>) if letter >= 65 && letter <= 90 -> Ok(index)
        Ok(<<10, 10, letter>>) if letter >= 97 && letter <= 122 -> Ok(index)
        Ok(_) | Error(Nil) -> cut_point(bits, index + 1, limit)
      }
  }
}

// The one scan here that repeats across frames: it reads back over the open
// last line every frame, so its cost is that line's length, not the answer's.
//
// The byte just past the last line feed at or before `index`, or `floor`
// when there is none at or after it. It scans backwards and stops at
// `floor`, so it reads at most the text a cut could still be found in.
fn last_line_feed(bits: BitArray, index: Int, floor: Int) -> Int {
  case index < floor {
    True -> floor
    False ->
      case bit_array.slice(bits, index, 1) {
        Ok(<<10>>) -> index + 1
        Ok(_) | Error(Nil) -> last_line_feed(bits, index - 1, floor)
      }
  }
}

// The offset just past the line feed that ends the line starting at `from`.
fn next_line_end(bits: BitArray, from: Int) -> Result(Int, Nil) {
  case bit_array.slice(bits, from, 1) {
    Ok(<<10>>) -> Ok(from + 1)
    Ok(_) -> next_line_end(bits, from + 1)
    Error(Nil) -> Error(Nil)
  }
}

// Moves the checkpoint as far into the tail's opening paragraph as the
// conditions on `Head` allow, reading each byte for them once.
//
// A new checkpoint is placed only after checking it against this frame's
// parse of the whole tail: the text before it must parse into a single
// paragraph line, and joining that line to the parse of the rest must give
// exactly `lines`. That also settles that the tail opens with a paragraph
// at all. A checkpoint that fails the check bars checkpoints for the rest
// of the tail, so the check is not paid again on every frame. Moving an
// existing checkpoint forward parses only the lines it passes, which are
// plain paragraph lines by the conditions and so parse on their own into
// the words they add to the paragraph's line.
fn checkpoint(
  slot: Slot,
  text: String,
  bits: BitArray,
  lines: List(span.Line),
  layout: Layout,
) -> Slot {
  let start = case slot.head {
    NoHead -> slot.tail_from
    Head(at:, ..) -> at
  }
  let complete = last_line_feed(bits, slot.unchanged_to - 1, start)
  case slot.plain {
    Barred -> slot
    Readable -> {
      let #(plain_to, plain) =
        plain_extent(bits, int.max(slot.plain_to, start), complete)
      let slot = Slot(..slot, plain_to:, plain:)
      case last_opening(bits, plain_to, start) {
        Error(Nil) -> slot
        Ok(at) -> moved(slot, text, bits, start, at, lines, layout)
      }
    }
  }
}

// Places or moves the checkpoint to `at`, the text from `start` to it
// being plain paragraph lines.
fn moved(
  slot: Slot,
  text: String,
  bits: BitArray,
  start: Int,
  at: Int,
  lines: List(span.Line),
  layout: Layout,
) -> Slot {
  let placed = {
    use passed <- result.try(text_between(bits, start, at))
    use line <- result.try(
      one_paragraph(markdown.render_sanitized(passed, layout.room)),
    )
    case slot.head {
      // The passed lines must also be free of a setext underline and a
      // table row on their own, so the checkpoint's safety does not rest
      // on `tail_lines` having checked them on an earlier frame.
      Head(line: head, ..) ->
        case keeps_paragraph(passed) {
          True -> Ok(Head(at:, line: markdown.join_soft_break(head, line)))
          False -> Error(Nil)
        }
      NoHead -> {
        use rest <- result.try(open_text(slot, text, bits, at))
        let parsed = markdown.render_sanitized(rest, layout.room)
        case keeps_paragraph(rest) && joined(line, parsed) == lines {
          True -> Ok(Head(at:, line:))
          False -> Error(Nil)
        }
      }
    }
  }
  case placed {
    Ok(head) -> Slot(..slot, head:)
    Error(Nil) -> Slot(..slot, plain: Barred)
  }
}

// The paragraph line of text that parses into exactly one paragraph.
fn one_paragraph(lines: List(span.Line)) -> Result(span.Line, Nil) {
  case lines {
    [line, span.Line(spans: [], ..)] -> Ok(line)
    [line, span.Line(spans: [span.Span(content: "", ..)], ..)] -> Ok(line)
    _ -> Error(Nil)
  }
}

// How far from `from` up to `limit` the text stays plain checkpoint text,
// and whether it is still plain there. It stops at a character that opens
// or closes inline Markdown, at a blank line, and at a hard break: two
// spaces or a backslash before a line feed.
fn plain_extent(bits: BitArray, from: Int, limit: Int) -> #(Int, Plain) {
  case from >= limit {
    True -> #(int.max(from, limit), Readable)
    False ->
      case bit_array.slice(bits, from, 1) {
        Ok(<<byte>>) ->
          case bars_checkpoint(bits, from, byte) {
            True -> #(from, Barred)
            False -> plain_extent(bits, from + 1, limit)
          }
        Ok(_) | Error(Nil) -> #(from, Barred)
      }
  }
}

// Whether the byte at `at` ends checkpoint text: one of the characters
// Markdown pairs across a line — `*`, `_`, a backtick, `~`, `=`, brackets,
// angle brackets, `|` and a backslash — or `&`, whose entity may stand for
// the whitespace a join trims, or the line feed of a blank line or of a hard
// break.
fn bars_checkpoint(bits: BitArray, at: Int, byte: Int) -> Bool {
  case byte {
    0x2A
    | 0x5F
    | 0x60
    | 0x7E
    | 0x3D
    | 0x5B
    | 0x5D
    | 0x3C
    | 0x3E
    | 0x7C
    | 0x5C
    | 0x26 -> True
    0x0A -> ends_break_or_blank(bits, at - 1, 0)
    _ -> False
  }
}

// Whether the line feed just after `index` ends a blank line — one of only
// spaces, which Markdown counts as blank and which ends the paragraph — or
// a line with a hard break, two or more spaces before its line feed. It
// reads back over the spaces before the line feed, so its cost is those
// spaces.
fn ends_break_or_blank(bits: BitArray, index: Int, spaces: Int) -> Bool {
  case bit_array.slice(bits, index, 1) {
    Ok(<<0x20>>) -> ends_break_or_blank(bits, index - 1, spaces + 1)
    Ok(<<0x0A>>) | Error(Nil) -> True
    Ok(_) -> spaces >= 2
  }
}

// The last line start after `start` and at or before `limit` whose first
// character is an ASCII letter: where a checkpoint may go. It reads back
// only over the plain text found since the last one.
fn last_opening(bits: BitArray, limit: Int, start: Int) -> Result(Int, Nil) {
  case limit <= start {
    True -> Error(Nil)
    False ->
      case bit_array.slice(bits, limit - 1, 2) {
        Ok(<<0x0A, letter>>)
          if { letter >= 65 && letter <= 90 }
          || { letter >= 97 && letter <= 122 }
        -> Ok(limit)
        Ok(_) | Error(Nil) -> last_opening(bits, limit - 1, start)
      }
  }
}
