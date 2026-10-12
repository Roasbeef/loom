//// The landing page: a guided read.
////
//// Each story below is a short introduction followed by a figure. The text
//// blocks of the figure scroll beside a sticky panel, and the block under
//// the reading line decides the step. The same panel has buttons, so the
//// page works by keyboard and without scrolling.

import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute.{attribute}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import site/figure
import site/figures
import site/inline
import site/model.{type Model} as m
import site/msg.{type FigureId, type Msg}
import site/route
import site/ui

/// The landing page.
pub fn view(model: Model) -> Element(Msg) {
  html.div([attribute.class("page")], [
    ui.header(""),
    html.main([attribute.id("main"), attribute.tabindex(-1)], [
      hero(),
      facts(),
      contents(),
      story(
        model,
        "durable",
        "1",
        "Durability",
        "Loom commits a tool call twice: once before it runs and once after",
        [
          "Each session is one SQLite file that holds a write-once conversation tree. Prompts, tool intents, results, configuration and usage become durable records, and a fork shares history with its parent up to the branch point, so trying another approach leaves the original conversation intact.",
          "The processes that work on a session are a supervision tree over that file. Kill them at any instant and the file is still consistent. The figure follows one tool call through such a crash.",
        ],
        None,
        msg.Crash,
      ),
      story(
        model,
        "sandbox",
        "2",
        "Sandboxing and approval",
        "Commands run in a kernel sandbox, and widening it takes your answer",
        [
          "BEAM processes isolate faults, not untrusted code: any process in the VM can run `os:cmd` or open the network. So Loom's first rule, Rule Zero, is that nothing the model influences runs in the harness VM. Commands, agent-written programs and extensions run in separate OS processes under kernel enforcement: bubblewrap, Landlock and seccomp on Linux, and Seatbelt on macOS.",
          "Every effect leaves the harness through one door, the broker. When a call needs more access than the session grants, it is refused before anything runs, and the refusal can become a question for you. The figure follows one such question from the model to the sandbox.",
        ],
        None,
        msg.Approval,
      ),
      story(
        model,
        "code-mode",
        "3",
        "Code mode",
        "The model can write one typed program instead of ten tool calls",
        [
          "In code mode the model writes a short Gleam program. Loom vets it, compiles it offline, runs it in a jailed BEAM node and returns one structured result. Every effect the program has goes through the same broker that checks the model's direct tool calls.",
          "Gleam has no `eval`, no reflection and no dynamic module lookup, so what a program can do is bounded by its imports, and that bound can be read off the source before anything runs.",
        ],
        None,
        msg.CodeMode,
      ),
      story(
        model,
        "distributed",
        "4",
        "Distributed runtime",
        "A session on an executor can change orchestrator in six durable steps",
        [
          "A distributed Loom runs one session on two machines. The orchestrator keeps the conversation: the runtime, the session's SQLite store, approvals and provider keys. The executor keeps the checkout and runs the session's workspace tool calls beside it. They join over TLS Erlang distribution with pinned certificates.",
          "An owner can hand the conversation to another orchestrator with `sessions.move`. Ownership is two catalogue rows ordered by a write-ahead intent. A TLA+ model of the protocol checks that two orchestrators never serve the session at once. The figure has eight frames: the state before, the six steps of the protocol in order, and the state after.",
        ],
        Some(
          "In development. The distributed runtime is documented on open pull requests (issue #697, PR #923) and is not on `main` yet.",
        ),
        msg.Migration,
      ),
      clients(),
      more(),
      install(),
    ]),
    ui.footer(),
  ])
}

fn hero() -> Element(Msg) {
  html.section([attribute.class("hero"), attribute.id("top")], [
    html.div([attribute.class("hero-inner")], [
      html.div([attribute.class("hero-text")], [
        html.p([attribute.class("kicker")], [
          element.text("A coding agent harness written in Gleam, on the BEAM"),
        ]),
        html.h1([], [
          element.text(
            "Loom records each step of an agent session on disk and runs its commands in a kernel sandbox.",
          ),
        ]),
        html.p([attribute.class("lede")], [
          element.text(
            "You can close the terminal, restart the daemon and pick the work back up. When the agent needs more access than you granted, Loom shows you the exact action and waits for your answer. When ten tool calls would do, the model can write one typed program instead.",
          ),
        ]),
        html.div([attribute.class("actions")], [
          html.a(
            [
              attribute.class("button button-primary"),
              attribute.href(route.doc("getting-started")),
            ],
            [
              element.text("Install from source"),
            ],
          ),
          html.a(
            [
              attribute.class("button"),
              attribute.href(ui.repo),
              attribute.target("_blank"),
              attribute.rel("noopener"),
            ],
            [element.text("View on GitHub")],
          ),
        ]),
        html.p([attribute.class("status")], [
          element.text(
            "Loom is under active development. You build it from source on Linux or macOS. No prebuilt download is published yet.",
          ),
        ]),
      ]),
      html.div(
        [attribute.class("hero-mark"), attribute("aria-hidden", "true")],
        [
          ui.mark(240),
        ],
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
              "Gleam on the BEAM. Building it needs Erlang/OTP 29 or later.",
            ),
            #(
              "Interfaces",
              "A terminal client, `loom`, and a web view, both served by one local daemon, `loomd`.",
            ),
            #("Platforms", "Linux and macOS."),
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

fn contents() -> Element(Msg) {
  html.nav(
    [attribute.class("contents"), attribute("aria-label", "In this page")],
    [
      html.p([attribute.class("kicker")], [element.text("In this page")]),
      html.ol(
        [],
        list.map(
          [
            #("durable", "A tool call that survives a crash"),
            #("sandbox", "A command that needs more access"),
            #("code-mode", "A program in place of tool calls"),
            #("distributed", "A session that changes machines"),
          ],
          fn(entry) {
            html.li([], [
              html.button(
                [
                  attribute.class("link"),
                  attribute.type_("button"),
                  event.on_click(msg.JumpTo(entry.0)),
                ],
                [element.text(entry.1)],
              ),
            ])
          },
        ),
      ),
    ],
  )
}

fn story(
  model: Model,
  id: String,
  number: String,
  topic: String,
  title: String,
  intro: List(String),
  notice: Option(String),
  figure_id: FigureId,
) -> Element(Msg) {
  html.section([attribute.class("story"), attribute.id(id)], [
    html.div([attribute.class("story-head")], [
      html.p([attribute.class("kicker")], [
        element.text(number <> ". " <> topic),
      ]),
      html.h2([], [element.text(title)]),
      ..list.append(list.map(intro, inline.paragraph), case notice {
        Some(text) -> [html.p([attribute.class("notice")], inline.render(text))]
        None -> []
      })
    ]),
    figure.scrolly(
      figures.spec(figure_id),
      m.step(model, figure_id),
      m.is_playing(model, figure_id),
    ),
  ])
}

fn clients() -> Element(Msg) {
  html.section([attribute.class("story"), attribute.id("clients")], [
    html.div([attribute.class("story-head")], [
      html.p([attribute.class("kicker")], [
        element.text("5. Terminal and browser"),
      ]),
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
          "Several people can work in one session. The owner invites them as operators, who can direct the work and answer approvals, or as observers, who can follow without changing anything. The daemon binds to loopback only; a browser on another machine reaches it through a tunnel such as `ssh -L`.",
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
    html.img([attribute.src(src), attribute.alt(alt), attribute.loading("lazy")]),
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

fn install() -> Element(Msg) {
  html.section([attribute.class("story install"), attribute.id("install")], [
    html.div([attribute.class("story-head")], [
      html.p([attribute.class("kicker")], [element.text("Get started")]),
      html.h2([], [element.text("Build Loom from source on Linux or macOS")]),
      html.p(
        [],
        inline.render(
          "You need Gleam 1.19.0, Erlang/OTP 29 or later, Go 1.26 or later, `rebar3`, a C compiler, `make` and `strip`. `make install` builds the client, the server, the sandbox helper and the code-mode toolchain under `~/.local`, and the result bundles the BEAM runtime.",
        ),
      ),
    ]),
    html.pre([attribute.class("install-code")], [
      html.code([], [
        element.text(
          "git clone https://github.com/Roasbeef/loom.git\ncd loom\nmake install\nexport PATH=\"$HOME/.local/bin:$PATH\"\n\nloom --demo        # the terminal, with no provider and no server\nloom               # in a project: starts or reconnects to the daemon",
        ),
      ]),
    ]),
    html.div([attribute.class("actions")], [
      html.a(
        [
          attribute.class("button button-primary"),
          attribute.href(route.doc("getting-started")),
        ],
        [
          element.text("Read the install guide"),
        ],
      ),
      html.a(
        [attribute.class("button"), attribute.href(route.doc("configuration"))],
        [
          element.text("Configure a model"),
        ],
      ),
    ]),
  ])
}
