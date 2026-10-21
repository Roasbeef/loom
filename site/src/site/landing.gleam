//// The landing page.
////
//// A short guided read. The hero says what Loom is, a recorded
//// session shows it working, and then one section each for durability, the
//// distributed runtime and working together, followed by the two clients,
//// the sandbox, code mode, the platforms and how to install. The durable,
//// sandbox, code-mode and distributed sections each carry a step-through
//// figure: the text blocks scroll beside a sticky panel, and the block under
//// the reading line decides the step. The panel also has buttons, so the page
//// works by keyboard and without scrolling.
////
//// A sticky sidebar lists the sections and marks the one in view. On a
//// phone it becomes an "On this page" control under the header.
////
//// ## Flow
////
//// - `sections` is the list the sidebar and the scroll spy share.
//// - `view` is the page: header, hero, then the sidebar beside the sections.
//// - `story` is one figure's section; `multiplayer`, `clients`, `more`,
////   `status` and `install` are the rest.

import gleam/list
import lustre/attribute.{attribute}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import site/code
import site/figure
import site/figures
import site/inline
import site/model.{type Model} as m
import site/msg.{type FigureId, type Msg, type ShotView}
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
    Section("replay", "Recorded session"),
    Section("durable", "Durability"),
    Section("distributed", "Distributed runtime"),
    Section("multiplayer", "Working together"),
    Section("clients", "Terminal and web"),
    Section("sandbox", "Sandboxing"),
    Section("code-mode", "Code mode"),
    Section("more", "Also in Loom"),
    Section("status", "Platforms and status"),
    Section("install", "Install"),
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
      html.div([attribute.class("landing")], [
        toc(model),
        html.div([attribute.class("landing-body")], [
          replay_view.view(model),
          story(
            model,
            "durable",
            "Durability",
            "A crash doesn't lose your session",
            [
              "Kill the daemon mid-tool-call and nothing committed is lost. Every prompt, tool call and result goes into one SQLite file as it happens, so the file is always consistent. Sessions are OTP supervision trees, so a crash in one strand restarts only that strand.",
              "You can also fork a session to try another approach without losing the first. The figure kills the daemon mid-tool-call.",
            ],
            msg.Crash,
          ),
          story(
            model,
            "distributed",
            "Distributed runtime",
            "The model and the tools don't have to share a machine",
            [
              "Provider keys and history stay on one server while the tools run on the machine that has your code. The orchestrator holds the conversation, the keys and approvals. The executor holds your checkout and runs tool calls. They connect over Erlang distribution on TLS with pinned certificates.",
              "You can move a session to another orchestrator with `loom sessions move`. We model-checked the move in TLA+, with a crash possible between any two writes, to make sure two orchestrators never both own a session. [What remote sessions can't do yet](#/docs/distributed-runtime).",
            ],
            msg.Migration,
          ),
          multiplayer(),
          clients(model),
          story(
            model,
            "sandbox",
            "Sandboxing and approval",
            "Commands run in a kernel sandbox",
            [
              "Anything the model can influence runs in a separate sandboxed OS process, never in the harness itself. We call that Rule Zero. The sandbox is bubblewrap, Landlock and seccomp on Linux, and Seatbelt on macOS. If a call needs more access than the session grants, it's refused before it runs, and you can approve it.",
            ],
            msg.Approval,
          ),
          story(
            model,
            "code-mode",
            "Code mode",
            "One typed program instead of ten tool calls",
            [
              "In code mode the model writes a short Gleam program. Loom vets it, compiles it offline, runs it in a jailed BEAM node and returns one structured result. Gleam has no `eval` and no reflection, so a program can only do what its imports allow, and you can check that by reading it before it runs.",
            ],
            msg.CodeMode,
          ),
          more(),
          status(),
          install(model),
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
        html.p([attribute.class("kicker")], [element.text("Loom")]),
        html.h1([], [element.text("A durable, distributed coding harness.")]),
        html.p([attribute.class("lede")], [
          element.text(
            "Loom runs coding agents without losing work when something dies. A session keeps its history on disk, the tools can run on your dev box while the model runs somewhere else, and a few people can share one session. It's written in Gleam and runs on the BEAM.",
          ),
        ]),
        html.div([attribute.class("actions")], [
          ui.download_button(),
          html.a(
            [
              attribute.class("button"),
              attribute.href(
                route.doc("getting-started") <> "/build-from-source",
              ),
            ],
            [element.text("Build from source")],
          ),
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
            "Under active development. Linux x86_64 and macOS arm64.",
          ),
        ]),
      ]),
      html.div(
        [attribute.class("hero-mark"), attribute("aria-hidden", "true")],
        [ui.mark(240)],
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

fn story(
  model: Model,
  id: String,
  topic: String,
  title: String,
  intro: List(String),
  figure_id: FigureId,
) -> Element(Msg) {
  html.section([attribute.class("story"), attribute.id(id)], [
    html.div([attribute.class("story-head")], [
      html.p([attribute.class("kicker")], [element.text(topic)]),
      html.h2([], [element.text(title)]),
      ..list.map(intro, inline.paragraph)
    ]),
    figure.scrolly(
      figures.spec(figure_id),
      m.step(model, figure_id),
      m.is_playing(model, figure_id),
      model.copied,
    ),
  ])
}

fn multiplayer() -> Element(Msg) {
  html.section([attribute.class("story"), attribute.id("multiplayer")], [
    html.div([attribute.class("story-head")], [
      html.p([attribute.class("kicker")], [element.text("Multiplayer")]),
      html.h2([], [element.text("Several people can work in one session")]),
      html.p(
        [],
        inline.render(
          "Two people can drive one agent session, or one drives and others watch. The owner invites operators, who can direct the work and answer approvals, and observers, who can only watch. Everyone you invite attaches from their own terminal or browser and sees the transcript and tool steps live, and every command is tagged with who sent it. [The multiplayer guide]("
          <> release.source("docs/guide/multiplayer.md")
          <> ") walks through it.",
        ),
      ),
    ]),
  ])
}

fn clients(model: Model) -> Element(Msg) {
  html.section([attribute.class("story"), attribute.id("clients")], [
    html.div([attribute.class("story-head")], [
      html.p([attribute.class("kicker")], [element.text("Terminal and browser")]),
      html.h2([], [element.text("Terminal and browser, same session")]),
      html.p(
        [],
        inline.render(
          "Use the terminal, the browser, or both on the same session. A prompt typed in one shows up in the other, and an approval answered in either settles it. The daemon, `loomd`, hosts the sessions. The web view needs `--ui` and listens on loopback only, so use `ssh -L` to reach it from another machine.",
        ),
      ),
    ]),
    html.div([attribute.class("shots")], [
      shot(
        "./img/web-session.png",
        "The web session view with a live transcript, collapsible tool steps, subagent status and the advisor review rail.",
        "The web session view: a live transcript with collapsible tool steps, reasoning blocks, subagent status and the advisor review rail.",
      ),
      terminal_shot(model.shot_view),
    ]),
  ])
}

/// The terminal capture, collapsed by default, with a pair of buttons that
/// swap in the capture with the tool details expanded. Both images are 2x
/// renders shown at half their pixel size, so the text stays sharp on a
/// high-density screen. The figure keeps one `img` at a time; the buttons
/// are `aria-pressed` toggles so a screen reader hears the current choice.
fn terminal_shot(chosen: ShotView) -> Element(Msg) {
  let #(src, alt, width, height) = case chosen {
    msg.Compact -> #(
      "./img/code-mode-compact.png",
      "The terminal client after a code-mode program read three files concurrently, with the tool call collapsed to a card showing the first lines of the program, the three reads and the result.",
      1312,
      1140,
    )
    msg.Expanded -> #(
      "./img/code-mode.png",
      "The terminal client with the code-mode tool call expanded: the whole Gleam program, the JSON result with the line count of each of three files, and the three file reads.",
      1312,
      1646,
    )
  }
  html.figure([attribute.class("shot")], [
    html.div(
      [
        attribute.class("shot-toggle"),
        attribute("role", "group"),
        attribute("aria-label", "Terminal screenshot detail"),
      ],
      [
        shot_button("Compact", msg.Compact, chosen),
        shot_button("Expanded", msg.Expanded, chosen),
      ],
    ),
    html.img([
      attribute.src(src),
      attribute.alt(alt),
      attribute.width(width),
      attribute.height(height),
      attribute.loading("lazy"),
    ]),
    html.figcaption([], [
      element.text(
        "The terminal client running a code-mode program. A scripted local provider supplies the demo; compilation, sandboxed execution and file reads are real.",
      ),
    ]),
  ])
}

fn shot_button(
  label: String,
  option: ShotView,
  chosen: ShotView,
) -> Element(Msg) {
  html.button(
    [
      attribute.class("btn btn-play"),
      attribute.type_("button"),
      attribute("aria-pressed", case option == chosen {
        True -> "true"
        False -> "false"
      }),
      event.on_click(msg.ShotViewChosen(option)),
    ],
    [element.text(label)],
  )
}

fn shot(src: String, alt: String, caption: String) -> Element(Msg) {
  html.figure([attribute.class("shot")], [
    html.img([
      attribute.src(src),
      attribute.alt(alt),
      attribute.loading("lazy"),
    ]),
    html.figcaption([], [element.text(caption)]),
  ])
}

fn more() -> Element(Msg) {
  html.section([attribute.class("story more"), attribute.id("more")], [
    html.div([attribute.class("story-head")], [
      html.p([attribute.class("kicker")], [element.text("Also in Loom")]),
      html.h2([], [element.text("Also included")]),
    ]),
    html.dl(
      [attribute.class("rows")],
      list.flat_map(
        [
          #(
            "Subagents",
            "Run in parallel on their own conversation branch and send results back to the parent.",
          ),
          #(
            "Model routing",
            "Each role gets a list of models to try in order, across Anthropic, OpenAI-compatible, OpenAI Responses and Gemini.",
          ),
          #(
            "Advisor and goals",
            "A second model can review the primary's work, and an operator can pin a goal that Loom works toward across runs.",
          ),
          #(
            "Language servers",
            "Definitions, references, diagnostics and rename, run in the jail. Profiles for Gleam, Go and Rust.",
          ),
          #(
            "MCP and extensions",
            "MCP servers show up as typed modules in code mode. Extensions are Gleam programs that run sandboxed with declared capabilities.",
          ),
          #(
            "Memory and automation",
            "Search earlier sessions, schedule prompts and run background jobs.",
          ),
        ],
        fn(row) {
          [
            html.dt([], [element.text(row.0)]),
            html.dd([], inline.render(row.1)),
          ]
        },
      ),
    ),
  ])
}

// PLATFORMS AND STATUS ---------------------------------------------------------

fn status() -> Element(Msg) {
  html.section(
    [attribute.class("story status-section"), attribute.id("status")],
    [
      html.div([attribute.class("story-head")], [
        html.p([attribute.class("kicker")], [
          element.text("Platforms and status"),
        ]),
        html.h2([], [
          element.text("What runs where today"),
        ]),
        html.p(
          [],
          inline.render(
            "A release is built for one platform, because it carries the BEAM runtime and a native SQLite library that were built on that platform. The table says what the release workflow builds and what enforces the sandbox on each platform. The sources are [docs/distribution.md]("
            <> release.source("docs/distribution.md")
            <> ") and [ADR-006]("
            <> release.source("docs/adr/006-macos-seatbelt-boundary.md")
            <> ").",
          ),
        ),
      ]),
      table(["Platform", "Release archives", "Sandbox", "State"], [
        [
          "Linux x86_64",
          "Built twice on separate runners and compared byte for byte.",
          "bubblewrap and Landlock, seccomp when the network is off, cgroup v2 limits where a cgroup is delegated.",
          "Built and smoke-tested in CI.",
        ],
        [
          "macOS arm64",
          "Built twice on native macOS runners and compared byte for byte.",
          "Seatbelt, with enforcement gaps that the helper reports.",
          "The release lane is new, and its first hosted comparison has not run.",
        ],
        [
          "Linux arm64",
          "None. The release workflow does not build it.",
          "The sandbox code targets arm64. It has never been run.",
          "The release build has never been run.",
        ],
        [
          "Windows",
          "None.",
          "None.",
          "Not supported. The design lists it as a later milestone.",
        ],
      ]),
      html.div([attribute.class("story-head status-notes")], [
        html.h3([], [element.text("What the distributed runtime has and lacks")]),
        html.p(
          [],
          inline.render(
            "On `main` it has one orchestrator with one executor, executor pools, two orchestrators with peer mail between them, and `sessions.move`. It has no failover and cannot move a session between executors. A remote session refuses extension tools, operator-added directories, background code mode and MCP façades in code mode, and a move does not carry running processes. The list is the one in [the architecture page]("
            <> release.source("docs/architecture/distributed.md")
            <> ").",
          ),
        ),
      ]),
    ],
  )
}

/// The heading of a column, for the label a phone shows beside a cell.
fn cell_label(head: List(String), index: Int) -> String {
  case list.drop(head, index) {
    [label, ..] -> label
    [] -> ""
  }
}

/// A table whose first column heads its rows.
fn table(head: List(String), rows: List(List(String))) -> Element(Msg) {
  html.div([attribute.class("table-wrap status-table")], [
    html.table([], [
      html.thead([], [
        html.tr(
          [],
          list.map(head, fn(cell) {
            html.th([attribute("scope", "col")], [element.text(cell)])
          }),
        ),
      ]),
      html.tbody(
        [],
        list.map(rows, fn(row) {
          case row {
            [first, ..rest] ->
              html.tr([], [
                html.th([attribute("scope", "row")], [element.text(first)]),
                ..list.index_map(rest, fn(cell, index) {
                  html.td(
                    [attribute("data-label", cell_label(head, index + 1))],
                    inline.render(cell),
                  )
                })
              ])
            [] -> html.tr([], [])
          }
        }),
      ),
    ]),
  ])
}

// INSTALL ----------------------------------------------------------------------

fn install(model: Model) -> Element(Msg) {
  html.section([attribute.class("story install"), attribute.id("install")], [
    html.div([attribute.class("story-head")], [
      html.p([attribute.class("kicker")], [element.text("Get started")]),
      html.h2([], [element.text("Install Loom")]),
      html.p(
        [],
        inline.render(
          "Download the server and a client, check them against `SHA256SUMS`, and put their `bin` directories on your `PATH`. After that, `loom update` installs later releases.",
        ),
      ),
    ]),
    html.div([attribute.class("actions")], [
      ui.download_button(),
      html.a(
        [
          attribute.class("button"),
          attribute.href(route.doc("getting-started")),
        ],
        [element.text("Read the install guide")],
      ),
    ]),
    html.div([attribute.class("story-head install-source")], [
      html.h3([], [element.text("Or build from source")]),
      html.p(
        [],
        inline.render(
          "You need Gleam 1.19.0, Erlang/OTP 29 or later, Go 1.26 or later, `rebar3`, a C compiler, `make` and `strip`. `make install` builds the client, the server, the sandbox helper and the code-mode toolchain under `~/.local`.",
        ),
      ),
    ]),
    html.div([attribute.class("install-code")], [
      code.view(
        "landing-install",
        "sh",
        "git clone https://github.com/Roasbeef/loom.git\ncd loom\nmake install\nexport PATH=\"$HOME/.local/bin:$PATH\"\n\nloom --demo        # the terminal, with no provider and no server\nloom               # in a project: starts or reconnects to the daemon",
        model.copied,
      ),
    ]),
  ])
}
