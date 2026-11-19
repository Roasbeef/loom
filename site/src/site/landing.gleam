//// The landing page.
////
//// A short page. The hero says what Loom is and where to get it. A recorded
//// session shows it working. Four stories follow, one claim each, with a
//// paragraph, a link to the documentation page and a figure the reader can
//// step through with its buttons. Then the two clients, a list of what else
//// is in the box, and how to install.
////
//// The page states each claim once and leaves the explanation to the
//// documentation. A figure here is the panel alone, and the long text of
//// each of its steps is on the documentation page that embeds the same
//// figure.
////
//// ## Flow
////
//// - `view` is the page: header, `hero`, the replay, the four `story`
////   sections, then `clients`, `more` and `install`.
//// - `story` is one claim beside its figure.

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

/// The landing page.
pub fn view(model: Model) -> Element(Msg) {
  html.div([attribute.class("page")], [
    ui.header(""),
    html.main([attribute.id("main"), attribute.tabindex(-1)], [
      hero(),
      replay_view.view(model),
      story(
        model,
        "durable",
        "Durability",
        "Kill the daemon in the middle of a tool call",
        "Every tool call is committed twice, the intent before it runs and the result after, into one SQLite file per session. Open the session again and it resumes from what was committed. A call that isn't safe to repeat, like `bash`, isn't rerun. It gets an explicit outcome-unknown result.",
        "How a session is stored",
        route.doc("sessions"),
        msg.Crash,
      ),
      story(
        model,
        "sandbox",
        "Sandboxing",
        "Commands run in a kernel sandbox",
        "Shell commands, programs the model writes and MCP servers never run in the harness VM. Each gets its own OS process, under bubblewrap and Landlock on Linux (plus seccomp when the network is off) or Seatbelt on macOS. A call that needs more access than the session has stops and asks. A once-only yes covers that exact call, by a digest of its arguments.",
        "Approvals and the sandbox",
        route.doc("approvals-and-sandboxing"),
        msg.Approval,
      ),
      story(
        model,
        "code-mode",
        "Code mode",
        "The model can write a program",
        "In code mode the model sends one short Gleam program where it would have made a string of tool calls. Gleam has no `eval` and no reflection, so what a program imports bounds what it can do. Loom vets the imports, compiles offline and runs the result in a jailed BEAM node.",
        "How code mode works",
        route.doc("code-mode"),
        msg.CodeMode,
      ),
      story(
        model,
        "distributed",
        "Distributed runtime",
        "Keys on one machine, tools on another",
        "An orchestrator holds the conversation, the provider keys and the approvals. An executor runs the tool calls next to your checkout. `loom sessions move` hands a session to another orchestrator. A TLA+ model of one move, with a crash possible between any two writes, checks that two orchestrators never serve the session at once.",
        "What remote sessions can't do yet",
        route.doc("distributed-runtime"),
        msg.Migration,
      ),
      clients(model),
      more(),
      install(model),
    ]),
    ui.footer(),
  ])
}

// THE TOP OF THE PAGE ----------------------------------------------------------

fn hero() -> Element(Msg) {
  html.section([attribute.class("hero"), attribute.id("top")], [
    html.div([attribute.class("hero-inner")], [
      html.div([attribute.class("hero-text")], [
        html.h1([], [
          element.text("A coding agent whose sessions survive a crash."),
        ]),
        html.p([attribute.class("lede")], [
          element.text(
            "Loom is a coding agent harness written in Gleam, on the BEAM. Each session is one SQLite file. Commands run in a kernel sandbox, and tool calls can run on a different machine from the one that holds your keys.",
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
        html.p(
          [attribute.class("status")],
          inline.render(
            "Under active development. Linux x86_64 and macOS arm64. [Platform status]("
            <> route.doc("getting-started")
            <> "/platforms).",
          ),
        ),
      ]),
      html.div(
        [attribute.class("hero-mark"), attribute("aria-hidden", "true")],
        [ui.mark(180)],
      ),
    ]),
  ])
}

// THE STORIES ------------------------------------------------------------------

/// One claim: a heading, a paragraph and a link to the documentation page,
/// beside the figure that shows the mechanism. The section's id is what the
/// page's own links and the tests name it by.
fn story(
  model: Model,
  id: String,
  topic: String,
  title: String,
  body: String,
  link_label: String,
  link_target: String,
  figure_id: FigureId,
) -> Element(Msg) {
  html.section([attribute.class("story claim"), attribute.id(id)], [
    html.div([attribute.class("story-head")], [
      html.p([attribute.class("kicker")], [element.text(topic)]),
      html.h2([], [element.text(title)]),
      inline.paragraph(body),
      html.p([attribute.class("more-link")], [
        html.a([attribute.href(link_target)], [element.text(link_label)]),
      ]),
    ]),
    figure.compact(
      figures.spec(figure_id),
      m.step(model, figure_id),
      m.is_playing(model, figure_id),
    ),
  ])
}

fn clients(model: Model) -> Element(Msg) {
  html.section([attribute.class("story"), attribute.id("clients")], [
    html.div([attribute.class("story-head")], [
      html.p([attribute.class("kicker")], [element.text("Clients")]),
      html.h2([], [element.text("A terminal and a browser on one session")]),
      html.p(
        [],
        inline.render(
          "Both attach to one daemon, `loomd`. A prompt typed in one shows up in the other, and either can answer an approval. The web view is opt-in with `--ui` and listens on loopback only. [Terminal and web]("
          <> route.doc("terminal-and-web")
          <> ").",
        ),
      ),
    ]),
    html.div([attribute.class("shots")], [
      shot(
        "./img/web-session.png",
        "The web session view with a live transcript, collapsible tool steps, subagent status and the advisor review rail.",
        "The web view of a session.",
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
      html.h2([], [element.text("Also in Loom")]),
    ]),
    html.dl(
      [attribute.class("rows")],
      list.flat_map(
        [
          #(
            "Multiplayer",
            "Invite operators who can drive a session and observers who can only watch. Every prompt and approval records who sent it. [Guide]("
              <> release.source("docs/guide/multiplayer.md")
              <> ").",
          ),
          #(
            "Self-evolution",
            "The agent can write its own extensions, programs and prompt profiles. You approve one exact version, and authored code runs in a jail. Local workspaces only for now. [How it works]("
              <> route.doc("self-evolution")
              <> ").",
          ),
          #(
            "Subagents",
            "Run in parallel on their own conversation branch and report back to the parent.",
          ),
          #(
            "Model routing",
            "Each role gets a list of models to try in order, across Anthropic, OpenAI-compatible, OpenAI Responses and Gemini.",
          ),
          #(
            "Advisor and goals",
            "A second model can review the first one's work. An operator can pin a goal that Loom keeps working toward across runs.",
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

// INSTALL ----------------------------------------------------------------------

fn install(model: Model) -> Element(Msg) {
  html.section([attribute.class("story install"), attribute.id("install")], [
    html.div([attribute.class("story-head")], [
      html.p([attribute.class("kicker")], [element.text("Get started")]),
      html.h2([], [element.text("Install Loom")]),
      html.p(
        [],
        inline.render(
          "Download a release, or build it. Building needs Gleam 1.19.0, Erlang/OTP 29 or later, Go 1.26 or later, `rebar3`, a C compiler, `make` and `strip`. `loom --demo` runs with no provider. For real work you bring a provider key, and [the install guide]("
          <> route.doc("getting-started")
          <> "/choose-a-model) shows where it goes.",
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
  ])
}
