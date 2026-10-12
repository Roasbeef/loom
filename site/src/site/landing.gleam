//// The landing page.
////
//// Product proof comes before the recorded task. Architecture figures live in
//// the documentation, linked from the three differentiators. The sidebar and
//// scroll spy share `sections`, including the old architecture section ids.
////
//// ## Flow
////
//// - `view` places `hero` and `clients` before the compact section navigation.
//// - `differentiators` links recovery, tool permissions and distributed work
////   to their full explanations; `more` keeps the code-mode deep link.
//// - `install` leads to source prerequisites, a demo and a first prompt.

import gleam/list
import lustre/attribute.{attribute}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import site/code
import site/inline
import site/model.{type Model}
import site/msg.{type Msg}
import site/release
import site/replay_view
import site/route
import site/ui

/// A section of the page, as the sidebar names it.
pub type Section {
  Section(id: String, label: String)
}

/// The sections in page order. The ids are the ids of the elements.
pub fn sections() -> List(Section) {
  [
    Section("clients", "Terminal and web"),
    Section("durable", "Durability"),
    Section("sandbox", "Sandboxing"),
    Section("distributed", "Distributed runtime"),
    Section("replay", "Recorded session"),
    Section("install", "Get started"),
    Section("code-mode", "Code mode"),
    Section("more", "Deeper docs"),
    Section("status", "Platforms and status"),
  ]
}

/// The ids of the sections, in page order, for the scroll spy.
pub fn section_ids() -> List(String) {
  list.map(sections(), fn(section) { section.id })
}

/// The label of a section, or an empty string for an unknown id.
pub fn label_of(id: String) -> String {
  case list.find(sections(), fn(section) { section.id == id }) {
    Ok(section) -> section.label
    Error(Nil) -> ""
  }
}

/// The landing page.
pub fn view(model: Model) -> Element(Msg) {
  html.div([attribute.class("page")], [
    ui.header(""),
    html.main([attribute.id("main"), attribute.tabindex(-1)], [
      hero(),
      clients(),
      html.div([attribute.class("landing")], [
        toc(model),
        html.div([attribute.class("landing-body")], [
          differentiators(),
          replay_view.view(model),
          install(model),
          more(),
          status(),
        ]),
      ]),
    ]),
    ui.footer(),
  ])
}

// THE TOP OF THE PAGE ----------------------------------------------------------

fn hero() -> Element(Msg) {
  html.section([attribute.class("hero"), attribute.id("top")], [
    html.div([attribute.class("hero-inner")], [
      html.div([attribute.class("hero-text")], [
        html.p([attribute.class("hero-identity")], [
          element.text("Written in Gleam. Running on the BEAM."),
        ]),
        html.h1([], [
          element.text("A coding agent harness built to recover."),
        ]),
        html.p([attribute.class("lede")], [
          element.text(
            "Work from the terminal or browser with durable sessions and sandboxed tools. Reopen committed work after a crash, branch to try another approach, and run tools beside your checkout on another machine.",
          ),
        ]),
        html.div([attribute.class("actions")], [
          ui.download_button(),
          html.a(
            [
              attribute.class("button button-quiet"),
              attribute.href(release.repo),
              attribute.target("_blank"),
              attribute.rel("noopener"),
            ],
            [element.text("View on GitHub")],
          ),
        ]),
        html.p([attribute.class("status")], [
          element.text(
            "Active development. Build from source today; release archives are not published yet.",
          ),
        ]),
      ]),
      html.div(
        [attribute.class("hero-mark"), attribute("aria-hidden", "true")],
        [ui.mark(160)],
      ),
    ]),
  ])
}

// THE SIDEBAR ------------------------------------------------------------------

/// The sticky list of sections. On a wide screen it is a column beside the
/// page. On a narrow one it is a bar under the header that shows the current
/// section and opens a list.
fn toc(model: Model) -> Element(Msg) {
  let current = label_of(model.section)
  html.nav([attribute.class("toc"), attribute("aria-label", "On this page")], [
    html.button(
      [
        attribute.class("toc-toggle"),
        attribute.type_("button"),
        attribute("aria-expanded", case model.contents_open {
          True -> "true"
          False -> "false"
        }),
        attribute("aria-controls", "toc-list"),
        event.on_click(msg.ToggleContents),
      ],
      [
        html.span([attribute.class("toc-toggle-label")], [
          element.text("On this page"),
        ]),
        html.span([attribute.class("toc-current")], [element.text(current)]),
      ],
    ),
    html.ol(
      [
        attribute.id("toc-list"),
        attribute.class(case model.contents_open {
          True -> "toc-list is-open"
          False -> "toc-list"
        }),
      ],
      list.map(sections(), fn(section) {
        html.li([], [
          html.button(
            [
              attribute.class(case section.id == model.section {
                True -> "toc-item is-current"
                False -> "toc-item"
              }),
              attribute.type_("button"),
              event.on_click(msg.JumpTo(section.id)),
              ..case section.id == model.section {
                True -> [attribute("aria-current", "location")]
                False -> []
              }
            ],
            [element.text(section.label)],
          ),
        ])
      }),
    ),
  ])
}

// THE STORIES ------------------------------------------------------------------

// Each short story retains its old anchor, while the full diagram has a stable
// documentation route. A recovery claim is qualified by committed work and
// the tool's replay policy, rather than promising to resume arbitrary effects.
fn differentiators() -> Element(Msg) {
  html.div(
    [attribute.class("differentiators")],
    list.map(
      [
        #(
          "durable",
          "Keep the work you committed",
          "A crash does not erase committed conversation history. Reopen the session to recover; interrupted tools follow their replay policy. Fork a conversation without losing the original.",
          "sessions",
          "How recovery works",
        ),
        #(
          "sandbox",
          "Give tools a boundary",
          "Commands and agent-written programs run outside the harness VM in kernel sandboxes. Calls that need more access can ask you for a specific grant.",
          "approvals-and-sandboxing",
          "Tools and approvals",
        ),
        #(
          "distributed",
          "Put execution beside the code",
          "Keep the conversation on an orchestrator and run workspace tools on an executor. Move the session between orchestrators while its checkout stays put. Automatic failover is not available.",
          "distributed-runtime",
          "Distributed work and limits",
        ),
      ],
      fn(item) {
        html.section([attribute.class("story benefit"), attribute.id(item.0)], [
          html.h2([], [element.text(item.1)]),
          inline.paragraph(item.2),
          html.a([attribute.href(route.doc(item.3))], [element.text(item.4)]),
        ])
      },
    ),
  )
}

fn clients() -> Element(Msg) {
  html.section([attribute.class("story"), attribute.id("clients")], [
    html.div([attribute.class("story-head")], [
      html.p([attribute.class("kicker")], [element.text("Terminal and browser")]),
      html.h2([], [
        element.text("One session, in your terminal and browser"),
      ]),
      html.p(
        [],
        inline.render(
          "Follow the transcript, inspect tool steps and answer approvals from either interface. Both attach to the same daemon; prompts and decisions stay in sync.",
        ),
      ),
      html.p(
        [],
        inline.render(
          "These are captures of Loom's existing interfaces. Open either image to inspect it at full size. [Using the terminal and opt-in web view](#/docs/terminal-and-web).",
        ),
      ),
    ]),
    html.div([attribute.class("shots")], [
      shot(
        "./img/web-session.png",
        "The web session view with a live transcript, collapsible tool steps, subagent status and the advisor review rail.",
        "The web session view: a live transcript with collapsible tool steps, reasoning blocks, subagent status and the advisor review rail.",
      ),
      shot(
        "./img/code-mode.png",
        "The terminal client running a code-mode program that reads three files concurrently and returns their line counts.",
        "The terminal client running a code-mode program. A scripted local provider supplies the demo; compilation, sandboxed execution and file reads are real.",
      ),
    ]),
  ])
}

fn shot(src: String, alt: String, caption: String) -> Element(Msg) {
  html.figure([attribute.class("shot")], [
    html.a(
      [
        attribute.href(src),
        attribute.target("_blank"),
        attribute.rel("noopener"),
      ],
      [
        html.img([
          attribute.src(src),
          attribute.alt(alt),
          attribute.loading("eager"),
        ]),
      ],
    ),
    html.figcaption([], [element.text(caption)]),
  ])
}

fn more() -> Element(Msg) {
  html.section([attribute.class("story"), attribute.id("code-mode")], [
    html.h2([], [element.text("Go deeper when you need to")]),
    inline.paragraph(
      "In code mode, the model writes a typed Gleam program, compiled offline and run in a jail. Each effect goes through the same checked broker. [See the program-to-result diagram](#/docs/code-mode).",
    ),
    html.div([attribute.id("more")], [
      inline.paragraph(
        "[Sessions, forks and memory](#/docs/sessions), [models and configuration](#/docs/configuration), [shared terminal and web sessions](#/docs/terminal-and-web), and [the architecture documents]("
        <> release.tree("docs/architecture")
        <> ") cover the rest of the system.",
      ),
    ]),
  ])
}

// PLATFORMS AND STATUS ---------------------------------------------------------

fn status() -> Element(Msg) {
  html.section(
    [attribute.class("story status-section"), attribute.id("status")],
    [
      html.h2([], [element.text("Development and platform status")]),
      inline.paragraph(
        "Loom is under active development. Linux x86_64 and macOS arm64 have build and sandbox test lanes in CI. The release workflow targets both, but no release archives are published yet; a workflow target is not a released binary. Linux arm64 has no release lane, and Windows is not supported.",
      ),
      inline.paragraph(
        "Linux uses bubblewrap, Landlock and seccomp; macOS uses Seatbelt and reports enforcement gaps. [Distribution and verification]("
        <> release.source("docs/distribution.md")
        <> ") and [the macOS boundary]("
        <> release.source("docs/adr/006-macos-seatbelt-boundary.md")
        <> ") describe the guarantees. License: TBD; the project has not chosen a licence.",
      ),
    ],
  )
}

// INSTALL ----------------------------------------------------------------------

fn install(model: Model) -> Element(Msg) {
  html.section([attribute.class("story install"), attribute.id("install")], [
    html.div([attribute.class("story-head")], [
      html.h2([], [element.text("Start with one prompt")]),
      inline.paragraph(
        "Build with Gleam 1.19.0, Erlang/OTP 29+, Go 1.26+, rebar3, a C compiler, make and strip. [Read the source-build prerequisites](#/docs/getting-started/build-from-source) before running these commands.",
      ),
    ]),
    code.view(
      "landing-install",
      "sh",
      "git clone https://github.com/Roasbeef/loom.git\ncd loom\nmake install\nexport PATH=\"$HOME/.local/bin:$PATH\"\nloom --demo  # explore the terminal without a provider or daemon",
      model.copied,
    ),
    inline.paragraph(
      "For real work, [configure your model and credentials](#/docs/configuration), then run `loom` in your project and choose New session. Try: \"Find the entry point, explain how it works, and suggest one small improvement.\"",
    ),
    html.div([attribute.class("actions")], [
      ui.download_button(),
      html.a(
        [
          attribute.class("button button-quiet"),
          attribute.href(release.releases_url),
        ],
        [element.text("Release status")],
      ),
    ]),
  ])
}
