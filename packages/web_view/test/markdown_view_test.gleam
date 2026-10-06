//// An assistant's Markdown on the page: which rows are formatted, what each
//// construct becomes, and that nothing the session wrote reaches the page
//// as markup, an attribute or a URL the page would follow
//// (protocol-change/051, "Nothing from the session becomes markup").
////
//// The row cases render a whole component from a capture, so they exercise
//// the dispatch by speaker and the parse in `update` as well as
//// `markdown_view`; the construct cases draw a parsed tree directly.

import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import lane_fixture
import lustre/element
import lustre/element/html
import page_fixture
import session_view/markdown
import web_view/component
import web_view/markdown_view

// A memo is drawn as a marker comment in a string, which the browser does
// not receive as a node, so it is taken out before a fence's markup is read.
fn unmemoized(html: String) -> String {
  string.replace(html, "<!-- lustre:memo -->", "")
}

fn page(texts: List(String)) -> String {
  component.new(page_fixture.start())
  |> component.apply([lane_fixture.answered(texts)])
  |> lane_fixture.opened
  |> component.view
  |> element.to_string
  |> unmemoized
}

fn drawn(source: String) -> String {
  html.div([], markdown_view.blocks(markdown.parse(source)))
  |> element.to_string
  |> unmemoized
}

fn count(haystack: String, needle: String) -> Int {
  list.length(string.split(haystack, needle)) - 1
}

pub fn an_answer_is_rendered_and_a_prompt_is_not_test() {
  let html = page(["**bold** and `code`"])
  assert string.contains(
    html,
    "<div class=\"line assistant markdown\"><p class=\"md-p\"><strong>bold</strong> and <code class=\"md-code-span\">code</code></p></div>",
  )
  assert string.contains(html, "<pre class=\"line user\">go</pre>")
}

// The model holds no parsed trees: every answer is parsed when its row is
// drawn, and each still renders, however many there are.
pub fn every_row_renders_its_markdown_test() {
  let texts =
    int.range(from: 100, to: 0, with: [], run: fn(acc, n) {
      ["**answer " <> int.to_string(n) <> "**", ..acc]
    })
  let html = page(texts)
  assert string.contains(html, "<strong>answer 1</strong>")
  assert string.contains(html, "<strong>answer 100</strong>")
}

pub fn the_settled_answer_is_rendered_and_its_prompt_is_not_test() {
  let html =
    component.new(page_fixture.start())
    |> component.apply([lane_fixture.captured(10, None)])
    |> component.view
    |> element.to_string
  assert string.contains(
    html,
    "<div class=\"line assistant markdown\"><p class=\"md-p\">Done: two files.</p></div>",
  )
  assert string.contains(html, "review the &lt;patch&gt; &amp; report</pre>")
}

// Each row is parsed on its own, so a fence the model never closed ends
// with its row: the next answer's bold is still bold.
pub fn an_unclosed_fence_stays_in_its_row_test() {
  let html = page(["```\nlet x = 1\n**not bold**", "**bold**"])
  assert string.contains(
    html,
    "<pre><code><span>let x = 1\n</span><span>**not bold**</span></code></pre>",
  )
  assert string.contains(html, "<strong>bold</strong>")
}

pub fn headings_lists_quotes_and_rules_test() {
  let html =
    drawn(
      "# Title\n\n- one\n- two\n\n3. three\n4. four\n\n> quoted\n\n---\n\n~~gone~~ *it*",
    )
  assert string.contains(html, "<p class=\"md-heading md-h1\">Title</p>")
  assert string.contains(
    html,
    "<ul class=\"md-list\"><li class=\"md-item\"><span class=\"md-marker\">•</span><div class=\"md-item-body\"><p class=\"md-p\">one</p></div></li>",
  )
  assert string.contains(html, "<span class=\"md-marker\">3.</span>")
  assert string.contains(html, "<span class=\"md-marker\">4.</span>")
  assert !string.contains(html, "start=")
  assert string.contains(
    html,
    "<blockquote class=\"md-quote\"><p class=\"md-p\">quoted</p></blockquote>",
  )
  assert string.contains(html, "<hr class=\"md-rule\">")
  assert string.contains(html, "<s>gone</s> <em>it</em>")
}

pub fn a_code_fence_labels_its_language_as_text_test() {
  let html = drawn("```gleam\npub fn main() { <b> }\n```")
  assert string.contains(
    html,
    "<div class=\"md-code\"><span class=\"md-code-lang\">gleam</span><pre><code><span><span class=\"tok-kw\">pub</span> <span class=\"tok-kw\">fn</span> main() { &lt;b&gt; }</span>",
  )
  assert string.contains(html, "main() { &lt;b&gt; }")
  assert !string.contains(html, "<b>")
}

// A language the scanner has no rules for, and a fence with none, draw as one
// text node per line with no token markup.
pub fn an_unknown_language_is_not_coloured_test() {
  let html = drawn("```rust\nlet x = 1;\n```")
  assert string.contains(
    html,
    "<pre><code><span>let x = 1;</span></code></pre>",
  )
  assert !string.contains(html, "tok-")
}

// A program is session text. Its tokens' text is text nodes and its classes
// come from the closed kind type, so a string that closes a tag and opens a
// script is characters and nothing else.
pub fn hostile_text_in_a_gleam_fence_stays_escaped_text_test() {
  let html =
    drawn("```gleam\nlet s = \"</span><script>alert(1)</script>\"\n```")
  assert string.contains(
    html,
    "<span class=\"tok-str\">&quot;&lt;/span&gt;&lt;script&gt;alert(1)&lt;/script&gt;&quot;</span>",
  )
  assert !string.contains(html, "<script>")
  assert !string.contains(html, "</span><script")
}

// The language tag chooses the scanner and is otherwise only a label: a tag
// shaped like an attribute breakout is escaped text and never a class.
pub fn a_hostile_language_tag_never_reaches_a_class_test() {
  let html = drawn("```x\" onmouseover=\"alert(1)\nlet x\n```")

  // The fence is still a code block, with the tag as an escaped text label.
  assert string.contains(html, "<div class=\"md-code\">")
  assert string.contains(html, "<span class=\"md-code-lang\">x&quot;</span>")
  assert string.contains(html, "<pre><code><span>let x</span></code></pre>")
  assert !string.contains(html, "onmouseover=\"alert")
  assert !string.contains(html, "tok-")
}

pub fn a_diff_fence_draws_added_and_removed_lines_test() {
  let html = drawn("```diff\n-old\n+new\n context\n```")
  assert string.contains(html, "<span class=\"tok-del\">-old</span>\n")
  assert string.contains(html, "<span class=\"tok-add\">+new</span>\n")
  assert string.contains(html, "<span> context</span>")
}

pub fn a_table_test() {
  let html = drawn("| a | b |\n|:-:|--:|\n| 1 | **2** |")
  assert string.contains(
    html,
    "<thead><tr><th class=\"md-center\">a</th><th class=\"md-right\">b</th></tr></thead>",
  )
  assert string.contains(
    html,
    "<tbody><tr><td class=\"md-center\">1</td><td class=\"md-right\"><strong>2</strong></td></tr></tbody>",
  )
}

// The constructs the terminal drew through mork and the shared parser now
// recognises for both hosts: alerts, task boxes, footnotes, and links named
// by a reference or written bare.
pub fn alerts_tasks_footnotes_and_references_test() {
  let html =
    drawn(
      "> [!WARNING]\n> careful\n\n- [x] done\n\nSee [docs][d], www.x.test and <me@x.test>[^1].\n\n[d]: https://x.test/docs\n[^1]: The note.",
    )
  assert string.contains(
    html,
    "<blockquote class=\"md-quote\"><p class=\"md-heading md-h4\">Warning</p><p class=\"md-p\">careful</p></blockquote>",
  )
  assert string.contains(
    html,
    "<div class=\"md-item-body\"><p class=\"md-p\">☑ done</p>",
  )
  assert string.contains(
    html,
    "<loom-link><span class=\"ll-text\">docs</span><span class=\"ll-url\" hidden>https://x.test/docs</span></loom-link>",
  )
  assert string.contains(
    html,
    "<loom-link><span class=\"ll-text\">www.x.test</span><span class=\"ll-url\" hidden>http://www.x.test</span></loom-link>",
  )
  assert string.contains(
    html,
    "<loom-link><span class=\"ll-text\">me@x.test</span><span class=\"ll-url\" hidden>mailto:me@x.test</span></loom-link>",
  )
  assert string.contains(html, "<span class=\"md-link-target\">[1]</span>")
  assert string.contains(
    html,
    "<div class=\"md-item\"><span class=\"md-marker\">[1]</span><div class=\"md-item-body\"><p class=\"md-p\">The note.</p></div></div>",
  )
  assert !string.contains(html, "[d]:")
  assert !string.contains(html, "href")
}

// A label and a destination named through a definition reach the page only
// as text, as an inline link's do.
pub fn a_reference_destination_stays_text_test() {
  let html =
    drawn(
      "[x][evil] and [^\"onclick=a]\n\n[evil]: javascript:alert(1)\n[^\"onclick=a]: \" onmouseover=\"b",
    )
  assert !string.contains(html, "href")
  assert !string.contains(html, " onclick=\"")
  assert !string.contains(html, " onmouseover=\"")
  assert string.contains(html, ">javascript:alert(1)</span>")
  assert string.contains(html, "[&quot;onclick=a]")
}

// ------------------------------------------------------------- security

pub fn html_in_an_answer_is_text_test() {
  let html =
    page([
      "<script>alert(1)</script>\n\n<img src=x onerror=alert(1)> **<b>x</b>**",
    ])
  assert !string.contains(html, "<script")
  assert !string.contains(html, "<img")
  assert !string.contains(html, "<b>")
  assert string.contains(html, "&lt;script&gt;alert(1)&lt;/script&gt;")
  assert string.contains(html, "<strong>&lt;b&gt;x&lt;/b&gt;</strong>")
}

pub fn a_link_is_its_label_and_its_destination_as_hidden_text_test() {
  let html =
    page([
      "[click](javascript:alert(1)) and [docs](https://example.com) and <https://example.com/a> and ![pic](http://x/y.png)",
    ])
  assert !string.contains(html, "href")
  assert !string.contains(html, "<a ")
  assert !string.contains(html, "<img")
  assert !string.contains(html, "src=")
  assert string.contains(
    html,
    "<loom-link><span class=\"ll-text\">click</span><span class=\"ll-url\" hidden>javascript:alert(1)</span></loom-link>",
  )
  assert string.contains(
    html,
    "<loom-link><span class=\"ll-text\">https://example.com/a</span><span class=\"ll-url\" hidden>https://example.com/a</span></loom-link> and",
  )
  assert string.contains(
    html,
    "<span class=\"md-image\">[image: pic · http://x/y.png]</span>",
  )
}

// A hostile label and destination are escaped text in the two spans: the
// element gains no `href` and no event attribute, and the only attributes in
// the link's markup are the fixed classes and `hidden`.
pub fn a_hostile_link_gains_no_attribute_test() {
  let html =
    page([
      "[\"><img src=x onerror=alert(1)>](https://x.test/\"onmouseover=\"alert(1)\"onclick=\"b)",
    ])
  assert string.contains(
    html,
    "<loom-link><span class=\"ll-text\">&quot;&gt;&lt;img src=x onerror=alert(1)&gt;</span><span class=\"ll-url\" hidden>https://x.test/&quot;onmouseover=&quot;alert(1)&quot;onclick=&quot;b</span></loom-link>",
  )
  assert !string.contains(html, "href")
  assert !string.contains(html, "<img")
}

// Every quote, angle bracket and attribute-shaped run the source holds ends
// up escaped inside a text node, so no element gains an attribute from it.
pub fn attribute_shaped_text_stays_text_test() {
  let html =
    page([
      "```\n\" onmouseover=\"alert(1)\n```\n\n# \" class=\"x\" style=\"y\n\n| \" onclick=\"z |\n| --- |\n| a |\n\n[\"><svg onload=alert(1)>](\"onfocus=\"x)",
    ])
  assert !string.contains(html, " onmouseover=\"")
  assert !string.contains(html, " onclick=\"")
  assert !string.contains(html, " onfocus=\"")
  assert !string.contains(html, " style=\"")
  assert !string.contains(html, "<svg")
  assert !string.contains(html, "class=\"x\"")
  assert string.contains(html, "&quot; onmouseover=&quot;alert(1)")
  assert string.contains(html, "&quot; onclick=&quot;z")
}

pub fn deeply_nested_input_is_bounded_test() {
  let html =
    page([
      string.repeat(">", 20_000) <> " deep",
      string.repeat("- ", 10_000) <> "deep",
      string.repeat("*a ", 5000) <> string.repeat("b* ", 5000),
      string.repeat("[", 20_000),
    ])
  assert count(html, "<blockquote") == markdown.max_depth
  assert count(html, "<ul class=\"md-list\"") <= markdown.max_depth
  assert string.contains(html, string.repeat("[", 20_000))
}

fn previewed(source: String, limit: Int) -> String {
  html.span([], markdown_view.line(source, limit))
  |> element.to_string
}

// A preview is the first block's words on one row with bold and code kept, so
// it reads as the text does once opened and shows no markers.
pub fn a_line_keeps_bold_and_code_and_drops_the_markers_test() {
  assert previewed("**Done:** `calc.py` has `mul`\n\nmore below", 140)
    == "<span><strong>Done:</strong> <code class=\"md-code-span\">calc.py</code> has <code class=\"md-code-span\">mul</code></span>"
  assert previewed("# Summary\n\nbody", 140) == "<span>Summary</span>"
  assert previewed("- first item\n- second", 140) == "<span>first item</span>"
  assert previewed("", 140) == "<span></span>"
}

// A cut is made on the parsed spans at a word, so a span that was open is
// closed, no marker is left in the text, and the ellipsis stays on the row.
pub fn a_cut_line_closes_its_spans_and_ends_in_an_ellipsis_test() {
  let cut = previewed("**alpha beta gamma delta** epsilon", 14)
  assert cut == "<span><strong>alpha beta…</strong></span>"
  assert !string.contains(previewed("`abcdefghij` tail", 5), "`")
  assert previewed("short", 140) == "<span>short</span>"
}

// Session text in a preview is text: markup in it is escaped.
pub fn a_line_is_only_ever_text_test() {
  let html = previewed("**<script>alert(1)</script>**", 140)
  assert string.contains(html, "&lt;script&gt;")
  assert !string.contains(html, "<script")
}
