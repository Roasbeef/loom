//// The web view's Markdown parser: each construct it recognises, what it
//// leaves as text, and its behaviour on hostile input.
////
//// The hostile cases are sized so that a parser quadratic in the input would
//// run far past EUnit's five-second limit, and one exponential in a run of
//// brackets, as mork is, would not finish at all. Passing them is the
//// evidence that the work is linear; the depth checks are the evidence that
//// a view recursing over the tree recurses a bounded number of levels.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/markdown.{
  Alert, Break, BulletList, Cell, Center, Code, CodeBlock, Done, Emphasis,
  Footnote, FootnoteRef, H1, H2, H3, Heading, Image, Left, Link, Note, Open,
  OrderedList, Paragraph, Quote, Right, Rule, Strikethrough, Strong, Table, Task,
  Text, Unaligned, Warning,
}

pub fn a_paragraph_is_its_text_test() {
  assert markdown.parse("hello world") == [Paragraph([Text("hello world")])]
}

pub fn strong_and_emphasis_test() {
  assert markdown.parse("**bold** and *it* and __b__ and _i_")
    == [
      Paragraph([
        Strong([Text("bold")]),
        Text(" and "),
        Emphasis([Text("it")]),
        Text(" and "),
        Strong([Text("b")]),
        Text(" and "),
        Emphasis([Text("i")]),
      ]),
    ]
}

pub fn a_triple_run_is_both_test() {
  assert markdown.parse("***both***")
    == [Paragraph([Emphasis([Strong([Text("both")])])])]
}

pub fn strikethrough_test() {
  assert markdown.parse("~~gone~~ ~kept~")
    == [Paragraph([Strikethrough([Text("gone")]), Text(" ~kept~")])]
}

pub fn an_underscore_inside_a_word_is_text_test() {
  assert markdown.parse("snake_case_name and 2*3*4 and a * b")
    == [
      Paragraph([
        Text("snake_case_name and 2"),
        Emphasis([Text("3")]),
        Text("4 and a * b"),
      ]),
    ]
}

pub fn an_unclosed_delimiter_is_text_test() {
  assert markdown.parse("**not closed") == [Paragraph([Text("**not closed")])]
}

pub fn code_spans_test() {
  assert markdown.parse("run `make check` or `` a`b ``")
    == [
      Paragraph([
        Text("run "),
        Code("make check"),
        Text(" or "),
        Code("a`b"),
      ]),
    ]
}

pub fn code_span_content_is_not_markdown_test() {
  assert markdown.parse("`**x** <b>`") == [Paragraph([Code("**x** <b>")])]
}

pub fn an_unmatched_backtick_run_is_text_test() {
  assert markdown.parse("``` a ` b") == [Paragraph([Text("``` a ` b")])]
}

pub fn escapes_test() {
  assert markdown.parse("\\*not\\* \\a") == [Paragraph([Text("*not* \\a")])]
}

pub fn headings_test() {
  assert markdown.parse("# One\n## Two ##\n### C#\n#tag")
    == [
      Heading(H1, [Text("One")]),
      Heading(H2, [Text("Two")]),
      Heading(H3, [Text("C#")]),
      Paragraph([Text("#tag")]),
    ]
}

pub fn setext_headings_test() {
  assert markdown.parse("Title\n===\n\nSub\n---")
    == [Heading(H1, [Text("Title")]), Heading(H2, [Text("Sub")])]
}

pub fn fenced_code_keeps_its_bytes_test() {
  assert markdown.parse("```gleam extra\nlet x = **1**\n  <b>\n```\nafter")
    == [
      CodeBlock(Some("gleam"), "let x = **1**\n  <b>"),
      Paragraph([Text("after")]),
    ]
}

pub fn an_unclosed_fence_runs_to_the_end_test() {
  assert markdown.parse("before\n\n```\ncode\n\n**still code**")
    == [
      Paragraph([Text("before")]),
      CodeBlock(None, "code\n\n**still code**"),
    ]
}

pub fn indented_code_test() {
  assert markdown.parse("    let x = 1\n\n    y\n\ntext")
    == [CodeBlock(None, "let x = 1\n\ny"), Paragraph([Text("text")])]
}

pub fn a_rule_test() {
  assert markdown.parse("a\n\n---\n\n* * *")
    == [Paragraph([Text("a")]), Rule, Rule]
}

pub fn quotes_nest_test() {
  assert markdown.parse("> outer\n> > inner")
    == [
      Quote([Paragraph([Text("outer")]), Quote([Paragraph([Text("inner")])])]),
    ]
}

pub fn bullet_lists_test() {
  assert markdown.parse("- one\n- **two**\n  - nested\n\n- three")
    == [
      BulletList([
        [Paragraph([Text("one")])],
        [
          Paragraph([Strong([Text("two")])]),
          BulletList([[Paragraph([Text("nested")])]]),
        ],
        [Paragraph([Text("three")])],
      ]),
    ]
}

pub fn ordered_lists_keep_their_start_test() {
  assert markdown.parse("3. c\n4. d")
    == [OrderedList(3, [[Paragraph([Text("c")])], [Paragraph([Text("d")])]])]
}

pub fn a_number_inside_a_paragraph_is_text_test() {
  assert markdown.parse("in the year\n2024. it rained")
    == [Paragraph([Text("in the year 2024. it rained")])]
}

pub fn task_items_test() {
  assert markdown.parse("- [ ] todo\n- [x] done\n- [X] also\n- [ ]\n  - n")
    == [
      BulletList([
        [Paragraph([Task(Open), Text("todo")])],
        [Paragraph([Task(Done), Text("done")])],
        [Paragraph([Task(Done), Text("also")])],
        [Paragraph([Text("[ ]")]), BulletList([[Paragraph([Text("n")])]])],
      ]),
    ]
}

pub fn a_task_box_before_a_block_stands_alone_test() {
  assert markdown.parse("- [ ] # heading")
    == [BulletList([[Paragraph([Task(Open)]), Heading(H1, [Text("heading")])]])]
}

pub fn a_fence_inside_a_list_item_test() {
  assert markdown.parse("- item\n  ```\n  code\n  ```")
    == [BulletList([[Paragraph([Text("item")]), CodeBlock(None, "code")]])]
}

pub fn tables_test() {
  assert markdown.parse(
      "| a | *b* | c |\n|:--|:-:|--:|\n| 1 | 2\n| x \\| y | z | w | extra |",
    )
    == [
      Table(
        header: [
          Cell(Left, [Text("a")]),
          Cell(Center, [Emphasis([Text("b")])]),
          Cell(Right, [Text("c")]),
        ],
        rows: [
          [Cell(Left, [Text("1")]), Cell(Center, [Text("2")]), Cell(Right, [])],
          [
            Cell(Left, [Text("x | y")]),
            Cell(Center, [Text("z")]),
            Cell(Right, [Text("w")]),
          ],
        ],
      ),
    ]
}

pub fn a_table_may_follow_a_paragraph_directly_test() {
  assert markdown.parse(
      "Results for\nthe run:\n| a | b |\n|---|---|\n| 1 | 2 |",
    )
    == [
      Paragraph([Text("Results for the run:")]),
      Table(
        header: [Cell(Unaligned, [Text("a")]), Cell(Unaligned, [Text("b")])],
        rows: [
          [Cell(Unaligned, [Text("1")]), Cell(Unaligned, [Text("2")])],
        ],
      ),
    ]
}

pub fn a_mismatched_delimiter_row_is_not_a_table_test() {
  assert markdown.parse("a | b\n--- | --- | ---")
    == [Paragraph([Text("a | b --- | --- | ---")])]
}

pub fn an_unaligned_column_test() {
  let assert [Table(header: [Cell(Unaligned, _)], ..)] =
    markdown.parse("| a |\n| --- |")
    as "a bare dash row is unaligned"
}

pub fn links_keep_their_destination_as_text_test() {
  assert markdown.parse("see [the *docs*](https://example.com/x) now")
    == [
      Paragraph([
        Text("see "),
        Link([Text("the "), Emphasis([Text("docs")])], "https://example.com/x"),
        Text(" now"),
      ]),
    ]
}

pub fn a_destination_keeps_balanced_parentheses_test() {
  assert markdown.parse("[x](javascript:alert(1)) [w](/wiki/A_(b)))")
    == [
      Paragraph([
        Link([Text("x")], "javascript:alert(1)"),
        Text(" "),
        Link([Text("w")], "/wiki/A_(b)"),
        Text(")"),
      ]),
    ]
}

pub fn a_link_cannot_hold_a_link_test() {
  assert markdown.parse("[a [b](u) c](v)")
    == [Paragraph([Text("[a "), Link([Text("b")], "u"), Text(" c](v)")])]
}

pub fn a_bracket_without_a_destination_is_text_test() {
  assert markdown.parse("[a] and [b](has space) and ]")
    == [Paragraph([Text("[a] and [b](has space) and ]")])]
}

pub fn images_test() {
  assert markdown.parse("![a **cat**](cat.png)")
    == [Paragraph([Image("a cat", "cat.png")])]
}

pub fn autolinks_test() {
  assert markdown.parse("<https://example.com> <b>bold</b>")
    == [
      Paragraph([
        Link([Text("https://example.com")], "https://example.com"),
        Text(" <b>bold</b>"),
      ]),
    ]
}

pub fn html_is_text_test() {
  let source = "<script>alert(1)</script>\n\n<div onclick=\"x\">hi</div>"
  assert markdown.parse(source)
    == [
      Paragraph([Text("<script>alert(1)</script>")]),
      Paragraph([Text("<div onclick=\"x\">hi</div>")]),
    ]
}

pub fn line_breaks_test() {
  assert markdown.parse("soft\nbreak and hard  \nbreak\\\nagain")
    == [
      Paragraph([
        Text("soft break and hard"),
        Break,
        Text("break"),
        Break,
        Text("again"),
      ]),
    ]
}

pub fn crlf_is_a_line_ending_test() {
  assert markdown.parse("# a\r\nb")
    == [Heading(H1, [Text("a")]), Paragraph([Text("b")])]
}

// Inline text is read as tokens cut at ASCII bytes. Non-ASCII text, wide
// characters and combining marks come back byte for byte, and delimiters
// beside them still pair.
pub fn non_ascii_text_keeps_its_bytes_test() {
  assert markdown.parse("*héllo* 漢字_x_ `ç` [naïve](ü) e\u{301}**b**")
    == [
      Paragraph([
        Emphasis([Text("héllo")]),
        Text(" 漢字_x_ "),
        Code("ç"),
        Text(" "),
        Link([Text("naïve")], "ü"),
        Text(" e\u{301}"),
        Strong([Text("b")]),
      ]),
    ]
}

pub fn a_heading_anchor_is_dropped_test() {
  assert markdown.parse("# Title {#title}\n\n## Keep {#not an anchor}")
    == [
      Heading(H1, [Text("Title")]),
      Heading(H2, [Text("Keep {#not an anchor}")]),
    ]
}

pub fn alerts_test() {
  assert markdown.parse("> [!NOTE]\n> body\n\n> [!warning] inline\n> more")
    == [
      Alert(Note, [Paragraph([Text("body")])]),
      Alert(Warning, [Paragraph([Text("inline more")])]),
    ]
}

pub fn an_unknown_alert_is_a_quote_test() {
  assert markdown.parse("> [!NOPE]\n> body")
    == [Quote([Paragraph([Text("[!NOPE] body")])])]
}

pub fn a_quote_continues_lazily_test() {
  assert markdown.parse("> quoted\nlazy\n\nafter")
    == [
      Quote([Paragraph([Text("quoted lazy")])]),
      Paragraph([Text("after")]),
    ]
  assert markdown.parse("> quoted\n- item")
    == [
      Quote([Paragraph([Text("quoted")])]),
      BulletList([[Paragraph([Text("item")])]]),
    ]
}

pub fn a_link_may_carry_a_title_test() {
  assert markdown.parse("[a](https://x.test \"T\") [b](y 'u') [c](z (v))")
    == [
      Paragraph([
        Link([Text("a")], "https://x.test"),
        Text(" "),
        Link([Text("b")], "y"),
        Text(" "),
        Link([Text("c")], "z"),
      ]),
    ]
}

pub fn reference_links_test() {
  let source =
    "[full][Ref] and [ref][] and [Ref] and ![pic][img] and [none][nope]\n\n"
    <> "[ref]: https://x.test \"Title\"\n"
    <> "[img]: <https://x.test/i.png>\n"
    <> "[ref]: https://ignored.test"
  assert markdown.parse(source)
    == [
      Paragraph([
        Link([Text("full")], "https://x.test"),
        Text(" and "),
        Link([Text("ref")], "https://x.test"),
        Text(" and "),
        Link([Text("Ref")], "https://x.test"),
        Text(" and "),
        Image("pic", "https://x.test/i.png"),
        Text(" and [none][nope]"),
      ]),
    ]
}

pub fn a_reference_follows_a_failed_destination_test() {
  assert markdown.parse("[foo](not a link)\n\n[foo]: /url")
    == [Paragraph([Link([Text("foo")], "/url"), Text("(not a link)")])]
}

pub fn a_definition_in_a_fence_defines_nothing_test() {
  assert markdown.parse("[a]\n\n```\n[a]: /x\n```")
    == [Paragraph([Text("[a]")]), CodeBlock(None, "[a]: /x")]
}

pub fn an_undefined_definition_shape_is_text_test() {
  assert markdown.parse("[a]: /x trailing words")
    == [Paragraph([Text("[a]: /x trailing words")])]
}

pub fn footnotes_test() {
  let source =
    "One[^1] and two[^note] and [^none].\n\n[^1]: First.\n[^note]: Second\n    goes on."
  assert markdown.parse(source)
    == [
      Paragraph([
        Text("One"),
        FootnoteRef("1"),
        Text(" and two"),
        FootnoteRef("note"),
        Text(" and [^none]."),
      ]),
      Footnote("1", [Paragraph([Text("First.")])]),
      Footnote("note", [Paragraph([Text("Second goes on.")])]),
    ]
}

pub fn bare_links_test() {
  assert markdown.parse(
      "see https://x.test/path. and www.x.test, (https://x.test/a_(b)) "
      <> "http://x.test/a) https://x.test?q=1&amp; mid-www.x.test http://nodot",
    )
    == [
      Paragraph([
        Text("see "),
        Link([Text("https://x.test/path")], "https://x.test/path"),
        Text(". and "),
        Link([Text("www.x.test")], "http://www.x.test"),
        Text(", ("),
        Link([Text("https://x.test/a_(b)")], "https://x.test/a_(b)"),
        Text(") "),
        Link([Text("http://x.test/a")], "http://x.test/a"),
        Text(") "),
        Link([Text("https://x.test?q=1")], "https://x.test?q=1"),
        Text("&amp; mid-www.x.test http://nodot"),
      ]),
    ]
}

// A URL written inside a link's label must not run on into the label's
// close and the real destination, or the link would go to a wrong address.
pub fn a_bare_url_in_a_label_does_not_swallow_the_destination_test() {
  assert markdown.parse("[see https://a.test](https://b.test)")
    == [
      Paragraph([Link([Text("see "), Text("https://a.test")], "https://b.test")]),
    ]
}

pub fn a_bare_url_stops_before_a_close_paren_test() {
  assert markdown.parse("(https://a.test) and x")
    == [
      Paragraph([
        Text("("),
        Link([Text("https://a.test")], "https://a.test"),
        Text(") and x"),
      ]),
    ]
}

// A link cannot hold a link, in a label's emphasis either.
pub fn a_link_holds_no_link_test() {
  assert markdown.parse("[**see https://a.test**](https://b.test)")
    == [
      Paragraph([
        Link([Strong([Text("see "), Text("https://a.test")])], "https://b.test"),
      ]),
    ]
}

pub fn email_autolinks_test() {
  assert markdown.parse("<me@x.test> and me@x.test")
    == [
      Paragraph([
        Link([Text("me@x.test")], "mailto:me@x.test"),
        Text(" and me@x.test"),
      ]),
    ]
}

// --------------------------------------------------------- hostile input

// Depth of the deepest block container, counting a list item's blocks one
// level below the list.
fn block_depth(blocks: List(markdown.Block)) -> Int {
  list.fold(blocks, 0, fn(deepest, block) {
    int.max(deepest, case block {
      Quote(blocks:) | Alert(blocks:, ..) | Footnote(blocks:, ..) ->
        1 + block_depth(blocks)
      BulletList(items:) | OrderedList(items:, ..) ->
        1 + list.fold(items, 0, fn(d, item) { int.max(d, block_depth(item)) })
      Paragraph(..) | Heading(..) | CodeBlock(..) | Table(..) | Rule -> 0
    })
  })
}

fn inline_depth(inlines: List(markdown.Inline)) -> Int {
  list.fold(inlines, 0, fn(deepest, inline) {
    int.max(deepest, case inline {
      Emphasis(children:) | Strong(children:) | Strikethrough(children:) ->
        1 + inline_depth(children)
      Link(label:, ..) -> 1 + inline_depth(label)
      Text(..) | Code(..) | Image(..) | Task(..) | FootnoteRef(..) | Break -> 0
    })
  })
}

fn deepest_inline(blocks: List(markdown.Block)) -> Int {
  list.fold(blocks, 0, fn(deepest, block) {
    int.max(deepest, case block {
      Paragraph(inlines:) | Heading(inlines:, ..) -> inline_depth(inlines)
      Quote(blocks:) | Alert(blocks:, ..) | Footnote(blocks:, ..) ->
        deepest_inline(blocks)
      BulletList(items:) | OrderedList(items:, ..) ->
        list.fold(items, 0, fn(d, item) { int.max(d, deepest_inline(item)) })
      Table(header:, rows:) ->
        list.fold([header, ..rows], 0, fn(d, row) {
          list.fold(row, d, fn(d, cell) {
            int.max(d, inline_depth(cell.inlines))
          })
        })
      CodeBlock(..) | Rule -> 0
    })
  })
}

pub fn a_run_of_brackets_is_text_test() {
  let source = string.repeat("[", 50_000)
  assert markdown.parse(source) == [Paragraph([Text(source)])]
}

pub fn a_run_of_bracket_parens_is_text_test() {
  let source = string.repeat("[a](", 20_000)
  assert markdown.parse(source) == [Paragraph([Text(source)])]
}

// The inputs that hung the terminal under mork, at 50,000 characters each:
// a run of `[`, of `![` and of `[a](`. Each must be text, and each must be
// text with every definition form in play too, since references, footnotes
// and titles add scans a bracket can start.
pub fn the_inputs_that_hung_mork_are_text_test() {
  let definitions = "\n\n[a]: /x\n[^a]: note"
  [
    string.repeat("[", 50_000),
    string.repeat("![", 25_000),
    string.repeat("[a](", 12_500),
  ]
  |> list.each(fn(source) {
    assert markdown.parse(source) == [Paragraph([Text(source)])]
    let assert [Paragraph(_), Footnote(..)] =
      markdown.parse(source <> definitions)
      as "the run is one paragraph beside its definitions"
  })
}

// Runs aimed at the scans the definitions add: shortcut and full references,
// footnote labels, titles, bare links and their trailing punctuation. Each is
// 50,000 characters or more, far past where a quadratic scan would run out
// of time.
pub fn runs_against_the_added_scans_are_bounded_test() {
  let definitions = "\n\n[a]: /x\n[^a]: note"
  [
    string.repeat("[a]", 20_000),
    string.repeat("[a][", 20_000),
    string.repeat("[a][a", 12_500),
    string.repeat("[[a]", 15_000),
    string.repeat("[^a", 20_000),
    string.repeat("[^", 25_000),
    string.repeat("[a](b \"", 10_000),
    string.repeat("[a](b (", 10_000),
    string.repeat("www.", 15_000),
    string.repeat("www.a", 12_000),
    string.repeat("http://a.b)", 6000),
    string.repeat("https://a", 7000),
    "www.a.b" <> string.repeat(")", 50_000),
    "www.a.b" <> string.repeat(".", 50_000),
    "www.a.b" <> string.repeat("&amp", 12_500),
  ]
  |> list.each(fn(source) {
    let assert [_, ..] = markdown.parse(source <> definitions)
      as "a hostile run parses"
  })
}

pub fn a_run_of_closing_parens_links_once_each_test() {
  let assert [Paragraph(inlines)] =
    markdown.parse(string.repeat("[a](b)", 10_000))
    as "a run of links is one paragraph"
  assert list.length(inlines) == 10_000
}

pub fn runs_of_backticks_are_bounded_test() {
  // Every run length from 1 to 400 once, each unmatched: 80,000 backticks.
  let source =
    upto(1, 400)
    |> list.map(fn(n) { string.repeat("`", n) <> " " })
    |> string.concat
  let assert [Paragraph(_)] = markdown.parse(source)
    as "unmatched backtick runs are one paragraph"
  let paired = string.repeat("` ", 40_000)
  let assert [Paragraph(_)] = markdown.parse(paired)
    as "paired backticks are one paragraph"
}

pub fn runs_of_delimiters_are_bounded_test() {
  let sources = [
    string.repeat("*", 50_000),
    string.repeat("*a ", 20_000),
    string.repeat("_a ", 20_000),
    string.repeat("~~a ", 20_000),
    string.repeat("**a *b ", 10_000),
    string.repeat("*[`_", 20_000),
    string.repeat("![", 20_000),
    string.repeat("<a ", 20_000),
    string.repeat("<http:", 20_000),
    string.repeat("\\", 50_000),
    string.repeat("]", 50_000),
  ]
  list.each(sources, fn(source) {
    assert deepest_inline(markdown.parse(source)) <= markdown.max_emphasis + 1
  })
}

pub fn nested_emphasis_is_capped_test() {
  let source = string.repeat("*a ", 1000) <> string.repeat("b* ", 1000)
  assert deepest_inline(markdown.parse(source)) <= markdown.max_emphasis
}

pub fn deep_quotes_are_capped_test() {
  let source = string.repeat(">", 50_000) <> " text"
  assert block_depth(markdown.parse(source)) == markdown.max_depth
  let spaced = string.repeat("> ", 25_000) <> "text"
  assert block_depth(markdown.parse(spaced)) == markdown.max_depth
}

pub fn deep_lists_are_capped_test() {
  let flat = string.repeat("- ", 25_000) <> "x"
  assert block_depth(markdown.parse(flat)) <= markdown.max_depth
  let indented =
    upto(0, 1999)
    |> list.map(fn(level) { string.repeat("  ", level) <> "- x" })
    |> string.join("\n")
  assert block_depth(markdown.parse(indented)) <= markdown.max_depth
}

pub fn many_fences_and_lines_test() {
  let fences = string.repeat("```\n", 20_000)
  let assert [_, ..] = markdown.parse(fences) as "fences parse"
  let table = "a|b\n-|-\n" <> string.repeat("|x|y|\n", 20_000)
  let assert [Table(rows:, ..)] = markdown.parse(table) as "one table"
  assert list.length(rows) == 20_000
}

// A deterministic stream of short strings over the characters the parser
// treats specially. Each must parse, and the tree's depth must stay inside
// the bounds whatever the mix.
pub fn mixed_markup_stays_bounded_test() {
  let alphabet = string.to_graphemes("*_~`[]()!<>#-+|\\ \n>1.:ax")
  let count = list.length(alphabet)
  upto(1, 400)
  |> list.each(fn(seed) {
    let source = generate(seed, 300, alphabet, count, [])
    let blocks = markdown.parse(source)
    assert block_depth(blocks) <= markdown.max_depth
    assert deepest_inline(blocks) <= markdown.max_emphasis + 1
  })
}

fn generate(
  state: Int,
  remaining: Int,
  alphabet: List(String),
  count: Int,
  out: List(String),
) -> String {
  case remaining {
    0 -> string.concat(out)
    _ -> {
      let state = { state * 1_103_515_245 + 12_345 } % 2_147_483_648
      let pick =
        alphabet
        |> list.drop(state / 65_536 % count)
        |> list.first
      let grapheme = case pick {
        Ok(grapheme) -> grapheme
        Error(Nil) -> "a"
      }
      generate(state, remaining - 1, alphabet, count, [grapheme, ..out])
    }
  }
}

fn upto(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..upto(from + 1, to)]
  }
}
