//// Figure: code mode, from a program to a result.
////
//// Sources: `docs/code-mode.md` and `docs/architecture/code-mode.md`
//// ("The pipeline", "Layer one: vetting", "The prelude is the capability
//// system", "Program modes and capability admission"), and `docs/loom-design.md`
//// section 6. The program is the first example in `docs/code-mode.md`.

import gleam/option.{None, Some}
import lustre/attribute
import lustre/element.{type Element}
import site/figure.{type Spec, Sample, Spec, Step}
import site/msg.{type Msg}
import site/svgx.{cls, text}

const program = "import cap/fs
import cap/report
import cap/task
import gleam/list
import gleam/result
import gleam/string

pub fn main() -> report.Outcome {
  let paths = [\"README.md\", \"docs/loom-design.md\", \"docs/code-mode.md\"]
  case task.parallel_map(paths, max_concurrency: 3, with: line_count) {
    Ok(counts) ->
      list.zip(paths, counts)
      |> list.map(fn(pair) { #(pair.0, report.int(pair.1)) })
      |> report.object
      |> report.value
    Error(failures) -> report.failure(string.inspect(failures))
  }
}

fn line_count(path: String) -> Result(Int, fs.FsError) {
  use text <- result.map(fs.read(path))
  list.length(string.split(text, \"\\n\"))
}"

/// The words of every step.
pub fn spec() -> Spec {
  Spec(id: msg.CodeMode, title: "Code mode: from a program to a result", steps: [
    Step(
      label: "The task",
      tag: "",
      caption: "Three files, one question: how many lines does each have?",
      heading: "Three tool calls would be three round trips",
      body: [
        "A tool call is a round trip. The model emits a call, the harness runs it, and the result returns as context for the next turn. Counting the lines of three files that way takes three turns, and all three file texts land in the context although the model wanted only the counts.",
        "In code mode the model writes one program instead.",
      ],
      state: [
        #("Without code mode", "three model turns, three file texts in the context"),
        #("With code mode", "one execution, one result"),
      ],
      sample: None,
      failure: None,
    ),
    Step(
      label: "Write",
      tag: "",
      caption: "The model submits a Gleam program through the code_mode tool.",
      heading: "The model writes a Gleam program",
      body: [
        "The program imports capability modules: `cap/fs`, `cap/task` and `cap/report`. The import list is its permission set. It did not import `cap/proc` or `cap/net`, so it cannot run a command or open a connection, whatever its logic computes.",
        "The model submits it as `{\"program\": \"...\", \"seam\": \"workspace\"}`. A saved program can be run again by path with `program_path`.",
      ],
      state: [
        #("Can do", "read files, concurrently"),
        #("Cannot do", "run a command, use the network, start an agent"),
      ],
      sample: Some(Sample("The program", program)),
      failure: None,
    ),
    Step(
      label: "Vet",
      tag: "",
      caption: "A lint in the harness rejects anything outside the capability modules.",
      heading: "Vetting reads the source, not the behaviour",
      body: [
        "Vetting parses the source with `glance` and applies exact rules. It rejects any `@external` and, failing closed, any attribute at all, because `@external` is Gleam's only bridge to arbitrary Erlang. It rejects any import outside the allowlist: the capability prelude and a fixed pure part of the standard library. A token-level scan backs up the parser.",
        "This works because Gleam has no `eval`, no reflection, no macros and no dynamic module lookup. A program's maximal capabilities can be read off its imports without running it.",
      ],
      state: [
        #("Where", "the harness VM, a pure function"),
        #("Result", "pass, or `VetRejected` with a reason"),
      ],
      sample: None,
      failure: Some("A rejection comes back to the model as an ordinary result that it can fix."),
    ),
    Step(
      label: "Compile",
      tag: "",
      caption: "The compiler builds the program inside the jail, offline.",
      heading: "A hermetic build, and the type checker checks every argument",
      body: [
        "`gleam build --warnings-as-errors` runs in the sandbox, offline, against a pinned and vendored prelude. The program is written to a path the compile service chooses, `loom_program.gleam`, so it cannot shadow `cap/fs` with a module of its own.",
        "The type checker also validates every tool argument. A wrong call fails here, before any node starts.",
      ],
      state: [
        #("Where", "the kernel jail"),
        #("Result", "a build, or `CompileFailed` with the compiler's diagnostics"),
      ],
      sample: None,
      failure: Some("A build that fails only on unused imports, arguments or bindings is rewritten and retried once, automatically."),
    ),
    Step(
      label: "Run",
      tag: "",
      caption: "A fresh satellite node starts in the jail and runs the program.",
      heading: "The program runs in a disposable BEAM node",
      body: [
        "The satellite starts with Erlang distribution disabled, so it cannot reach or join another node. It has no network, enforced by seccomp and an empty network namespace. A cgroup, a CPU limit and a wall-clock deadline bound it, and it is destroyed when the program returns.",
        "Its only link to the outside is one Unix socket that carries framed `cap_call` and `cap_result` messages.",
      ],
      state: [
        #("Distribution", "disabled"),
        #("Network", "none"),
        #("Deadline", "five minutes by default, fifteen at most"),
      ],
      sample: None,
      failure: None,
    ),
    Step(
      label: "Call capabilities",
      tag: "",
      caption: "Each fs.read is a cap_call over the socket, checked by the broker.",
      heading: "Every effect is one checked call",
      body: [
        "`task.parallel_map` runs the three reads at once. Each `fs.read` becomes a `cap_call` frame carrying the execution's token. The broker checks the token, the session policy and the strand's tools, performs the read, and answers with a `cap_result`.",
        "A capability that needs a tool the strand does not hold, such as `proc.run` without `bash`, is refused with `tool_not_held`. All calls share one budget: a cap on outstanding effects, six by default, and one deadline.",
      ],
      state: [
        #("Checked", "execution token, session policy, the strand's tools"),
        #("Budget", "six outstanding effects by default, pooled across the program"),
      ],
      sample: None,
      failure: None,
    ),
    Step(
      label: "Return",
      tag: "",
      caption: "Only the structured result reaches the model.",
      heading: "The model receives one value",
      body: [
        "`main` returns a `report.Outcome`. The harness marshals it back and the satellite is destroyed. The three file texts never entered the conversation: the model sees a map from each path to its line count.",
      ],
      state: [
        #("Success", "`Ran`, carrying the program's outcome"),
        #("Failure", "`RunFailed`, as an ordinary result"),
      ],
      sample: None,
      failure: None,
    ),
  ])
}

/// The drawing for a step.
pub fn drawing(step: Int) -> Element(Msg) {
  svgx.root(560, 450, "A program passes vetting, compiles and runs in a jail, and calls the broker", [
    svgx.defs(),
    // The model.
    svgx.group([cls("node", [#("is-hot", step <= 1 || step == 6)])], [
      svgx.rect(14, 30, 120, 192, [attribute.class("node-box")]),
      text(26, 56, "Model", [attribute.class("t t-strong")]),
      text(26, 76, "one strand", [attribute.class("t t-sm")]),
      svgx.rect(24, 140, 100, 72, [cls("inner", [#("is-hot", step == 6)])]),
      text(34, 160, "context", [attribute.class("t t-sm t-dim")]),
      text(34, 180, context_line_one(step), [attribute.class("t t-sm")]),
      text(34, 198, context_line_two(step), [attribute.class("t t-sm")]),
    ]),
    // The harness: vet and broker.
    svgx.rect(154, 30, 392, 192, [attribute.class("zone zone-trust")]),
    text(168, 50, "Harness VM, trusted", [attribute.class("t t-sm t-dim")]),
    svgx.group([cls("node", [#("is-hot", step == 2)])], [
      svgx.rect(168, 64, 168, 148, [attribute.class("node-box")]),
      text(180, 88, "Vet", [attribute.class("t t-strong")]),
      check(180, 108, "no @external", step >= 2),
      check(180, 130, "imports on allowlist", step >= 2),
      check(180, 152, "token-stream backstop", step >= 2),
      text(180, 192, "else VetRejected", [attribute.class("t t-sm t-dim")]),
    ]),
    svgx.group([cls("node", [#("is-hot", step == 5)])], [
      svgx.rect(358, 64, 174, 148, [attribute.class("node-box")]),
      text(370, 88, "ToolBroker", [attribute.class("t t-strong")]),
      check(370, 108, "execution token", step >= 5),
      check(370, 130, "session policy", step >= 5),
      check(370, 152, "strand holds the tool", step >= 5),
      text(370, 192, "serves or refuses", [attribute.class("t t-sm t-dim")]),
    ]),
    // The jail: build and satellite.
    svgx.rect(14, 244, 532, 192, [attribute.class("zone zone-jail")]),
    text(270, 264, "Kernel jail, untrusted", [attribute.class("t t-sm t-dim")]),
    svgx.group([cls("node", [#("is-hot", step == 3)])], [
      svgx.rect(30, 278, 200, 146, [attribute.class("node-box")]),
      text(42, 302, "gleam build", [attribute.class("t t-strong")]),
      text(42, 326, "offline, warnings are errors", [attribute.class("t t-sm")]),
      text(42, 346, "vendored cap prelude", [attribute.class("t t-sm")]),
      text(42, 366, "loom_program.gleam", [attribute.class("t t-sm t-mono")]),
      text(42, 404, "else CompileFailed", [attribute.class("t t-sm t-dim")]),
    ]),
    satellite(step),
    // Arrows between the stages.
    svgx.line(134, 130, 166, 130, [cls("wire", [#("is-on", step == 1)])]),
    svgx.path("M 252 212 V 260 H 130 V 276", [cls("wire", [#("is-on", step == 3)])]),
    svgx.line(230, 350, 248, 350, [cls("wire", [#("is-on", step == 4)])]),
    svgx.line(445, 276, 445, 214, [cls("wire", [#("is-on", step == 5)])]),
    svgx.path("M 445 64 V 20 H 74 V 28", [cls("wire wire-return", [#("is-on", step == 6)])]),
    text(260, 14, "outcome", [cls("t t-sm t-dim mid wire-label", [#("is-on", step == 6)])]),
    // Capability calls travelling along the socket.
    svgx.group([cls("flow", [#("is-on", step == 5)])], [
      svgx.circle(445, 270, 5, [attribute.class("pkt pkt-a")]),
      svgx.circle(445, 270, 5, [attribute.class("pkt pkt-b")]),
      svgx.circle(445, 270, 5, [attribute.class("pkt pkt-c")]),
    ]),
    text(436, 238, "cap_call, cap_result", [cls("t t-sm t-dim end wire-label", [#("is-on", step == 5)])]),
  ])
}

fn context_line_one(step: Int) -> String {
  case step {
    6 -> "one result:"
    _ -> "no tool output"
  }
}

fn context_line_two(step: Int) -> String {
  case step {
    6 -> "3 line counts"
    _ -> "yet"
  }
}

fn check(x: Int, y: Int, label: String, on: Bool) -> Element(Msg) {
  svgx.group([cls("check", [#("is-on", on)])], [
    svgx.circle(x + 5, y - 4, 4, [attribute.class("check-dot")]),
    text(x + 18, y, label, [attribute.class("t t-sm")]),
  ])
}

fn satellite(step: Int) -> Element(Msg) {
  let alive = step >= 4 && step <= 5
  svgx.group(
    [
      cls("node satellite", [
        #("is-hot", step == 4 || step == 5),
        #("is-gone", step == 6),
      ]),
    ],
    [
      svgx.rect(250, 278, 280, 146, [attribute.class("node-box")]),
      text(262, 302, "Satellite, a BEAM node", [attribute.class("t t-strong")]),
      text(262, 322, "no distribution, no network", [attribute.class("t t-sm")]),
      chip(262, "fs.read", alive, step == 5, 0),
      chip(344, "fs.read", alive, step == 5, 120),
      chip(426, "fs.read", alive, step == 5, 240),
      text(262, 396, "cgroup, CPU limit, wall deadline", [attribute.class("t t-sm t-dim")]),
      text(262, 414, case step {
        6 -> "destroyed: the program returned"
        _ -> "destroyed when the program returns"
      }, [attribute.class("t t-sm t-dim")]),
    ],
  )
}

fn chip(x: Int, label: String, shown: Bool, busy: Bool, delay: Int) -> Element(Msg) {
  svgx.group(
    [cls("chip", [#("is-hidden", !shown), #("is-busy", busy)]), svgx.delay(delay)],
    [
      svgx.rect(x, 338, 72, 28, [attribute.class("chip-box")]),
      text(x + 36, 357, label, [attribute.class("t t-sm mid t-mono")]),
    ],
  )
}
