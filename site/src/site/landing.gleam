//// The landing page.
////
//// A guided read. It opens with what Loom is, then a recorded session
//// (`site/replay_view`), then four short stories, each a few paragraphs and
//// a step-through figure, then the clients, the other parts, the platforms
//// and how to install. The text blocks of a figure scroll beside a sticky
//// panel, and the block under the reading line decides the step. The same
//// panel has buttons, so the page works by keyboard and without scrolling.
////
//// A sticky sidebar lists the sections and marks the one in view. On a
//// phone it becomes an "On this page" control under the header.
////
//// ## Flow
////
//// - `sections` is the list the sidebar and the scroll spy share.
//// - `view` is the page: header, hero, at-a-glance facts, then the sidebar
////   beside the sections.
//// - `story` is one figure's section, `clients`, `more`, `status` and
////   `install` are the rest.

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
    Section("sandbox", "Sandboxing"),
    Section("code-mode", "Code mode"),
    Section("distributed", "Distributed runtime"),
    Section("clients", "Terminal and web"),
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
      facts(),
      html.div([attribute.class("landing")], [
        toc(model),
        html.div([attribute.class("landing-body")], [
          replay_view.view(model),
          story(
            model,
            "durable",
            "Durability",
            "Each session is a process tree over a write-once file, and it commits a tool call twice",
            [
              "Each session is one SQLite file that holds a write-once conversation tree. Prompts, tool intents, results, configuration and usage become durable records, and a fork shares history with its parent up to the branch point, so trying another approach leaves the original conversation intact.",
              "The processes that work on a session are an OTP supervision tree over that file. A crash in one strand restarts only that strand, and killing the whole tree at any instant leaves the file consistent. The figure follows one tool call through such a kill.",
            ],
            msg.Crash,
          ),
          story(
            model,
            "sandbox",
            "Sandboxing and approval",
            "Commands run in a kernel sandbox, and widening it takes your answer",
            [
              "BEAM processes isolate faults, not untrusted code: any process in the VM can run `os:cmd` or open the network. So Loom's first rule, Rule Zero, is that nothing the model influences runs in the harness VM. Commands, agent-written programs and extensions run in separate OS processes under kernel enforcement: bubblewrap, Landlock and a seccomp network filter on Linux, and Seatbelt on macOS.",
              "Every command and every code-mode capability call goes through one door, the broker, and the native file tools check their own paths in the harness. When a call needs more access than the session grants, it is refused before anything runs, and the refusal can become a question for you. The figure follows one such question from the model to the sandbox.",
            ],
            msg.Approval,
          ),
          story(
            model,
            "code-mode",
            "Code mode",
            "The model can write one typed program instead of ten tool calls",
            [
              "In code mode the model writes a short Gleam program. Loom vets it, compiles it offline, runs it in a jailed BEAM node and returns one structured result. Every effect the program has goes through the same broker that checks the model's direct tool calls.",
              "Gleam has no `eval`, no reflection and no dynamic module lookup, so what a program can do is bounded by its imports, and that bound can be read off the source before anything runs.",
            ],
            msg.CodeMode,
          ),
          story(
            model,
            "distributed",
            "Distributed runtime",
            "A session's runtime and its tool calls can run on different machines, and the session can move",
            [
              "A distributed Loom runs one session on two machines. The orchestrator keeps the conversation: the runtime, the session's SQLite store, approvals and provider keys. The executor keeps the checkout and runs the session's workspace tool calls beside it. They join over TLS Erlang distribution with pinned certificates. Executors can be grouped into pools, and two orchestrators can list each other as peers.",
              "An owner can hand the conversation to another orchestrator with `loom sessions move`. Ownership is two catalogue rows ordered by a write-ahead intent, and a TLA+ model of one move, with a crash possible between any two writes, checks that two orchestrators never serve the session at once. The figure has eight frames: the state before, the six steps of the protocol in order, and the state after. [The distributed runtime page](#/docs/distributed-runtime) lists what a remote session cannot do yet.",
            ],
            msg.Migration,
          ),
          clients(model),
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
        html.h1([], [
          element.text(
            "A coding agent harness written in Gleam, running on the BEAM.",
          ),
        ]),
        html.p([attribute.class("lede")], [
          element.text(
            "Each session is an OTP supervision tree over a write-once SQLite file, so a crashed process is restarted by its supervisor and a killed daemon loses no committed work. Commands run in kernel sandboxes. A distributed runtime puts a session's runtime on an orchestrator and its tool calls on executors, and lets a session move from one orchestrator to another.",
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
            "Loom is under active development. The release workflow builds Linux x86_64 and macOS arm64.",
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

fn facts() -> Element(Msg) {
  html.section(
    [attribute.class("facts"), attribute("aria-label", "At a glance")],
    [
      html.dl(
        [],
        list.flat_map(
          [
            #(
              "Language",
              "Gleam, on Erlang/OTP 29 or later. A release bundles the BEAM runtime.",
            ),
            #(
              "Interfaces",
              "A terminal client, `loom`, and an opt-in web view. Both attach to one local daemon, `loomd`.",
            ),
            #(
              "Sandbox",
              "bubblewrap, Landlock and seccomp on Linux. Seatbelt on macOS.",
            ),
            #(
              "State",
              "A SQLite file per session, with a write-once conversation tree.",
            ),
          ],
          fn(fact) {
            [
              html.div([], [
                html.dt([], [element.text(fact.0)]),
                html.dd([], inline.render(fact.1)),
              ]),
            ]
          },
        ),
      ),
    ],
  )
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

fn clients(model: Model) -> Element(Msg) {
  html.section([attribute.class("story"), attribute.id("clients")], [
    html.div([attribute.class("story-head")], [
      html.p([attribute.class("kicker")], [element.text("Terminal and browser")]),
      html.h2([], [
        element.text(
          "The terminal and the web view are two clients of one daemon",
        ),
      ]),
      html.p(
        [],
        inline.render(
          "`loomd` hosts every session on one machine. The terminal client `loom` and the browser page both attach to it, so a prompt typed in one appears in the other, and an approval answered in either settles the question for both.",
        ),
      ),
      html.p(
        [],
        inline.render(
          "Several people can work in one session. The owner invites them as operators, who can direct the work and answer approvals, or as observers, who can follow without changing anything. The daemon's web listener binds to loopback only; a browser on another machine reaches it through a tunnel such as `ssh -L`. The web view is off until you start the daemon with `--ui`.",
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
      html.h2([], [element.text("Other parts of the system")]),
    ]),
    html.dl(
      [attribute.class("rows")],
      list.flat_map(
        [
          #(
            "Subagents",
            "A subagent is a strand with its own conversation branch and configuration. Strands run concurrently, exchange durable messages and return structured results to a parent.",
          ),
          #(
            "Model routing",
            "A catalogue names model endpoints and routes roles to ordered fallback chains. Anthropic, OpenAI-compatible, OpenAI Responses and Gemini adapters share one orchestration layer.",
          ),
          #(
            "Advisor and goals",
            "A second model can review the primary's work in a separate conversation and send a nudge or a blocking verdict. With an advisor, an operator can pin a goal that Loom works toward across runs.",
          ),
          #(
            "Language servers",
            "Definitions, references, hover, diagnostics and rename run through language servers in the jail. Profiles exist for Gleam, Go and Rust.",
          ),
          #(
            "MCP and extensions",
            "A configured MCP server becomes a typed module in code mode. Installed Gleam extensions run outside the harness VM with declared capabilities.",
          ),
          #(
            "Memory and automation",
            "Loom can search earlier sessions, keep workspace memory, deliver scheduled prompts and run bounded background jobs.",
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
          element.text(
            "The release workflow builds Linux and macOS, and the distributed runtime is in the main branch",
          ),
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
      html.h2([], [element.text("Install Loom from a release or from source")]),
      html.p(
        [],
        inline.render(
          "A release is a set of archives for one platform, with a manifest and `SHA256SUMS`. You download the server and a client, check them, unpack them and put their `bin` directories on your `PATH`. `loom update` then installs later releases for you.",
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
