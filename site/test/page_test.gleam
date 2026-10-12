//// Tests that render whole pages to HTML and read what came out. They catch
//// what a unit test of one function cannot: a sidebar entry whose section
//// does not exist, a documentation link to a branch that is not `main`, a
//// banned word in text that only appears in one step of one figure.

import gleam/int
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

// THE SIDEBAR -----------------------------------------------------------------

pub fn every_sidebar_entry_names_a_section_that_exists_test() {
  let html = landing_html()
  list.each(landing.section_ids(), fn(id) {
    assert string.contains(html, "id=\"" <> id <> "\"")
  })
}

pub fn section_ids_are_unique_test() {
  let ids = landing.section_ids()
  assert list.unique(ids) == ids
}

pub fn the_sidebar_marks_the_current_section_test() {
  let model = m.Model(..m.new(route.Landing), section: "distributed")
  let html = element.to_string(landing.view(model))
  assert string.contains(html, "aria-current=\"location\"")
  assert landing.label_of("distributed") == "Distributed runtime"
  assert landing.label_of("nowhere") == ""
}

pub fn the_sidebar_is_in_page_order_test() {
  // The scroll spy reports the last section whose top has passed the probe,
  // so the list must follow the order of the sections in the page.
  let html = landing_html()
  let positions =
    list.map(landing.section_ids(), fn(id) {
      position_of(html, "id=\"" <> id <> "\"")
    })
  assert list.all(positions, fn(position) { position >= 0 })
  assert positions == list.sort(positions, int.compare)
}

fn position_of(html: String, needle: String) -> Int {
  case string.split_once(html, needle) {
    Ok(#(before, _)) -> string.length(before)
    Error(Nil) -> -1
  }
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

pub fn the_footer_says_the_licence_is_not_chosen_test() {
  assert string.contains(landing_html(), "License: TBD")
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

pub fn open_pull_requests_are_not_claimed_test() {
  // PR #938 and PR #934 are not merged, so no page may present what they add.
  let html = landing_html()
  assert !string.contains(html, "#938")
  assert !string.contains(html, "#934")
  assert !string.contains(string.lowercase(html), "khepri")
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
