//// The live tail against a full render of the same text.
////
//// `live_tail` builds a streaming answer's rows from what it kept of the
//// last frame, and a replay golden compares frames byte for byte, so the
//// rows it gives must be exactly the rows `render.render_line` gives for the
//// whole text on every frame. These tests hold it to that over streams
//// generated from a seeded sequence: Markdown with fences, lists, quotes,
//// tables, setext underlines and inline delimiters; wide, combining and
//// flag characters; terminal controls the hygiene pass rewrites; and
//// reference definitions and footnotes, which make a stream unsplittable.
//// Each stream is cut into deltas at arbitrary codepoints, so a delta can
//// end inside a word, a grapheme, a fence marker or an escape sequence, and
//// the width changes at random frames, as a resize does. A stream is also
//// sometimes replaced or collapsed to its newest bytes, which the cache must
//// notice rather than extend.
////
//// `markdown.rewrap` is checked the same way on its own, over random styled
//// spans, since Markdown output reaches only some of the span shapes the
//// word wrapper sees. And one test runs deltas through the model and the
//// projection and compares its rows with a projection that kept nothing.

import core/json
import etui/backend
import etui/span
import etui/style
import gleam/int
import gleam/list
import gleam/string
import host/bootstrap
import session_view/connection_event
import session_view/transcript_line.{type Speaker, Assistant, Line, Reasoning}
import tui
import tui/inbound
import tui/live_tail
import tui/markdown
import tui/model as tui_model
import tui/projection
import tui/render
import tui/view_set
import tui_test/pushed

// A linear congruential sequence: the tests need a fixed, reproducible
// spread of inputs rather than good randomness.
type Random {
  Random(state: Int)
}

fn next(random: Random, bound: Int) -> #(Int, Random) {
  let state = { random.state * 1_103_515_245 + 12_345 } % 2_147_483_648
  #({ state / 65_536 } % int.max(1, bound), Random(state))
}

fn pick(random: Random, from: List(a), default: a) -> #(a, Random) {
  let #(index, random) = next(random, list.length(from))
  let chosen = case list.drop(from, index) {
    [value, ..] -> value
    [] -> default
  }
  #(chosen, random)
}

// The pieces a generated answer is made of. Words and separators are the
// common case; the rest are the constructs that can reach across a delta,
// a line or a blank line, and the text the hygiene pass rewrites.
const words = [
  "alpha", "beta", "gamma", "delta", "x", "wörd", "漢字", "漢字漢字", "👍🏽", "🇺🇸",
  "e\u{301}", "naïve", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
]

const separators = [" ", " ", " ", " ", "\n", "\n\n", "\n\n", "  \n"]

const constructs = [
  "*", "**", "_", "`", "~~", "==", "\n```\n", "\n```gleam\n", "\n~~~\n",
  "\n\n# ", "\n- ", "\n1. ", "\n> ", "\n===\n", "\n---\n",
  "\n\n| a | b |\n|---|---|\n| c | d |\n", "[link](http://x.y)", "<b>", "&amp;",
  "\\", "www.example.com", ":smile:", "\n    indented\n", "\n\nPara ", "\n\nz",
]

const hostile = [
  "\t", "\r\n", "\r", "\u{1b}[31m", "\u{1b}]0;title\u{7}", "\u{200b}", "\u{9d}",
]

const global = ["\n[x]: http://x\n", "[^1]", "^[note]"]

// Which pieces a generated answer may use. Hostile text and reference
// syntax each switch the tail to a slower, whole-text path for the rest of
// the stream, so they appear only in some streams and the others reach the
// settled-block and re-wrap paths. Prose is long paragraphs of words with
// the odd construct, which is what moves a paragraph's checkpoint and what
// has to drop it.
type Mix {
  Markdown
  Hostile
  Prose
}

const prose_separators = [" ", " ", " ", " ", " ", " ", "\n", "\n"]

// One generated answer: mostly words and separators, with constructs mixed
// in, and in a hostile mix terminal controls and reference syntax.
fn answer(
  random: Random,
  pieces: Int,
  acc: List(String),
  mix: Mix,
) -> #(String, Random) {
  case pieces {
    0 -> #(string.concat(list.reverse(acc)), random)
    _ -> {
      let #(roll, random) = next(random, 100)
      let #(piece, random) = case roll, mix {
        roll, Prose if roll < 55 -> pick(random, words, "x")
        roll, Prose if roll < 97 -> pick(random, prose_separators, " ")
        _, Prose -> pick(random, constructs, " ")
        roll, _ if roll < 45 -> pick(random, words, "x")
        roll, _ if roll < 75 -> pick(random, separators, " ")
        roll, Markdown if roll < 100 -> pick(random, constructs, " ")
        roll, Hostile if roll < 94 -> pick(random, constructs, " ")
        roll, Hostile if roll < 99 -> pick(random, hostile, " ")
        _, _ -> pick(random, global, " ")
      }
      answer(random, pieces - 1, [piece, ..acc], mix)
    }
  }
}

// The answer cut into deltas of one to twelve codepoints, so a cut can
// fall anywhere a provider's token boundary could.
fn deltas(
  random: Random,
  codepoints: List(UtfCodepoint),
  acc: List(String),
) -> #(List(String), Random) {
  case codepoints {
    [] -> #(list.reverse(acc), random)
    _ -> {
      let #(size, random) = next(random, 12)
      let #(taken, rest) = list.split(codepoints, size + 1)
      deltas(random, rest, [string.from_utf_codepoints(taken), ..acc])
    }
  }
}

fn layout(speaker: Speaker, width: Int) -> live_tail.Layout {
  live_tail.Layout(
    room: render.markdown_room(speaker, width),
    finish: fn(rows, run) {
      render.finish_markdown_rows(speaker, rows, run, "main")
    },
  )
}

// The state of one stream as the model would hold it: its fragments newest
// first, the text they join to, and the pane width.
type Stream {
  Stream(fragments: List(String), text: String, width: Int)
}

// Pane widths a frame may take. Each leaves the body a dozen cells after
// the speaker's mark and a list's indentation: etui's word wrapper never
// finishes a word whose first grapheme is wider than the row it is given,
// with or without a cache, and an indented line narrows the row by its
// indentation. A width that leaves a one-cell row tests the wrapper rather
// than the tail; `markdown.rewrap` is checked at narrow widths below, with
// text that has no wide characters.
fn widths(speaker: Speaker) -> List(Int) {
  case speaker {
    Assistant -> [16, 18, 24, 31, 40, 80, 133]
    _ -> [26, 28, 33, 40, 80, 133]
  }
}

// Feeds `pending` deltas one frame at a time and checks every frame. A
// frame sometimes resizes the pane, sometimes replaces the stream with its
// newest bytes as a collapse does, and sometimes starts it over as a new
// operation does.
fn feed(
  random: Random,
  speaker: Speaker,
  pending: List(String),
  stream: Stream,
  cache: live_tail.Cache,
  frame: Int,
) -> Random {
  case pending {
    [] -> random
    [delta, ..rest] -> {
      let #(event, random) = next(random, 40)
      let #(width, random) = case event {
        0 | 1 | 2 -> pick(random, widths(speaker), stream.width)
        _ -> #(stream.width, random)
      }
      let stream = case event {
        3 -> {
          let newest =
            string.drop_start(stream.text, string.length(stream.text) / 2)
          Stream(fragments: [delta, newest], text: newest <> delta, width:)
        }
        4 -> Stream(fragments: [delta], text: delta, width:)
        _ ->
          Stream(
            fragments: [delta, ..stream.fragments],
            text: stream.text <> delta,
            width:,
          )
      }
      let #(rows, pass) =
        live_tail.rows(
          live_tail.begin(cache),
          speaker,
          stream.text,
          stream.fragments,
          layout(speaker, width),
        )
      let expected =
        render.render_line(Line(speaker, stream.text), width, "main")
      assert rows == expected
        as {
          "frame " <> int.to_string(frame) <> " drew what a full render draws"
        }
      feed(random, speaker, rest, stream, live_tail.finish(pass), frame + 1)
    }
  }
}

fn run_stream(random: Random, speaker: Speaker, mix: Mix) -> Random {
  let #(pieces, random) = next(random, 160)
  let #(text, random) = answer(random, pieces + 10, [], mix)
  let #(cut, random) = deltas(random, string.to_utf_codepoints(text), [])
  let #(width, random) = pick(random, widths(speaker), 40)
  feed(random, speaker, cut, Stream([], "", width), live_tail.new(), 0)
}

// One stream in four is reasoning; independently, one in four is hostile,
// one in four is prose and the rest are Markdown.
fn run_streams(random: Random, remaining: Int) -> Nil {
  case remaining {
    0 -> Nil
    _ -> {
      let #(which, random) = next(random, 16)
      let speaker = case which % 4 {
        0 -> Reasoning
        _ -> Assistant
      }
      let mix = case which / 4 {
        0 -> Hostile
        1 -> Prose
        _ -> Markdown
      }
      run_streams(run_stream(random, speaker, mix), remaining - 1)
    }
  }
}

// The default run takes a few seconds. `LOOM_LIVE_TAIL_STREAMS` and
// `LOOM_LIVE_TAIL_SEED` raise the count and move the seed for a hunt.
pub fn generated_streams_draw_what_a_full_render_draws_test() {
  let seed = setting("LOOM_LIVE_TAIL_SEED", 20_260_926)
  run_streams(Random(seed), setting("LOOM_LIVE_TAIL_STREAMS", 300))
}

fn setting(name: String, default: Int) -> Int {
  case bootstrap.getenv(name) {
    Ok(text) ->
      case int.parse(string.trim(text)) {
        Ok(value) if value > 0 -> value
        Ok(_) | Error(Nil) -> default
      }
    Error(Nil) -> default
  }
}

// Every delta of `text` fed at `width`, one character at a time, except
// that the width becomes `resized` at frame `at`. The answer is the settled
// rows the cache holds at the end and the furthest paragraph checkpoint it
// held on any frame, so a test can show its shortcut was taken rather than
// passing because every frame fell back to a full render. Either is counted
// only while the slot has been carried from frame to frame, which is what
// makes it a shortcut: a slot started over on every frame settles and
// checkpoints too, and reuses none of it.
fn feed_characters(
  text: String,
  width: Int,
  resized: Int,
  at: Int,
) -> #(Int, Int) {
  let cut =
    string.to_utf_codepoints(text)
    |> list.map(fn(codepoint) { string.from_utf_codepoints([codepoint]) })
  let #(_, cache, furthest) =
    list.index_fold(
      cut,
      #(Stream([], "", width), live_tail.new(), 0),
      fn(acc, delta, index) {
        let #(stream, cache, furthest) = acc
        let width = case index >= at {
          True -> resized
          False -> width
        }
        let stream =
          Stream(
            fragments: [delta, ..stream.fragments],
            text: stream.text <> delta,
            width:,
          )
        let #(rows, pass) =
          live_tail.rows(
            live_tail.begin(cache),
            Assistant,
            stream.text,
            stream.fragments,
            layout(Assistant, width),
          )
        assert rows
          == render.render_line(Line(Assistant, stream.text), width, "main")
          as {
            "character "
            <> int.to_string(index)
            <> " drew what a full render draws"
          }
        let cache = live_tail.finish(pass)
        let checkpoint = case live_tail.shortcuts(cache) {
          #(_, checkpoint, carried) if carried > 1 -> checkpoint
          _ -> 0
        }
        #(stream, cache, int.max(furthest, checkpoint))
      },
    )
  let settled = case live_tail.shortcuts(cache) {
    #(settled, _, carried) if carried > 1 -> settled
    _ -> 0
  }
  #(settled, furthest)
}

// A resize changes every row, so the settled rows and the tail's wrap must
// both be rebuilt at the new width rather than reused from the old one.
pub fn a_resize_mid_stream_rebuilds_every_row_test() {
  let paragraphs =
    "The first paragraph is long enough to wrap onto several rows here.\n\n"
    <> "A second paragraph settles once the third begins, at either width.\n\n"
    <> "Third paragraph, still streaming when the pane changes its width."
  let #(settled, _) = feed_characters(paragraphs, 40, 23, 90)
  assert settled > 0 as "the first paragraph settled at the new width"
  let #(settled, _) = feed_characters(paragraphs, 23, 40, 140)
  assert settled > 0 as "and at the other"
}

// A long paragraph is parsed from its checkpoint on each frame, and a line
// that changes the paragraph before the checkpoint must drop it: a setext
// underline makes the whole paragraph a heading, and a table's delimiter row
// makes the line above it a header. Emphasis that opens after the checkpoint
// and closes lines later, a hard break, and an entity at the end of a line
// are the constructs next to a checkpoint that must still join exactly.
pub fn a_long_paragraph_joins_at_its_checkpoint_test() {
  let lines =
    "Plain words run on for a while here\n"
    <> "and continue onto a second line of it\n"
    <> "then a third line that keeps going on\n"
  checkpointed(lines <> "and a last line\n===\nAfter it", 40, 40, 0)
  checkpointed(lines <> "cell one | cell two\n---|---\nx | y\n", 40, 40, 0)
  checkpointed(
    lines <> "then *emphasis that\nruns over lines* and ends\nplain again\n",
    40,
    40,
    0,
  )
  checkpointed(lines <> "a hard break  \nfollows and\nmore words", 40, 40, 0)
  checkpointed(lines <> "an entity &amp;\nat the end\nand more", 40, 40, 0)
  checkpointed(lines <> "   indented lazy line\nnext line\nmore", 40, 40, 0)
}

// Feeds a long paragraph and requires that a checkpoint was placed in it
// on some frame, so the join was exercised and not merely skipped.
fn checkpointed(text: String, width: Int, resized: Int, at: Int) -> Nil {
  let #(_, furthest) = feed_characters(text, width, resized, at)
  assert furthest > 0 as "the paragraph was parsed from a checkpoint"
}

// A blank line inside an open fence is not a place to cut: the letter after
// it is code, and settling there would draw it as prose. The fence opens and
// closes across deltas, and the text after it settles once it is closed.
pub fn a_fence_open_across_deltas_is_not_cut_test() {
  let _ =
    feed_characters(
      "Intro line\n\n```gleam\nlet x = 1\n\nfoo bar\n\nbaz\n```\n\nAfter the fence\n\nMore",
      30,
      30,
      0,
    )
}

// Wide and combining characters, flags and emoji with modifiers, cut
// between the codepoints of one grapheme and wrapped at widths that force
// them onto their own rows.
pub fn wide_and_combining_characters_wrap_the_same_test() {
  let text =
    "漢字漢字漢字 e\u{301}e\u{301} 🇺🇸🇺🇸 👍🏽👍🏽 naïve wörd 漢字 🇺🇸 e\u{301}\n"
    <> "next line 漢字漢字漢字漢字漢字 👍🏽 end\n\nPara 🇺🇸🇺🇸🇺🇸 漢"
  let _ = feed_characters(text, 7, 7, 0)
  let _ = feed_characters(text, 5, 12, 60)
}

// Random styled spans, a prefix of them cut inside a span, and the full
// line: re-wrapping from the prefix's rows must give the full line's rows.
fn random_spans(
  random: Random,
  count: Int,
  acc: List(span.Span),
) -> #(List(span.Span), Random) {
  case count {
    0 -> #(list.reverse(acc), random)
    _ -> {
      let #(content, random) = pick(random, span_texts, "x")
      let #(which, random) = next(random, 4)
      let styled = case which {
        0 ->
          span.span_styled(
            content,
            style.new(style.Indexed(1), style.Default, style.bold()),
          )
        1 -> span.Span(..span.span_plain(content), link: "http://x")
        _ -> span.span_plain(content)
      }
      random_spans(random, count - 1, [styled, ..acc])
    }
  }
}

const span_texts = [
  "one", "two three", " ", "  ", "four ", " five", "漢字", "e\u{301}", "🇺🇸",
  "longwordlongwordlongword", "a b c d e f", "x", "🏽", "*", "\u{301}ok", "🇺",
  "🇸 x", " 🏽", "ᄀ", "ᅡ", "\u{600}", "字 ",
]

// The first `keep` bytes of a line's spans: whole spans, then part of the
// span the cut falls in, as a line looks while its last span is growing.
fn prefix_of(spans: List(span.Span), keep: Int) -> List(span.Span) {
  case spans, keep {
    _, 0 | [], _ -> []
    [first, ..rest], _ -> {
      let size = string.byte_size(first.content)
      case size <= keep {
        True -> [first, ..prefix_of(rest, keep - size)]
        False -> {
          let codepoints = string.to_utf_codepoints(first.content)
          let part = string.from_utf_codepoints(list.take(codepoints, keep))
          [span.Span(..first, content: part)]
        }
      }
    }
  }
}

fn rewrap_cases(random: Random, remaining: Int) -> Nil {
  case remaining {
    0 -> Nil
    _ -> {
      let #(count, random) = next(random, 14)
      // The line opens with a word, as a paragraph does: an indented line
      // is narrowed by its indentation, which at these widths would leave a
      // wide character a one-cell row.
      let #(spans, random) =
        random_spans(random, count + 1, [span.span_plain("start")])
      let full = span.line_new(spans)
      let size =
        list.fold(spans, 0, fn(total, value) {
          total + string.byte_size(value.content)
        })
      let #(keep, random) = next(random, size + 1)
      let before = span.line_new(prefix_of(spans, keep))
      let #(width, random) = pick(random, [2, 3, 4, 5, 8, 12, 24, 40], 12)
      let previous = #(before, markdown.wrap_line(before, width))
      assert markdown.rewrap(previous, full, width)
        == markdown.wrap_line(full, width)
        as "re-wrapping a grown line gives the rows wrapping it whole gives"
      rewrap_cases(random, remaining - 1)
    }
  }
}

pub fn rewrap_matches_a_full_wrap_over_random_spans_test() {
  rewrap_cases(Random(11), 40_000)
}

// The projection keeps the live tail's cache on the model. Its rows after
// each paint must be the rows a projection with an empty cache builds, so
// the model's wiring — which stream feeds which line, the gutters, the
// release of a finished answer — is checked as well as the cache.
pub fn a_projection_keeping_the_cache_matches_one_that_kept_nothing_test() {
  let #(text, _) = answer(Random(99), 400, [], Markdown)
  let #(cut, _) = deltas(Random(5), string.to_utf_codepoints(text), [])
  list.index_fold(cut, pushed.attached(), fn(model, delta, index) {
    let model =
      inbound.accept_connection_message(
        model,
        pushed.delta("main", "op-1", delta),
      )
    case index % 7 {
      6 -> {
        let painted =
          tui.update(backend.Resize(model.view.width, model.view.height), model)
        let fresh =
          projection.refresh_render_cache(
            painted,
            tui_model.Model(
              ..painted,
              view: painted.view
                |> view_set.caches(
                  tui_model.Caches(
                    ..painted.view.caches,
                    live_tail: live_tail.new(),
                  ),
                )
                |> view_set.rendered_revision(
                  painted.view.rendered_revision - 1,
                ),
            ),
          )
        assert fresh.view.caches.rendered_rows
          == painted.view.caches.rendered_rows
          as "a painted frame's rows are the rows of a projection from nothing"
        assert fresh.view.rendered_gutters == painted.view.rendered_gutters
          as "and so are its copy gutters"
        painted
      }
      _ -> model
    }
  })
  Nil
}

// A tool call's stream is replaced by its newest fragment on every delta,
// so its fragment list never continues. The live tail does not cache tool
// calls, so the frames painted while a tool call's arguments stream must
// keep reusing the answer's cache rather than rebuild it on every chunk.
// No reducer drops the cache: it lives in the terminal's view, and the
// projection checks it against the answer's own stream.
pub fn a_tool_call_delta_keeps_the_answers_cache_test() {
  let answer =
    "First paragraph of the answer.\n\nSecond paragraph follows it.\n\nThird"
  let model =
    list.fold(string.to_graphemes(answer), pushed.attached(), fn(model, piece) {
      inbound.accept_connection_message(
        model,
        pushed.delta("main", "op-1", piece),
      )
    })
  let painted =
    tui.update(backend.Resize(model.view.width, model.view.height), model)
  let #(settled, _, _) = live_tail.shortcuts(painted.view.caches.live_tail)
  assert settled > 0 as "the answer's first paragraphs settled"
  let called =
    list.fold(["{\"pa", "th\":", "\"x\"}"], painted, fn(model, chunk) {
      inbound.accept_connection_message(model, tool_call_delta(chunk))
      |> fn(model) {
        tui.update(backend.Resize(model.view.width, model.view.height), model)
      }
    })
  let #(kept, _, carried) = live_tail.shortcuts(called.view.caches.live_tail)
  assert kept == settled as "tool call deltas left the settled rows in place"

  // A projection that started the slot over would settle the same rows, so
  // the carried count is what shows each paint continued the slot.
  assert carried >= 3
    as "each paint continued the slot rather than starting over"
}

fn tool_call_delta(text: String) -> connection_event.Message {
  pushed.push([
    #("event", json.String("stream_delta")),
    #(
      "body",
      json.Object([
        #("strand", json.String("main")),
        #("op", json.String("op-1")),
        #("kind", json.String("tool_call")),
        #("text", json.String(text)),
      ]),
    ),
  ])
}
