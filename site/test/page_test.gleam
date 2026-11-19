//// Tests that render whole pages to HTML and read what came out. They catch
//// what a unit test of one function cannot: a replay link to a figure the
//// page does not hold, a documentation link to a branch that is not `main`, a
//// banned word in text that only appears in one step of one figure.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/element
import site/code
import site/docs
import site/figure
import site/figures
import site/landing
import site/markdown
import site/model as m
import site/msg
import site/release
import site/replay
import site/route

fn landing_html() -> String {
  element.to_string(landing.view(m.new(route.Landing)))
}

// ROUTES ----------------------------------------------------------------------

pub fn known_routes_parse_test() {
  assert route.parse("") == route.Landing
  assert route.parse("#/") == route.Landing
  assert route.parse("#/docs") == route.DocsHome
  assert route.parse("#/docs/sessions") == route.Doc("sessions", "")
  assert route.parse("#/docs/code-mode/why") == route.Doc("code-mode", "why")
  assert route.parse("#/install") == route.Doc("getting-started", "")
}

pub fn unknown_routes_are_the_landing_page_test() {
  assert route.parse("#/nowhere/at/all/x") == route.Landing
}

pub fn to_hash_inverts_parse_test() {
  let routes = [
    route.Landing,
    route.DocsHome,
    route.Doc("sessions", ""),
    route.Doc("sessions", "the-three-stores"),
  ]
  list.each(routes, fn(r) {
    assert route.parse(route.to_hash(r)) == r
  })
}

// THE FIGURES ON THE LANDING PAGE ----------------------------------------------

pub fn every_figure_the_replay_links_to_is_on_the_landing_page_test() {
  // A link from a replay step scrolls to the element that carries the
  // figure's `data-fig`. If the page has no such element, the link does
  // nothing and says nothing, so the page must hold every figure the script
  // names.
  let html = landing_html()
  list.each(replay.steps(), fn(step) {
    case step.underneath {
      Some(link) -> {
        let key = msg.figure_key(link.figure)
        assert string.contains(html, "data-fig=\"" <> key <> "\"")
      }
      None -> Nil
    }
  })
}

pub fn a_landing_figure_is_the_panel_without_its_step_text_test() {
  // The long text of a step belongs to the documentation page. If it came
  // back here, the page would grow by a screen for every step.
  let html = landing_html()
  assert string.contains(html, "data-fig-panel=\"crash\"")
  assert !string.contains(html, "class=\"step\"")
}

pub fn the_landing_page_stays_short_test() {
  // The page was once about 5,000 words. This budget is what keeps it from
  // growing back a paragraph at a time: a new section has to pay for itself
  // by cutting another. The count is of every word in the markup, which is
  // more than a reader sees: each drawing is there in a wide and a narrow
  // layout, and each figure carries its table of states for screen readers.
  // A figure costs about 220 of these words, so the budget is five figures
  // and the prose around them. The page measured 1,585 when it was set.
  let words = word_count(visible_text(landing_html()))
  assert words <= 1700
}

/// The text of a page without its tags.
fn visible_text(html: String) -> String {
  string.split(html, "<")
  |> list.map(fn(piece) {
    case string.split_once(piece, ">") {
      Ok(#(_, text)) -> text
      Error(Nil) -> piece
    }
  })
  |> string.join(" ")
}

fn word_count(text: String) -> Int {
  string.split(text, " ")
  |> list.filter(fn(word) { string.trim(word) != "" })
  |> list.length
}

pub fn every_claim_links_to_its_documentation_page_test() {
  let html = landing_html()
  list.each(
    [
      "sessions", "approvals-and-sandboxing", "code-mode", "distributed-runtime",
      "self-evolution", "terminal-and-web",
    ],
    fn(slug) {
      assert string.contains(html, "href=\"#/docs/" <> slug <> "\"")
      assert list.any(docs.pages(), fn(page) { page.slug == slug })
    },
  )
}

pub fn the_hero_links_to_the_platform_status_test() {
  // The table of what runs where lives on the install page, and the hero's
  // status line is the way to it.
  assert string.contains(
    landing_html(),
    "href=\"#/docs/getting-started/platforms\"",
  )
}

// THE RELEASE -----------------------------------------------------------------

pub fn the_download_button_points_at_the_latest_release_test() {
  assert string.contains(
    landing_html(),
    "href=\"https://github.com/Roasbeef/loom/releases/latest\"",
  )
}

pub fn the_page_shows_the_version_label_test() {
  assert string.contains(landing_html(), release.label())
}

pub fn the_footer_names_the_mit_licence_test() {
  assert string.contains(landing_html(), "MIT License")
}

// WHAT THE PAGE CLAIMS ---------------------------------------------------------

pub fn no_distributed_runtime_badge_remains_test() {
  let html = string.lowercase(landing_html())
  assert !string.contains(html, "in development")
  assert !string.contains(html, "not on main")
  assert !string.contains(html, "not on `main`")
  assert !string.contains(html, "distributed/remote-codemode")
}

pub fn source_links_name_the_main_branch_only_test() {
  let html = landing_html()
  let pieces = string.split(html, "/blob/")
  // The first piece is the text before the first link.
  list.each(list.drop(pieces, 1), fn(piece) {
    assert string.starts_with(piece, "main/")
  })
}

// COPY ------------------------------------------------------------------------

/// Every string the page and its figures and replay can show, joined.
fn all_copy() -> String {
  let figure_text =
    list.flat_map(figures.all(), fn(id) {
      let spec = figures.spec(id)
      list.flat_map(spec.steps, fn(step) {
        list.flatten([
          [step.label, step.tag, step.caption, step.heading],
          step.body,
          list.flat_map(step.state, fn(row) { [row.0, row.1] }),
          case step.failure {
            Some(text) -> [text]
            None -> []
          },
          case step.sample {
            Some(sample) -> [sample.title, sample.text]
            None -> []
          },
        ])
      })
    })
  let diagram_text =
    list.flat_map(figures.all(), fn(id) {
      let spec = figures.spec(id)
      list.flatten([
        list.map(spec.diagram.nodes, fn(node) {
          node.title <> " " <> node.detail
        }),
        list.flat_map(spec.diagram.frames, fn(frame) {
          list.flatten([
            list.map(frame.states, fn(state) { state.text }),
            list.map(frame.pulses, fn(pulse) { pulse.label }),
          ])
        }),
      ])
    })
  let replay_text =
    list.flat_map(replay.steps(), fn(step) {
      [
        step.title,
        step.body(None),
        step.body(Some(msg.AllowOnce)),
        step.body(Some(msg.AllowSession)),
        step.body(Some(msg.Deny)),
      ]
    })
  string.join(
    list.flatten([figure_text, diagram_text, replay_text, [landing_html()]]),
    "\n",
  )
}

pub fn the_copy_has_no_em_dash_test() {
  assert !string.contains(all_copy(), "—")
}

pub fn the_copy_has_no_marketing_filler_test() {
  let copy = string.lowercase(all_copy())
  list.each(
    [
      "supercharge", "unleash", "seamless", "next-generation", "revolutionary",
      "robust", "leverage", "cutting-edge", "game-chang", "blazing",
      "effortless", "world-class",
    ],
    fn(word) {
      assert !string.contains(copy, word)
    },
  )
}

// MARKDOWN AND CODE ------------------------------------------------------------

pub fn markdown_reads_the_blocks_the_pages_use_test() {
  let blocks =
    markdown.parse(
      "# Title\n\nA lede.\n\n## A heading\n\n- one\n- two\n\n```sh\n$ make install\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n::figure crash\n",
    )
  assert blocks
    == [
      markdown.Title("Title"),
      markdown.Para("A lede."),
      markdown.Heading(2, "a-heading", "A heading"),
      markdown.Bullets(["one", "two"]),
      markdown.Code("sh", "$ make install"),
      markdown.Table(["a", "b"], [["1", "2"]]),
      markdown.Figure("crash"),
    ]
}

pub fn slugs_are_lowercase_words_joined_by_hyphens_test() {
  assert markdown.slug("Why this is safe to run") == "why-this-is-safe-to-run"
  assert markdown.slug("The `code_mode` tool") == "the-code-mode-tool"
}

pub fn the_outline_lists_the_second_level_headings_test() {
  let blocks = markdown.parse("# T\n\n## One\n\n### Sub\n\n## Two\n")
  assert markdown.outline(blocks) == [#("one", "One"), #("two", "Two")]
}

pub fn a_rendered_heading_links_to_itself_under_its_page_test() {
  let blocks = markdown.parse("# T\n\nlede\n\n## Build from source\n")
  let html =
    blocks
    |> markdown.render(
      markdown.Host("getting-started", None, fn(_) { element.none() }),
    )
    |> list.map(element.to_string)
    |> string.join("")
  assert string.contains(
    html,
    "href=\"#/docs/getting-started/build-from-source\"",
  )
  assert string.contains(html, "id=\"build-from-source\"")
}

pub fn every_fenced_sample_gets_a_copy_button_test() {
  let blocks =
    markdown.parse(
      "# T\n\nlede\n\n```sh\nmake install\n```\n\n```toml\na = 1\n```\n",
    )
  let html =
    blocks
    |> markdown.render(markdown.Host("p", None, fn(_) { element.none() }))
    |> list.map(element.to_string)
    |> string.join("")
  assert list.length(string.split(html, ">Copy<")) == 3
}

pub fn a_shell_sample_copies_its_commands_without_the_prompts_test() {
  assert code.copyable("sh", "$ make install\n$ loom --demo")
    == "make install\nloom --demo"
  assert code.copyable("sh", "$ make install\nbuilt") == "make install"
}

pub fn other_samples_copy_as_written_test() {
  assert code.copyable("sh", "make install\nloom") == "make install\nloom"
  assert code.copyable("toml", "$ not a prompt") == "$ not a prompt"
}

pub fn the_copied_label_shows_for_the_copied_sample_only_test() {
  let some = code.view("a", "sh", "ls", Some("a")) |> element.to_string
  let other = code.view("a", "sh", "ls", Some("b")) |> element.to_string
  assert string.contains(some, ">Copied<")
  assert !string.contains(other, ">Copied<")
}

// DOCUMENTATION PAGES ----------------------------------------------------------

pub fn documentation_slugs_are_unique_test() {
  let slugs = list.map(docs.pages(), fn(page) { page.slug })
  assert list.unique(slugs) == slugs
}

pub fn the_install_page_leads_the_documentation_test() {
  let assert [first, ..] = docs.pages()
  assert first.slug == "getting-started"
  assert first.title == "Install"
}

pub fn the_embedded_figure_names_exist_test() {
  list.each(figures.all(), fn(id) {
    assert msg.figure_from_key(msg.figure_key(id)) == Ok(id)
    assert figure.count(figures.spec(id)) >= 4
  })
}

// TERMINAL SCREENSHOT ---------------------------------------------------------

pub fn terminal_shot_starts_collapsed_test() {
  let html = landing_html()
  assert string.contains(html, "img/code-mode-compact.png")
  assert !string.contains(html, "src=\"./img/code-mode.png\"")
}

pub fn terminal_shot_toggle_swaps_the_image_test() {
  let model = m.Model(..m.new(route.Landing), shot_view: msg.Expanded)
  let html = element.to_string(landing.view(model))
  assert string.contains(html, "src=\"./img/code-mode.png\"")
  assert !string.contains(html, "code-mode-compact.png")
}

pub fn terminal_shot_images_have_alt_text_and_size_test() {
  let compact = landing_html()
  assert string.contains(compact, "width=\"1312\"")
  assert string.contains(compact, "alt=\"The terminal client after")
}
